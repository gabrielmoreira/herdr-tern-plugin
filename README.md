# Herdr for Tern

Your Herdr sessions, inside Tern.

![The Herdr picker in Tern](assets/picker.png)

Two commands in Tern's palette, both found by searching `herdr`:

- **Open Herdr in a Tab**: the session's own Herdr client runs in a Tern tab. Live control of its workspaces, tabs and panes, without leaving Tern.
- **Import Herdr Session into Tern**: copies a running session into Tern. Pick which workspaces come along, choose where they land (a new session, whose row shows the exact name it will take, or a session that already exists), and whether they arrive as one session or one per workspace. Herdr keeps running: it is a copy, not a move.

The picker lists every local session with its workspace and tab counts, and the workspaces inside each one, so you can see what you are bringing over before anything runs.

## Get started

```sh
tern plugin install github.com/gabrielmoreira/herdr-tern-plugin
```

You need desktop Tern and Herdr. The plugin looks for `herdr` on Tern's PATH and in Herdr's own install folders; set `HERDR_BIN` if it lives somewhere else.

## Notes

- Every mirrored pane starts in the same directory, running the same program as its Herdr pane. Exact split ratios are not reproduced.
- On Windows, a console window flashes on each refresh, because Tern spawns plugin children without `CREATE_NO_WINDOW`. Details in [TERN-PLUGIN-FEEDBACK.md](TERN-PLUGIN-FEEDBACK.md).

Made by [Gabriel Moreira](https://github.com/gabrielmoreira). [MIT](LICENSE).
