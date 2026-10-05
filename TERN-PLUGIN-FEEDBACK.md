# Feedback for the Tern plugin team

Every issue below was hit while building `herdr-tern-plugin` (a window-half plugin
that lists, imports and attaches local Herdr sessions). Each entry has the symptom,
the impact on the plugin, a minimum reproduction, the evidence collected on this
machine, and the change that would remove the problem.

Environment: Windows 11 (build 26200), Tern `0.4.5` (`1d14241`), Windows
Terminal set as the system default terminal application, plugin linked from a
checkout (`tern plugin link`).

## 1. `tern.process.run` shows a console window for every console program it starts

**Symptom.** Any child that is a console application makes a Windows Terminal
window appear and disappear on screen, once per spawn.

**Impact.** The picker lists sessions with `herdr session list --json` on every
open and on every refresh, so the whole window flashes at the user. There is no
plugin-side workaround: `ProcessOptions` exposes `cwd`, `env`, `stdin` and
`timeout_ms` only, and every way to hide a console on Windows is a flag of the
*parent's* `CreateProcess` call.

**Root cause.** The spawn is not passing `CREATE_NO_WINDOW`. A GUI-subsystem
parent with no console of its own plus a console child is exactly the case that
allocates a new console, and with Windows Terminal as the default terminal
application that allocation opens a Windows Terminal window.

**Reproduction.**

```js
// gui-probe.mjs, compiled with: bun build --compile --windows-hide-console
// It has no console of its own, so any window that appears belongs to a child.
const child = Bun.spawnSync([herdr, "session", "list", "--json"], {
  stdout: "pipe",
  windowsHide: process.argv[2] === "hidden", // Node/Bun turn this into CREATE_NO_WINDOW
});
```

Result on this machine, 4 spawns each, counting new visible windows of class
`CASCADIA_HOSTING_WINDOW_CLASS` / `PseudoConsoleWindow`:

| mode | new console windows |
| --- | --- |
| without `windowsHide` (what Tern does today) | 4 |
| with `windowsHide` (`CREATE_NO_WINDOW`) | 0 |

**Ask.** Pass `CREATE_NO_WINDOW` for plugin spawns on Windows (always, or behind a
`ProcessOptions` field such as `hide = true`). Herdr's own CLI is a console
application; the same applies to `git`, `rg`, `gh` and anything else a plugin
shells out to.

## 2. A plugin reload invalidates canvas handles, and in-flight callbacks keep using them

**Symptom.** After a reload, a process callback that draws into the plugin's
canvas fails with `runtime error: pane is not a canvas`, even though the canvas
still exists in the same window. The canvas stays on the message it had before the
reload until the plugin draws again.

**Impact.** The picker froze on `Reading local Herdr sessions...` with nothing on
screen to explain it. Only the window log had the warning:

```text
WARN tern::plugin: Herdr for Tern: could not draw the session picker
  runtime error: pane is not a canvas
  window.luau:122: in function 'draw'
  window.luau:389: in function <window.luau:360>
```

`cx.canvas:list()` in the same window still reported the canvas with the same
pane, owner and title, and its `get` returned a view, so the handle is only stale
for *setting*.

**Reproduction.** Link a plugin (`tern plugin link <dir>`, documented as reloading
the daemon's plugins) or run `tern plugin reload`, then let the plugin draw from a
`tern.process.run` callback that started before the reload. Reloading 60-600 ms
after the draw that started the process reproduced it; the same run with the fix
below recovered in all four cases.

**What the plugin has to do instead.** Resolve the canvas pane again in the current
VM before each draw, and retry with the resolved pane when `canvas:set` fails:

```lua
local target = own_canvas_pane(cx) or pane
local ok, err = pcall(cx.canvas.set, cx.canvas, target, view)
if not ok then
  local live = own_canvas_pane(cx)
  if live and live ~= target then ok, err = pcall(cx.canvas.set, cx.canvas, live, view) end
end
```

**Ask.** Either make a canvas handle survive a reload, or fail loudly with
something the plugin can branch on (a documented error, or `canvas:valid(pane)`),
and document that process callbacks of a reloaded VM may still run against
pre-reload handles. The current behaviour costs every plugin a deterministic
resolve-and-retry dance.

## 3. `ui.el("button")` renders as plain text unless the plugin ships CSS

**Symptom.** A `button` node in a canvas view has no background, border or hover
treatment; it reads as a sentence with a click handler. The styling arrives only
after the plugin ships a stylesheet (declared in `plugin.toml`) that targets a role
of its own, e.g.

```toml
styles = ["window.css"]
```

```css
button[data-role='herdr-tern-plugin.action'] { background: var(--raise); border: 1px solid var(--l3); ... }
```

**Impact.** The first version of this plugin looked unfinished, and the workaround
means every plugin author re-invents the theme's action styling by hand.

**Ask.** One of: style `button` natively from the theme; document that a bare
button is intentionally unstyled and ship a documented theme-styled variant (for
example a `tone`-aware action node); or provide theme tokens (a token list, or
the ability to reference the chrome's own classes) instead of raw CSS.

## 4. Items built by `ui.list` can arrive without their props

**Symptom.** `ui.list({ { label = ..., detail = ... }, ... })` can hand back a node
whose children have no `p` table, so `key`, `actions` and `mark` have to be added
by the plugin after the fact.

**Impact.** Attaching a click action to a row becomes an exercise in repairing the
builder's output:

```lua
local node = ui.list(items)
for index, child in ipairs(node.c or {}) do
  local item = child.p or {}
  item.key = listed[index].name
  item.actions = { click = "pick=" .. listed[index].name }
  child.p = item
end
```

**Ask.** Always emit stable per-item props (and an item id or key) from `ui.list`,
or document the shape precisely, including when `p` is absent.

## 5. Nothing in the API answers "is this pane my canvas?"

Related to issue 2: `cx.canvas:list()` and `cx.canvas:get` tell a plugin which
canvases it owns, but there is no predicate for a single pane id, and the only way
to learn that a pane id is no longer settable is the `pane is not a canvas` error
raised out of a `pcall`. A documented `canvas:is(pane)` (or a typed error code)
would let a plugin check before drawing instead of catching.

## 6. A plugin draw error only logs a warning, and the canvas silently keeps its old content

**Symptom.** When a plugin's draw raises, the pane keeps the view it had before
and the window log carries one `WARN` with the error and a stack; nothing on
screen changes and no error reaches the plugin's own handlers. The blank-looking
window in this session came from `runtime error: main.workspaces: duplicate
child key "pr-reviews"`: the plugin's workspace rows were keyed by workspace
label, and the real `default` session holds two workspaces labelled `pr-reviews`.

**Impact.** The failure looks like "the button did nothing" both to the user and
to whoever debugs the plugin, and the plugin cannot show its own error because
drawing is what failed. A control-endpoint debugger also disappears into it: the
click *did* run the handler, the draw then threw, and the recovery re-drew the
previous screen, which reads exactly like a click that never landed. Hours went
into the tooling before the log line named the cause.

**Ask.** One of: render the failing draw as a visible error in the pane; expose a
hook or an error channel the plugin can branch on; or make the window log line
carry a stable error code. Duplicate child keys could also name the parent node
and both paths, not just the key.

**Related, still open.** `a11y ACTION SEL` rejects the ids its own tree reports
(u32 above i32 max reaches the parser as `int_value: Some(2147483647)`) and its
selector grammar is undocumented in `tern help dev`. `plugins run` only takes
palette commands, so a canvas action cannot be invoked by key.

## 7. A canvas has no text input, so a plugin cannot ask for a name

**Symptom.** `tern.ui.el` takes `input` only as `checkbox` or `radio`, and
`CanvasSpec.view` excludes input, editor and image kinds. Nothing on the window
side reads the window's own input line either.

**Impact.** `herdr-tern-plugin` asks where an import should land and can offer a
new session or one that already exists, but it cannot let the user type the new
session's name; it can only offer names it computed itself. Tern's own prompts
can ask for a string, plugins cannot.

**Ask.** Allow one single-line text input in a canvas view (value in, change
event out), or expose the window's input line to plugins, so a plugin can ask
for a short string the way the built-in prompts do.

## 8. `ctl click` and `ctl pick` disagree about what is under a point

**Symptom.** On a window opened with `tern --control`, `pick X Y` names the
plugin's button at exactly the rect that `tree` and `a11y` report for it, but
`click X Y` on the same point returns `{"ok":true,"focused":"textarea.tv-input"}`
and the button's handler never runs; the canvas keeps the view it had. The same
rect-centre clicks work in a harness window that uses default settings, and the
user's real mouse clicks work in the window that loads the user's
`settings.json`, so the two commands appear to disagree about the coordinate
space only there.

**Impact.** A plugin's click paths cannot be driven from `ctl` on a real window,
which is what live verification of a picker needs; the failure also looks exactly
like a plugin bug, and it cost real time to separate from one (see issue 6).

**Ask.** Make `click` deliver to whatever `pick` answers at that point, or
document the coordinate space each command uses. A `click` variant that takes a
`tree`/`a11y` selector, or an action-by-key invocation (issue 6), would remove
the ambiguity entirely.

## 9. A process hook that runs long once disables the plugin until reload

**Symptom.** A run of the plugin's own smoke test on another machine (Tern
`0.4.5`, Herdr `0.9.3`, cold start) logged:

```text
WARN tern::plugin: plugin hook exceeded its budget; disabled until reload
plugin=herdr-tern-plugin hook=process
runtime error: tern: process exceeded 50 ms
```

The picker stayed on its loading message and never listed a session until the
plugin was reloaded.

**Impact.** One slow callback (a cold VM, a slow disk, a long session list)
turns the plugin off for the rest of the window's life, with nothing on screen
to tell the user and nothing the plugin can catch: the disable happens outside
plugin code, and the plugin's own recovery paths never run again. A plugin
cannot even keep its synchronous work small enough by design, because the first
callback on a cold VM already carries loading the plugin itself.

**What the plugin had to do instead.** Keep the process callback's synchronous
work proportional: the session-list decode and one draw stay in the hook, and
the per-session `session.json` reads moved to staggered `tern.after` timers, one
file per callback, with the import step re-reading the chosen session's state
so nothing acts on stale rows.

**Ask.** One of: raise or remove the 50 ms budget for process callbacks;
disable only the offending hook invocation instead of the plugin until reload;
or surface the disable in the pane and to the plugin (an event, or a documented
error) so a plugin can tell the user instead of dying silently.
