import {
  createAgentSessionFromServices,
  createAgentSessionRuntime,
  createAgentSessionServices,
  getAgentDir,
  hasTrustRequiringProjectResources,
  InteractiveMode,
  ProjectTrustStore,
  runPrintMode,
  runRpcMode,
  SessionManager,
  SettingsManager
} from "@earendil-works/pi-coding-agent";
import { createHekateExtension } from "@hekate/pi-extension";
import { createInterface } from "node:readline/promises";

export function parseAgentOptions(args) {
  const options = { mode: "tui", prompt: undefined, session: true, subagents: false, projectTrust: null, noContextFiles: false };
  for (const argument of args) {
    if (argument.startsWith("--mode=")) options.mode = argument.slice(7);
    else if (argument.startsWith("--prompt=")) options.prompt = argument.slice(9);
    else if (argument === "--no-session") options.session = false;
    else if (argument === "--subagents") options.subagents = true;
    else if (argument === "--no-context-files") options.noContextFiles = true;
    else if (argument === "--trust-project" && options.projectTrust === null) options.projectTrust = true;
    else if (argument === "--no-trust-project" && options.projectTrust === null) options.projectTrust = false;
    else return null;
  }
  if (!new Set(["tui", "print", "json", "rpc"]).has(options.mode)) return null;
  if (options.mode === "rpc" && options.prompt) return null;
  return options;
}

export async function readAgentStdin(input = process.stdin, limit = 1024 * 1024) {
  if (input.isTTY) throw new Error("Print and JSON modes require --prompt or piped stdin.");
  const chunks = [];
  let bytes = 0;
  for await (const chunk of input) {
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    bytes += buffer.length;
    if (bytes > limit) throw new Error("Agent stdin exceeds the 1 MiB limit.");
    chunks.push(buffer);
  }
  const prompt = Buffer.concat(chunks).toString("utf8").trim();
  if (!prompt) throw new Error("Print and JSON modes require a non-empty prompt.");
  return prompt;
}

export async function resolveProjectTrust({ cwd, mode, override, trustStore, hasTrustResources, input = process.stdin, output = process.stdout }) {
  if (!hasTrustResources(cwd)) return true;
  if (override !== null && override !== undefined) return override;
  const stored = trustStore.get(cwd);
  if (stored !== null) return stored;
  if (mode !== "tui" || !input.isTTY || !output.isTTY) return false;
  const terminal = createInterface({ input, output });
  try {
    const trusted = /^y(?:es)?$/i.test((await terminal.question(`Trust project resources in ${cwd}? [y/N] `)).trim());
    trustStore.set(cwd, trusted);
    return trusted;
  } finally {
    terminal.close();
  }
}

export const AGENT_SIGNAL_EXIT_CODES = { SIGINT: 130, SIGTERM: 143 };

export function forwardAgentSignals(runtime, { shutdown, emitter = process, exit = (code) => process.exit(code) }) {
  const detachers = [];
  for (const [signal, code] of Object.entries(AGENT_SIGNAL_EXIT_CODES)) {
    const handler = () => {
      void (async () => {
        try {
          await runtime.session?.abort?.();
        } finally {
          await shutdown();
          exit(code);
        }
      })();
    };
    emitter.on(signal, handler);
    detachers.push(() => emitter.off(signal, handler));
  }
  return () => {
    for (const detach of detachers.splice(0)) detach();
  };
}

export async function forwardAgentStdout(stdout, run) {
  if (!stdout || stdout === process.stdout) return await run();
  const original = process.stdout.write;
  process.stdout.write = (chunk, encoding, callback) => stdout.write(chunk, encoding, callback);
  try {
    return await run();
  } finally {
    process.stdout.write = original;
  }
}

export async function runAgent(options, cwd, injected = {}) {
  const api = {
    createAgentSessionFromServices,
    createAgentSessionRuntime,
    createAgentSessionServices,
    getAgentDir,
    hasTrustRequiringProjectResources,
    InteractiveMode,
    ProjectTrustStore,
    runPrintMode,
    runRpcMode,
    SessionManager,
    SettingsManager,
    createHekateExtension,
    readAgentStdin,
    resolveProjectTrust,
    forwardAgentSignals,
    forwardAgentStdout,
    stdout: process.stdout,
    signals: process,
    exit: (code) => process.exit(code),
    ...injected
  };
  const agentDir = api.getAgentDir();
  const trustStore = new api.ProjectTrustStore(agentDir);
  const extensionFactory = api.createHekateExtension({ subagents: options.subagents });
  const createRuntime = async ({ cwd: runtimeCwd, sessionManager, sessionStartEvent }) => {
    const projectTrusted = await api.resolveProjectTrust({
      cwd: runtimeCwd,
      mode: options.mode,
      override: options.projectTrust,
      trustStore,
      hasTrustResources: api.hasTrustRequiringProjectResources
    });
    const settingsManager = api.SettingsManager.create(runtimeCwd, agentDir, { projectTrusted });
    const services = await api.createAgentSessionServices({
      cwd: runtimeCwd,
      agentDir,
      settingsManager,
      resourceLoaderOptions: {
        extensionFactories: [extensionFactory],
        noContextFiles: options.noContextFiles || !projectTrusted
      }
    });
    return {
      ...(await api.createAgentSessionFromServices({ services, sessionManager, sessionStartEvent })),
      services,
      diagnostics: services.diagnostics
    };
  };
  const sessionManager = options.session ? api.SessionManager.create(cwd) : api.SessionManager.inMemory();
  const runtime = await api.createAgentSessionRuntime(createRuntime, { cwd, agentDir, sessionManager });
  let disposed = false;
  const shutdown = async () => {
    if (disposed) return;
    disposed = true;
    await runtime.dispose();
  };
  const detachSignals = api.forwardAgentSignals(runtime, { shutdown, emitter: api.signals, exit: api.exit });
  try {
    return await api.forwardAgentStdout(api.stdout, async () => {
      if (options.mode === "rpc") return await api.runRpcMode(runtime);
      if (options.mode === "print" || options.mode === "json") {
        const prompt = options.prompt ?? await api.readAgentStdin();
        return await api.runPrintMode(runtime, { mode: options.mode === "json" ? "json" : "text", initialMessage: prompt });
      }
      const interactive = new api.InteractiveMode(runtime, { initialMessage: options.prompt, startupDiagnostics: runtime.diagnostics });
      await interactive.run();
      return 0;
    });
  } finally {
    detachSignals();
    await shutdown();
  }
}
