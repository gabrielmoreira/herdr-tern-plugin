local ui = tern.ui
local title = "Herdr for Tern"
local opened, sessions = {}, {}
local picker, request = nil, 0

local function valid_name(name)
	return type(name) == "string" and #name > 0 and #name <= 64
		and string.match(name, "^[%w_.-]+$") ~= nil
end

local function button(label, action)
	return ui.el("button", { text = label, actions = { click = action } })
end

local function owned(cx, pane)
	local canvas = pane and cx.canvas:get(pane)
	return canvas ~= nil and canvas.owner == tern.plugin.id
end

local function update(cx, pane, message, rows)
	if not owned(cx, pane) then return end
	local children = { ui.text(message) }
	for _, row in rows or {} do table.insert(children, row) end
	table.insert(children, button("Refresh sessions", "refresh"))
	cx.canvas:set(pane, { view = ui.card(title, children) })
end

local function refresh(cx, pane)
	request += 1
	local revision = request
	sessions = {}
	update(cx, pane, "Reading local Herdr sessions...")
	local ok, err = pcall(function()
		tern.process.run({ "herdr", "session", "list", "--json" }, { timeout_ms = 10000 }, function(result, fresh)
			if not fresh or revision ~= request or not owned(fresh, pane) then return end
			if result.timed_out or result.status ~= 0 then
				update(fresh, pane, "Could not list sessions: " .. (if result.timed_out then "Herdr timed out." else string.sub(result.stderr, 1, 1500)))
				return
			end
			local decoded, data = pcall(tern.json.decode, result.stdout)
			if not decoded or type(data) ~= "table" or type(data.sessions) ~= "table" then
				update(fresh, pane, "Herdr returned an invalid session list.")
				return
			end
			local rows = {}
			for _, session in data.sessions do
				if type(session) ~= "table" or not valid_name(session.name) then
					update(fresh, pane, "Herdr returned an unsupported session name.")
					return
				end
				sessions[session.name] = session
				local status = if session.running then "running" else "saved; starts on open"
				table.insert(rows, if session.connection_error then ui.text(session.name .. ": " .. tostring(session.connection_error))
					else button(session.name .. " (" .. status .. ")", "open." .. session.name))
			end
			update(fresh, pane, if #rows == 0 then "No local sessions found." else "Choose a session:", rows)
		end)
	end)
	if not ok then update(cx, pane, "Could not run herdr. Check Tern's PATH. " .. tostring(err)) end
end

tern.command({ id = "open", title = "Open Herdr Session", icon = "terminal", run = function(cx)
	-- Listing and attaching must use the same local host.
	cx.hosts:switch("local")
	if not owned(cx, picker) then
		picker = nil
		for _, canvas in cx.canvas:list() do
			if canvas.owner == tern.plugin.id and canvas.title == title then picker = canvas.pane; break end
		end
	end
	if picker then
		cx.layout:focus(picker)
	else
		local pane, err = cx.canvas:open({ title = title, view = ui.text("Reading local Herdr sessions..."), how = "tab",
			about = "Attach existing local Herdr sessions. Their tabs, panes and programs stay in Herdr." })
		if not pane then cx:toast("error", "Herdr session picker unavailable", err or "Canvases unavailable."); return end
		picker = pane
	end
	refresh(cx, picker)
end })

tern.on("canvas_action", function(ev, cx)
	if ev.owner ~= tern.plugin.id or not owned(cx, ev.pane) then return nil end
	if ev.act == "refresh" then refresh(cx, ev.pane); return true end
	local name = string.match(ev.act, "^open%.(.+)$")
	if not name then return nil end
	local session = sessions[name]
	if not valid_name(name) or not session or session.connection_error then
		update(cx, ev.pane, "Session unavailable. Refresh the list.")
		return true
	end
	local existing = opened[name]
	local pane = existing and cx.session:pane(existing)
	local program = string.lower(pane and pane.program or "")
	if pane and (pane.kind == "terminal" or pane.kind == "agent")
		and (program == "herdr" or program == "herdr.exe")
		and pane.exited == nil and pane.error == nil and pane.at_prompt ~= true then
		cx.layout:focus(existing)
		return true
	end
	local ok, terminal = pcall(function()
		return cx.hosts:terminal("local", { command = "herdr --session=" .. name })
	end)
	if not ok then
		update(cx, ev.pane, "Could not open " .. name .. ": " .. tostring(terminal))
	else
		opened[name] = terminal
		local tab = cx.session:tab_of(terminal)
		if tab then cx.layout:name_tab(tab, "Herdr / " .. name) end
	end
	return true
end)
