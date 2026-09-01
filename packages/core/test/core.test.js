import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { copyFile, mkdtemp, mkdir, readFile, stat, symlink, unlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import {
  checkProject,
  compileProject,
  createOperationJournal,
  createTransactionId,
  importLegacyProject,
  loadInstallManifest,
  planInstallation,
  validateMigrationReport
} from "../src/index.js";
import { parseYaml } from "../src/parser.js";
import { validateSchema } from "../src/validator.js";

const config = `schema_version: 1
hekate: {enabled: true}
workflow: {enabled: true, profile: medium, overrides: {}}
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
`;

const project = `schema_version: 1
identity:
  name: {state: known, value: Hekate}
  kind: {state: known, value: cli}
  description: {state: known, value: Workflow compiler}
stack:
  languages: {state: known, value: [{name: javascript, version: ES2023, package_manager: npm}]}
  frameworks: {state: known, value: []}
  runtimes: {state: known, value: [{name: node, version: "20"}]}
  dependencies: {state: known, value: [yaml, ajv]}
verification:
  format: {state: not_applicable}
  lint: {state: not_applicable}
  test: {state: known, value: [npm test]}
  build: {state: not_applicable}
  validate: {state: known, value: [git diff --check]}
architecture:
  references: {state: known, value: []}
  constraints: {state: known, value: []}
confirmation: {state: confirmed}
extensions: {}
`;

const repositoryRoot = fileURLToPath(new URL("../../../", import.meta.url));

async function fixture(projectText = project) {
  const root = await mkdtemp(path.join(tmpdir(), "hekate-core-"));
  await mkdir(path.join(root, ".workflow"));
  await writeFile(path.join(root, ".workflow/config.yml"), config);
  await writeFile(path.join(root, ".workflow/project.yml"), projectText);
  return root;
}

async function legacyFixture() {
  const root = await mkdtemp(path.join(tmpdir(), "hekate-legacy-"));
  await mkdir(path.join(root, ".workflow"));
  for (const file of ["workflow.yml", "stack.yml", "architecture.yml", "conventions.yml", "presets.yml", "status.yml"]) {
    await copyFile(new URL(`../../../templates/.workflow/${file}`, import.meta.url), path.join(root, ".workflow", file));
  }
  return root;
}

test("shipped v1 authored templates parse and validate", async () => {
  for (const kind of ["config", "project"]) {
    const file = `.workflow/${kind}.yml`;
    const bytes = await readFile(new URL(`../../../templates/${file}`, import.meta.url));
    const parsed = parseYaml(bytes, file);
    assert.deepEqual(parsed.diagnostics, []);
    assert.deepEqual(validateSchema(kind, parsed.value, file), []);
  }
});

test("strict parser rejects duplicate keys and aliases", () => {
  const duplicate = parseYaml(Buffer.from("a: 1\na: 2\n"), "duplicate.yml");
  assert.equal(duplicate.diagnostics[0].code, "HKT004");
  const alias = parseYaml(Buffer.from("a: &value 1\nb: *value\n"), "alias.yml");
  assert.equal(alias.diagnostics[0].code, "HKT006");
  const tag = parseYaml(Buffer.from("a: !unsafe value\n"), "tag.yml");
  assert.equal(tag.diagnostics[0].code, "HKT005");
  const numericKey = parseYaml(Buffer.from("1: value\n"), "key.yml");
  assert.equal(numericKey.diagnostics[0].code, "HKT008");
});

test("strict parser enforces resource limits", () => {
  const oversized = parseYaml(Buffer.alloc(1024 * 1024 + 1, 32), "large.yml");
  assert.equal(oversized.diagnostics[0].code, "HKT009");
  const nested = parseYaml(Buffer.from(`${"a: {".repeat(65)}value${"}".repeat(65)}\n`), "deep.yml");
  assert.equal(nested.diagnostics[0].code, "HKT009");
  const wide = parseYaml(Buffer.from(`items:\n${"  - 0\n".repeat(100001)}`), "wide.yml");
  assert.equal(wide.diagnostics.length, 1);
  assert.equal(wide.diagnostics[0].code, "HKT009");
});

test("compile is deterministic and check detects stale inputs", async () => {
  const root = await fixture();
  const missing = await checkProject({ root });
  assert.equal(missing.gateState, "stale");
  assert.equal(missing.lockStatus, "missing");

  const first = await compileProject({ root });
  assert.equal(first.ok, true);
  assert.equal(first.wrote, true);
  const lockPath = path.join(root, ".workflow/status.lock.json");
  const firstBytes = await readFile(lockPath);
  const firstMtime = (await stat(lockPath)).mtimeMs;

  const second = await compileProject({ root });
  assert.equal(second.wrote, false);
  assert.deepEqual(await readFile(lockPath), firstBytes);
  assert.equal((await stat(lockPath)).mtimeMs, firstMtime);

  await writeFile(path.join(root, ".workflow/project.yml"), `${project}\n# changed\n`);
  const stale = await checkProject({ root });
  assert.equal(stale.gateState, "stale");
  assert.equal(stale.lockStatus, "stale");
  assert.equal((await compileProject({ root, mode: "check" })).ok, false);
});

test("gate states are derived from authored facts", async () => {
  const incomplete = await fixture(project.replace("name: {state: known, value: Hekate}", "name: {state: unknown}"));
  const result = await compileProject({ root: incomplete });
  assert.equal(result.gateState, "needs_configuration");
  assert.equal(result.wrote, true);
  assert.equal(result.ok, false);

  const disabled = await fixture();
  await writeFile(path.join(disabled, ".workflow/config.yml"), config.replace("hekate: {enabled: true}", "hekate: {enabled: false}"));
  const off = await compileProject({ root: disabled });
  assert.equal(off.gateState, "off");
  assert.equal(off.ok, true);

  const awaitingConfirmation = await fixture(project.replace("confirmation: {state: confirmed}", "confirmation: {state: pending}"));
  const pending = await compileProject({ root: awaitingConfirmation });
  assert.equal(pending.gateState, "needs_confirmation");

  const workflowDisabled = await fixture();
  await writeFile(path.join(workflowDisabled, ".workflow/config.yml"), config.replace("workflow: {enabled: true", "workflow: {enabled: false"));
  const disabledResult = await compileProject({ root: workflowDisabled });
  assert.equal(disabledResult.gateState, "workflow_disabled");
});

test("invalid source never replaces a current lock", async () => {
  const root = await fixture();
  await compileProject({ root });
  const lockPath = path.join(root, ".workflow/status.lock.json");
  const before = await readFile(lockPath);
  await writeFile(path.join(root, ".workflow/config.yml"), "schema_version: [\n");
  const result = await compileProject({ root });
  assert.equal(result.gateState, "invalid");
  assert.deepEqual(await readFile(lockPath), before);
});

test("future schemas fail closed", async () => {
  const root = await fixture();
  await writeFile(path.join(root, ".workflow/config.yml"), "schema_version: 2\n");
  const result = await checkProject({ root });
  assert.equal(result.gateState, "unsupported_schema");
  assert.equal(result.diagnostics[0].code, "HKT100");
});

test("architecture references are hashed into the lock", async () => {
  const withReference = project.replace(
    "references: {state: known, value: []}",
    "references: {state: known, value: [{path: docs/architecture.md}]}"
  );
  const root = await fixture(withReference);
  await mkdir(path.join(root, "docs"));
  await writeFile(path.join(root, "docs/architecture.md"), "# Architecture\n");
  await compileProject({ root });
  const lock = JSON.parse(await readFile(path.join(root, ".workflow/status.lock.json"), "utf8"));
  assert.equal(lock.inputs.some((input) => input.path === "docs/architecture.md"), true);
  assert.equal(Object.hasOwn(lock, "generated_at"), false);
});

test("extensions do not participate in readiness facts", async () => {
  const root = await fixture(project.replace("extensions: {}", "extensions:\n  vendor.example:\n    state: unknown"));
  const result = await compileProject({ root });
  assert.equal(result.gateState, "ready");
  assert.equal(result.ok, true);
});

test("disabled states ignore project and lock contents", async () => {
  const root = await fixture("not: valid: yaml\n");
  await writeFile(path.join(root, ".workflow/config.yml"), config.replace("hekate: {enabled: true}", "hekate: {enabled: false}"));
  await writeFile(path.join(root, ".workflow/status.lock.json"), "not json\n");
  const checked = await checkProject({ root });
  assert.equal(checked.gateState, "off");
  assert.deepEqual(checked.diagnostics, []);
  const compiled = await compileProject({ root });
  assert.equal(compiled.ok, true);
  assert.equal(compiled.gateState, "off");
  assert.deepEqual(compiled.diagnostics, []);
});

test("compile check requires a ready current lock", async () => {
  const absent = await mkdtemp(path.join(tmpdir(), "hekate-core-absent-"));
  assert.equal((await compileProject({ root: absent, mode: "check" })).ok, false);

  const off = await fixture();
  await writeFile(path.join(off, ".workflow/config.yml"), config.replace("hekate: {enabled: true}", "hekate: {enabled: false}"));
  await compileProject({ root: off });
  assert.equal((await compileProject({ root: off, mode: "check" })).ok, false);

  const disabled = await fixture();
  await writeFile(path.join(disabled, ".workflow/config.yml"), config.replace("workflow: {enabled: true", "workflow: {enabled: false"));
  await compileProject({ root: disabled });
  assert.equal((await compileProject({ root: disabled, mode: "check" })).ok, false);
});

test("compile does not replace a future lock schema", async () => {
  const root = await fixture();
  const lockPath = path.join(root, ".workflow/status.lock.json");
  const future = Buffer.from('{"schema_version":2,"future":true}\n');
  await writeFile(lockPath, future);
  const result = await compileProject({ root });
  assert.equal(result.ok, false);
  assert.equal(result.lockStatus, "unsupported");
  assert.deepEqual(await readFile(lockPath), future);
});

test("disabled state preserves but does not fail on a future lock", async () => {
  const root = await fixture();
  await writeFile(path.join(root, ".workflow/config.yml"), config.replace("hekate: {enabled: true}", "hekate: {enabled: false}"));
  const lockPath = path.join(root, ".workflow/status.lock.json");
  const future = Buffer.from('{"schema_version":2,"future":true}\n');
  await writeFile(lockPath, future);
  const result = await compileProject({ root });
  assert.equal(result.gateState, "off");
  assert.equal(result.ok, true);
  assert.equal(result.wrote, false);
  assert.deepEqual(await readFile(lockPath), future);
});

test("managed workflow paths reject symlinks", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "hekate-core-link-root-"));
  const external = await fixture();
  await symlink(path.join(external, ".workflow"), path.join(root, ".workflow"), "dir");
  const linkedDirectory = await checkProject({ root });
  assert.equal(linkedDirectory.gateState, "invalid");
  assert.equal(linkedDirectory.diagnostics[0].code, "HKT221");

  const lockRoot = await fixture();
  const outside = path.join(await mkdtemp(path.join(tmpdir(), "hekate-core-link-file-")), "outside.json");
  const original = Buffer.from("outside\n");
  await writeFile(outside, original);
  await symlink(outside, path.join(lockRoot, ".workflow/status.lock.json"));
  const linkedLock = await compileProject({ root: lockRoot });
  assert.equal(linkedLock.ok, false);
  assert.equal(linkedLock.lockStatus, "unsafe");
  assert.deepEqual(await readFile(outside), original);
});

test("concurrent compiles use independent atomic temporary files", async () => {
  const root = await fixture();
  const results = await Promise.all(Array.from({ length: 24 }, () => compileProject({ root })));
  assert.equal(results.every((result) => result.ok), true);
  assert.equal((await checkProject({ root })).lockStatus, "current");
});

test("project schema rejects untyped nested stack values", async () => {
  const root = await fixture(project.replace(
    "languages: {state: known, value: [{name: javascript, version: ES2023, package_manager: npm}]}",
    "languages: {state: known, value: [javascript]}"
  ));
  const result = await compileProject({ root });
  assert.equal(result.gateState, "invalid");
  assert.equal(result.ok, false);
});

test("install manifest is valid and selects adapter components deterministically", async () => {
  const loaded = await loadInstallManifest();
  assert.deepEqual(loaded.diagnostics, []);
  assert.equal(loaded.manifest.manifest_version, 1);

  const root = await mkdtemp(path.join(tmpdir(), "hekate-plan-"));
  const allAdapters = ["aider", "claude", "codex", "copilot", "cursor", "gemini"];
  const first = await planInstallation({ root, sourceRoot: repositoryRoot, adapters: [...allAdapters].reverse() });
  const second = await planInstallation({ root, sourceRoot: repositoryRoot, adapters: allAdapters });
  assert.deepEqual(first.diagnostics, []);
  assert.deepEqual(first.plan, second.plan);
  assert.deepEqual(first.plan.selected_adapters, allAdapters);
  assert.deepEqual(first.plan.selected_components, ["aider", "claude", "copilot", "core", "cursor", "gemini", "portable-skills"]);
  assert.equal(first.plan.assets.some((asset) => asset.asset_id === "claude-instructions"), true);
  assert.equal(first.plan.assets.some((asset) => asset.asset_id === "portable-skill-workflow"), true);
  assert.equal(first.plan.assets.some((asset) => asset.asset_id === "aider-config"), true);
});

test("install planner rejects unknown adapters", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "hekate-plan-"));
  const result = await planInstallation({ root, sourceRoot: repositoryRoot, adapters: ["unknown"] });
  assert.equal(result.plan, null);
  assert.equal(result.diagnostics[0].code, "HKT410");
});

test("install planner preserves seeds and does not claim modified templates", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "hekate-plan-"));
  await mkdir(path.join(root, ".workflow"));
  await writeFile(path.join(root, ".workflow/config.yml"), "project-owned\n");
  await writeFile(path.join(root, "AGENTS.md"), "user-modified\n");
  const result = await planInstallation({ root, sourceRoot: repositoryRoot, adapters: [] });
  assert.deepEqual(result.diagnostics, []);
  const byId = Object.fromEntries(result.plan.assets.map((asset) => [asset.asset_id, asset]));
  assert.equal(byId["workflow-config"].disposition, "preserve");
  assert.equal(byId["root-agents"].disposition, "replace-candidate");
  assert.equal(byId["workflow-project"].disposition, "create");
  assert.equal(byId["project-gitignore"].disposition, "merge");
  assert.equal(byId["generated-lock"].disposition, "regenerate");
});

test("install planner rejects symlinked managed parents", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "hekate-plan-"));
  const outside = await mkdtemp(path.join(tmpdir(), "hekate-plan-outside-"));
  await symlink(outside, path.join(root, ".workflow"), "dir");
  const result = await planInstallation({ root, sourceRoot: repositoryRoot, adapters: [] });
  assert.equal(result.plan, null);
  assert.equal(result.diagnostics[0].code, "HKT424");
});

test("install state distinguishes recorded ownership from filename presence", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "hekate-plan-"));
  await writeFile(path.join(root, "AGENTS.md"), "locally modified\n");
  const installedState = {
    schema_version: 1,
    manifest_version: 1,
    source_release: "v0.2.0-beta.1",
    selected_components: ["core"],
    selected_adapters: [],
    assets: [{
      asset_id: "root-agents",
      destination: "AGENTS.md",
      ownership: "template-managed",
      installed_source_hash: null,
      destination_hash: null
    }]
  };
  const result = await planInstallation({ root, sourceRoot: repositoryRoot, installedState });
  assert.deepEqual(result.diagnostics, []);
  const agents = result.plan.assets.find((asset) => asset.asset_id === "root-agents");
  assert.equal(agents.provenance, "recorded");
  assert.equal(agents.disposition, "replace");
});

test("install planner removes only unmodified assets from deselected components", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "hekate-plan-remove-"));
  const bytes = await readFile(path.join(repositoryRoot, "templates/adapters/claude/CLAUDE.md"));
  await writeFile(path.join(root, "CLAUDE.md"), bytes);
  const destinationHash = `sha256:${createHash("sha256").update(bytes).digest("hex")}`;
  const installedState = {
    schema_version: 1,
    manifest_version: 1,
    source_release: "v0.2.0-beta.1",
    selected_components: ["core", "claude"],
    selected_adapters: ["claude"],
    assets: [{
      asset_id: "claude-instructions",
      destination: "CLAUDE.md",
      ownership: "template-managed",
      installed_source_hash: destinationHash,
      destination_hash: destinationHash
    }]
  };
  const removable = await planInstallation({ root, sourceRoot: repositoryRoot, adapters: [], installedState });
  assert.deepEqual(removable.diagnostics, []);
  const removal = removable.plan.assets.find((asset) => asset.asset_id === "claude-instructions");
  assert.equal(removal.disposition, "remove");
  assert.equal(removal.target_hash, null);

  await writeFile(path.join(root, "CLAUDE.md"), Buffer.concat([bytes, Buffer.from("\nlocal edit\n")]));
  const modified = await planInstallation({ root, sourceRoot: repositoryRoot, adapters: [], installedState });
  assert.deepEqual(modified.diagnostics, []);
  assert.equal(modified.plan.assets.find((asset) => asset.asset_id === "claude-instructions").disposition, "preserve");
});

test("operation journal schema rejects incomplete entries", () => {
  const journal = {
    schema_version: 1,
    transaction_id: "20260830T120000Z-0123456789abcdef",
    status: "planned",
    manifest_version: 1,
    source_release: null,
    target_release: "v1.0.0",
    operations: [{ operation: "replace", path: "AGENTS.md" }]
  };
  assert.notDeepEqual(validateSchema("journal", journal, "journal.json"), []);
});

test("operation journals are canonical and enforce ownership boundaries", () => {
  const transactionId = createTransactionId(new Date("2026-08-30T12:00:00Z"), Buffer.from("0123456789abcdef", "hex"));
  assert.equal(transactionId, "20260830T120000Z-0123456789abcdef");
  const input = {
    transactionId,
    manifestVersion: 1,
    sourceRelease: "v0.2.0-beta.1",
    targetRelease: "v1.0.0",
    operations: [
      { operation: "replace", path: "AGENTS.md", before_hash: `sha256:${"1".repeat(64)}`, after_hash: `sha256:${"2".repeat(64)}`, backup_path: ".workflow/backups/run/AGENTS.md", ownership: "template-managed" },
      { operation: "create", path: ".agents/skills/workflow/SKILL.md", before_hash: null, after_hash: `sha256:${"3".repeat(64)}`, backup_path: null, ownership: "template-managed" }
    ]
  };
  const first = createOperationJournal(input);
  const second = createOperationJournal({ ...input, operations: [...input.operations].reverse() });
  assert.deepEqual(first.diagnostics, []);
  assert.deepEqual(first.bytes, second.bytes);

  const protectedReplacement = createOperationJournal({
    ...input,
    operations: [{ ...input.operations[0], path: ".workflow/project.yml", ownership: "project-seed" }]
  });
  assert.equal(protectedReplacement.journal, null);
  assert.equal(protectedReplacement.diagnostics[0].code, "HKT433");
});

test("legacy importer produces deterministic typed targets and a redacted inventory", async () => {
  const root = await legacyFixture();
  const stackPath = path.join(root, ".workflow/stack.yml");
  const stack = await readFile(stackPath, "utf8");
  await writeFile(stackPath, stack
    .replace('project_name: ""', 'project_name: "Example"')
    .replace('project_kind: ""', 'project_kind: "desktop-app"')
    .replace("  []\n\nruntimes:", "  - name: typescript\n    version: \"5.9\"\n    package_manager: npm\n    secret_field: nested-secret\n\nruntimes:")
    .replace('  test: ""', '  test: "npm test"')
    .replace("  []\n\nbuild_and_run:", "  - name: payments\n    purpose: secret-do-not-report\n\nbuild_and_run:"));

  const first = await importLegacyProject({ root });
  const second = await importLegacyProject({ root });
  assert.deepEqual(first.diagnostics, []);
  assert.deepEqual(first.importBytes, second.importBytes);
  assert.deepEqual(first.reportBytes, second.reportBytes);
  assert.deepEqual(first.imported.project.identity.name, { state: "known", value: "Example" });
  assert.deepEqual(first.imported.project.identity.kind, { state: "known", value: "other" });
  assert.deepEqual(first.imported.project.verification.test, { state: "known", value: ["npm test"] });
  assert.equal(first.imported.config.workflow.profile, "custom");
  assert.equal(first.report.summary.unresolved, 0);
  assert.equal(first.reportBytes.includes(Buffer.from("secret-do-not-report")), false);
  assert.equal(first.reportBytes.includes(Buffer.from("secret_field")), false);
  assert.equal(first.reportBytes.includes(Buffer.from("nested-secret")), false);
  assert.equal(first.importBytes.includes(Buffer.from("secret-do-not-report")), true);
  assert.equal(first.importBytes.includes(Buffer.from("nested-secret")), true);
});

test("legacy typecheck commands remain preserved when no typed v1 field exists", async () => {
  const root = await legacyFixture();
  const stackPath = path.join(root, ".workflow/stack.yml");
  await writeFile(stackPath, (await readFile(stackPath, "utf8")).replace('  build: ""', '  build: ""\n  typecheck: "npm run typecheck"'));

  const result = await importLegacyProject({ root });
  assert.deepEqual(result.diagnostics, []);
  assert.equal(result.imported.project.extensions["legacy.hekate"].stack.build_and_run.typecheck, "npm run typecheck");
  const entry = result.report.entries.find((item) => item.source_file === ".workflow/stack.yml" && item.source_path === "/build_and_run/typecheck");
  assert.equal(entry.critical, true);
  assert.equal(entry.disposition, "preserved");
  assert.equal(entry.target_path, "/project/extensions/legacy.hekate/stack/build_and_run/typecheck");
});

test("legacy importer blocks conflicting profiles and malformed critical values", async () => {
  const root = await legacyFixture();
  const workflowPath = path.join(root, ".workflow/workflow.yml");
  await writeFile(workflowPath, (await readFile(workflowPath, "utf8")).replace("profile: null", "profile: fast"));
  const presetsPath = path.join(root, ".workflow/presets.yml");
  await writeFile(presetsPath, `meta: {active_preset: full}\n${await readFile(presetsPath, "utf8")}`);
  const result = await importLegacyProject({ root });
  assert.equal(result.imported, null);
  assert.equal(result.diagnostics.some((item) => item.code === "HKT511"), true);
  assert.equal(result.report.summary.unresolved > 0, true);
  assert.equal(result.report.entries.every((entry) => entry.redacted), true);

  const malformed = await legacyFixture();
  const stackPath = path.join(malformed, ".workflow/stack.yml");
  await writeFile(stackPath, (await readFile(stackPath, "utf8")).replace("languages:\n", "languages: invalid\nlegacy_languages:\n"));
  const malformedResult = await importLegacyProject({ root: malformed });
  assert.equal(malformedResult.imported, null);
  assert.equal(malformedResult.diagnostics.some((item) => item.code === "HKT506"), true);
});

test("legacy importer rejects symlinked critical files", async () => {
  const root = await legacyFixture();
  const outside = path.join(await mkdtemp(path.join(tmpdir(), "hekate-legacy-outside-")), "stack.yml");
  await writeFile(outside, "meta: {}\n");
  await writeFile(path.join(root, ".workflow/stack.yml"), "placeholder");
  await unlink(path.join(root, ".workflow/stack.yml"));
  await symlink(outside, path.join(root, ".workflow/stack.yml"));
  const result = await importLegacyProject({ root });
  assert.equal(result.imported, null);
  assert.equal(result.diagnostics[0].code, "HKT501");
});

test("legacy importer inventories adapters and archives orchestration without exposing keys", async () => {
  const root = await legacyFixture();
  await writeFile(path.join(root, ".workflow/state.yml"), "install:\n  adapters: [gemini, aider, gemini]\nschema: {state_version: 2}\n");
  await writeFile(path.join(root, ".workflow/orchestration.yml"), "schema_version: 2\nprofiles:\n  sk_live_private_value: {harness: claude}\n");
  const workflowPath = path.join(root, ".workflow/workflow.yml");
  await writeFile(workflowPath, (await readFile(workflowPath, "utf8"))
    .replace("no_unrequested_dependencies: true", "no_unrequested_dependencies: false")
    .replace("ask_before_destructive: true", "ask_before_destructive: false"));

  const result = await importLegacyProject({ root });
  assert.deepEqual(result.diagnostics, []);
  assert.deepEqual(result.imported.selected_adapters, ["aider", "gemini"]);
  assert.equal(result.imported.archived["orchestration.yml"].profiles.sk_live_private_value.harness, "claude");
  assert.equal(result.reportBytes.includes(Buffer.from("sk_live_private_value")), false);
  assert.equal(result.report.entries.find((item) => item.source_file === ".workflow/orchestration.yml").critical, true);
  for (const sourcePath of ["/scope_control/no_unrequested_dependencies", "/scope_control/ask_before_destructive"]) {
    const entry = result.report.entries.find((item) => item.source_file === ".workflow/workflow.yml" && item.source_path === sourcePath);
    assert.equal(entry.disposition, "deprecated");
    assert.match(entry.target_path, /^\/archived\//);
  }
});

test("legacy importer privately archives malformed non-critical extension bytes", async () => {
  const root = await legacyFixture();
  const malformed = Buffer.from("extensions:\n  private_key: HKT_MALFORMED_SECRET\n  broken: [\n");
  await writeFile(path.join(root, ".workflow/orchestration.local.yml"), malformed);

  const result = await importLegacyProject({ root });
  assert.deepEqual(result.diagnostics, []);
  assert.notEqual(result.imported, null);
  const archived = result.imported.archived["orchestration.local.yml"];
  assert.equal(archived.encoding, "base64");
  assert.deepEqual(Buffer.from(archived.bytes, archived.encoding), malformed);
  const entry = result.report.entries.find((item) => item.source_file === ".workflow/orchestration.local.yml");
  assert.equal(entry.critical, false);
  assert.equal(entry.disposition, "unresolved");
  assert.notEqual(entry.diagnostic_code, null);
  assert.equal(result.reportBytes.includes(Buffer.from("HKT_MALFORMED_SECRET")), false);
  assert.equal(result.importBytes.includes(Buffer.from("HKT_MALFORMED_SECRET")), false);
});

test("legacy importer rejects future orchestration and report count tampering", async () => {
  const root = await legacyFixture();
  await writeFile(path.join(root, ".workflow/orchestration.yml"), "schema_version: 3\n");
  const result = await importLegacyProject({ root });
  assert.equal(result.imported, null);
  assert.equal(result.diagnostics.some((item) => item.code === "HKT515"), true);

  const tampered = structuredClone(result.report);
  tampered.summary.unresolved = 0;
  assert.equal(validateMigrationReport(tampered).some((item) => item.code === "HKT517"), true);
  assert.notDeepEqual(validateSchema("legacy-import", {
    schema_version: 1,
    source_layout: "legacy-0.x",
    selected_adapters: [],
    config: {},
    project: {},
    archived: {}
  }, "import.json"), []);
});

test("legacy importer rejects malformed installed orchestration", async () => {
  const root = await legacyFixture();
  await writeFile(path.join(root, ".workflow/orchestration.yml"), "profiles:\n  review: [\n");
  const result = await importLegacyProject({ root });
  assert.equal(result.imported, null);
  assert.equal(result.report.entries.find((item) => item.source_file === ".workflow/orchestration.yml").critical, true);
});

test("legacy importer rejects malformed installed state rather than losing adapters", async () => {
  const root = await legacyFixture();
  await writeFile(path.join(root, ".workflow/state.yml"), "install:\n  adapters: [claude\n");
  const result = await importLegacyProject({ root });
  assert.equal(result.imported, null);
  const entry = result.report.entries.find((item) => item.source_file === ".workflow/state.yml");
  assert.equal(entry.critical, true);
  assert.equal(entry.disposition, "unresolved");
});
