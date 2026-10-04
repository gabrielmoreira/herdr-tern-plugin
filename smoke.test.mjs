import { expect, test } from "bun:test";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { connect } from "node:net";
import { tmpdir } from "node:os";
import { delimiter, dirname, join } from "node:path";

const tern = process.env.TERN_BIN ?? (process.platform === "win32" ? "tern.com" : "tern");
const herdr = process.env.HERDR_BIN ?? "herdr";

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
  throw new Error("Smoke fixture did not become ready", { cause: lastError });
}

test("opens, reuses, and reattaches a real Herdr session", async () => {
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
  let gui, server, daemon, port, guiReady = false;

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
  const api = (...args) => run([herdr, `--session=${session}`, ...args]);
  const open = async () => {
    await control("plugins run plugin.herdr-tern-plugin.open");
    await control('plugins expect "Choose a session:"');
    const { nodes } = await control("tree .sf-act");
    const button = nodes.find((node) => node.text.startsWith(`${session} (`));
    expect(button).toBeDefined();
    const [x, y, width, height] = button.rect;
    await control(`click ${x + width / 2} ${y + height / 2}`);
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
  } finally {
    const cleanup = await Promise.allSettled([
      guiReady ? control("quit") : Promise.resolve(),
      server ? api("session", "stop", session, "--json") : Promise.resolve(),
    ]);
    for (const child of [gui, server, daemon]) if (child?.exitCode === null) child.kill();
    await Promise.all([gui, server, daemon].filter(Boolean).map((child) => child.exited));
    if (server) await api("session", "delete", session, "--json");
    await rm(directory, { recursive: true, force: true });
    const errors = cleanup.filter((result) => result.status === "rejected").map((result) => result.reason);
    if (errors.length) throw new AggregateError(errors, "Smoke cleanup failed");
  }
}, 120_000);
