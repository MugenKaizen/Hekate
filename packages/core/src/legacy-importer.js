import { createHash } from "node:crypto";
import { constants } from "node:fs";
import { lstat, open, realpath } from "node:fs/promises";
import path from "node:path";
import { canonicalBytes } from "./canonical-json.js";
import { parseYaml } from "./parser.js";
import { validateSchema } from "./validator.js";

const FILES = [
  ["workflow", ".workflow/workflow.yml", true, "deprecated"],
  // The legacy project-fact files are opt-in in the current payload, so their
  // absence is not an error. Their values stay critical when they are present:
  // facts they carry must survive an upgrade.
  ["stack", ".workflow/stack.yml", false, "preserved", true],
  ["architecture", ".workflow/architecture.yml", false, "preserved", true],
  ["conventions", ".workflow/conventions.yml", false, "preserved", true],
  ["presets", ".workflow/presets.yml", false, "deprecated"],
  ["status", ".workflow/status.yml", false, "deprecated"],
  ["state", ".workflow/state.yml", false, "deprecated", true],
  ["orchestration", ".workflow/orchestration.yml", false, "deprecated", true],
  ["orchestration.local", ".workflow/orchestration.local.yml", false, "deprecated"],
  ["session.local", ".workflow/session.local.yml", false, "deprecated"]
];
const PROFILES = {
  fast: { tdd: "off", history: false },
  medium: { tdd: "prefer-test-first", history: false },
  full: { tdd: "require-test-evidence", history: true }
};
const KINDS = new Set(["web-app", "cli", "library", "service", "mobile", "monorepo", "documentation", "other"]);
const ADAPTERS = new Set(["aider", "claude", "codex", "copilot", "cursor", "gemini", "pi"]);
const KNOWN_KEYS = new Set(`active_preset anti_patterns api_docs architecture ask_before_destructive ask_user backend branches build build_and_run cache changelog checks ci classes code_style commit commits confirm_with_user constants containerization controls coverage_min default dependency_rules description destructive_actions dev directories documentation e2e emoji_map enabled enforce_on_save existing_project external_services features files flow format formatter frameworks frontend full hekate history hosting infra initialized install integration kind label language languages layers lazy_load lint linter location max_line_length medium meta mobile modules name naming new_project no_unrelated_refactors no_unrequested_dependencies orchestration other package_manager patterns preset presets primary process profile project_kind project_name protected purpose readme_required references require_body_for required required_fields_filled required_files required_files_present required_non_empty_fields review_checklist runtimes schema schema_version scope_control search settings source stack state status style style_notes subject_max_length test test_files testing tests tdd typecheck types unit validate values variables version workflow`.split(" "));

function issue(code, file, message, pathValue = "") {
  return { code, severity: "error", file, path: pathValue, message };
}

function hash(bytes) {
  return `sha256:${createHash("sha256").update(bytes).digest("hex")}`;
}

function pointerPart(value) {
  const text = String(value);
  const safe = KNOWN_KEYS.has(text) ? text : `$key-sha256-${createHash("sha256").update(text).digest("hex").slice(0, 16)}`;
  return safe.replaceAll("~", "~0").replaceAll("/", "~1");
}

function leaves(value, pointer = "") {
  if (Array.isArray(value)) {
    return value.length ? value.flatMap((item, index) => leaves(item, `${pointer}/${index}`)) : [pointer];
  }
  if (value !== null && typeof value === "object") {
    const entries = Object.entries(value);
    return entries.length ? entries.flatMap(([key, item]) => leaves(item, `${pointer}/${pointerPart(key)}`)) : [pointer];
  }
  return [pointer];
}

async function safeOptionalFile(root, relative) {
  const parts = relative.split("/");
  let current = root;
  for (const [index, part] of parts.entries()) {
    current = path.join(current, part);
    let metadata;
    try { metadata = await lstat(current); }
    catch (error) {
      if (error.code === "ENOENT") return null;
      throw error;
    }
    if (metadata.isSymbolicLink()) throw new Error("path contains a symbolic link");
    if (index < parts.length - 1 && !metadata.isDirectory()) throw new Error("path parent is not a directory");
    if (index === parts.length - 1 && !metadata.isFile()) throw new Error("path is not a regular file");
  }
  const resolved = await realpath(current);
  if (!resolved.startsWith(`${root}${path.sep}`)) throw new Error("path resolves outside the project");
  const handle = await open(current, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0));
  try {
    const metadata = await handle.stat();
    if (!metadata.isFile()) throw new Error("opened path is not a regular file");
    return await handle.readFile();
  } finally {
    await handle.close();
  }
}

function get(value, ...keys) {
  let current = value;
  for (const key of keys) {
    if (current === null || typeof current !== "object" || Array.isArray(current)) return undefined;
    current = current[key];
  }
  return current;
}

function unknown() {
  return { state: "unknown" };
}

function known(value) {
  return { state: "known", value };
}

function buildReport(entries) {
  entries.sort((left, right) => {
    const leftKey = `${left.source_file}:${left.source_path}`;
    const rightKey = `${right.source_file}:${right.source_path}`;
    return leftKey < rightKey ? -1 : leftKey > rightKey ? 1 : 0;
  });
  const summary = { preserved: 0, transformed: 0, deprecated: 0, unresolved: 0 };
  for (const entry of entries) summary[entry.disposition] += 1;
  return { schema_version: 1, source_layout: "legacy-0.x", summary, entries };
}

export function validateMigrationReport(report) {
  const schemaDiagnostics = validateSchema("migration-report", report, "report.json");
  if (schemaDiagnostics.length) return schemaDiagnostics;
  const counts = { preserved: 0, transformed: 0, deprecated: 0, unresolved: 0 };
  const diagnostics = [];
  for (const [index, entry] of report.entries.entries()) {
    counts[entry.disposition] += 1;
    if (entry.disposition === "unresolved" && (entry.target_path !== null || entry.diagnostic_code === null)) {
      diagnostics.push(issue("HKT516", "report.json", "Unresolved report entry requires a diagnostic and no target.", `/entries/${index}`));
    }
    if (entry.disposition !== "unresolved" && (entry.target_path === null || entry.diagnostic_code !== null)) {
      diagnostics.push(issue("HKT516", "report.json", "Resolved report entry has inconsistent target fields.", `/entries/${index}`));
    }
  }
  if (Object.keys(counts).some((key) => counts[key] !== report.summary[key])) {
    diagnostics.push(issue("HKT517", "report.json", "Report summary does not match its entries.", "/summary"));
  }
  return diagnostics;
}

export async function importLegacyProject({ root }) {
  const diagnostics = [];
  const documents = {};
  const rawArchives = {};
  const entries = [];
  let projectRoot;
  try { projectRoot = await realpath(root); }
  catch (error) {
    return { imported: null, report: null, importBytes: null, reportBytes: null, diagnostics: [issue("HKT500", "root", `Cannot resolve import root: ${error.message}`)] };
  }

  for (const [name, relative, required, defaultDisposition, criticalOverride] of FILES) {
    const critical = criticalOverride ?? required;
    let bytes;
    try { bytes = await safeOptionalFile(projectRoot, relative); }
    catch (error) {
      diagnostics.push(issue("HKT501", relative, `Cannot safely read legacy file: ${error.message}`));
      entries.push({ source_file: relative, source_path: "", source_hash: hash(Buffer.alloc(0)), target_path: null, disposition: "unresolved", critical, redacted: true, diagnostic_code: "HKT501" });
      continue;
    }
    if (bytes === null) {
      if (required) {
        diagnostics.push(issue("HKT502", relative, "Required legacy file is missing."));
        entries.push({ source_file: relative, source_path: "", source_hash: hash(Buffer.alloc(0)), target_path: null, disposition: "unresolved", critical: true, redacted: true, diagnostic_code: "HKT502" });
      }
      continue;
    }
    const parsed = parseYaml(bytes, relative);
    if (parsed.diagnostics.length || parsed.value === null || typeof parsed.value !== "object" || Array.isArray(parsed.value)) {
      const parseDiagnostics = parsed.diagnostics.length ? parsed.diagnostics : [issue("HKT503", relative, "Legacy document root must be a mapping.")];
      const diagnosticCode = parseDiagnostics[0].code;
      entries.push({ source_file: relative, source_path: "", source_hash: hash(bytes), target_path: null, disposition: "unresolved", critical, redacted: true, diagnostic_code: diagnosticCode });
      if (critical) diagnostics.push(...parseDiagnostics);
      else rawArchives[`${name}.yml`] = { encoding: "base64", bytes: bytes.toString("base64"), diagnostic_code: diagnosticCode };
      continue;
    }
    documents[name] = parsed.value;
    const sourceHash = hash(bytes);
    const targetBase = defaultDisposition === "preserved"
      ? `/project/extensions/legacy.hekate/${name}`
      : `/archived/${name}.yml`;
    for (const sourcePath of leaves(parsed.value)) {
      entries.push({ source_file: relative, source_path: sourcePath, source_hash: sourceHash, target_path: `${targetBase}${sourcePath}`, disposition: defaultDisposition, critical, redacted: true, diagnostic_code: null });
    }
  }

  const mark = (name, sourcePath, targetPath, disposition = "transformed") => {
    const relative = FILES.find(([fileName]) => fileName === name)?.[1];
    for (const entry of entries) {
      if (entry.source_file === relative && (entry.source_path === sourcePath || entry.source_path.startsWith(`${sourcePath}/`))) {
        if (entry.disposition === "unresolved") continue;
        entry.target_path = `${targetPath}${entry.source_path.slice(sourcePath.length)}`;
        entry.disposition = disposition;
        entry.diagnostic_code = null;
      }
    }
  };
  const markExact = (name, sourcePath, targetPath, disposition = "transformed") => {
    const relative = FILES.find(([fileName]) => fileName === name)?.[1];
    const entry = entries.find((item) => item.source_file === relative && item.source_path === sourcePath);
    if (entry && entry.disposition !== "unresolved") {
      entry.target_path = targetPath;
      entry.disposition = disposition;
      entry.diagnostic_code = null;
    }
  };
  const unresolved = (name, sourcePath, code, message) => {
    const relative = FILES.find(([fileName]) => fileName === name)?.[1] ?? name;
    diagnostics.push(issue(code, relative, message, sourcePath));
    let matched = false;
    for (const entry of entries) {
      if (entry.source_file === relative && (entry.source_path === sourcePath || entry.source_path.startsWith(`${sourcePath}/`))) {
        entry.target_path = null;
        entry.disposition = "unresolved";
        entry.diagnostic_code = code;
        matched = true;
      }
    }
    if (!matched) entries.push({ source_file: relative, source_path: sourcePath, source_hash: hash(Buffer.alloc(0)), target_path: null, disposition: "unresolved", critical: true, redacted: true, diagnostic_code: code });
  };

  if (diagnostics.length) {
    const report = buildReport(entries);
    return { imported: null, report, importBytes: null, reportBytes: canonicalBytes(report), diagnostics };
  }

  const workflow = documents.workflow;
  const stack = documents.stack;
  const architecture = documents.architecture;
  const conventions = documents.conventions;

  const booleanAt = (name, sourcePath, value, fallback) => {
    if (value === undefined) return fallback;
    if (typeof value !== "boolean") {
      unresolved(name, sourcePath, "HKT504", "Legacy boolean setting has the wrong type.");
      return fallback;
    }
    return value;
  };
  const stringFact = (sourcePath, value, required = false) => {
    if (value === undefined || value === "") return unknown();
    if (typeof value !== "string") {
      unresolved("stack", sourcePath, "HKT505", "Legacy string fact has the wrong type.");
      return unknown();
    }
    return known(value);
  };
  const objectListFact = (name, sourcePath, value, allowedKeys) => {
    if (value === undefined || Array.isArray(value) && value.length === 0) return unknown();
    if (!Array.isArray(value)) {
      unresolved("stack", sourcePath, "HKT506", `Legacy ${name} must be a list.`);
      return unknown();
    }
    const normalized = [];
    for (const [index, item] of value.entries()) {
      if (typeof item === "string" && item) normalized.push({ name: item });
      else if (item && typeof item === "object" && !Array.isArray(item) && typeof item.name === "string" && item.name) {
        normalized.push(Object.fromEntries(allowedKeys.filter((key) => typeof item[key] === "string" && item[key]).map((key) => [key, item[key]])));
      } else unresolved("stack", `${sourcePath}/${index}`, "HKT507", `Legacy ${name} entry requires a non-empty name.`);
    }
    return normalized.length ? known(normalized) : unknown();
  };
  const stringListFact = (name, sourcePath, value) => {
    if (value === undefined || Array.isArray(value) && value.length === 0) return unknown();
    if (!Array.isArray(value) || value.some((item) => typeof item !== "string" || !item)) {
      unresolved(name, sourcePath, "HKT508", "Legacy list fact must contain non-empty strings.");
      return unknown();
    }
    return known([...new Set(value)]);
  };
  const commandFact = (sourcePath, value) => {
    if (value === undefined || value === "" || Array.isArray(value) && value.length === 0) return unknown();
    const commands = typeof value === "string" ? [value] : value;
    if (!Array.isArray(commands) || commands.some((command) => typeof command !== "string" || !command || command.includes("\0") || /[\r\n]/.test(command))) {
      unresolved("stack", sourcePath, "HKT509", "Legacy verification command is malformed or multiline.");
      return unknown();
    }
    return known(commands);
  };

  const profileCandidates = [
    ["workflow", "/meta/profile", get(workflow, "meta", "profile")],
    ["workflow", "/meta/preset", get(workflow, "meta", "preset")],
    ["presets", "/meta/active_preset", get(documents.presets, "meta", "active_preset")],
    ["status", "/active_preset", get(documents.status, "active_preset")]
  ].filter(([, , value]) => value !== undefined && value !== null && value !== "");
  for (const [name, sourcePath, value] of profileCandidates) {
    if (typeof value !== "string" || ![...Object.keys(PROFILES), "custom"].includes(value)) unresolved(name, sourcePath, "HKT510", "Legacy profile is unsupported.");
  }
  const selectedProfiles = [...new Set(profileCandidates.map(([, , value]) => value).filter((value) => typeof value === "string"))];
  if (selectedProfiles.length > 1) {
    for (const [name, sourcePath] of profileCandidates) unresolved(name, sourcePath, "HKT511", "Legacy profile owners conflict.");
  }
  const profile = selectedProfiles[0] ?? "custom";
  for (const [name, sourcePath] of profileCandidates) mark(name, sourcePath, "/config/workflow/profile");

  let tdd = get(workflow, "process", "tdd", "mode");
  if (tdd === undefined) {
    const legacyMode = get(workflow, "process", "light_tdd", "mode");
    const legacyEnabled = get(workflow, "process", "light_tdd", "enabled");
    if (legacyMode !== undefined || legacyEnabled !== undefined) {
      if (legacyEnabled === false || legacyMode === "off") tdd = "off";
      else if (legacyEnabled === true && legacyMode === "soft") tdd = "prefer-test-first";
      else if (legacyEnabled === true && legacyMode === "strict-lite") tdd = "require-test-evidence";
      else unresolved("workflow", "/process/light_tdd", "HKT512", "Legacy TDD settings conflict or are unsupported.");
      markExact("workflow", "/process/light_tdd/mode", "/config/workflow/overrides/tdd/mode");
      markExact("workflow", "/process/light_tdd/enabled", "/config/workflow/overrides/tdd/mode");
    }
  } else mark("workflow", "/process/tdd/mode", "/config/workflow/overrides/tdd/mode");
  if (tdd !== undefined && !["off", "prefer-test-first", "require-test-evidence"].includes(tdd)) {
    unresolved("workflow", get(workflow, "process", "tdd", "mode") === undefined ? "/process/light_tdd/mode" : "/process/tdd/mode", "HKT512", "Legacy TDD mode is unsupported.");
    tdd = undefined;
  }

  const historyCandidates = [
    ["/process/history/enabled", get(workflow, "process", "history", "enabled")],
    ["/history/enabled", get(workflow, "history", "enabled")]
  ].filter(([, value]) => value !== undefined);
  for (const [sourcePath, value] of historyCandidates) {
    if (typeof value !== "boolean") unresolved("workflow", sourcePath, "HKT504", "Legacy history setting has the wrong type.");
  }
  const historyValues = [...new Set(historyCandidates.map(([, value]) => value).filter((value) => typeof value === "boolean"))];
  if (historyValues.length > 1) {
    for (const [sourcePath] of historyCandidates) unresolved("workflow", sourcePath, "HKT513", "Legacy history owners conflict.");
  }
  const history = historyValues[0];
  for (const [sourcePath] of historyCandidates) mark("workflow", sourcePath, "/config/workflow/overrides/history/enabled");

  const overrides = {};
  const base = PROFILES[profile];
  if (profile === "custom") {
    overrides.tdd = { mode: tdd ?? "off" };
    overrides.history = { enabled: history ?? false };
  } else {
    if (tdd !== undefined && tdd !== base.tdd) overrides.tdd = { mode: tdd };
    if (history !== undefined && history !== base.history) overrides.history = { enabled: history };
  }

  const hekateEnabled = booleanAt("workflow", "/hekate/enabled", get(workflow, "hekate", "enabled"), true);
  const workflowEnabled = booleanAt("workflow", "/hekate/modules/workflow", get(workflow, "hekate", "modules", "workflow"), true);
  mark("workflow", "/hekate/enabled", "/config/hekate/enabled", "preserved");
  mark("workflow", "/hekate/modules/workflow", "/config/workflow/enabled", "preserved");
  if (get(workflow, "process", "commit", "consent") === "explicit-request-only") {
    markExact("workflow", "/process/commit/consent", "/config/policy/commit_consent", "preserved");
  }
  if (get(workflow, "scope_control", "no_unrequested_dependencies") === true) {
    markExact("workflow", "/scope_control/no_unrequested_dependencies", "/config/policy/dependency_changes");
  }
  if (get(workflow, "scope_control", "ask_before_destructive") === true) {
    markExact("workflow", "/scope_control/ask_before_destructive", "/config/policy/destructive_actions");
  }

  const name = stringFact("/meta/project_name", get(stack, "meta", "project_name"), true);
  const description = stringFact("/meta/description", get(stack, "meta", "description"));
  let kind = stringFact("/meta/project_kind", get(stack, "meta", "project_kind"), true);
  if (kind.state === "known" && !KINDS.has(kind.value)) kind = known("other");
  markExact("stack", "/meta/project_name", `/project/identity/name/${name.state === "known" ? "value" : "state"}`);
  markExact("stack", "/meta/project_kind", `/project/identity/kind/${kind.state === "known" ? "value" : "state"}`);
  markExact("stack", "/meta/description", `/project/identity/description/${description.state === "known" ? "value" : "state"}`);

  const languages = objectListFact("languages", "/languages", get(stack, "languages"), ["name", "version", "package_manager"]);
  const runtimes = objectListFact("runtimes", "/runtimes", get(stack, "runtimes"), ["name", "version"]);
  const markObjectList = (sourcePath, value, targetPath, allowedKeys) => {
    if (Array.isArray(value) && value.length === 0) markExact("stack", sourcePath, targetPath);
    if (!Array.isArray(value)) return;
    let targetIndex = 0;
    for (const [sourceIndex, item] of value.entries()) {
      if (typeof item === "string" && item) {
        markExact("stack", `${sourcePath}/${sourceIndex}`, `${targetPath}/value/${targetIndex}/name`);
        targetIndex += 1;
      } else if (item && typeof item === "object" && !Array.isArray(item) && typeof item.name === "string" && item.name) {
        for (const key of allowedKeys) {
          if (typeof item[key] === "string" && item[key]) markExact("stack", `${sourcePath}/${sourceIndex}/${key}`, `${targetPath}/value/${targetIndex}/${key}`);
        }
        targetIndex += 1;
      }
    }
  };
  markObjectList("/languages", get(stack, "languages"), "/project/stack/languages", ["name", "version", "package_manager"]);
  markObjectList("/runtimes", get(stack, "runtimes"), "/project/stack/runtimes", ["name", "version"]);
  const frameworkGroups = get(stack, "frameworks");
  let frameworks = unknown();
  if (frameworkGroups !== undefined) {
    if (!frameworkGroups || typeof frameworkGroups !== "object" || Array.isArray(frameworkGroups)) unresolved("stack", "/frameworks", "HKT506", "Legacy frameworks must be a mapping.");
    else {
      const values = Object.values(frameworkGroups).flatMap((value) => Array.isArray(value) ? value : [value]);
      if (values.some((value) => typeof value !== "string" || !value)) {
        if (values.length) unresolved("stack", "/frameworks", "HKT508", "Legacy framework groups must contain non-empty strings.");
      } else if (values.length) frameworks = known([...new Set(values)]);
    }
  }
  if (frameworkGroups && typeof frameworkGroups === "object" && !Array.isArray(frameworkGroups)) {
    const flattened = frameworks.state === "known" ? frameworks.value : [];
    for (const [group, values] of Object.entries(frameworkGroups)) {
      if (Array.isArray(values) && values.length === 0) markExact("stack", `/frameworks/${group}`, "/project/stack/frameworks");
      if (Array.isArray(values)) {
        for (const [index, value] of values.entries()) {
          if (typeof value === "string" && value) markExact("stack", `/frameworks/${group}/${index}`, `/project/stack/frameworks/value/${flattened.indexOf(value)}`);
        }
      }
    }
  }
  const dependencies = stringListFact("stack", "/dependencies", get(stack, "dependencies"));
  const dependencyValues = get(stack, "dependencies");
  if (Array.isArray(dependencyValues) && dependencyValues.length === 0) markExact("stack", "/dependencies", "/project/stack/dependencies");
  if (Array.isArray(dependencyValues)) {
    const uniqueDependencies = dependencies.state === "known" ? dependencies.value : [];
    for (const [index, value] of dependencyValues.entries()) {
      if (typeof value === "string" && value) markExact("stack", `/dependencies/${index}`, `/project/stack/dependencies/value/${uniqueDependencies.indexOf(value)}`);
    }
  }

  const verification = {};
  for (const command of ["format", "lint", "test", "build", "validate"]) {
    const value = get(stack, "build_and_run", command);
    verification[command] = commandFact(`/build_and_run/${command}`, value);
    if (typeof value === "string") markExact("stack", `/build_and_run/${command}`, `/project/verification/${command}${value ? "/value/0" : ""}`);
    if (Array.isArray(value) && value.length === 0) markExact("stack", `/build_and_run/${command}`, `/project/verification/${command}`);
    if (Array.isArray(value)) value.forEach((_item, index) => markExact("stack", `/build_and_run/${command}/${index}`, `/project/verification/${command}/value/${index}`));
  }
  const constraints = stringListFact("architecture", "/dependency_rules", get(architecture, "dependency_rules"));
  const dependencyRules = get(architecture, "dependency_rules");
  if (Array.isArray(dependencyRules) && dependencyRules.length === 0) markExact("architecture", "/dependency_rules", "/project/architecture/constraints");
  if (Array.isArray(dependencyRules)) dependencyRules.forEach((_item, index) => markExact("architecture", `/dependency_rules/${index}`, `/project/architecture/constraints/value/${index}`));
  if (get(documents.status, "schema_version") !== undefined) {
    const statusVersion = get(documents.status, "schema_version");
    if (!Number.isSafeInteger(statusVersion) || statusVersion > 1) unresolved("status", "/schema_version", "HKT515", "Legacy status uses an unsupported future schema.");
  }
  for (const name of ["orchestration", "orchestration.local"]) {
    const version = get(documents[name], "schema_version");
    if (version !== undefined && (!Number.isSafeInteger(version) || version > 2)) unresolved(name, "/schema_version", "HKT515", "Legacy orchestration uses an unsupported future schema.");
  }

  let selectedAdapters = [];
  const legacyAdapters = get(documents.state, "install", "adapters");
  if (legacyAdapters !== undefined) {
    if (!Array.isArray(legacyAdapters) || legacyAdapters.some((adapter) => typeof adapter !== "string" || !ADAPTERS.has(adapter))) {
      unresolved("state", "/install/adapters", "HKT518", "Legacy adapter selection is malformed or unsupported.");
    } else {
      selectedAdapters = [...new Set(legacyAdapters)].sort();
      legacyAdapters.forEach((adapter, index) => markExact("state", `/install/adapters/${index}`, `/selected_adapters/${selectedAdapters.indexOf(adapter)}`));
    }
  }

  const config = {
    schema_version: 1,
    hekate: { enabled: hekateEnabled },
    workflow: { enabled: workflowEnabled, profile, overrides },
    policy: { commit_consent: "explicit-request-only", destructive_actions: "explicit-consent", dependency_changes: "explicit-consent" },
    enforcement: { configuration: "block", destructive_actions: "confirm", dependency_changes: "confirm", generated_lock: "protect" },
    extensions: {}
  };
  const project = {
    schema_version: 1,
    identity: { name, kind, description },
    stack: { languages, frameworks, runtimes, dependencies },
    verification,
    architecture: { references: { state: "not_applicable" }, constraints },
    confirmation: { state: "pending" },
    // Optional legacy fact files that were not installed contribute nothing.
    extensions: { "legacy.hekate": Object.fromEntries(Object.entries({ stack, architecture, conventions }).filter(([, value]) => value !== undefined)) }
  };
  const archived = { ...Object.fromEntries(Object.entries(documents).map(([name, value]) => [`${name}.yml`, value])), ...rawArchives };
  const imported = { schema_version: 1, source_layout: "legacy-0.x", selected_adapters: selectedAdapters, config, project, archived };
  diagnostics.push(...validateSchema("config", config, ".workflow/config.yml"));
  diagnostics.push(...validateSchema("project", project, ".workflow/project.yml"));
  diagnostics.push(...validateSchema("legacy-import", imported, "import.json"));
  const report = buildReport(entries);
  diagnostics.push(...validateMigrationReport(report));
  return {
    imported: diagnostics.length ? null : imported,
    report,
    importBytes: diagnostics.length ? null : canonicalBytes(imported),
    reportBytes: canonicalBytes(report),
    diagnostics
  };
}
