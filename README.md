# Herdr for Tern

Your Herdr sessions, right inside Tern.

Two palette commands, one picker. **Open Herdr in a Tab** keeps you working on a session inside Tern; **Import Herdr Session into Tern** copies one in. Both land on the same screen, with the command you picked coming first.

## Open a session in a tab

The session's own Herdr client runs in a Tern tab: live control of its workspaces, tabs, panes and running programs, without leaving Tern. Open it again and the tab it already opened comes into focus.

## Import a session into Tern

A running session, copied into Tern panes — Herdr keeps running, the import is a copy, not a move.

- **See what's inside first.** Every session shows up as a panel with its workspace and tab counts; expand it to see the workspaces.
- **Pick what comes along.** Choose the workspaces to import — each row is its own choice, even when two share a name.
- **Choose the landing.** A new session, whose row shows the exact name it will take, number and all — or any session that already exists, and the tabs are added right into it.
- **One session, or one per workspace.** Tabs keep their workspace order and are named `workspace - tab` inside multi-tab workspaces; each Herdr pane becomes a Tern pane running the same program in the same directory.

Anything that could not be built is reported in the summary on the picker, so nothing lands quietly.

## Get started

You'll need desktop Tern, Git, and Herdr. The plugin uses `herdr` from Tern's PATH, or from Herdr's own install folder; set `HERDR_BIN` to point at it yourself.

```sh
tern plugin install github.com/gabrielmoreira/herdr-tern-plugin
```

## Known issue

On Windows, each session list or refresh runs `herdr` as a child process, and Tern starts plugin child processes without `CREATE_NO_WINDOW`, so a console window flashes on screen for a moment. See [TERN-PLUGIN-FEEDBACK.md](TERN-PLUGIN-FEEDBACK.md) for the details and the fix we asked Tern for.

Made by [Gabriel Moreira](https://github.com/gabrielmoreira). [MIT](LICENSE).
