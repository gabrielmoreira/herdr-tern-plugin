local ui = tern.ui
local title = "Herdr for Tern"
local opened, sessions, session_list = {}, {}, {}
local chosen
local step = "sessions"
local workspaces
-- Where an import lands: nil is a session Tern creates, else the name of a Tern
-- session that already exists. `destinations` is that session list, read when
-- the import step opens.
local target
local destinations
-- Defined further down; the destination row needs it before it is assigned.
local free_session_name
local request = 0
-- Count reads in flight, cancelled when a newer refresh starts.
local pending = {}
local importing = 0
local herdr
local searched = {}

local about = "Pick a local Herdr session: open its client in a Tern tab, or import picked workspaces into Tern as one session or one per workspace. Herdr keeps running."

local function valid_name(name)
	return type(name) == "string" and #name > 0 and #name <= 64
		and string.match(name, "^[%w_.-]+$") ~= nil
end

-- Tern resets a bare button to plain text, so the picker's buttons carry a role
-- of ours that window.css turns into a real control.
local function action_button(label, act, tone)
	return ui.el("button", { text = label, actions = { click = act }, role = "herdr-tern-plugin.action", tone = tone })
end

-- Herdr discovery: the binary the plugin launches, wherever it is installed.
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

-- Where Herdr's own installer and the package managers put the binary. Tern
-- looks a program up on the PATH of its own process, which a desktop launch can
-- have smaller than the shell's, so a bare `herdr` can be missing there.
local function herdr_dirs()
	local home = tern.getenv("USERPROFILE") or tern.getenv("HOME")
	local local_app_data = tern.getenv("LOCALAPPDATA")
	local dirs = {}
	if home then
		local standalone = home .. "/.herdr/packages/standalone"
		table.insert(dirs, standalone .. "/current")
		table.insert(dirs, standalone .. "/bin")
		table.insert(dirs, home .. "/.local/bin")
		table.insert(dirs, home .. "/.local/share/mise/shims")
		table.insert(dirs, home .. "/.cargo/bin")
		table.insert(dirs, home .. "/.nix-profile/bin")
	end
	if local_app_data then table.insert(dirs, local_app_data .. "/mise/shims") end
	for _, dir in { "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/nix/var/nix/profiles/default/bin" } do
		table.insert(dirs, dir)
	end
	return dirs
end

local function find_herdr()
	local tried = {}
	for _, name in { "HERDR_BIN", "HERDR_BIN_PATH" } do
		local explicit = tern.getenv(name)
		if explicit and #explicit > 0 then
			if tern.fs.exists(explicit) then return explicit end
			table.insert(tried, name .. "=" .. explicit)
		end
	end
	for _, directory in herdr_dirs() do
		local path = herdr_in(directory)
		if path then return path end
		table.insert(tried, directory)
	end
	local home = tern.getenv("USERPROFILE") or tern.getenv("HOME")
	local releases = home and (home .. "/.herdr/packages/standalone/releases")
	local listed, entries = pcall(tern.fs.list, releases or "")
	local best, best_key
	for _, entry in listed and entries or {} do
		local path = herdr_in(releases .. "/" .. entry)
		local key = version_key(entry)
		if path and (not best or is_newer(key, best_key)) then best, best_key = path, key end
	end
	if best then return best end
	searched = tried
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

-- Both palette commands open the same picker; the command's own action comes
-- first. Open attaches the live Herdr client in a Tern tab; Import opens a
-- second step that picks the workspaces and how they land in Tern.
local modes = {
	open = { hint = "Pick a session to show its Herdr client in a Tern tab." },
	import = { hint = "Pick a session to copy into Tern. The next step picks the workspaces and whether they land as one session or one per workspace. Herdr keeps running." },
}
local mode = "open"

-- Picker UI: the canvas lifecycle plus the picker's rows and actions.
-- The picker canvas. A reload can race the canvas replica: the first command
-- in the new VM may not see the old canvas, open a second one, and then every
-- draw and keyed set would land in whichever the list happens to name first
-- while the user looks at the other. Prefer the picker sharing the focused
-- pane's tab, keep that one, and close the duplicates.
local function own_picker(cx)
	local pickers = {}
	for _, canvas in cx.canvas:list() do
		if canvas.owner == tern.plugin.id and canvas.title == title then table.insert(pickers, canvas.pane) end
	end
	if #pickers == 0 then return nil end
	if #pickers == 1 then return pickers[1] end
	local focused = cx.session:focused()
	local tab = focused and cx.session:tab_of(focused)
	local keep
	for _, pane in ipairs(pickers) do
		if tab and cx.session:tab_of(pane) == tab then keep = pane end
	end
	keep = keep or pickers[#pickers]
	for _, pane in ipairs(pickers) do
		if pane ~= keep then pcall(function() cx.layout:close(pane) end) end
	end
	return keep
end

-- Draw through canvas:set, which the daemon authorises from the stored creator
-- id. Do not gate on canvas:get: this window's replica of a canvas can still be
-- empty when a process callback runs, and treating that as "not ours" dropped
-- every update, leaving the picker on its first line with nothing logged.
-- A plugin reload (a linked plugin, or Tern reloading after a file change)
-- invalidates the canvas handles an earlier VM held, and its in-flight process
-- callbacks land in the new VM holding a stale pane, so resolve the picker's
-- canvas in the current VM, retry with it, and re-open the canvas when even the
-- resolved handle is rejected, which re-claims it in this VM.
local function draw(cx, pane, message, children)
	local body = { ui.text({ ui.span(message, "muted") }) }
	local hint = modes[mode].hint
	if hint then table.insert(body, ui.text({ ui.span(hint, "muted") })) end
	for _, child in ipairs(children or {}) do table.insert(body, child) end
	-- canvas:set takes the document, canvas:open takes the bare node; handing
	-- the document to open draws "canvas node needs string k" into the log.
	local card = ui.card(title, body)
	local document = { view = card }
	local target = own_picker(cx) or pane
	local ok, err = pcall(cx.canvas.set, cx.canvas, target, document)
	if not ok then
		local live = own_picker(cx)
		if live and live ~= target then ok, err = pcall(cx.canvas.set, cx.canvas, live, document) end
	end
	if not ok then
		local reopened, opened = pcall(function()
			return cx.canvas:open({ title = title, view = card, how = "tab", about = about })
		end)
		if reopened and opened ~= nil and opened ~= false then
			ok = true
		else
			ok, err = false, tostring(opened)
		end
	end
	if not ok then tern.log.warn("Herdr for Tern: could not draw the session picker", tostring(err)) end
	return ok
end

-- Herdr saves every session's live structure next to its socket, and the
-- session list hands that directory over, so the picker reads what a session
-- holds without starting another process: each process already costs a console
-- window on Windows. A missing or unreadable state only drops the peek.
local function saved_workspaces(session)
	local dir = type(session.session_dir) == "string" and session.session_dir or nil
	if not dir then return nil end
	local ok, text = pcall(tern.fs.read, dir .. "/session.json", 524288)
	if not ok then return nil end
	local decoded, state = pcall(tern.json.decode, text)
	if not decoded or type(state) ~= "table" or type(state.workspaces) ~= "table" then return nil end
	local out = {}
	for index, workspace in ipairs(state.workspaces) do
		local label = (type(workspace.custom_name) == "string" and #workspace.custom_name > 0 and workspace.custom_name)
			or (type(workspace.identity_cwd) == "string" and string.match(workspace.identity_cwd, "([^/\\]+)[/\\]*$"))
			or ("workspace " .. tostring(index))
		table.insert(out, {
			-- Herdr allows the same workspace label twice, and Tern rejects
			-- duplicate child keys, so rows carry the workspace's id. The saved
			-- state names it `id`; the import snapshot names it `workspace_id`,
			-- and both hold the same value, which is what the wanted set joins on.
			key = tostring(workspace.id or index),
			label = label,
			tabs = type(workspace.tabs) == "table" and #workspace.tabs or 0,
		})
	end
	return out
end

-- Counts with their plural, so labels read as prose.
local function counted(number, word)
	return number .. " " .. word .. (if number == 1 then "" else "s")
end

local function session_detail(session)
	local base = if session.running then "running" else "starts when opened"
	if not session.peek then return base end
	local tabs = 0
	for _, workspace in ipairs(session.peek) do tabs += workspace.tabs end
	return base .. " · " .. counted(#session.peek, "workspace") .. " · " .. counted(tabs, "tab")
end

-- One collapsible section per session: collapsed it carries the counts,
-- expanded it shows the workspaces the session holds. The key keeps a
-- section's identity, so the user's expansion survives refreshes, and
-- clicking a section picks that session for the action under the list. A
-- landing count replaces just this section through a keyed canvas:set.
local function session_section(session)
	local head = {
		ui.span(session.name, "strong"),
		ui.span("  " .. session_detail(session), "muted"),
	}
	local rows = {}
	for _, workspace in ipairs(session.peek or {}) do
		table.insert(rows, {
			label = { ui.span(workspace.label) },
			detail = counted(workspace.tabs, "tab"),
			icon = "folder",
		})
	end
	local body = {
		ui.row({ ui.badge(if session.running then "running" else "stopped", if session.running then "accent" else "muted") }),
	}
	if #rows > 0 then
		local list = ui.list(rows)
		local list_props = list.p or {}
		list_props.role = "herdr-tern-plugin.rows"
		list.p = list_props
		table.insert(body, list)
	else
		-- While the read is in flight the section says so: "No saved
		-- workspaces to show." reads as a fact about a session still loading.
		local empty = if session.peek_tried then "No saved workspaces to show." else "Reading saved workspaces…"
		table.insert(body, ui.text({ ui.span(empty, "muted") }))
	end
	local node = ui.section(head, body)
	local props = node.p or {}
	props.key = session.name
	props.role = "herdr-tern-plugin.session"
	props.collapsible = true
	props.collapsed = session.name ~= chosen
	props.actions = { click = "pick=" .. session.name }
	if session.name == chosen then props.tone = "accent" end
	node.p = props
	return node
end

local function session_sections()
	local sections = {}
	for _, session in ipairs(session_list) do
		table.insert(sections, session_section(session))
	end
	if #sections == 0 then return ui.text({ ui.span("No local sessions found.", "muted") }) end
	local col = ui.col(sections)
	-- The key is what the timer's keyed canvas:set path starts from: a bare
	-- section key does not resolve below the root, and the canvas appends the
	-- node after the actions row instead of replacing it in place.
	local props = col.p or {}
	props.key = "sessions"
	col.p = props
	return col
end

-- The import step: one row per saved workspace, each row its own choice, so
-- what lands in Tern is decided before anything runs.
local function workspace_list()
	local items = {}
	for _, workspace in ipairs(workspaces) do
		table.insert(items, {
			-- Selection reads from the row's mark alone: tinting every picked
			-- row accent turns a fully picked list into a wall of blue.
			label = { ui.span(workspace.label, if workspace.selected then nil else "muted") },
			detail = counted(workspace.tabs, "tab"),
			icon = "folder",
			tone = if workspace.selected then nil else "muted",
		})
	end
	local node = ui.list(items)
	local node_props = node.p or {}
	node_props.role = "herdr-tern-plugin.rows"
	node.p = node_props
	for index, child in ipairs(node.c or {}) do
		local item = child.p or {}
		item.key = workspaces[index].key
		item.actions = { click = "toggle=" .. workspaces[index].key }
		if workspaces[index].selected then item.mark = "pick" end
		child.p = item
	end
	local props = node.p or {}
	props.key = "workspaces"
	props.max = { lines = 10 }
	props.empty = { ui.span("No saved workspaces to pick from.", "muted") }
	node.p = props
	return node
end

-- Where the picked workspaces land. A session Tern creates is named after the
-- Herdr session, and the row spells out the name it would really take, so a
-- taken name shows the number it would get instead of pretending otherwise. Any
-- existing session can be the destination instead, which is how an import joins
-- the session it was mirrored from before.
local function destination_section(cx)
	local suggested = free_session_name(cx, "Herdr " .. chosen)
	local items = {
		{
			label = { ui.span("New session ", "muted"), ui.span(suggested, "strong") },
			detail = "creates it",
			tone = if target == nil then "accent" else "muted",
		},
	}
	for _, session in ipairs(destinations or {}) do
		table.insert(items, {
			label = { ui.span(session.name, "strong") },
			detail = if session.current then "current session" else "existing session",
			icon = "terminal",
			tone = if target == session.name then "accent" else "muted",
		})
	end
	local node = ui.list(items)
	for index, child in ipairs(node.c or {}) do
		local item = child.p or {}
		local session = (destinations or {})[index - 1]
		item.key = if session then "dest-" .. tostring(session.id) else "dest-new"
		item.actions = { click = if session then "dest=" .. session.name else "dest_new" }
		if (session and target == session.name) or (not session and target == nil) then item.mark = "pick" end
		child.p = item
	end
	local props = node.p or {}
	props.key = "destination"
	props.max = { lines = 6 }
	props.role = "herdr-tern-plugin.rows"
	node.p = props
	local choice = if target then 'into "' .. target .. '"' else 'new session "' .. suggested .. '"'
	local head = { ui.span("Destination", "strong"), ui.span("  " .. choice, "muted") }
	local section = ui.section(head, { node })
	local section_props = section.p or {}
	section_props.key = "destination-section"
	section_props.collapsible = true
	section_props.collapsed = false
	section.p = section_props
	return section
end

local function picked_counts()
	local workspaces_picked, tabs_picked = 0, 0
	for _, workspace in ipairs(workspaces or {}) do
		if workspace.selected then
			workspaces_picked += 1
			tabs_picked += workspace.tabs
		end
	end
	return workspaces_picked, tabs_picked
end

local function picker_actions()
	local actions = {}
	if step == "workspaces" then
		if workspaces then
			local count, tabs = picked_counts()
			if target then
				if count > 0 then
					table.insert(actions, action_button(
						'Into "' .. target .. '" (' .. counted(tabs, "tab") .. ")", "import_run=one", "accent"))
					table.insert(actions, action_button(
						'Tabs as panes into "' .. target .. '" (' .. counted(tabs, "pane") .. ")", "import_run=panes"))
				end
			elseif count > 0 then
				table.insert(actions, action_button(
					"One session (" .. counted(tabs, "tab") .. ")", "import_run=one", "accent"))
				table.insert(actions, action_button(
					counted(count, "session") .. ", one per workspace (" .. counted(tabs, "tab") .. ")", "import_run=split"))
				table.insert(actions, action_button(
					"Tabs as panes, one tab per workspace (" .. counted(tabs, "pane") .. ")", "import_run=panes"))
			end
		elseif target then
			table.insert(actions, action_button('All workspaces into "' .. target .. '"', "import_run=one", "accent"))
			table.insert(actions, action_button('All workspaces as tabs of panes into "' .. target .. '"', "import_run=panes"))
		else
			table.insert(actions, action_button("All workspaces in one session", "import_run=one", "accent"))
			table.insert(actions, action_button("All workspaces as one session per workspace", "import_run=split"))
			table.insert(actions, action_button("All workspaces as tabs of panes", "import_run=panes"))
		end
		table.insert(actions, action_button("Back", "back"))
		return ui.row(actions)
	end
	local session = chosen and sessions[chosen]
	if mode == "open" then
		if session then table.insert(actions, action_button('Open "' .. chosen .. '" in a tab', "open=" .. chosen, "accent")) end
	elseif session and session.running then
		table.insert(actions, action_button('Import "' .. chosen .. '"', "import=" .. chosen, "accent"))
	end
	table.insert(actions, action_button("Refresh sessions", "refresh"))
	return ui.row(actions)
end

local function picker_message()
	if step == "workspaces" then
		if workspaces then
			return 'Import "' .. chosen .. '": pick the workspaces, then where they land.'
		end
		return 'Import "' .. chosen .. '": the saved workspaces could not be read, so the import brings them all.'
	end
	if mode == "import" and chosen and sessions[chosen] and not sessions[chosen].running then
		return "That session is not running. Start it in Herdr first."
	end
	return "Choose a session:"
end

local function draw_picker(cx, pane)
	local body = {}
	if step == "workspaces" then
		if workspaces then
			table.insert(body, workspace_list())
			-- The list caps its height, so count what is below the fold.
			local hidden = #workspaces - 10
			if hidden > 0 then
				table.insert(body, ui.text({ ui.span("Scroll the list for " .. counted(hidden, "more workspace") .. ".", "muted") }))
			end
		end
		table.insert(body, ui.rule(""))
		table.insert(body, destination_section(cx))
	else
		table.insert(body, session_sections())
	end
	table.insert(body, picker_actions())
	draw(cx, pane, picker_message(), body)
end

local function program_name(program)
	return string.lower(string.match(program, "([^/\\]+)$") or program)
end

-- Import reads a session snapshot and mirrors the picked workspaces as Tern
-- sessions, tabs and panes running the same programs in the same directories.
-- The Herdr session keeps running: the mirror is a copy, not a move.

local function launch_of(pane)
	local cwd = if type(pane.cwd) == "string" and #pane.cwd > 0 then pane.cwd else nil
	local command = if type(pane.agent) == "string" and #pane.agent > 0 then pane.agent else nil
	return { cwd = cwd, command = command }
end

local function matching(items, key, value)
	local out = {}
	for _, item in ipairs(items or {}) do
		if type(item) == "table" and item[key] == value then table.insert(out, item) end
	end
	return out
end

-- A copy sorted by Herdr's public numbers: table.sort mutates in place, and
-- the decoded snapshot the views were built from must stay as it arrived.
local function sorted_by_number(items)
	local out = {}
	for _, item in ipairs(items or {}) do table.insert(out, item) end
	table.sort(out, function(a, b) return (a.number or 0) < (b.number or 0) end)
	return out
end

-- A tab's panes ordered the way its split tree reads: top to bottom, then left
-- to right. Splits are rebuilt left to right, so this keeps the mirror's shape
-- close to the original for the common row and column layouts.
local function panes_of_tab(snapshot, tab_id)
	local rects = {}
	for _, layout in ipairs(snapshot.layouts or {}) do
		if layout.tab_id == tab_id then
			for _, leaf in ipairs(layout.panes or {}) do rects[leaf.pane_id] = leaf.rect or {} end
		end
	end
	local panes = matching(snapshot.panes, "tab_id", tab_id)
	table.sort(panes, function(a, b)
		local ra, rb = rects[a.pane_id] or {}, rects[b.pane_id] or {}
		if (ra.y or 0) ~= (rb.y or 0) then return (ra.y or 0) < (rb.y or 0) end
		if (ra.x or 0) ~= (rb.x or 0) then return (ra.x or 0) < (rb.x or 0) end
		return tostring(a.pane_id) < tostring(b.pane_id)
	end)
	return panes
end

local function first_leaf(tree)
	while type(tree) == "table" and not tree.pane do tree = tree[1] end
	return type(tree) == "table" and tree.pane or nil
end

-- The pane a fresh session starts with, looked up through its own tab so a
-- close can never reach a pane of another session.
local function initial_pane(cx, session_id)
	local ok, listed = pcall(function() return cx.session:sessions() end)
	for _, info in ipairs(ok and listed or {}) do
		if info.id == session_id then
			local tab = (info.tabs or {})[1]
			local layout = tab and cx.session:layout(tab)
			if layout and layout.root then return first_leaf(layout.root) end
		end
	end
	return nil
end

free_session_name = function(cx, base)
	local used = {}
	local ok, listed = pcall(function() return cx.sessions:list() end)
	for _, session in ipairs(ok and listed or {}) do
		if type(session.name) == "string" then used[session.name] = true end
	end
	local name, index = base, 2
	while used[name] and index <= 20 do
		name = base .. " (" .. index .. ")"
		index += 1
	end
	return name
end

-- One planned Tern tab per Herdr tab. Tern has one level of tabs where Herdr
-- has workspaces holding tabs, so a workspace holding several tabs prefixes its
-- name; a workspace holding one names its tab from the tab's own label, and a
-- tab Herdr only numbered keeps the workspace's name.
local function plan_tabs(label, tabs, snapshot)
	local plans = {}
	for _, tab in ipairs(tabs) do
		local own = if type(tab.label) == "string" and tab.label ~= tostring(tab.number) then tab.label else nil
		table.insert(plans, {
			title = if #tabs > 1 then label .. " - " .. (own or tostring(tab.number or 1)) else (own or label),
			panes = panes_of_tab(snapshot, tab.tab_id),
		})
	end
	return plans
end

-- Panes mode: one plan per workspace, and each Herdr tab contributes only its
-- first pane, so a workspace holding several tabs reads as panes of one Tern
-- tab. A tab with its own split keeps the first pane and says so in the skip
-- list, because a Tern pane cannot hold a group.
local function plan_panes(label, tabs, snapshot, skipped)
	local panes = {}
	for _, tab in ipairs(tabs) do
		local own = if type(tab.label) == "string" and tab.label ~= tostring(tab.number) then tab.label else tostring(tab.number or 1)
		local leaves = panes_of_tab(snapshot, tab.tab_id)
		if leaves[1] then
			table.insert(panes, leaves[1])
			if #leaves > 1 then
				table.insert(skipped, label .. " - " .. own .. " (first of " .. #leaves .. " panes)")
			end
		end
	end
	if #panes == 0 then return nil end
	return { title = label, panes = panes }
end

-- A tab spec laying the panes out in columns of two (three when there are
-- many), so a workspace reads as a grid instead of one narrow strip. Splits
-- carry no ratio: `even` levels the shares once the tree is built.
local function grid_spec(title, panes)
	local count = #panes
	local rows = if count <= 6 then 2 else 3
	local root
	for column = math.ceil(count / rows), 1, -1 do
		local first = (column - 1) * rows + 1
		local side
		for row = math.min(column * rows, count), first, -1 do
			local leaf = { launch = launch_of(panes[row]) }
			side = if side == nil then leaf else { split = "down", [1] = leaf, [2] = side }
		end
		root = if root == nil then side else { split = "right", [1] = side, [2] = root }
	end
	root.name = title
	return root
end

-- Creates one Tern tab per plan (and its panes) in the current session; returns
-- how many landed and the titles that could not be built.
local function build_plans(cx, plans)
	local tabs_made, panes_made, failed = 0, 0, {}
	for _, plan in ipairs(plans) do
		-- A tab whose panes are gone still lands, as a plain shell tab.
		local spec = if #plan.panes > 0 then grid_spec(plan.title, plan.panes) else { name = plan.title }
		local tab, err = cx.layout:tab(spec)
		if tab then
			cx.layout:even(tab)
			tabs_made += 1
			panes_made += if #plan.panes > 0 then #plan.panes else 1
		else
			table.insert(failed, plan.title .. (if err then " (" .. err .. ")" else ""))
		end
	end
	return tabs_made, panes_made, failed
end

local function import_into(cx, name, snapshot, wanted, mode, destination)
	cx.hosts:switch("local")
	local sessions_made, tabs_made, panes_made, skipped = 0, 0, 0, {}
	local groups = {}
	for index, workspace in ipairs(sorted_by_number(snapshot.workspaces)) do
		local label = workspace.label or ("workspace " .. tostring(workspace.number or 1))
		-- The wanted set is keyed by workspace id, so two workspaces sharing
		-- a label stay separate choices.
		if wanted and not wanted[tostring(workspace.workspace_id or index)] then
			table.insert(skipped, label .. " (not picked)")
		else
			local tabs = sorted_by_number(matching(snapshot.tabs, "workspace_id", workspace.workspace_id))
			if #tabs == 0 then
				table.insert(skipped, label .. " (no tabs)")
			elseif mode == "panes" then
				local plan = plan_panes(label, tabs, snapshot, skipped)
				if plan then table.insert(groups, { label = label, plans = { plan } }) end
			else
				table.insert(groups, { label = label, plans = plan_tabs(label, tabs, snapshot) })
			end
		end
	end
	if #groups == 0 then return "Nothing to import: no picked workspace holds tabs." end
	local targets = {}
	if destination then
		-- The picked workspaces join a session that already exists, so every
		-- group lands in one place and nothing is closed on the way in.
		local plans = {}
		for _, group in ipairs(groups) do
			for _, plan in ipairs(group.plans) do table.insert(plans, plan) end
		end
		table.insert(targets, { name = destination, plans = plans, existing = true })
	elseif mode == "split" then
		for _, group in ipairs(groups) do
			table.insert(targets, { name = "Herdr " .. name .. "/" .. group.label, plans = group.plans })
		end
	else
		local plans = {}
		for _, group in ipairs(groups) do
			for _, plan in ipairs(group.plans) do table.insert(plans, plan) end
		end
		table.insert(targets, { name = "Herdr " .. name, plans = plans })
	end
	for _, item in ipairs(targets) do
		if item.existing then
			local switched, err = pcall(function() cx.sessions:switch(item.name) end)
			if not switched then
				table.insert(skipped, item.name .. " (" .. tostring(err) .. ")")
			else
				local tabs, panes, failed = build_plans(cx, item.plans)
				tabs_made += tabs
				panes_made += panes
				for _, title in ipairs(failed) do table.insert(skipped, title) end
			end
		else
			item.name = free_session_name(cx, item.name)
			local created, session = pcall(function() return cx.sessions:create({ name = item.name }) end)
			if not created or type(session) ~= "table" then
				table.insert(skipped, item.name .. " (" .. tostring(session) .. ")")
			else
				sessions_made += 1
				local stray = initial_pane(cx, session.id)
				local tabs, panes, failed = build_plans(cx, item.plans)
				tabs_made += tabs
				panes_made += panes
				for _, title in ipairs(failed) do table.insert(skipped, title) end
				if stray then pcall(function() cx.layout:close(stray) end) end
			end
		end
	end
	local summary = if destination
		then 'Imported ' .. name .. ' into "' .. destination .. '": '
		else 'Imported ' .. name .. ' into Tern as ' .. sessions_made .. " session(s): "
	summary = summary .. tabs_made .. " tab(s) and " .. panes_made .. " pane(s). Herdr keeps running."
	if #skipped > 0 then summary = summary .. " Skipped " .. table.concat(skipped, ", ") .. "." end
	cx:toast("info", "Herdr import finished", summary)
	return summary
end

local function import_session(cx, pane, name, wanted, mode, destination)
	importing += 1
	local revision = importing
	local what = if wanted then "the picked workspaces from " else "all workspaces from "
	local where = if destination then ' into "' .. destination .. '"' else " into Tern"
	draw(cx, pane, "Importing " .. what .. name .. where .. "...")
	local ok, err = pcall(function()
		tern.process.run({ herdr_bin(), "--session=" .. name, "api", "snapshot" }, { timeout_ms = 20000 }, function(result, fresh)
			if revision ~= importing then return end
			if not fresh then
				tern.log.warn("Herdr for Tern: the import had no window context to draw in")
				return
			end
			if result.timed_out or result.status ~= 0 then
				draw(fresh, pane, "Could not read " .. name .. ": "
					.. (if result.timed_out then "Herdr timed out." else string.sub(result.stderr, 1, 1500)))
				return
			end
			local decoded, data = pcall(tern.json.decode, result.stdout)
			local snapshot = if decoded and type(data) == "table" and type(data.result) == "table" then data.result.snapshot else nil
			if type(snapshot) ~= "table" or type(snapshot.workspaces) ~= "table" or #snapshot.workspaces == 0 then
				draw(fresh, pane, "Herdr returned no session snapshot to import.")
				return
			end
			local drew, failure = pcall(function() return import_into(fresh, name, snapshot, wanted, mode, destination) end)
			if not drew then tern.log.warn("Herdr for Tern: import failed", tostring(failure)) end
			draw(fresh, pane, if drew then failure else "Could not import " .. name .. ": " .. tostring(failure))
		end)
	end)
	if not ok then
		tern.log.warn("Herdr for Tern: could not import " .. name, tostring(err))
		draw(cx, pane, "Could not import " .. name .. ": " .. tostring(err))
	end
end

-- Application flow: listing, the picker screens, open and the import step.
local function refresh(cx, pane)
	request += 1
	local revision = request
	-- Cancel count reads still in flight: their callbacks would no-op on the
	-- revision guard, but cancelling drops their reads too.
	for _, handle in ipairs(pending) do handle:cancel() end
	table.clear(pending)
	sessions, session_list = {}, {}
	-- Discover the binary again on every refresh: Herdr may have been
	-- updated or reinstalled since the last list.
	herdr = nil
	-- A refresh always starts on the session list: `plugins run` can land
	-- here while the picker is on the import step, and those rows are stale.
	step = "sessions"
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
			for _, session in ipairs(data.sessions) do
				if type(session) ~= "table" or not valid_name(session.name) then
					draw(fresh, pane, "Herdr returned an unsupported session name.")
					return
				end
				sessions[session.name] = session
				table.insert(session_list, session)
			end
			-- Keep the user's pick across refreshes, and start on the first
			-- session so the actions are never shown without a target.
			if not (chosen and sessions[chosen]) then chosen = session_list[1] and session_list[1].name or nil end
			draw_picker(fresh, pane)
			-- The per-session state reads leave the process hook: Tern disables
			-- a plugin's hook past 50 ms, so each file is read in its own
			-- staggered timer callback and the counts land as they are read.
			for offset, session in ipairs(session_list) do
				table.insert(pending, tern.timer(offset * 40, function(cx)
					if revision ~= request then return end
					local peek = saved_workspaces(session)
					session.peek_tried = true
					if peek then
						session.peek = peek
						-- Only a picker that still exists gets the count: a
						-- closed picker must not be re-opened by a landing read.
						local pane = own_picker(cx)
						if pane then
							-- The path starts at the keyed sections column: a
							-- bare section key does not resolve and the canvas
							-- appends the section after the actions row.
							local ok = pcall(cx.canvas.set, cx.canvas, pane, { set = { ["sessions." .. session.name] = session_section(session) } })
							-- A stale handle falls back to a full draw; a picker
							-- that closed since the check is left alone.
							if not ok and own_picker(cx) then draw_picker(cx, pane) end
						end
					end
				end))
			end
		end)
	end)
	if not ok then
		tern.log.warn("Herdr for Tern: could not run " .. bin, tostring(err), "searched " .. table.concat(searched, ", "))
		draw(cx, pane, "Could not run " .. bin .. ". Put Herdr on the PATH Tern sees, or set HERDR_BIN. " .. tostring(err))
	end
end

local function show(cx, kind)
	-- Listing, attaching and importing must use the same local host.
	cx.hosts:switch("local")
	mode = kind
	step = "sessions"
	local pane = own_picker(cx)
	if pane then
		cx.layout:focus(pane)
	else
		local opened_pane, err = cx.canvas:open({ title = title, view = ui.text("Reading local Herdr sessions..."), how = "tab",
			about = about })
		if not opened_pane then cx:toast("error", "Herdr session picker unavailable", err or "Canvases unavailable."); return end
		pane = opened_pane
	end
	refresh(cx, pane)
end

-- A still-current Herdr client: a pane whose terminal is a live Herdr that
-- has not exited, errored, or returned to the shell prompt.
local function is_live_herdr_client(client)
	local program = program_name(client and client.program or "")
	return client ~= nil
		and (client.kind == "terminal" or client.kind == "agent")
		and (program == "herdr" or program == "herdr.exe")
		and client.exited == nil and client.error == nil and client.at_prompt ~= true
end

-- Attach a session as a full Herdr client in its own Tern tab, reusing the one
-- already open for it when it is still current.
local function open_session(cx, pane, name)
	local existing = opened[name]
	local client = existing and cx.session:pane(existing)
	if is_live_herdr_client(client) then
		cx.layout:focus(existing)
		return
	end
	local ok, terminal = pcall(function()
		return cx.hosts:terminal("local", { command = attach_command(name) })
	end)
	if not ok then
		draw(cx, pane, "Could not open " .. name .. ": " .. tostring(terminal), { session_sections(), picker_actions() })
	else
		opened[name] = terminal
		local tab = cx.session:tab_of(terminal)
		if tab then cx.layout:name_tab(tab, "Herdr / " .. name) end
	end
end

-- The workspace rows of the import step, all picked to start with; a missing
-- saved state leaves them unreadable and the import falls back to everything.
local function import_step(cx, pane, name)
	-- The counts land on timers, so read the chosen session's state again
	-- here: the picker must not offer workspaces from a stale read.
	local entry = sessions[name]
	if entry then
		local fresh = saved_workspaces(entry)
		if fresh then entry.peek = fresh end
	end
	local peek = entry and entry.peek
	target = nil
	local hosts_ok, hosts = pcall(function() return cx.hosts:list() end)
	local local_host
	for _, host in ipairs(hosts_ok and hosts or {}) do
		if host.kind == "local" then local_host = host.id end
	end
	local ok, listed_sessions = pcall(function() return cx.sessions:list() end)
	-- An import always lands on the local host, so only its sessions can be a
	-- destination; another host's session would be switched away from.
	destinations = {}
	-- No local host means the hosts could not be read; every session stays a
	-- candidate so the step still opens instead of erroring out.
	for _, session in ipairs(ok and listed_sessions or {}) do
		if local_host == nil or session.host == local_host then table.insert(destinations, session) end
	end
	if peek and #peek > 0 then
		workspaces = {}
		for _, workspace in ipairs(peek) do
			table.insert(workspaces, { key = workspace.key, label = workspace.label, tabs = workspace.tabs, selected = true })
		end
	else
		workspaces = nil
	end
	step = "workspaces"
	draw_picker(cx, pane)
end

tern.on("canvas_action", function(ev, cx)
	if ev.owner ~= tern.plugin.id then return nil end
	local pane = ev.pane
	local value = if type(ev.value) == "string" then ev.value else ""
	if ev.act == "refresh" then
		refresh(cx, pane)
		return true
	end
	if ev.act == "back" then
		step = "sessions"
		draw_picker(cx, pane)
		return true
	end
	if ev.act == "pick" then
		local session_name = value
		if sessions[session_name] then
			chosen = session_name
			step = "sessions"
			draw_picker(cx, pane)
		else
			draw(cx, pane, "Session unavailable. Refresh the list.", { picker_actions() })
		end
		return true
	end
	if ev.act == "toggle" then
		local key = value
		for _, workspace in ipairs(workspaces or {}) do
			if workspace.key == key then workspace.selected = not workspace.selected end
		end
		draw_picker(cx, pane)
		return true
	end
	if ev.act == "dest_new" then
		target = nil
		draw_picker(cx, pane)
		return true
	end
	if ev.act == "dest" then
		target = value
		draw_picker(cx, pane)
		return true
	end
	if ev.act == "open" then
		local session_name = value
		if not valid_name(session_name) or not sessions[session_name] then
			draw(cx, pane, "Session unavailable. Refresh the list.", { picker_actions() })
			return true
		end
		open_session(cx, pane, session_name)
		return true
	end
	if ev.act == "import" then
		local session_name = value
		if not valid_name(session_name) or not (sessions[session_name] and sessions[session_name].running) then
			draw(cx, pane, "Session unavailable. Refresh the list.", { picker_actions() })
			return true
		end
		chosen = session_name
		import_step(cx, pane, session_name)
		return true
	end
	if ev.act == "import_run" then
		if not (chosen and sessions[chosen] and sessions[chosen].running) then
			draw(cx, pane, "Session unavailable. Refresh the list.", { picker_actions() })
			return true
		end
		local wanted = nil
		if workspaces then
			wanted = {}
			for _, workspace in ipairs(workspaces) do
				if workspace.selected then wanted[workspace.key] = true end
			end
			if not next(wanted) then
				draw_picker(cx, pane)
				return true
			end
		end
		step = "sessions"
		import_session(cx, pane, chosen, wanted, value, target)
		return true
	end
	return nil
end)

-- Registration: the two commands and the picker's action handler are the
-- plugin's public entry points.
tern.command({ id = "open", title = "Open Herdr in a Tab", icon = "terminal", run = function(cx) show(cx, "open") end })
tern.command({ id = "import", title = "Import Herdr Session into Tern", icon = "terminal", run = function(cx) show(cx, "import") end })

-- A chord for each command: `h` opens the picker, `i` goes to the import step.
tern.bind(if tern.runtime.os == "macos" then "cmd+alt+shift+h" else "ctrl+alt+shift+h", "plugin.herdr-tern-plugin.open")
tern.bind(if tern.runtime.os == "macos" then "cmd+alt+shift+i" else "ctrl+alt+shift+i", "plugin.herdr-tern-plugin.import")
