local ui = tern.ui
local title = "Herdr for Tern"
local opened, sessions = {}, {}
local request = 0
local herdr

local function valid_name(name)
	return type(name) == "string" and #name > 0 and #name <= 64
		and string.match(name, "^[%w_.-]+$") ~= nil
end

local function button(label, action)
	return ui.el("button", { text = label, actions = { click = action } })
end

local function version_key(name)
	local key = {}
	for digits in string.gmatch(name, "%d+") do table.insert(key, tonumber(digits) or 0) end
	return key
end

local function is_newer(a, b)
	for i = 1, math.max(#a, #b) do
		local x, y = a[i] or -1, b[i] or -1
		if x ~= y then return x > y end
	end
	return false
end

local function herdr_in(directory)
	for _, name in { "herdr.exe", "herdr" } do
		local path = directory .. "/" .. name
		if tern.fs.exists(path) then return path end
	end
	return nil
end

-- Tern looks the program up on the PATH of its own process, which a desktop
-- launch can have smaller than the shell's, so a bare `herdr` may be missing
-- there. Herdr's own install layout is checked before giving up.
local function find_herdr()
	for _, name in { "HERDR_BIN", "HERDR_BIN_PATH" } do
		local explicit = tern.getenv(name)
		if explicit and #explicit > 0 and tern.fs.exists(explicit) then return explicit end
	end
	local home = tern.getenv("USERPROFILE") or tern.getenv("HOME")
	local standalone = home and (home .. "/.herdr/packages/standalone")
	if standalone then
		local current = herdr_in(standalone .. "/current")
		if current then return current end
		local listed, entries = pcall(tern.fs.list, standalone .. "/releases")
		local best, best_key
		for _, entry in listed and entries or {} do
			local path = herdr_in(standalone .. "/releases/" .. entry)
			local key = version_key(entry)
			if path and (not best or is_newer(key, best_key)) then best, best_key = path, key end
		end
		if best then return best end
	end
	return "herdr"
end

local function herdr_bin()
	if not herdr then herdr = find_herdr() end
	return herdr
end

local function attach_command(name)
	local bin = herdr_bin()
	if string.find(bin, "%s") then bin = '"' .. bin .. '"' end
	return bin .. " --session=" .. name
end

-- Draw through canvas:set, which the daemon authorises from the stored creator
-- id. Do not gate on canvas:get: this window's replica of a canvas can still be
-- empty when a process callback runs, and treating that as "not ours" dropped
-- every update, leaving the picker on its first line with nothing logged.
local function draw(cx, pane, message, rows)
	local children = { ui.text(message) }
	for _, row in rows or {} do table.insert(children, row) end
	table.insert(children, button("Refresh sessions", "refresh"))
	local ok, err = pcall(cx.canvas.set, cx.canvas, pane, { view = ui.card(title, children) })
	if not ok then tern.log.warn("Herdr for Tern: could not draw the session picker", tostring(err)) end
	return ok
end

local function own_picker(cx)
	for _, canvas in cx.canvas:list() do
		if canvas.owner == tern.plugin.id and canvas.title == title then return canvas.pane end
	end
	return nil
end

local function program_name(program)
	return string.lower(string.match(program, "([^/\\]+)$") or program)
end

local function refresh(cx, pane)
	request += 1
	local revision = request
	sessions = {}
	herdr = nil
	local bin = herdr_bin()
	draw(cx, pane, "Reading local Herdr sessions...")
	local ok, err = pcall(function()
		tern.process.run({ bin, "session", "list", "--json" }, { timeout_ms = 10000 }, function(result, fresh)
			if revision ~= request then return end
			if not fresh then
				tern.log.warn("Herdr for Tern: the session list had no window context to draw in")
				return
			end
			if result.timed_out or result.status ~= 0 then
				draw(fresh, pane, "Could not list sessions: " .. (if result.timed_out then "Herdr timed out." else string.sub(result.stderr, 1, 1500)))
				return
			end
			local decoded, data = pcall(tern.json.decode, result.stdout)
			if not decoded or type(data) ~= "table" or type(data.sessions) ~= "table" then
				draw(fresh, pane, "Herdr returned an invalid session list.")
				return
			end
			local rows = {}
			for _, session in data.sessions do
				if type(session) ~= "table" or not valid_name(session.name) then
					draw(fresh, pane, "Herdr returned an unsupported session name.")
					return
				end
				sessions[session.name] = session
				local state = if session.running then "running" else "saved; starts on open"
				table.insert(rows, if session.connection_error then ui.text(session.name .. ": " .. tostring(session.connection_error))
					else button(session.name .. " (" .. state .. ")", "open." .. session.name))
			end
			draw(fresh, pane, if #rows == 0 then "No local sessions found." else "Choose a session:", rows)
		end)
	end)
	if not ok then
		draw(cx, pane, "Could not run " .. bin .. ". Put Herdr on the PATH Tern sees, or set HERDR_BIN. " .. tostring(err))
	end
end

tern.command({ id = "open", title = "Open Herdr Session", icon = "terminal", run = function(cx)
	-- Listing and attaching must use the same local host.
	cx.hosts:switch("local")
	local pane = own_picker(cx)
	if pane then
		cx.layout:focus(pane)
	else
		local opened_pane, err = cx.canvas:open({ title = title, view = ui.text("Reading local Herdr sessions..."), how = "tab",
			about = "Attach existing local Herdr sessions. Their tabs, panes and programs stay in Herdr." })
		if not opened_pane then cx:toast("error", "Herdr session picker unavailable", err or "Canvases unavailable."); return end
		pane = opened_pane
	end
	refresh(cx, pane)
end })

tern.on("canvas_action", function(ev, cx)
	if ev.owner ~= tern.plugin.id then return nil end
	if ev.act == "refresh" then refresh(cx, ev.pane); return true end
	local name = string.match(ev.act, "^open%.(.+)$")
	if not name then return nil end
	local session = sessions[name]
	if not valid_name(name) or not session or session.connection_error then
		draw(cx, ev.pane, "Session unavailable. Refresh the list.")
		return true
	end
	local existing = opened[name]
	local pane = existing and cx.session:pane(existing)
	local program = program_name(pane and pane.program or "")
	if pane and (pane.kind == "terminal" or pane.kind == "agent")
		and (program == "herdr" or program == "herdr.exe")
		and pane.exited == nil and pane.error == nil and pane.at_prompt ~= true then
		cx.layout:focus(existing)
		return true
	end
	local ok, terminal = pcall(function()
		return cx.hosts:terminal("local", { command = attach_command(name) })
	end)
	if not ok then
		draw(cx, ev.pane, "Could not open " .. name .. ": " .. tostring(terminal))
	else
		opened[name] = terminal
		local tab = cx.session:tab_of(terminal)
		if tab then cx.layout:name_tab(tab, "Herdr / " .. name) end
	end
	return true
end)
