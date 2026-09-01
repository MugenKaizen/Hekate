import assert from "node:assert/strict";
import { cp, mkdir, mkdtemp, readFile, readdir, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { compileProject } from "@hekate/core";
import { createHekateExtension, evaluateToolCall, resolveHekateSessionState } from "../src/index.js";

const readyConfig = `schema_version: 1
hekate: {enabled: true}
workflow: {enabled: true, profile: medium, overrides: {}}
policy: {commit_consent: explicit-request-only, destructive_actions: explicit-consent, dependency_changes: explicit-consent}
enforcement: {configuration: block, destructive_actions: confirm, dependency_changes: confirm, generated_lock: protect}
extensions: {}
`;
const readyProject = `schema_version: 1
identity:
  name: {state: known, value: Hekate}
  kind: {state: known, value: cli}
  description: {state: known, value: Gate fixture}
stack:
  languages: {state: known, value: [{name: javascript}]}
  frameworks: {state: known, value: []}
  runtimes: {state: known, value: [{name: node, version: "20"}]}
  dependencies: {state: known, value: []}
verification:
  format: {state: not_applicable}
  lint: {state: not_applicable}
  test: {state: known, value: [npm test]}
  build: {state: not_applicable}
  validate: {state: not_applicable}
architecture:
  references: {state: known, value: []}
  constraints: {state: known, value: []}
confirmation: {state: confirmed}
extensions: {}
`;
const repositoryRoot = fileURLToPath(new URL("../../../", import.meta.url));

function context(overrides = {}) {
  return {
    cwd: "/project",
    hasUI: false,
    ui: { confirm: async () => false, setStatus() {} },
    ...overrides
  };
}

function registeredExtension(state) {
  const handlers = {};
  const activeTools = [];
  const entries = [];
  const commands = new Map();
  const resolveState = typeof state === "function" ? state : async () => ({
    state,
    diagnostics: [],
    verificationCommands: state === "ready" ? ["npm test"] : []
  });
  createHekateExtension({ resolveState })({
    on(name, handler) { handlers[name] = handler; },
    registerCommand(name, command) { commands.set(name, command); },
    getActiveTools() { return ["read", "grep", "find", "ls", "bash", "edit", "write"]; },
    setActiveTools(tools) { activeTools.push(tools); },
    appendEntry(type, data) { entries.push({ type, data }); }
  });
  return { handlers, activeTools, entries, commands };
}

async function readyFixture() {
  const root = await mkdtemp(path.join(tmpdir(), "hekate-extension-ready-"));
  await mkdir(path.join(root, ".workflow"));
  await writeFile(path.join(root, ".workflow/config.yml"), readyConfig);
  await writeFile(path.join(root, ".workflow/project.yml"), readyProject);
  assert.equal((await compileProject({ root })).ok, true);
  return root;
}

test("subagent tool is exposed only when explicitly enabled", () => {
  const tools = [];
  createHekateExtension({ subagents: true })({
    on() {},
    registerCommand() {},
    registerTool(tool) { tools.push(tool); },
    setActiveTools() {},
    appendEntry() {}
  });
  assert.deepEqual(tools.map((tool) => tool.name), ["subagent"]);
  const disabled = registeredExtension("ready");
  assert.equal("subagent" in disabled.handlers, false);
});

test("bootstrap UI writes only authored Hekate configuration", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "hekate-bootstrap-ui-"));
  const extension = registeredExtension(resolveHekateSessionState);
  const answers = ["medium", "Example", "cli", "npm test"];
  const notifications = [];
  await extension.commands.get("hekate-bootstrap").handler("", context({
    cwd: root,
    hasUI: true,
    ui: {
      select: async () => answers.shift(),
      input: async () => answers.shift(),
      notify: (message, level) => notifications.push({ message, level })
    }
  }));
  assert.equal((await resolveHekateSessionState(root)).state, "configuring");
  assert.deepEqual(await readdir(root), [".workflow"]);
  assert.equal(notifications.at(-1).level, "info");
  assert.deepEqual(extension.activeTools.at(-1), ["read", "grep", "find", "ls", "edit", "write"]);
  const protectedCall = await extension.handlers.tool_call({ toolName: "bash", input: { command: "pwd" } }, context({ cwd: root }));
  assert.equal(protectedCall.block, true);

  answers.push("full");
  await extension.commands.get("hekate-settings").handler("", context({
    cwd: root,
    hasUI: true,
    ui: {
      select: async () => answers.shift(),
      notify: (message, level) => notifications.push({ message, level })
    }
  }));
  assert.equal((await resolveHekateSessionState(root)).state, "configuring");
  assert.equal(notifications.at(-1).level, "info");
});

test("bootstrap replaces only exact pristine installer seeds", async () => {
  const workflowSeed = path.join(repositoryRoot, "templates/.workflow");
  const answersFor = () => ["full", "Seeded", "service", "npm test"];

  const pristineRoot = await mkdtemp(path.join(tmpdir(), "hekate-bootstrap-pristine-"));
  await mkdir(path.join(pristineRoot, ".workflow"));
  await cp(path.join(workflowSeed, "config.yml"), path.join(pristineRoot, ".workflow/config.yml"));
  await cp(path.join(workflowSeed, "project.yml"), path.join(pristineRoot, ".workflow/project.yml"));
  const pristineExtension = registeredExtension(resolveHekateSessionState);
  const pristineAnswers = answersFor();
  const pristineNotifications = [];
  await pristineExtension.commands.get("hekate-bootstrap").handler("", context({
    cwd: pristineRoot,
    hasUI: true,
    ui: {
      select: async () => pristineAnswers.shift(),
      input: async () => pristineAnswers.shift(),
      notify: (message, level) => pristineNotifications.push({ message, level })
    }
  }));
  assert.equal(pristineNotifications.at(-1).level, "info");
  assert.match(await readFile(path.join(pristineRoot, ".workflow/config.yml"), "utf8"), /"profile": "full"/);
  assert.match(await readFile(path.join(pristineRoot, ".workflow/project.yml"), "utf8"), /"value": "Seeded"/);

  for (const customizedFile of ["config.yml", "project.yml"]) {
    const root = await mkdtemp(path.join(tmpdir(), "hekate-bootstrap-custom-"));
    await mkdir(path.join(root, ".workflow"));
    await cp(path.join(workflowSeed, "config.yml"), path.join(root, ".workflow/config.yml"));
    await cp(path.join(workflowSeed, "project.yml"), path.join(root, ".workflow/project.yml"));
    const customizedPath = path.join(root, ".workflow", customizedFile);
    await writeFile(customizedPath, `${await readFile(customizedPath, "utf8")}# user customization\n`);
    const beforeConfig = await readFile(path.join(root, ".workflow/config.yml"));
    const beforeProject = await readFile(path.join(root, ".workflow/project.yml"));
    const extension = registeredExtension(resolveHekateSessionState);
    const answers = answersFor();
    const notifications = [];
    await extension.commands.get("hekate-bootstrap").handler("", context({
      cwd: root,
      hasUI: true,
      ui: {
        select: async () => answers.shift(),
        input: async () => answers.shift(),
        notify: (message, level) => notifications.push({ message, level })
      }
    }));
    assert.equal(notifications.at(-1).level, "error");
    assert.match(notifications.at(-1).message, /does not overwrite customized/);
    assert.deepEqual(await readFile(path.join(root, ".workflow/config.yml")), beforeConfig);
    assert.deepEqual(await readFile(path.join(root, ".workflow/project.yml")), beforeProject);
  }
});

test("absent and disabled projects remain unaffected", async () => {
  for (const state of ["absent", "off"]) {
    const extension = registeredExtension(state);
    await extension.handlers.session_start({}, context());
    assert.deepEqual(extension.activeTools, []);
    assert.deepEqual(extension.entries, []);
    assert.equal(await extension.handlers.tool_call({ toolName: "custom", input: {} }, context()), undefined);
  }
});

test("real disabled core states resolve to extension no-op", async () => {
  const project = `schema_version: 1
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
confirmation: {state: pending}
extensions: {}
`;
  for (const disabled of ["hekate", "workflow"]) {
    const root = await mkdtemp(path.join(tmpdir(), "hekate-extension-state-"));
    await mkdir(path.join(root, ".workflow"));
    await writeFile(path.join(root, ".workflow", "config.yml"), `schema_version: 1
hekate: {enabled: ${disabled !== "hekate"}}
workflow: {enabled: ${disabled !== "workflow"}, profile: medium, overrides: {}}
policy: {commit_consent: explicit-request-only, destructive_actions: explicit-consent, dependency_changes: explicit-consent}
enforcement: {configuration: block, destructive_actions: confirm, dependency_changes: confirm, generated_lock: protect}
extensions: {}
`);
    await writeFile(path.join(root, ".workflow", "project.yml"), project);
    assert.equal((await resolveHekateSessionState(root)).state, "off");
  }
});

test("blocked projects expose only known read-only tools in every mode", async () => {
  for (const mode of ["tui", "print", "json", "rpc"]) {
    const extension = registeredExtension("blocked");
    await extension.handlers.session_start({}, context({ mode }));
    assert.deepEqual(extension.activeTools, [["read", "grep", "find", "ls"]]);
    assert.equal(await extension.handlers.tool_call({ toolName: "read", input: {} }, context({ mode })), undefined);
    assert.equal((await extension.handlers.tool_call({ toolName: "bash", input: { command: "pwd" } }, context({ mode }))).block, true);
    assert.equal((await extension.handlers.tool_call({ toolName: "unknown", input: {} }, context({ mode }))).block, true);
  }
});

test("live gate blocks mutation when a ready project becomes stale or forged", async () => {
  for (const mode of ["tui", "print", "json", "rpc"]) {
    for (const change of ["authored", "malformed-lock", "forged-lock"]) {
      const root = await readyFixture();
      const extension = registeredExtension(resolveHekateSessionState);
      await extension.handlers.session_start({}, context({ cwd: root, mode }));
      assert.equal(extension.entries.at(-1).data.state, "ready");

      const lockPath = path.join(root, ".workflow/status.lock.json");
      if (change === "authored") await writeFile(path.join(root, ".workflow/project.yml"), `${readyProject}\n# stale\n`);
      else if (change === "malformed-lock") await writeFile(lockPath, "{\n");
      else await writeFile(lockPath, Buffer.concat([await readFile(lockPath), Buffer.from("\n")]));

      assert.equal(await extension.handlers.tool_call({ toolName: "read", input: { path: "README.md" } }, context({ cwd: root, mode })), undefined);
      const decision = await extension.handlers.tool_call({ toolName: "edit", input: { path: "src/app.js" } }, context({ cwd: root, mode }));
      assert.equal(decision.block, true, `${mode} ${change}`);
      assert.deepEqual(extension.activeTools.at(-1), ["read", "grep", "find", "ls"]);
      assert.equal(extension.entries.at(-1).data.state, "blocked");
    }
  }
});

test("configuration mode limits writes to authored Hekate files", async () => {
  const session = { state: "configuring" };
  assert.equal(await evaluateToolCall(session, { toolName: "write", input: { path: ".workflow/config.yml" } }, context()), undefined);
  assert.equal((await evaluateToolCall(session, { toolName: "edit", input: { path: "src/app.js" } }, context())).block, true);
  assert.equal((await evaluateToolCall(session, { toolName: "bash", input: { command: "touch .workflow/config.yml" } }, context())).block, true);
});

test("ready mode protects generated and authorization state without prompt injection", async () => {
  const session = { state: "ready" };
  assert.equal((await evaluateToolCall(session, { toolName: "write", input: { path: ".workflow/status.lock.json" } }, context())).block, true);
  assert.equal((await evaluateToolCall(session, { toolName: "edit", input: { path: ".pi/settings.json" } }, context())).block, true);
  assert.equal(await evaluateToolCall(session, { toolName: "edit", input: { path: "src/app.js" } }, context()), undefined);

  const extension = registeredExtension("ready");
  assert.deepEqual(Object.keys(extension.handlers).sort(), ["session_start", "tool_call", "tool_result"]);
});

test("destructive commands require affirmative interactive confirmation", async () => {
  for (const command of ["rm -rf build", "rm -fr build", "git clean -df", "Remove-Item build -Force -Recurse"]) {
    const event = { toolName: command.startsWith("Remove") ? "powershell" : "bash", input: { command } };
    assert.equal((await evaluateToolCall({ state: "ready" }, event, context())).block, true);
    assert.equal((await evaluateToolCall({ state: "ready" }, event, context({ hasUI: true, ui: { confirm: async () => false } }))).block, true);
    assert.equal(await evaluateToolCall({ state: "ready" }, event, context({ hasUI: true, ui: { confirm: async () => true } })), undefined);
  }
});

test("permission bypass and dependency changes fail closed", async () => {
  for (const command of ["tool --dangerously-bypass-permissions", "git commit --no-verify"]) {
    assert.equal((await evaluateToolCall({ state: "ready" }, { toolName: "bash", input: { command } }, context({ hasUI: true, ui: { confirm: async () => true } }))).block, true);
  }
  for (const command of ["npm install left-pad", "pip install flask", "choco install git"]) {
    const event = { toolName: "bash", input: { command } };
    assert.equal((await evaluateToolCall({ state: "ready" }, event, context())).block, true);
    assert.equal(await evaluateToolCall({ state: "ready" }, event, context({ hasUI: true, ui: { confirm: async () => true } })), undefined);
  }
});

test("shell cannot mutate protected state and verification evidence stays out of prompts", async () => {
  const protectedWrite = { toolName: "bash", input: { command: "rm .workflow/status.lock.json" } };
  assert.equal((await evaluateToolCall({ state: "ready" }, protectedWrite, context({ hasUI: true, ui: { confirm: async () => true } }))).block, true);
  for (const command of [
    "command rm .workflow/status.lock.json",
    "sudo rm .workflow/status.lock.json",
    "env LC_ALL=C rm .workflow/status.lock.json",
    "xargs rm < paths .workflow/status.lock.json",
    "touch .workflow/status.lock.json",
    "ln -sf forged .workflow/status.lock.json"
  ]) {
    const result = await evaluateToolCall({ state: "ready" }, { toolName: "bash", input: { command } }, context({ hasUI: true, ui: { confirm: async () => true } }));
    assert.equal(result.block, true, command);
  }
  assert.equal(await evaluateToolCall({ state: "ready" }, { toolName: "bash", input: { command: "cat .workflow/status.lock.json" } }, context()), undefined);
  const windowsProtectedWrite = { toolName: "powershell", input: { command: "Set-Content .WORKFLOW\\STATUS.LOCK.JSON bad" } };
  assert.equal((await evaluateToolCall({ state: "ready" }, windowsProtectedWrite, context({ hasUI: true, ui: { confirm: async () => true } }))).block, true);

  const extension = registeredExtension("ready");
  await extension.handlers.session_start({}, context());
  const call = { toolCallId: "verify-1", toolName: "bash", input: { command: "npm test" } };
  assert.equal(await extension.handlers.tool_call(call, context()), undefined);
  extension.handlers.tool_result({ toolCallId: "verify-1", isError: false }, context());
  assert.deepEqual(extension.entries.at(-1), {
    type: "hekate-verification",
    data: { command: "npm test", passed: true }
  });
});

test("ready state adds nothing to model context", async () => {
  const used = new Set();
  const allowed = new Set(["on", "registerCommand", "registerTool", "getActiveTools", "setActiveTools", "appendEntry"]);
  const handlers = {};
  const entries = [];
  const base = {
    on(name, handler) { handlers[name] = handler; },
    registerCommand() {},
    getActiveTools() { return ["read", "bash", "edit"]; },
    setActiveTools() {},
    appendEntry(type, data) { entries.push({ type, data }); }
  };
  const pi = new Proxy(base, {
    get(target, property) {
      if (typeof property !== "string") return target[property];
      used.add(property);
      if (!allowed.has(property)) {
        throw new Error(`ready state used a context-injecting Pi API: ${property}`);
      }
      return target[property];
    }
  });
  createHekateExtension({
    resolveState: async () => ({ state: "ready", diagnostics: [], verificationCommands: ["npm test"] })
  })(pi);

  await handlers.session_start({}, context());
  assert.equal(await handlers.tool_call({ toolName: "edit", input: { path: "src/app.js" } }, context()), undefined);

  // Custom session entries are the only record Hekate keeps; they never enter
  // the model prompt.
  assert.deepEqual([...new Set(entries.map((entry) => entry.type))], ["hekate-state"]);
  for (const property of used) {
    assert.ok(allowed.has(property), `unexpected Pi API in ready state: ${property}`);
  }
});
