# Development

Keep the plugin minimal: `plugin.toml` and one `window.luau` at the repository root. Use English. Do not add a wrapper CLI or generated SDK files.

## Local smoke test

Install desktop Tern and Herdr, then run:

```sh
mise install
mise run test
```

The task runs `bun test`. It opens an isolated Tern window, creates a disposable Herdr session, checks input and pane reuse, then closes and removes its fixtures. It does not drive your existing Tern window or change your Herdr configuration.

If the executables are not on PATH, create an ignored `mise.local.toml`:

```toml
[env]
TERN_BIN = "tern.com" # Use "tern" outside Windows, or your local executable path.
HERDR_BIN = "herdr"  # Or your local executable path.
```

Keep local paths and credentials out of commits. Bun is only needed for development, not to run the plugin.
