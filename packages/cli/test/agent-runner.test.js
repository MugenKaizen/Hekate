import assert from "node:assert/strict";
import { mkdir, mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { createAgentSessionServices, SettingsManager } from "@earendil-works/pi-coding-agent";
import { AGENT_SIGNAL_EXIT_CODES, forwardAgentSignals, parseAgentOptions, readAgentStdin, resolveProjectTrust, runAgent } from "../src/agent-runner.js";
import { EventEmitter } from "node:events";
import { PassThrough, Readable } from "node:stream";

function fakeApi(events) {
  class InteractiveMode {
    constructor(runtime, options) { events.push(["tui-create", runtime, options]); }
    async run() { events.push(["tui-run"]); }
  }
  return {
    getAgentDir: () => "/agent",
    createHekateExtension: () => "mandatory-extension",
    hasTrustRequiringProjectResources: () => true,
    ProjectTrustStore: class { get() { return null; } set() {} },
    SettingsManager: { create: (cwd, agentDir, options) => ({ cwd, agentDir, ...options }) },
    resolveProjectTrust: async ({ override }) => override ?? false,
    readAgentStdin: async () => "stdin task",
    SessionManager: {
      create: (cwd) => ({ type: "persistent", cwd }),
      inMemory: () => ({ type: "memory" })
    },
    createAgentSessionServices: async (options) => {
      events.push(["services", options]);
      return { diagnostics: [], marker: "services" };
    },
    createAgentSessionFromServices: async (options) => ({
      session: { marker: "session", options, abort: async () => { events.push(["abort"]); } }
    }),
    createAgentSessionRuntime: async (factory, options) => {
      const created = await factory({ cwd: options.cwd, sessionManager: options.sessionManager });
      return { ...created, diagnostics: [], async dispose() { events.push(["dispose"]); } };
    },
    runPrintMode: async (_runtime, options) => { events.push(["print", options]); return 17; },
    runRpcMode: async () => { events.push(["rpc"]); return 19; },
    InteractiveMode
  };
}

test("agent option parsing rejects inconsistent modes", () => {
  assert.deepEqual(parseAgentOptions(["--mode=json", "--prompt=hello", "--no-session", "--subagents", "--no-context-files", "--no-trust-project"]), {
    mode: "json", prompt: "hello", session: false, subagents: true, projectTrust: false, noContextFiles: true
  });
  assert.equal(parseAgentOptions(["--mode=json"]).prompt, undefined);
  assert.equal(parseAgentOptions(["--mode=rpc", "--prompt=no"]), null);
  assert.equal(parseAgentOptions(["--trust-project", "--no-trust-project"]), null);
  assert.equal(parseAgentOptions(["--unknown"]), null);
});

test("print and JSON prompts accept bounded stdin", async () => {
  const input = Readable.from(["review ", "this\n"]);
  input.isTTY = false;
  assert.equal(await readAgentStdin(input), "review this");
  const oversized = Readable.from(["12345"]);
  oversized.isTTY = false;
  await assert.rejects(() => readAgentStdin(oversized, 4), /exceeds/);

  const events = [];
  await runAgent({ mode: "json", prompt: undefined, session: false, subagents: false, projectTrust: false, noContextFiles: false }, "/project", fakeApi(events));
  assert.equal(events.find(([name]) => name === "print")[1].initialMessage, "stdin task");
});

test("project resources are untrusted by default outside TUI", async () => {
  const trustStore = { get: () => null, set: () => assert.fail("must not persist an implicit decision") };
  const hasTrustResources = () => true;
  assert.equal(await resolveProjectTrust({ cwd: "/project", mode: "json", override: null, trustStore, hasTrustResources }), false);
  assert.equal(await resolveProjectTrust({ cwd: "/project", mode: "json", override: true, trustStore, hasTrustResources }), true);
  assert.equal(await resolveProjectTrust({ cwd: "/plain", mode: "json", override: null, trustStore, hasTrustResources: () => false }), true);
});

test("untrusted project context files are disabled independently of the CLI flag", async () => {
  const events = [];
  await runAgent({ mode: "print", prompt: "task", session: false, subagents: false, projectTrust: false, noContextFiles: false }, "/project", fakeApi(events));
  const services = events.find(([name]) => name === "services")[1];
  assert.equal(services.resourceLoaderOptions.noContextFiles, true);
});

test("pinned Pi services exclude untrusted project settings while retaining inline extensions", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "hekate-pi-trust-"));
  const agentDir = await mkdtemp(path.join(tmpdir(), "hekate-pi-agent-"));
  await mkdir(path.join(root, ".pi"));
  await writeFile(path.join(root, ".pi", "settings.json"), '{"theme":"project-theme"}\n');
  const settingsManager = SettingsManager.create(root, agentDir, { projectTrusted: false });
  let loaded = false;
  const services = await createAgentSessionServices({
    cwd: root,
    agentDir,
    settingsManager,
    resourceLoaderOptions: {
      noContextFiles: true,
      extensionFactories: [() => { loaded = true; }]
    }
  });
  assert.equal(services.settingsManager.isProjectTrusted(), false);
  assert.deepEqual(services.settingsManager.getProjectSettings(), {});
  assert.equal(services.settingsManager.getTheme(), undefined);
  assert.equal(services.resourceLoader.getAgentsFiles().agentsFiles.length, 0);
  assert.equal(loaded, true);
});

test("wrapper dispatches all Pi modes with a mandatory inline extension", async () => {
  for (const mode of ["tui", "print", "json", "rpc"]) {
    const events = [];
    const result = await runAgent({ mode, prompt: ["print", "json"].includes(mode) ? "task" : undefined, session: false, subagents: false, projectTrust: false, noContextFiles: true }, "/project", fakeApi(events));
    const services = events.find(([name]) => name === "services")[1];
    assert.deepEqual(services.resourceLoaderOptions.extensionFactories, ["mandatory-extension"]);
    assert.equal(services.resourceLoaderOptions.noContextFiles, true);
    assert.equal(services.settingsManager.projectTrusted, false);
    assert.ok(events.some(([name]) => name === ({ tui: "tui-run", print: "print", json: "print", rpc: "rpc" })[mode]));
    assert.equal(events.at(-1)[0], "dispose");
    assert.equal(result, { tui: 0, print: 17, json: 17, rpc: 19 }[mode]);
  }
});

function deferred() {
  let resolve;
  const promise = new Promise((settle) => { resolve = settle; });
  return { promise, resolve };
}

function holdingApi(events, hold) {
  return {
    ...fakeApi(events),
    runPrintMode: async (_runtime, options) => { events.push(["print", options]); await hold; return 17; },
    runRpcMode: async () => { events.push(["rpc"]); await hold; return 19; },
    InteractiveMode: class {
      constructor() { events.push(["tui-create"]); }
      async run() { events.push(["tui-run"]); await hold; }
    }
  };
}

async function until(condition) {
  while (!condition()) await new Promise(setImmediate);
}

function agentOptions(mode) {
  return { mode, prompt: ["print", "json"].includes(mode) ? "task" : undefined, session: false, subagents: false, projectTrust: false, noContextFiles: true };
}

test("wrapper forwards signals to the runtime and exits with the conventional code in every mode", async () => {
  for (const mode of ["tui", "print", "json", "rpc"]) {
    for (const [signal, code] of Object.entries(AGENT_SIGNAL_EXIT_CODES)) {
      const events = [];
      const hold = deferred();
      const signals = new EventEmitter();
      const exits = [];
      const run = runAgent(agentOptions(mode), "/project", { ...holdingApi(events, hold.promise), signals, exit: (exitCode) => exits.push(exitCode) });
      await until(() => signals.listenerCount(signal) > 0);
      signals.emit(signal);
      await until(() => exits.length > 0);
      assert.deepEqual(exits, [code]);
      assert.ok(events.findIndex(([name]) => name === "abort") < events.findIndex(([name]) => name === "dispose"));
      hold.resolve();
      await run;
      assert.equal(events.filter(([name]) => name === "dispose").length, 1);
    }
  }
});

test("signal handlers are detached once the run finishes", async () => {
  for (const mode of ["tui", "print", "json", "rpc"]) {
    const events = [];
    const signals = new EventEmitter();
    await runAgent(agentOptions(mode), "/project", { ...fakeApi(events), signals, exit: () => assert.fail("must not exit on a clean run") });
    for (const signal of Object.keys(AGENT_SIGNAL_EXIT_CODES)) assert.equal(signals.listenerCount(signal), 0);
    assert.ok(!events.some(([name]) => name === "abort"));
  }
});

test("signal forwarding cancels the session and never leaks listeners", async () => {
  const emitter = new EventEmitter();
  const aborted = [];
  const exits = [];
  const detach = forwardAgentSignals({ session: { abort: async () => aborted.push("abort") } }, {
    shutdown: async () => aborted.push("shutdown"),
    emitter,
    exit: (code) => exits.push(code)
  });
  emitter.emit("SIGTERM");
  await until(() => exits.length > 0);
  assert.deepEqual(aborted, ["abort", "shutdown"]);
  assert.deepEqual(exits, [AGENT_SIGNAL_EXIT_CODES.SIGTERM]);
  detach();
  assert.equal(emitter.listenerCount("SIGTERM"), 0);
  assert.equal(emitter.listenerCount("SIGINT"), 0);
  detach();
});

test("runtime stdout is forwarded to the wrapper sink in every non-TUI mode", async () => {
  const originalWrite = process.stdout.write;
  for (const mode of ["print", "json", "rpc"]) {
    const events = [];
    const sink = new PassThrough();
    const chunks = [];
    sink.on("data", (chunk) => chunks.push(chunk.toString()));
    const api = fakeApi(events);
    const write = (name) => { process.stdout.write(`${name} output\n`); };
    await runAgent(agentOptions(mode), "/project", {
      ...api,
      stdout: sink,
      signals: new EventEmitter(),
      exit: () => assert.fail("must not exit on a clean run"),
      runPrintMode: async (runtime, options) => { write("print"); return api.runPrintMode(runtime, options); },
      runRpcMode: async (runtime) => { write("rpc"); return api.runRpcMode(runtime); }
    });
    await new Promise(setImmediate);
    assert.deepEqual(chunks, [`${mode === "rpc" ? "rpc" : "print"} output\n`]);
    assert.equal(process.stdout.write, originalWrite);
  }
});
