# Development

Keep the plugin minimal: `plugin.toml` and one `window.luau` at the repository root. Use English. Do not add a wrapper CLI or generated SDK files.

## Canvas updates

Draw with `cx.canvas:set` and treat a thrown error as the failure signal. Do not gate drawing on `cx.canvas:get`: that reads the window's replica, which can still be empty when a process callback runs, and a guard on it silently drops the update with nothing logged. Resolve the picker's canvas pane in the current VM before each draw and retry once with it, and re-open the canvas when even the resolved handle is rejected: a plugin reload (plugin files changing, `tern plugin reload`, or the reload every plugin-directory change triggers) invalidates the canvas handles an earlier VM held, and an in-flight process callback lands in the new VM holding a stale pane, which otherwise leaves the canvas frozen on its last message. `canvas:set` takes a document (`{ view = node }`) while `canvas:open` takes the bare node; handing the document to `open` surfaces as `runtime error: canvas node needs string k`. Toast levels are `success`, `info` and `error` only: a `warn` toast raises.

## Finding herdr

Tern looks a program up on the PATH of its own process, and a desktop launch can have a smaller one than your shell, so the bare name can be missing there. The plugin therefore checks `HERDR_BIN`, then `HERDR_BIN_PATH` (which Herdr itself sets), then the directories Herdr's installer and the package managers use (`~/.herdr/packages/standalone/current` and `bin`, `~/.local/bin`, mise shims, `~/.cargo/bin`, Nix profiles, Homebrew and `/usr/local/bin`), then the newest release under `~/.herdr/packages/standalone/releases`, and only then the bare name. It resolves once, reuses the path for both the session list and the attach command, and logs every directory it searched when the process cannot start.

## Importing a session into Tern

`Import into Tern` mirrors a running Herdr session; Herdr keeps running, because the mirror is a copy. The flow has two screens.

The picker lists every local Herdr session as a collapsible `ui.section` keyed by the session name, so a user's expansion survives refreshes: collapsed it carries the workspace and tab counts, expanded the workspaces themselves. Those counts come from the session's autosaved `session.json`, in the `session_dir` that `herdr session list --json` hands over: no extra process. The reads run in staggered `tern.timer` callbacks, one file each, because Tern disables a plugin's process hook for the rest of the window's life once a callback passes 50 ms; the session-list decode and the first draw stay in the hook. The import step re-reads the chosen session's state before showing workspaces, so counts landing late never leave the picker offering a stale list. The autosave lags live changes by a few seconds; an unreadable or empty state falls back to importing every workspace.

The import step picks the workspaces and the destination. A new session's row spells out the name it would really take (`Herdr <session>`, or the numbered name when that one is taken), and every local Tern session that already exists is there too: picking one switches to it and adds the tabs there instead of creating a session. The picked workspaces then land as one Tern session, or one per workspace. The workspace list caps at ten rows and says how many are below the fold.

The mirror is built from `herdr --session=<name> api snapshot`. A workspace holding several tabs names its Tern tabs `workspace - tab`; a one-tab workspace uses the tab's own label, and a tab Herdr only numbered keeps the workspace's name. Panes are created left to right as splits of the tab's first pane, each starting in the Herdr pane's directory and running its `agent` program. Unpicked workspaces, and anything that cannot be matched, are skipped and reported in the summary.

Two data rules keep that standing. Tern rejects duplicate child keys, and Herdr allows two workspaces to share a label (the real `default` session carries `pr-reviews` twice), so every row is keyed by the workspace id, never by its label: the saved state names it `id` (`w4`), the import snapshot names it `workspace_id`, both carry the same value, and the picked set joins on it. Labels stay display-only: they name the split sessions and the skip lines in the summary. And the destination list is filtered to the local host, because the import always lands there.

Splits reuse one direction, so exact split ratios are not reproduced. Duplicate session names are suffixed with a number; anything that could not be built is reported in the summary drawn on the picker and in a toast. The session list is every local Herdr session, so the picker always acts on the session that was clicked, and the import always acts on the workspaces that were picked.

## Local smoke test

Use working desktop Tern and Herdr installations. Review mise's tool-pruning settings first; if running mise could prune unrelated tools, fix that setup or use Bun directly instead.

```sh
mise install
mise run test
```

With Bun already installed, `bun test` works too. Set executable overrides in the shell for that route; Bun does not load `mise.local.toml`.

The task runs `bun test`. It opens an isolated Tern window, creates a disposable Herdr session with a second pane, a second workspace and a third workspace that repeats a label, checks input and pane reuse, then imports that session and asserts the mirrored sessions, their tab names and their pane directories before closing and removing its fixtures. It does not drive your existing Tern window or change your Herdr configuration.

Three traps this test avoids. The picker lists every local Herdr session, so a test must target its own row instead of the first button with a matching label. The picker's peek reads Herdr's autosaved session state, which lags the fixture by a few seconds, so the test waits for the saved file to carry all three workspaces before opening the picker. And the accessors differ: `cx.session:current` does not exist, so read the current session from `cx.sessions:current()` and match tabs and panes by its id.

If the executables are not on PATH, create an ignored `mise.local.toml`:

```toml
[env]
TERN_BIN = "tern.com" # Use "tern" outside Windows, or your local executable path.
HERDR_BIN = "herdr"  # Or your local executable path.
```

Keep local paths and credentials out of commits. Bun is only needed for development, not to run the plugin.
