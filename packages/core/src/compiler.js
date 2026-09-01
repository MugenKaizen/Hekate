import { createHash, randomBytes } from "node:crypto";
import { constants, lstat, open, readFile, realpath, rename, unlink } from "node:fs/promises";
import path from "node:path";
import { canonicalBytes } from "./canonical-json.js";
import { parseYaml } from "./parser.js";
import { validateSchema } from "./validator.js";

const CONFIG_PATH = ".workflow/config.yml";
const PROJECT_PATH = ".workflow/project.yml";
const LOCK_PATH = ".workflow/status.lock.json";
const VERSION = "0.1.0";
const profiles = {
  fast: { tdd: { mode: "off" }, history: { enabled: false } },
  medium: { tdd: { mode: "prefer-test-first" }, history: { enabled: false } },
  full: { tdd: { mode: "require-test-evidence" }, history: { enabled: true } }
};

function issue(code, file, message, pathValue = "") {
  return { code, severity: "error", file, path: pathValue, message };
}

class UnsafeManagedPathError extends Error {}

async function workflowDirectoryExists(root) {
  try {
    const metadata = await lstat(path.join(root, ".workflow"));
    if (!metadata.isDirectory() || metadata.isSymbolicLink()) throw new UnsafeManagedPathError(".workflow must be a real directory");
    return true;
  } catch (error) {
    if (error.code === "ENOENT") return false;
    throw error;
  }
}

async function optionalBytes(root, relative) {
  const absolute = path.join(root, relative);
  try {
    const metadata = await lstat(absolute);
    if (!metadata.isFile() || metadata.isSymbolicLink()) throw new UnsafeManagedPathError(`${relative} must be a regular file`);
    return await readFile(absolute);
  } catch (error) {
    if (error.code === "ENOENT") return null;
    throw error;
  }
}

function hash(bytes) {
  return `sha256:${createHash("sha256").update(bytes).digest("hex")}`;
}

function resolvePolicy(config) {
  const overrides = config.workflow.overrides;
  let selected;
  if (config.workflow.profile === "custom") {
    if (!overrides.tdd || !overrides.history) {
      return { policy: null, diagnostics: [issue("HKT202", CONFIG_PATH, "Custom profile requires TDD and history overrides.", "/workflow/overrides")] };
    }
    selected = { tdd: { ...overrides.tdd }, history: { ...overrides.history } };
  } else {
    const base = profiles[config.workflow.profile];
    selected = {
      tdd: { ...base.tdd, ...(overrides.tdd ?? {}) },
      history: { ...base.history, ...(overrides.history ?? {}) }
    };
  }
  return {
    policy: {
      profile: config.workflow.profile,
      tdd: selected.tdd,
      history: selected.history,
      policy: config.policy,
      enforcement: config.enforcement
    },
    diagnostics: []
  };
}

function unknownFacts(project) {
  const paths = [
    ["identity", "name"], ["identity", "kind"], ["identity", "description"],
    ["stack", "languages"], ["stack", "frameworks"], ["stack", "runtimes"], ["stack", "dependencies"],
    ["verification", "format"], ["verification", "lint"], ["verification", "test"], ["verification", "build"], ["verification", "validate"],
    ["architecture", "references"], ["architecture", "constraints"]
  ];
  return paths
    .filter(([section, field]) => project[section][field].state === "unknown")
    .map(([section, field]) => `/${section}/${field}`);
}

function verificationCommands(project) {
  const result = [];
  for (const kind of ["format", "lint", "test", "build", "validate"]) {
    const fact = project.verification[kind];
    if (fact.state !== "known") continue;
    for (const authored of fact.value) {
      const run = authored.trim();
      if (!run || /[\r\n\0]/.test(run)) throw new Error(`Invalid verification command: ${kind}`);
      result.push({ kind, run });
    }
  }
  return result;
}

async function referenceInputs(root, project) {
  const fact = project.architecture.references;
  if (fact.state !== "known") return { inputs: [], diagnostics: [] };
  const inputs = [];
  const seen = new Set();
  const realRoot = await realpath(root);
  for (let index = 0; index < fact.value.length; index += 1) {
    const reference = fact.value[index].path;
    const pointer = `/architecture/references/value/${index}/path`;
    if (path.isAbsolute(reference) || reference.includes("\\") || reference.split("/").some((part) => !part || part === "." || part === "..") || [CONFIG_PATH, PROJECT_PATH, LOCK_PATH].includes(reference)) {
      return { inputs: [], diagnostics: [issue("HKT220", PROJECT_PATH, "Architecture reference must be a safe project-relative path.", pointer)] };
    }
    if (seen.has(reference)) return { inputs: [], diagnostics: [issue("HKT220", PROJECT_PATH, "Duplicate architecture reference.", pointer)] };
    seen.add(reference);
    const absolute = path.join(root, reference);
    try {
      const resolved = await realpath(absolute);
      const relativeToRoot = path.relative(realRoot, resolved);
      if (relativeToRoot === ".." || relativeToRoot.startsWith(`..${path.sep}`) || path.isAbsolute(relativeToRoot)) {
        throw new Error("path escapes project root");
      }
      const metadata = await lstat(absolute, { bigint: false });
      if (!metadata.isFile() || metadata.isSymbolicLink()) throw new Error("not a regular file");
      const bytes = await readFile(absolute);
      inputs.push({ path: reference, sha256: hash(bytes) });
    } catch {
      return { inputs: [], diagnostics: [issue("HKT221", PROJECT_PATH, "Architecture reference is missing or unsafe.", pointer)] };
    }
  }
  return { inputs, diagnostics: [] };
}

async function sourceCandidate(root, overrides = {}) {
  let configBytes;
  try {
    if (!await workflowDirectoryExists(root)) return { sourceState: "absent", diagnostics: [], candidate: null };
    configBytes = Object.hasOwn(overrides, "configBytes") ? overrides.configBytes : await optionalBytes(root, CONFIG_PATH);
  } catch (error) {
    if (error instanceof UnsafeManagedPathError) {
      return { sourceState: "invalid", diagnostics: [issue("HKT221", ".workflow", "Managed workflow paths must not be symlinks.")], candidate: null };
    }
    throw error;
  }
  let projectBytes = null;
  try { projectBytes = Object.hasOwn(overrides, "projectBytes") ? overrides.projectBytes : await optionalBytes(root, PROJECT_PATH); }
  catch (error) {
    if (!(error instanceof UnsafeManagedPathError)) throw error;
    projectBytes = Symbol.for("unsafe-project-path");
  }
  if (!configBytes && !projectBytes) return { sourceState: "absent", diagnostics: [], candidate: null };
  if (!configBytes) return { sourceState: "needs_configuration", diagnostics: [issue("HKT001", CONFIG_PATH, "Required authored config is missing.")], candidate: null };

  const configParsed = parseYaml(configBytes, CONFIG_PATH);
  if (configParsed.diagnostics.length) return { sourceState: "invalid", diagnostics: configParsed.diagnostics, candidate: null };
  if (Number.isInteger(configParsed.value?.schema_version) && configParsed.value.schema_version > 1) {
    return { sourceState: "unsupported_schema", diagnostics: [issue("HKT100", CONFIG_PATH, "Unsupported config schema version.", "/schema_version")], candidate: null };
  }
  const configDiagnostics = validateSchema("config", configParsed.value, CONFIG_PATH);
  if (configDiagnostics.length) return { sourceState: "invalid", diagnostics: configDiagnostics, candidate: null };
  const resolved = resolvePolicy(configParsed.value);
  if (resolved.diagnostics.length) return { sourceState: "invalid", diagnostics: resolved.diagnostics, candidate: null };

  let sourceState = !configParsed.value.hekate.enabled ? "off"
    : !configParsed.value.workflow.enabled ? "workflow_disabled" : "ready";
  if (sourceState !== "ready") {
    const lock = {
      schema_version: 1,
      compatibility: { contract_schema: 1, authored_schemas: { config: 1, project: 1 } },
      compiler: { name: "@hekate/core", version: VERSION },
      inputs: [{ path: CONFIG_PATH, sha256: hash(configBytes) }],
      gate: { state: sourceState, diagnostics: [] },
      resolved_policy: resolved.policy,
      verification_commands: [],
      extensions: { config: configParsed.value.extensions, project: {} }
    };
    return { sourceState, diagnostics: [], candidate: canonicalBytes(lock), lock };
  }
  if (projectBytes === Symbol.for("unsafe-project-path")) {
    return { sourceState: "invalid", diagnostics: [issue("HKT221", PROJECT_PATH, "Managed workflow paths must not be symlinks.")], candidate: null };
  }
  let project = null;
  let projectDiagnostics = [];
  if (projectBytes) {
    const parsed = parseYaml(projectBytes, PROJECT_PATH);
    projectDiagnostics = parsed.diagnostics;
    project = parsed.value;
    if (!projectDiagnostics.length && Number.isInteger(project?.schema_version) && project.schema_version > 1) {
      return { sourceState: "unsupported_schema", diagnostics: [issue("HKT100", PROJECT_PATH, "Unsupported project schema version.", "/schema_version")], candidate: null };
    }
    if (!projectDiagnostics.length) projectDiagnostics = validateSchema("project", project, PROJECT_PATH);
  } else if (sourceState === "ready") {
    sourceState = "needs_configuration";
    projectDiagnostics.push(issue("HKT001", PROJECT_PATH, "Required project facts are missing."));
  }
  if (projectDiagnostics.length && projectBytes) return { sourceState: "invalid", diagnostics: projectDiagnostics, candidate: null };

  let references = { inputs: [], diagnostics: [] };
  let commands = [];
  if (project) {
    references = await referenceInputs(root, project);
    if (references.diagnostics.length) return { sourceState: "invalid", diagnostics: references.diagnostics, candidate: null };
    if (sourceState === "ready") {
      const unknown = unknownFacts(project);
      if (unknown.length) {
        sourceState = "needs_configuration";
        projectDiagnostics = unknown.map((pointer) => issue("HKT210", PROJECT_PATH, "Required project fact is unknown.", pointer));
      } else if (project.confirmation.state === "pending") {
        sourceState = "needs_confirmation";
        projectDiagnostics = [issue("HKT211", PROJECT_PATH, "Project facts require confirmation.", "/confirmation/state")];
      }
    }
    try { commands = verificationCommands(project); }
    catch { return { sourceState: "invalid", diagnostics: [issue("HKT103", PROJECT_PATH, "Verification commands must be non-empty single lines.", "/verification")], candidate: null }; }
  }

  const inputs = [
    { path: CONFIG_PATH, sha256: hash(configBytes) },
    ...(projectBytes ? [{ path: PROJECT_PATH, sha256: hash(projectBytes) }] : []),
    ...references.inputs
  ].sort((left, right) => left.path < right.path ? -1 : left.path > right.path ? 1 : 0);
  const lock = {
    schema_version: 1,
    compatibility: { contract_schema: 1, authored_schemas: { config: 1, project: 1 } },
    compiler: { name: "@hekate/core", version: VERSION },
    inputs,
    gate: {
      state: sourceState,
      diagnostics: projectDiagnostics.map(({ code, file, path: diagnosticPath }) => ({ code, file, path: diagnosticPath }))
    },
    resolved_policy: resolved.policy,
    verification_commands: commands,
    extensions: { config: configParsed.value.extensions, project: project?.extensions ?? {} }
  };
  return { sourceState, diagnostics: projectDiagnostics, candidate: canonicalBytes(lock), lock };
}

async function inspect(root) {
  const source = await sourceCandidate(root);
  if (!source.candidate) return { ...source, gateState: source.sourceState, lockStatus: "unavailable" };
  let existing;
  try { existing = await optionalBytes(root, LOCK_PATH); }
  catch (error) {
    if (!(error instanceof UnsafeManagedPathError)) throw error;
    return source.sourceState === "ready"
      ? { ...source, gateState: "invalid", lockStatus: "unsafe", diagnostics: [...source.diagnostics, issue("HKT221", LOCK_PATH, "Generated lock must not be a symlink.")] }
      : { ...source, gateState: source.sourceState, lockStatus: "unsafe", diagnostics: source.diagnostics };
  }
  if (!existing) {
    const blocksOnLock = source.sourceState === "ready";
    return {
      ...source,
      gateState: blocksOnLock ? "stale" : source.sourceState,
      lockStatus: "missing",
      diagnostics: blocksOnLock ? [...source.diagnostics, issue("HKT300", LOCK_PATH, "Generated lock is missing.")] : source.diagnostics
    };
  }
  let parsedLock;
  try { parsedLock = JSON.parse(existing.toString("utf8")); }
  catch {
    return source.sourceState === "ready"
      ? { ...source, gateState: "invalid", lockStatus: "invalid", diagnostics: [...source.diagnostics, issue("HKT301", LOCK_PATH, "Generated lock is malformed.")] }
      : { ...source, gateState: source.sourceState, lockStatus: "invalid", diagnostics: source.diagnostics };
  }
  if (Number.isInteger(parsedLock?.schema_version) && parsedLock.schema_version > 1) {
    return source.sourceState === "ready"
      ? { ...source, gateState: "unsupported_schema", lockStatus: "unsupported", diagnostics: [...source.diagnostics, issue("HKT303", LOCK_PATH, "Unsupported lock schema version.")] }
      : { ...source, gateState: source.sourceState, lockStatus: "unsupported", diagnostics: source.diagnostics };
  }
  const lockDiagnostics = validateSchema("lock", parsedLock, LOCK_PATH);
  if (lockDiagnostics.length) {
    return source.sourceState === "ready"
      ? { ...source, gateState: "invalid", lockStatus: "invalid", diagnostics: [...source.diagnostics, ...lockDiagnostics] }
      : { ...source, gateState: source.sourceState, lockStatus: "invalid", diagnostics: source.diagnostics };
  }
  if (!existing.equals(source.candidate)) {
    return {
      ...source,
      gateState: source.sourceState === "ready" ? "stale" : source.sourceState,
      lockStatus: "stale",
      diagnostics: source.sourceState === "ready" ? [...source.diagnostics, issue("HKT302", LOCK_PATH, "Generated lock differs from authored inputs.")] : source.diagnostics
    };
  }
  return { ...source, gateState: source.sourceState, lockStatus: "current" };
}

async function atomicWrite(root, bytes) {
  if (!await workflowDirectoryExists(root)) throw new UnsafeManagedPathError(".workflow directory is missing");
  const destination = path.join(root, LOCK_PATH);
  try {
    const metadata = await lstat(destination);
    if (metadata.isSymbolicLink() || !metadata.isFile()) throw new UnsafeManagedPathError("Generated lock must be a regular file");
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
  const temporary = `${destination}.tmp-${process.pid}-${randomBytes(8).toString("hex")}`;
  let handle;
  let renamed = false;
  try {
    handle = await open(temporary, constants.O_CREAT | constants.O_EXCL | constants.O_WRONLY, 0o600);
    await handle.writeFile(bytes);
    await handle.sync();
    await handle.close();
    handle = null;
    if (!await workflowDirectoryExists(root)) throw new UnsafeManagedPathError(".workflow directory changed during compilation");
    await rename(temporary, destination);
    renamed = true;
    let directoryHandle;
    try {
      directoryHandle = await open(path.dirname(destination), constants.O_RDONLY);
      await directoryHandle.sync();
    } catch (error) {
      if (!["EINVAL", "ENOTSUP", "EPERM", "EISDIR"].includes(error.code)) throw error;
    } finally {
      if (directoryHandle) await directoryHandle.close();
    }
  } finally {
    if (handle) await handle.close().catch(() => {});
    if (!renamed) await unlink(temporary).catch(() => {});
  }
}

export async function checkProject({ root }) {
  const result = await inspect(path.resolve(root));
  return { ...result, ok: ["absent", "off", "workflow_disabled", "ready"].includes(result.gateState), wrote: false };
}

export async function resolveProjectLock({ root, configBytes, projectBytes }) {
  const result = await sourceCandidate(path.resolve(root), {
    configBytes: Buffer.isBuffer(configBytes) ? Buffer.from(configBytes) : configBytes,
    projectBytes: Buffer.isBuffer(projectBytes) ? Buffer.from(projectBytes) : projectBytes
  });
  return { ok: result.candidate !== null && !["invalid", "unsupported_schema"].includes(result.sourceState), sourceState: result.sourceState, bytes: result.candidate, lock: result.lock, diagnostics: result.diagnostics };
}

export async function compileProject({ root, mode = "write" }) {
  const absoluteRoot = path.resolve(root);
  const before = await inspect(absoluteRoot);
  if (mode === "check") return { ...before, ok: before.gateState === "ready" && before.lockStatus === "current", wrote: false };
  if (!before.candidate) return { ...before, ok: ["absent", "off", "workflow_disabled"].includes(before.gateState), wrote: false };
  if (["unsupported", "unsafe"].includes(before.lockStatus)) {
    return { ...before, ok: ["off", "workflow_disabled"].includes(before.gateState), wrote: false };
  }
  let existing = null;
  try { existing = await optionalBytes(absoluteRoot, LOCK_PATH); }
  catch (error) { if (!(error instanceof UnsafeManagedPathError)) throw error; return { ...before, ok: false, wrote: false }; }
  let wrote = false;
  if (!existing || !existing.equals(before.candidate)) {
    await atomicWrite(absoluteRoot, before.candidate);
    wrote = true;
  }
  const after = await inspect(absoluteRoot);
  return { ...after, ok: ["off", "workflow_disabled", "ready"].includes(after.gateState), wrote };
}
