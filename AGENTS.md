# Development

Keep the plugin minimal: `plugin.toml` and one `window.luau` at the repository root. Use English. Do not add a wrapper CLI or generated SDK files.

## Canvas updates

Draw with `cx.canvas:set` and treat a thrown error as the failure signal. Do not gate drawing on `cx.canvas:get`: that reads the window's replica, which can still be empty when a process callback runs, and a guard on it silently drops the update with nothing logged.

## Finding herdr

Tern looks a program up on the PATH of its own process, and a desktop launch can have a smaller one than your shell, so the bare name can be missing there. The plugin therefore checks `HERDR_BIN`, then `HERDR_BIN_PATH` (which Herdr itself sets), then `~/.herdr/packages/standalone/current`, then the newest release under `~/.herdr/packages/standalone/releases`, and only then the bare name. Resolve once and reuse the result for both the session list and the attach command.

## Local smoke test

Use working desktop Tern and Herdr installations. Review mise's tool-pruning settings first; if running mise could prune unrelated tools, fix that setup or use Bun directly instead.

```sh
mise install
mise run test
```

With Bun already installed, `bun test` works too. Set executable overrides in the shell for that route; Bun does not load `mise.local.toml`.

The task runs `bun test`. It opens an isolated Tern window, creates a disposable Herdr session, checks input and pane reuse, then closes and removes its fixtures. It does not drive your existing Tern window or change your Herdr configuration.

If the executables are not on PATH, create an ignored `mise.local.toml`:

```toml
[env]
TERN_BIN = "tern.com" # Use "tern" outside Windows, or your local executable path.
HERDR_BIN = "herdr"  # Or your local executable path.
```

Keep local paths and credentials out of commits. Bun is only needed for development, not to run the plugin.
