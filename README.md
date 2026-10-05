# Herdr for Tern

Your Herdr sessions, right inside Tern.

**Open a session in a tab** and keep going inside Tern: its Herdr client runs in a Tern tab, with live control of the session's own workspaces, tabs, panes and running programs.

**Import a running session into Tern** as a copy. The picker shows every session as a collapsible panel that carries its workspace and tab counts collapsed, and its workspaces expanded. Importing opens a second step that picks which workspaces to bring, **where they land**, and how: a **new Tern session** (the row spells out the name it will really take, number and all) or **a session that already exists**, in which case the picked tabs are added to it. Landing as all picked workspaces in one session (tabs in workspace order, named `workspace - tab` inside multi-tab workspaces), or as one Tern session per workspace. Each mirrored tab holds one pane per Herdr pane, running the same program in the same directory. Herdr keeps running.

## Get started

You'll need desktop Tern, Git, and Herdr. The plugin uses `herdr` from Tern's PATH, or from Herdr's own install folder; set `HERDR_BIN` to point at it yourself.

```sh
tern plugin install github.com/gabrielmoreira/herdr-tern-plugin
```

Open Tern's command palette and choose **Open Herdr in a Tab** or **Import Herdr Session into Tern**. Both open the same picker; the command you chose comes first. Pick a session, then the action under it.

## Known issue

On Windows, each session list or refresh runs `herdr` as a child process, and Tern starts plugin child processes without `CREATE_NO_WINDOW`, so a console window flashes on screen for a moment. See [TERN-PLUGIN-FEEDBACK.md](TERN-PLUGIN-FEEDBACK.md) for the details and the fix we asked Tern for.

Made by [Gabriel Moreira](https://github.com/gabrielmoreira). [MIT](LICENSE).
