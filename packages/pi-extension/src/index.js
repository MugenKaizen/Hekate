import path from "node:path";
import { lstat, mkdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import { compileProject } from "@hekate/core";
import { executePiChild, runSubagents } from "@hekate/subagents";
import { Type } from "typebox";

const READ_TOOLS = ["read", "grep", "find", "ls"];
const CONFIG_TOOLS = [...READ_TOOLS, "edit", "write"];
const MUTATION_TOOLS = new Set(["bash", "powershell", "edit", "write"]);
const CONFIG_PATHS = new Set([".workflow/config.yml", ".workflow/project.yml"]);
const PROTECTED_PATHS = new Set([
  ".pi/settings.json",
  ".workflow/install-state.json",
  ".workflow/status.lock.json",
  ".workflow/update.lock"
]);
const PROFILES = ["fast", "medium", "full", "custom"];
const SHELL_MUTATION = /(?:^|[;&|]\s*)(?:(?:command|builtin|nohup|sudo|xargs)\s+|env(?:\s+(?:-[^\s]+|[A-Za-z_][A-Za-z0-9_]*=[^\s]+))*\s+)*(?:rm|mv|cp|install|tee|truncate|touch|unlink|ln|sed\s+-i|set-content|remove-item|move-item|copy-item|new-item|node\s+-e|python(?:3)?\s+-c|powershell(?:\.exe)?\s+-command|pwsh\s+-command)\b|(?:^|[^<])>{1,2}(?!>)/i;
const BYPASS_FLAG = /(?:^|\s)(?:--dangerously-bypass-(?:approvals-and-sandbox|permissions)|--no-verify|--force-with-lease\s*=(?:false|0))(?=\s|$)/i;
const DEPENDENCY_COMMAND = /(?:^|[;&|]\s*)(?:(?:npm|pnpm|yarn|bun)\s+(?:add|install|remove|uninstall|update|upgrade|link)|pip(?:3)?\s+(?:install|uninstall)|poetry\s+(?:add|remove|update|install)|cargo\s+(?:add|remove|update|install)|dotnet\s+(?:add|remove)\s+\S*package|go\s+get|gem\s+(?:install|uninstall|update)|(?:apt-get|apt|brew|choco|winget)\s+(?:install|remove|upgrade|update))\b/i;
const PRISTINE_CONFIG = Buffer.from(`schema_version: 1
hekate:
  enabled: true
workflow:
  enabled: true
  profile: medium
  overrides: {}
policy:
  commit_consent: explicit-request-only
  destructive_actions: explicit-consent
  dependency_changes: explicit-consent
enforcement:
  configuration: block
  destructive_actions: confirm
  dependency_changes: confirm
  generated_lock: protect
extensions: {}
`);
const PRISTINE_PROJECT = Buffer.from(`schema_version: 1
identity:
  name: {state: unknown}
  kind: {state: unknown}
  description: {state: unknown}
stack:
  languages: {state: unknown}
  frameworks: {state: unknown}
  runtimes: {state: unknown}
  dependencies: {state: unknown}
verification:
  format: {state: unknown}
  lint: {state: unknown}
  test: {state: unknown}
  build: {state: unknown}
  validate: {state: unknown}
architecture:
  references: {state: unknown}
  constraints: {state: unknown}
confirmation:
  state: pending
extensions: {}
`);

function isDestructiveCommand(command) {
  if (/\bgit\s+(?:reset\s+--hard|clean\s+(?=[^\n;&|]*-[a-z]*f)|push\s+[^\n;&|]*(?:--force(?:-with-lease)?|-f\b))/i.test(command)) return true;
  if (/\b(?:chmod|chown)\s+(?:-[^\s]*R[^\s]*\s+|--recursive\b)/i.test(command)) return true;
  if (/\bremove-item\b(?=[^\n;&|]*(?:-recurse|-force))/i.test(command)) return true;
  return /\brm\b/i.test(command)
    && /\brm\s+(?=[^\n;&|]*(?:-[a-z]*r|--recursive))(?=[^\n;&|]*(?:-[a-z]*f|--force))/i.test(command);
}

function mutatesProtectedPath(command) {
  const normalized = command.replaceAll("\\", "/").toLowerCase();
  return SHELL_MUTATION.test(normalized)
    && [...PROTECTED_PATHS].some((protectedPath) => normalized.includes(protectedPath.toLowerCase()));
}

function relativeProjectPath(cwd, inputPath) {
  if (typeof inputPath !== "string" || inputPath.length === 0) return null;
  const absolute = path.resolve(cwd, inputPath);
  const relative = path.relative(cwd, absolute).split(path.sep).join("/");
  if (relative === ".." || relative.startsWith("../") || path.isAbsolute(relative)) return null;
  return relative;
}

function inputPath(event) {
  return event.input?.path ?? event.input?.file_path ?? event.input?.filePath ?? null;
}

function authoredBootstrap(profile, name, kind, testCommand) {
  const config = {
    schema_version: 1,
    hekate: { enabled: true },
    workflow: { enabled: true, profile, overrides: {} },
    policy: { commit_consent: "explicit-request-only", destructive_actions: "explicit-consent", dependency_changes: "explicit-consent" },
    enforcement: { configuration: "block", destructive_actions: "confirm", dependency_changes: "confirm", generated_lock: "protect" },
    extensions: {}
  };
  const unknown = { state: "unknown" };
  const project = {
    schema_version: 1,
    identity: { name: { state: "known", value: name }, kind: { state: "known", value: kind }, description: unknown },
    stack: { languages: unknown, frameworks: unknown, runtimes: unknown, dependencies: unknown },
    verification: {
      format: unknown,
      lint: unknown,
      test: testCommand ? { state: "known", value: [testCommand] } : unknown,
      build: unknown,
      validate: unknown
    },
    architecture: { references: unknown, constraints: unknown },
    confirmation: { state: "pending" },
    extensions: {}
  };
  return {
    config: Buffer.from(`${JSON.stringify(config, null, 2)}\n`),
    project: Buffer.from(`${JSON.stringify(project, null, 2)}\n`)
  };
}

async function ensureWorkflowDirectory(cwd) {
  const workflow = path.join(cwd, ".workflow");
  try {
    const metadata = await lstat(workflow);
    if (!metadata.isDirectory() || metadata.isSymbolicLink()) throw new Error(".workflow must be a real directory");
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
    await mkdir(workflow, { mode: 0o700 });
  }
  return workflow;
}

async function optionalAuthoredBytes(file) {
  try {
    const metadata = await lstat(file);
    if (!metadata.isFile() || metadata.isSymbolicLink()) throw new Error("Authored Hekate paths must be regular files.");
    return await readFile(file);
  } catch (error) {
    if (error.code === "ENOENT") return null;
    throw error;
  }
}

async function atomicAuthoredWrite(file, bytes) {
  const temporary = `${file}.hekate-${process.pid}-${Date.now()}.tmp`;
  await writeFile(temporary, bytes, { flag: "wx", mode: 0o600 });
  try { await rename(temporary, file); }
  finally { await rm(temporary, { force: true }); }
}

async function bootstrapProject(cwd, ui) {
  const profile = await ui.select("Hekate workflow profile", PROFILES);
  if (!profile) return false;
  const name = (await ui.input("Project name", path.basename(cwd)))?.trim();
  if (!name) return false;
  const kind = await ui.select("Project kind", ["web-app", "cli", "library", "service", "mobile", "monorepo", "documentation", "other"]);
  if (!kind) return false;
  const testCommand = (await ui.input("Primary test command", "Leave empty when not applicable"))?.trim() ?? "";
  const workflow = await ensureWorkflowDirectory(cwd);
  const configPath = path.join(workflow, "config.yml");
  const projectPath = path.join(workflow, "project.yml");
  const authored = authoredBootstrap(profile, name, kind, testCommand);
  const previousConfig = await optionalAuthoredBytes(configPath);
  const previousProject = await optionalAuthoredBytes(projectPath);
  if ((previousConfig && !previousConfig.equals(PRISTINE_CONFIG)) || (previousProject && !previousProject.equals(PRISTINE_PROJECT))) {
    throw new Error("Hekate bootstrap does not overwrite customized authored configuration.");
  }
  try {
    await atomicAuthoredWrite(configPath, authored.config);
    await atomicAuthoredWrite(projectPath, authored.project);
  } catch (error) {
    if (previousConfig) await atomicAuthoredWrite(configPath, previousConfig);
    else await rm(configPath, { force: true });
    if (previousProject) await atomicAuthoredWrite(projectPath, previousProject);
    else await rm(projectPath, { force: true });
    throw error;
  }
  const result = await compileProject({ root: cwd });
  if (!result.ok && !(result.lockStatus === "current" && ["needs_configuration", "needs_confirmation"].includes(result.gateState))) {
    throw new Error(`Hekate bootstrap validation failed: ${result.gateState}`);
  }
  return true;
}

async function updateProfile(cwd, ui) {
  const profile = await ui.select("Hekate workflow profile", PROFILES);
  if (!profile) return false;
  const configPath = path.join(cwd, ".workflow", "config.yml");
  const source = await readFile(configPath, "utf8");
  let updated;
  if (source.trimStart().startsWith("{")) {
    const document = JSON.parse(source);
    if (!PROFILES.includes(document?.workflow?.profile)) throw new Error("Hekate settings requires a valid workflow profile field.");
    document.workflow.profile = profile;
    updated = `${JSON.stringify(document, null, 2)}\n`;
  } else {
    const pattern = /^(\s*profile:\s*)(fast|medium|full|custom)(\s*(?:#.*)?)$/gm;
    const matches = [...source.matchAll(pattern)];
    if (matches.length !== 1) throw new Error("Hekate settings requires one unambiguous workflow profile field.");
    updated = source.replace(pattern, `$1${profile}$3`);
  }
  const temporary = `${configPath}.hekate-${process.pid}-${Date.now()}.tmp`;
  await writeFile(temporary, updated, { flag: "wx", mode: 0o600 });
  try { await rename(temporary, configPath); }
  finally { await rm(temporary, { force: true }); }
  const result = await compileProject({ root: cwd });
  if (!result.ok && !(result.lockStatus === "current" && ["needs_configuration", "needs_confirmation"].includes(result.gateState))) {
    const rollback = `${temporary}.rollback`;
    await writeFile(rollback, source, { flag: "wx", mode: 0o600 });
    await rename(rollback, configPath);
    throw new Error(`Hekate settings validation failed: ${result.gateState}`);
  }
  return true;
}

export async function resolveHekateSessionState(cwd) {
  const result = await compileProject({ root: cwd, mode: "check" });
  if (result.gateState === "absent") return { state: "absent", diagnostics: [] };
  if (["off", "workflow_disabled"].includes(result.gateState)) {
    return { state: "off", diagnostics: result.diagnostics };
  }
  if (result.ok) return {
    state: "ready",
    diagnostics: [],
    verificationCommands: result.lock?.verification_commands?.map(({ run }) => run) ?? []
  };
  if (result.lockStatus === "current" && ["needs_configuration", "needs_confirmation"].includes(result.gateState)) {
    return { state: "configuring", diagnostics: result.diagnostics };
  }
  return { state: "blocked", diagnostics: result.diagnostics };
}

export async function evaluateToolCall(session, event, ctx) {
  if (["absent", "off"].includes(session.state)) return undefined;

  if (session.state === "blocked") {
    if (READ_TOOLS.includes(event.toolName)) return undefined;
    return { block: true, reason: "Hekate project is invalid or stale; only read-only tools are available." };
  }

  if (session.state === "configuring") {
    if (READ_TOOLS.includes(event.toolName)) return undefined;
    if (["edit", "write"].includes(event.toolName)) {
      const relative = relativeProjectPath(ctx.cwd, inputPath(event));
      if (relative && CONFIG_PATHS.has(relative)) return undefined;
    }
    return { block: true, reason: "Hekate configuration mode permits writes only to declared authored config files." };
  }

  if (["edit", "write"].includes(event.toolName)) {
    const relative = relativeProjectPath(ctx.cwd, inputPath(event));
    if (!relative || PROTECTED_PATHS.has(relative)) {
      return { block: true, reason: "Direct writes to generated Hekate state or Pi authorization settings are blocked." };
    }
  }

  if (["bash", "powershell"].includes(event.toolName)) {
    const command = event.input?.command;
    if (typeof command === "string" && BYPASS_FLAG.test(command)) {
      return { block: true, reason: "Permission and approval bypass flags are not allowed." };
    }
    if (typeof command === "string" && mutatesProtectedPath(command)) {
      return { block: true, reason: "Shell mutation of generated Hekate state or Pi authorization settings is blocked." };
    }
    if (typeof command === "string" && isDestructiveCommand(command)) {
      if (!ctx.hasUI) return { block: true, reason: "Destructive commands require interactive confirmation." };
      const confirmed = await ctx.ui?.confirm?.("Destructive operation", command);
      if (!confirmed) return { block: true, reason: "Destructive command was not confirmed." };
    }
    if (typeof command === "string" && DEPENDENCY_COMMAND.test(command)) {
      if (!ctx.hasUI) return { block: true, reason: "Dependency changes require interactive confirmation." };
      const confirmed = await ctx.ui?.confirm?.("Dependency change", command);
      if (!confirmed) return { block: true, reason: "Dependency change was not confirmed." };
    }
  }
  return undefined;
}

export function createHekateExtension(options = {}) {
  const resolveState = options.resolveState ?? resolveHekateSessionState;
  return function hekateExtension(pi) {
    let session = { state: "absent", diagnostics: [] };
    let normalTools = null;
    const verificationCalls = new Map();
    const refreshSession = async (ctx, restoreNormalTools = false) => {
      normalTools ??= pi.getActiveTools?.() ?? null;
      const previous = session;
      session = await resolveState(ctx.cwd);
      if (session.state === "blocked") pi.setActiveTools(READ_TOOLS);
      else if (session.state === "configuring") pi.setActiveTools(CONFIG_TOOLS);
      else if (restoreNormalTools && normalTools && previous.state !== session.state) pi.setActiveTools(normalTools);
      const changed = previous.state !== session.state
        || JSON.stringify(previous.diagnostics ?? []) !== JSON.stringify(session.diagnostics ?? []);
      if (changed && !["absent", "off"].includes(session.state)) {
        pi.appendEntry("hekate-state", { state: session.state, diagnostics: session.diagnostics });
        ctx.ui?.setStatus?.("hekate", session.state);
      }
    };
    pi.registerCommand?.("hekate-bootstrap", {
      description: "Initialize Hekate authored configuration without changing project source",
      async handler(_args, ctx) {
        if (!ctx.hasUI) { ctx.ui?.notify?.("Hekate bootstrap requires interactive mode.", "error"); return; }
        try {
          const changed = await bootstrapProject(ctx.cwd, ctx.ui);
          if (changed) {
            await refreshSession(ctx, true);
            ctx.ui?.notify?.("Hekate configuration initialized; complete unknown facts before mutation.", "info");
          }
        } catch (error) { ctx.ui?.notify?.(error.message, "error"); }
      }
    });
    pi.registerCommand?.("hekate-settings", {
      description: "Change validated Hekate workflow settings",
      async handler(_args, ctx) {
        if (!ctx.hasUI) { ctx.ui?.notify?.("Hekate settings requires interactive mode.", "error"); return; }
        try {
          const changed = await updateProfile(ctx.cwd, ctx.ui);
          if (changed) {
            await refreshSession(ctx, true);
            ctx.ui?.notify?.("Hekate profile updated.", "info");
          }
        } catch (error) { ctx.ui?.notify?.(error.message, "error"); }
      }
    });
    if (options.subagents) {
      pi.registerTool({
        name: "subagent",
        label: "Subagents",
        description: "Run bounded advisory Pi children. Results always require parent review.",
        parameters: Type.Object({
          tasks: Type.Array(Type.Object({
            role: Type.Union([Type.Literal("researcher"), Type.Literal("reviewer"), Type.Literal("verifier"), Type.Literal("writer")]),
            prompt: Type.String(),
            cwd: Type.Optional(Type.String()),
            write: Type.Optional(Type.Boolean())
          }), { minItems: 1, maxItems: options.maxTasks ?? 8 })
        }),
        async execute(_id, params, signal, _update, ctx) {
          const tasks = params.tasks.map((task) => ({ ...task, cwd: task.cwd ?? ctx.cwd }));
          const results = await runSubagents(tasks, {
            execute: (task) => executePiChild(task, options.childOptions),
            concurrency: options.concurrency ?? 2,
            maxTasks: options.maxTasks ?? 8,
            maxTokens: options.maxTokens ?? Infinity,
            maxCost: options.maxCost ?? Infinity,
            outputLimit: options.outputLimit ?? 64 * 1024,
            parentCwd: ctx.cwd,
            signal
          });
          const summary = results.map((result, index) => `${index + 1}. ${result.role}: ${result.status}${result.truncated ? " (output truncated)" : ""}`).join("\n");
          return { content: [{ type: "text", text: summary }], details: { results } };
        }
      });
    }
    pi.on("session_start", async (_event, ctx) => {
      await refreshSession(ctx);
    });
    pi.on("tool_call", async (event, ctx) => {
      if (!READ_TOOLS.includes(event.toolName)) await refreshSession(ctx, true);
      const decision = await evaluateToolCall(session, event, ctx);
      const command = event.input?.command;
      if (!decision?.block && ["bash", "powershell"].includes(event.toolName) && typeof command === "string"
        && session.verificationCommands?.includes(command.trim())) {
        verificationCalls.set(event.toolCallId, command);
      }
      return decision;
    });
    pi.on("tool_result", (event, ctx) => {
      const command = verificationCalls.get(event.toolCallId);
      if (!command) return;
      verificationCalls.delete(event.toolCallId);
      const result = { command, passed: !event.isError };
      pi.appendEntry("hekate-verification", result);
      ctx.ui?.setStatus?.("hekate-verification", result.passed ? "passed" : "failed");
    });
  };
}

export default createHekateExtension();
