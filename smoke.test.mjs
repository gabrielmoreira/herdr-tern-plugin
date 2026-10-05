import { expect, test } from "bun:test";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { connect } from "node:net";
import { tmpdir } from "node:os";
import { delimiter, dirname, join } from "node:path";

const tern = process.env.TERN_BIN ?? (process.platform === "win32" ? "tern.com" : "tern");
const herdr = process.env.HERDR_BIN ?? "herdr";

const normalize = (path) => (path ?? "").replace(/[\\/]+/g, "/").replace(/\/+$/, "").toLowerCase();

async function waitFor(read, ready) {
  const deadline = Date.now() + 30_000;
  let lastError;
  while (Date.now() < deadline) {
    try {
      const value = await read();
      if (ready(value)) return value;
    } catch (error) {
      lastError = error;
    }
    await Bun.sleep(100);
  }
  throw new Error(`Smoke fixture did not become ready: ${lastError}`, { cause: lastError });
}

test("opens, reuses, reattaches, and imports a real Herdr session", async () => {
  const directory = await mkdtemp(join(tmpdir(), "herdr-tern-smoke-"));
  const session = `tern-smoke-${crypto.randomUUID()}`;
  const env = {
    ...process.env,
    PATH: `${dirname(Bun.which(herdr) ?? herdr)}${delimiter}${process.env.PATH ?? ""}`,
    TERN_CONFIG_DIR: join(directory, "tern"),
    HERDR_CONFIG_PATH: join(directory, "herdr.toml"),
  };
  for (const key of [
    "HERDR_SOCKET_PATH", "HERDR_CLIENT_SOCKET_PATH", "HERDR_SESSION",
    "HERDR_SESSION_NAME", "HERDR_WORKSPACE_ID", "HERDR_TAB_ID", "HERDR_PANE_ID",
  ]) delete env[key];
  env.TERN_DAEMON_SOCKET = process.platform === "win32"
    ? `\\\\.\\pipe\\${session}` : join(directory, "tern.sock");
  let gui, server, daemon, port, guiReady = false, extraDirectory, gammaDirectory, deltaDirectory;

  const spawn = (command, options = {}) => Bun.spawn(command, {
    cwd: import.meta.dir, env, stdout: "pipe", stderr: "pipe", ...options,
  });
  const run = async (command) => {
    const child = spawn(command, { timeout: 15_000 });
    const [stdout, stderr, code] = await Promise.all([
      new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited,
    ]);
    if (code !== 0) throw new Error(`${command.join(" ")} failed (${code}): ${stderr}`);
    return stdout.trim().startsWith("{") ? JSON.parse(stdout) : stdout;
  };
  const control = (command) => run([tern, "ctl", "--control", String(port), command]);
  // Buttons shorten long session names on a code-point boundary; the rows keep
  // them whole. Mirrors the plugin's short().
  const short = (name) => {
    const runes = [...name];
    return runes.length <= 24 ? name : runes.slice(0, 23).join("") + "…";
  };
  const api = (...args) => run([herdr, `--session=${session}`, ...args]);
  // The picker picks a row; the command's own button names what it will do, so
  // the test never clicks an action meant for another session.
  const act = async (command, label) => {
    await control(`plugins run ${command}`);
    await control('plugins expect "Choose a session:"');
    const { nodes } = await control("tree .sf-act");
    const row = nodes.find((node) => node.text.startsWith(session));
    expect(row).toBeDefined();
    await control(`click ${row.rect[0] + row.rect[2] / 2} ${row.rect[1] + row.rect[3] / 2}`);
    const { nodes: acting } = await control("tree .sf-act");
    const button = acting.find((node) => node.text === label);
    expect(button).toBeDefined();
    await control(`click ${button.rect[0] + button.rect[2] / 2} ${button.rect[1] + button.rect[3] / 2}`);
  };
  const open = async () => {
    await act("plugin.herdr-tern-plugin.open", `Open "${short(session)}" in a tab`);
    return control("state");
  };

  try {
    await writeFile(env.HERDR_CONFIG_PATH, "onboarding = false\n[experimental]\nallow_nested = true\n");
    await run([tern, "plugin", "link", import.meta.dir, "--json"]);
    const listener = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: () => new Response() });
    port = listener.port;
    listener.stop(true);
    const executable = tern.replace(/\.com$/i, ".exe");
    daemon = spawn([executable, "daemon", "--socket", env.TERN_DAEMON_SOCKET], { stdout: "ignore", stderr: "inherit" });
    await waitFor(() => new Promise((resolve, reject) => {
      const socket = connect(env.TERN_DAEMON_SOCKET);
      socket.once("connect", () => { socket.destroy(); resolve(true); });
      socket.once("error", (error) => { socket.destroy(); reject(error); });
    }), Boolean);
    server = spawn([herdr, `--session=${session}`, "server"], { stdout: "ignore", stderr: "inherit" });
    gui = spawn([executable, "--control", String(port)], { stdout: "ignore", stderr: "inherit" });
    await waitFor(() => control("state"), (state) => state.ok);
    guiReady = true;
    await waitFor(() => api("session", "list", "--json"), (list) => list.sessions.some((item) => item.name === session && item.running));
    const first = (await api("workspace", "create", "--cwd", import.meta.dir, "--label", "Plugin smoke", "--focus")).result;
    await api("tab", "rename", first.tab.tab_id, "Alpha");
    const second = (await api("tab", "create", "--workspace", first.workspace.workspace_id, "--label", "Beta", "--focus")).result;
    const client = await open();
    await control('expect "Alpha"');
    await control('expect "Beta"');
    await control('run "echo HERDR_SMOKE_OUTPUT"');
    await waitFor(() => api("pane", "read", second.root_pane.pane_id, "--format", "text"), (text) => /^HERDR_SMOKE_OUTPUT\s*$/m.test(text));
    const repeated = await open();
    expect(repeated.focused.id).toBe(client.focused.id);
    expect(repeated.tabs.length).toBe(client.tabs.length);
    const before = (await api("pane", "process-info", "--pane", second.root_pane.pane_id)).result.process_info;
    await control(`carly lua "cx.layout:close(${client.focused.id})"`);
    const after = (await api("pane", "process-info", "--pane", second.root_pane.pane_id)).result.process_info;
    expect(after.shell_pid).toBe(before.shell_pid);
    expect((await open()).focused.id).not.toBe(client.focused.id);
    await control('expect "HERDR_SMOKE_OUTPUT"');

    // Import is a flow: the picker names the session, the next step picks the
    // workspaces and how they land in Tern. One Tern session holds one tab per
    // imported Herdr tab, named `workspace - tab` inside multi-tab workspaces,
    // and one Tern pane per Herdr pane in the same directories. Herdr keeps
    // running.
    extraDirectory = await mkdtemp(join(tmpdir(), "herdr-tern-extra-"));
    const split = await api("pane", "split", first.root_pane.pane_id, "--direction", "right", "--cwd", extraDirectory, "--no-focus");
    expect(split.result.pane?.pane_id ?? split.result.root_pane?.pane_id ?? split.result.pane_id).toBeString();
    gammaDirectory = await mkdtemp(join(tmpdir(), "herdr-tern-gamma-"));
    const gamma = (await api("workspace", "create", "--cwd", gammaDirectory, "--label", "Plugin gamma", "--focus")).result;
    await api("tab", "rename", gamma.tab.tab_id, "Gamma");
    // Herdr allows two workspaces with the same label, and the real default
    // session carries exactly that: a picker row key may not be the label.
    deltaDirectory = await mkdtemp(join(tmpdir(), "herdr-tern-delta-"));
    const delta = (await api("workspace", "create", "--cwd", deltaDirectory, "--label", "Plugin smoke", "--focus")).result;
    await api("tab", "rename", delta.tab.tab_id, "Delta");
    const expectedCwds = (await api("pane", "list")).result.panes.map((pane) => normalize(pane.cwd)).sort();
    expect(expectedCwds).toHaveLength(5);
    const smokeCwds = expectedCwds.filter((cwd) => cwd !== normalize(gammaDirectory));

    const click = (node) => control(`click ${node.rect[0] + node.rect[2] / 2} ${node.rect[1] + node.rect[3] / 2}`);
    // The picker's peek reads Herdr's autosaved session state, which lags the
    // fixture by a few seconds, so wait for it to carry both workspaces before
    // the picker reads it.
    const sessionDir = (await api("session", "list", "--json")).sessions
      .find((item) => item.name === session)?.session_dir;
    expect(sessionDir).toBeString();
    await waitFor(() => Bun.file(join(sessionDir, "session.json")).text()
      .then((text) => (JSON.parse(text).workspaces ?? []).length >= 3), Boolean);
    const enterStep = async () => {
      await control("plugins run plugin.herdr-tern-plugin.import");
      await control('plugins expect "Choose a session:"');
      // The peek counts land on staggered timers, not in the process hook, so
      // wait for the section to carry them (a timer API that does not exist
      // would strand the counts and fail here). The pending state reads
      // "Reading saved workspaces…", so match the landed counts.
      await waitFor(() => control("tree .sf-act"),
        (tree) => (tree.nodes ?? []).some((node) => (node.text ?? "").startsWith(session) && /\d+ workspaces? · \d+ tabs?/.test(node.text)));
      const { nodes } = await control("tree .sf-act");
      const rows = nodes.filter((node) => (node.text ?? "").startsWith(session));
      // Exactly one row: a keyed canvas:set whose path misses the sections
      // column appends a second section below the buttons instead of
      // replacing the row in place.
      expect(rows).toHaveLength(1);
      const row = rows[0];
      expect(row).toBeDefined();
      await click(row);
      const { nodes: acting } = await control("tree .sf-act");
      const button = acting.find((node) => node.text === `Import "${short(session)}"`);
      expect(button).toBeDefined();
      await click(button);
      return control("tree .sf-act");
    };

    // The smoke workspace alone, as one session.
    {
      const { nodes } = await enterStep();
      const gammaRow = nodes.find((node) => node.text.startsWith("Plugin gamma"));
      expect(gammaRow).toBeDefined();
      await click(gammaRow);
      // The second "Plugin smoke" workspace is its own choice: same label,
      // different row, and unticking it must not untick the first.
      const { nodes: between } = await control("tree .sf-act");
      const deltaRow = between.find((node) => node.text === "Plugin smoke1 tab");
      expect(deltaRow).toBeDefined();
      await click(deltaRow);
      const { nodes: acting } = await control("tree .sf-act");
      const one = acting.find((node) => node.text === "One session (2 tabs)");
      expect(one).toBeDefined();
      await click(one);
    }
    await waitFor(() => control("state"),
      (state) => (state.sessions ?? []).some((item) => item.name === `Herdr ${session}`));
    // A partial import must still land its summary: the skip path once aborted
    // on an invalid toast level before drawing it. The summary is plain text,
    // so read the canvas view instead of the action-only tree.
    const canvasText = async () => {
      await control("carly lua \"local cs = cx.canvas:list() if #cs == 0 then return '' end "
        + "local v = cx.canvas:get(cs[1].pane) local n = (v.view or {}).c or {} "
        + "local s = n[1] and n[1].p and n[1].p.spans and n[1].p.spans[1] "
        + "return s and s.t or ''\"");
      return String(((await control("state")).carly?.last_tool?.text ?? "")).replace(/^→\s*/, "");
    };
    await waitFor(canvasText, (text) => text.startsWith("Imported "));

    // Everything, one session per workspace, after going back once.
    {
      const { nodes: stepped } = await enterStep();
      await click(stepped.find((node) => node.text === "Back"));
      const back = await control("tree .sf-act");
      expect((back.nodes ?? []).some((node) => node.text.startsWith(session))).toBe(true);
      const { nodes } = await enterStep();
      const splitButton = nodes.find((node) => node.text === "3 sessions, one per workspace (4 tabs)");
      expect(splitButton).toBeDefined();
      await click(splitButton);
    }
    await waitFor(() => control("state"), (state) => [
      `Herdr ${session}/Plugin smoke`,
      `Herdr ${session}/Plugin smoke (2)`,
      `Herdr ${session}/Plugin gamma`,
    ].every((name) => (state.sessions ?? []).some((item) => item.name === name)));

    const carly = async (code) => {
      await control(`carly lua "${code}"`);
      return ((await control("state")).carly.last_tool?.text ?? "").replace(/^→\s*/, "");
    };
    const mirrorOf = async (sessionName) => {
      const text = await carly(`cx.sessions:switch('${sessionName}') `
        + "local current = cx.sessions:current() local wanted, tabs = {}, {} "
        + "for _, t in ipairs(cx.session:tabs()) do if t.session == current.id then wanted[t.id] = true tabs[#tabs+1] = t.name or t.title end end "
        + "local cwds = {} for _, p in ipairs(cx.session:panes()) do if wanted[p.tab] then cwds[#cwds+1] = tostring(p.cwd) end end "
        + "table.sort(tabs) table.sort(cwds) return table.concat(tabs, ',') .. '||' .. table.concat(cwds, ',')");
      const [tabs, cwds] = text.split("||");
      return { tabs: tabs.split(",").filter(Boolean), cwds: cwds.split(",").filter(Boolean).map(normalize).sort() };
    };
    const smokeTabs = ["Plugin smoke - Alpha", "Plugin smoke - Beta"];
    const one = await mirrorOf(`Herdr ${session}`);
    expect(one.tabs).toEqual(smokeTabs);
    expect(one.cwds).toEqual(smokeCwds.filter((cwd) => cwd !== normalize(deltaDirectory)));
    const smoke = await mirrorOf(`Herdr ${session}/Plugin smoke`);
    const gammaMirror = await mirrorOf(`Herdr ${session}/Plugin gamma`);
    expect(smoke.tabs).toEqual(smokeTabs);
    expect(gammaMirror.tabs).toEqual(["Gamma"]);
    const deltaMirror = await mirrorOf(`Herdr ${session}/Plugin smoke (2)`);
    expect(deltaMirror.tabs).toEqual(["Delta"]);
    expect([...smoke.cwds, ...gammaMirror.cwds, ...deltaMirror.cwds].sort()).toEqual(expectedCwds);

    // Importing into a session that already exists. The destination row spells
    // out the name a new session would really take, so a taken name shows its
    // number instead of quietly becoming another session beside it.
    {
      const { nodes } = await enterStep();
      const suggested = nodes.find((node) => node.text.startsWith("New session") && node.text.includes("(2)"));
      expect(suggested).toBeDefined();
      await click(nodes.find((node) => node.text === "Plugin gamma1 tab"));
      const { nodes: between } = await control("tree .sf-act");
      await click(between.find((node) => node.text === "Plugin smoke1 tab"));
      const { nodes: acting } = await control("tree .sf-act");
      const existing = acting.find((node) => node.text.startsWith(`Herdr ${session}`) && !node.text.includes("/"));
      expect(existing).toBeDefined();
      await click(existing);
      const { nodes: picking } = await control("tree .sf-act");
      const into = picking.find((node) => node.text === `Into "${short(`Herdr ${session}`)}" (2 tabs)`);
      expect(into).toBeDefined();
      await click(into);
    }
    await waitFor(canvasText, (text) => text.startsWith(`Imported ${session} into "Herdr ${session}"`));
    const grown = await mirrorOf(`Herdr ${session}`);
    expect(grown.tabs).toEqual([...smokeTabs, ...smokeTabs].sort());
    expect((await control("state")).sessions.some((item) => item.name === `Herdr ${session} (2)`)).toBe(false);

    // Panes mode: the same workspace, its tabs as panes of one Tern tab.
    {
      const { nodes } = await enterStep();
      await click(nodes.find((node) => node.text === "Plugin gamma1 tab"));
      const { nodes: between } = await control("tree .sf-act");
      await click(between.find((node) => node.text === "Plugin smoke1 tab"));
      const { nodes: acting } = await control("tree .sf-act");
      const panes = acting.find((node) => node.text === "Tabs as panes, one tab per workspace (2 panes)");
      expect(panes).toBeDefined();
      await click(panes);
    }
    await waitFor(() => control("state"), (state) => (state.sessions ?? []).some((item) => item.name === `Herdr ${session} (2)`));
    const panesMirror = await mirrorOf(`Herdr ${session} (2)`);
    expect(panesMirror.tabs).toEqual(["Plugin smoke"]);
    // Panes mode keeps each tab's first pane: Alpha's root, and Beta's pane.
    const betaCwd = (await api("pane", "list")).result.panes
      .find((pane) => pane.pane_id === second.root_pane.pane_id)?.cwd;
    expect(panesMirror.cwds).toEqual([normalize(import.meta.dir), normalize(betaCwd)].sort());
  } finally {
    const cleanup = await Promise.allSettled([
      guiReady ? control("quit") : Promise.resolve(),
      server ? api("session", "stop", session, "--json") : Promise.resolve(),
    ]);
    for (const child of [gui, server, daemon]) if (child?.exitCode === null) child.kill();
    await Promise.all([gui, server, daemon].filter(Boolean).map((child) => child.exited));
    if (server) await api("session", "delete", session, "--json");
    await rm(directory, { recursive: true, force: true });
    for (const extra of [extraDirectory, gammaDirectory, deltaDirectory]) if (extra) await rm(extra, { recursive: true, force: true });
    const errors = cleanup.filter((result) => result.status === "rejected").map((result) => result.reason);
    if (errors.length) throw new AggregateError(errors, "Smoke cleanup failed");
  }
}, 120_000);
