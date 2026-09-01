import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { cp, mkdir, mkdtemp, readFile, readdir, unlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { acquireProjectUpdateLock, checkProject, compileProject, importLegacyProject } from "@hekate/core";

const cli = fileURLToPath(new URL("../bin/hekate.js", import.meta.url));
const repositoryRoot = fileURLToPath(new URL("../../../", import.meta.url));

function run(args, cwd, env = process.env) {
  return spawnSync(process.execPath, [cli, ...args], { cwd, encoding: "utf8", env });
}

test("CLI rejects invalid usage", () => {
  const result = run(["check", "--check"], process.cwd());
  assert.equal(result.status, 2);
  assert.match(result.stderr, /^usage:/);
});

test("check accepts a directory without Hekate inputs", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "hekate-cli-"));
  const result = run(["check", "--json"], root);
  assert.equal(result.status, 0);
  const output = JSON.parse(result.stdout);
  assert.equal(output.gate_state, "absent");
  assert.deepEqual(output.diagnostics, []);
});

function digest(bytes) {
  return `sha256:${createHash("sha256").update(bytes).digest("hex")}`;
}

async function projectSnapshot(root, relative = "") {
  const snapshot = {};
  const directory = path.join(root, relative);
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const item = relative ? `${relative}/${entry.name}` : entry.name;
    if ([".workflow/transactions", ".workflow/backups", ".workflow/migration"].some((excluded) => item === excluded || item.startsWith(`${excluded}/`))) continue;
    if (item === ".workflow/update.lock") continue;
    if (entry.isDirectory()) Object.assign(snapshot, await projectSnapshot(root, item));
    else snapshot[item] = (await readFile(path.join(root, item))).toString("base64");
  }
  return snapshot;
}

async function historicalFixture(release = "v0.2.0-beta.1", prefix = "hekate-cli-legacy-") {
  const root = await mkdtemp(path.join(tmpdir(), prefix));
  await cp(path.join(repositoryRoot, `packages/core/test/fixtures/historical/${release}/input`), root, { recursive: true });
  return root;
}

async function upgradeFixture() {
  const root = await mkdtemp(path.join(tmpdir(), "hekate-cli-upgrade-"));
  const source = await mkdtemp(path.join(tmpdir(), "hekate-cli-source-"));
  await mkdir(path.join(root, ".workflow"));
  await mkdir(path.join(source, "distribution"));
  await mkdir(path.join(source, "templates", ".workflow"), { recursive: true });
  const config = await readFile(path.join(repositoryRoot, "templates/.workflow/config.yml"));
  const project = Buffer.from(`schema_version: 1
identity:
  name: {state: known, value: Fixture}
  kind: {state: known, value: cli}
  description: {state: known, value: Upgrade fixture}
stack:
  languages: {state: known, value: [{name: javascript}]}
  frameworks: {state: known, value: []}
  runtimes: {state: known, value: [{name: node, version: "20"}]}
  dependencies: {state: known, value: []}
verification:
  format: {state: not_applicable}
  lint: {state: not_applicable}
  test: {state: not_applicable}
  build: {state: not_applicable}
  validate: {state: not_applicable}
architecture:
  references: {state: known, value: []}
  constraints: {state: known, value: []}
confirmation: {state: confirmed}
extensions: {}
`);
  const gitignore = Buffer.from("# hekate\n.workflow/backups/\n.workflow/session.local.yml\n");
  await writeFile(path.join(root, ".workflow/config.yml"), config);
  await writeFile(path.join(root, ".workflow/project.yml"), project);
  await writeFile(path.join(root, ".gitignore"), gitignore);
  await writeFile(path.join(source, "templates/.workflow/config.yml"), config);
  await writeFile(path.join(source, "templates/.workflow/project.yml"), project);
  await writeFile(path.join(source, "templates/gitignore.snippet"), gitignore);
  assert.equal((await compileProject({ root })).ok, true);
  const lock = await readFile(path.join(root, ".workflow/status.lock.json"));
  const manifest = {
    schema_version: 1,
    manifest_version: 1,
    adapters: [],
    components: [{ id: "core", default: true, adapters: [] }],
    assets: [
      { asset_id: "config", component: "core", source: "templates/.workflow/config.yml", destination: ".workflow/config.yml", ownership: "project-seed", update_strategy: "typed-migration", remove_strategy: "preserve", mode: "0644" },
      { asset_id: "project", component: "core", source: "templates/.workflow/project.yml", destination: ".workflow/project.yml", ownership: "project-seed", update_strategy: "typed-migration", remove_strategy: "preserve", mode: "0644" },
      { asset_id: "gitignore", component: "core", source: "templates/gitignore.snippet", destination: ".gitignore", ownership: "shared-merge", update_strategy: "structured-merge", remove_strategy: "remove-contribution", mode: "0644" },
      { asset_id: "lock", component: "core", source: null, destination: ".workflow/status.lock.json", ownership: "generated", update_strategy: "regenerate", remove_strategy: "remove-if-generated", mode: "0600" },
      { asset_id: "state", component: "core", source: null, destination: ".workflow/install-state.json", ownership: "generated", update_strategy: "regenerate", remove_strategy: "preserve", mode: "0600" }
    ]
  };
  await writeFile(path.join(source, "distribution/install-manifest.json"), `${JSON.stringify(manifest)}\n`);
  const state = {
    schema_version: 1,
    manifest_version: 1,
    source_release: "0.3.0",
    selected_components: ["core"],
    selected_adapters: [],
    assets: [
      { asset_id: "config", destination: ".workflow/config.yml", ownership: "project-seed", installed_source_hash: digest(config), destination_hash: digest(config) },
      { asset_id: "project", destination: ".workflow/project.yml", ownership: "project-seed", installed_source_hash: digest(project), destination_hash: digest(project) },
      { asset_id: "gitignore", destination: ".gitignore", ownership: "shared-merge", installed_source_hash: digest(gitignore), destination_hash: digest(gitignore) },
      { asset_id: "lock", destination: ".workflow/status.lock.json", ownership: "generated", installed_source_hash: null, destination_hash: digest(lock) },
      { asset_id: "state", destination: ".workflow/install-state.json", ownership: "generated", installed_source_hash: null, destination_hash: null }
    ]
  };
  await writeFile(path.join(root, ".workflow/install-state.json"), `${JSON.stringify(state)}\n`);
  return { root, source };
}

test("upgrade CLI plans without mutation and commits through the verified transaction engine", async () => {
  const { root, source } = await upgradeFixture();
  const statePath = path.join(root, ".workflow/install-state.json");
  const before = await readFile(statePath);
  const dryRun = run(["upgrade", "--to=0.3.1", "--force", "--dry-run", "--json", `--source=${source}`, `--target=${root}`], root);
  assert.equal(dryRun.status, 0, dryRun.stderr);
  assert.equal(JSON.parse(dryRun.stdout).dry_run, true);
  assert.deepEqual(await readFile(statePath), before);

  const refused = run(["upgrade", "--to=0.3.1", "--force", "--json", `--source=${source}`, `--target=${root}`], root);
  assert.equal(refused.status, 1);
  assert.equal(JSON.parse(refused.stdout).diagnostics[0].code, "HKT902");
  assert.deepEqual(await readFile(statePath), before);

  const corruptRuntime = path.join(await mkdtemp(path.join(tmpdir(), "hekate-runtime-corrupt-")), "runtime");
  await cp(path.join(repositoryRoot, "distribution/runtime"), corruptRuntime, { recursive: true });
  await writeFile(path.join(corruptRuntime, "schemas/config.schema.json"), "{}\n");
  const corrupt = run(["upgrade", "--to=0.3.1", "--force", "--yes", "--json", `--source=${source}`, `--target=${root}`], root, { ...process.env, HEKATE_RECOVERY_RUNTIME_ROOT: corruptRuntime });
  assert.equal(corrupt.status, 1);
  assert.equal(JSON.parse(corrupt.stdout).diagnostics[0].code, "HKT904");
  assert.deepEqual(await readFile(statePath), before);

  const applied = run(["upgrade", "--to=0.3.1", "--force", "--yes", "--json", `--source=${source}`, `--target=${root}`], root);
  assert.equal(applied.status, 0, `${applied.stdout}\n${applied.stderr}`);
  const result = JSON.parse(applied.stdout);
  assert.equal(result.ok, true);
  assert.equal(JSON.parse(await readFile(statePath, "utf8")).source_release, "0.3.1");
  assert.equal(JSON.parse(await readFile(path.join(root, `.workflow/transactions/${result.transaction_id}/operation-journal.json`), "utf8")).status, "committed");

  const rollbackPlan = run(["rollback", `--transaction=${result.transaction_id}`, "--dry-run", "--json", `--target=${root}`], root);
  assert.equal(rollbackPlan.status, 0, rollbackPlan.stderr);
  assert.ok(JSON.parse(rollbackPlan.stdout).actions.length > 0);
  await assert.rejects(readFile(path.join(root, ".workflow/update.lock")), { code: "ENOENT" });
  const refusedRollback = run(["rollback", `--transaction=${result.transaction_id}`, "--json", `--target=${root}`], root);
  assert.equal(refusedRollback.status, 1);
  assert.equal(JSON.parse(refusedRollback.stdout).diagnostics[0].code, "HKT902");
  const rolledBack = run(["rollback", `--transaction=${result.transaction_id}`, "--yes", "--json", `--target=${root}`], root);
  assert.equal(rolledBack.status, 0, `${rolledBack.stdout}\n${rolledBack.stderr}`);
  assert.equal(JSON.parse(rolledBack.stdout).rolled_back, true);
  assert.deepEqual(await readFile(statePath), before);
});

test("first forced upgrade preserves a customized typed installation without an ownership ledger", async () => {
  const { root } = await upgradeFixture();
  const configPath = path.join(root, ".workflow/config.yml");
  const projectPath = path.join(root, ".workflow/project.yml");
  const config = (await readFile(configPath, "utf8"))
    .replace("profile: medium", "profile: full")
    .replace("extensions: {}", "extensions:\n  release.fixture: preserved");
  const project = (await readFile(projectPath, "utf8"))
    .replace("description: {state: known, value: Upgrade fixture}", "description: {state: known, value: Customized typed installation}")
    .replace("extensions: {}", "extensions:\n  local.fact: preserved");
  await writeFile(configPath, config);
  await writeFile(projectPath, project);
  assert.equal((await compileProject({ root })).ok, true);
  await unlink(path.join(root, ".workflow/install-state.json"));
  const before = await projectSnapshot(root);

  const applied = run(["upgrade", "--to=0.3.0-beta.1", "--force", "--yes", "--json", `--source=${repositoryRoot}`, `--target=${root}`], root);
  assert.equal(applied.status, 0, `${applied.stdout}\n${applied.stderr}`);
  const result = JSON.parse(applied.stdout);
  assert.equal(result.ok, true);
  assert.equal(result.preservation, null);
  assert.equal(await readFile(configPath, "utf8"), config);
  assert.equal(await readFile(projectPath, "utf8"), project);
  assert.equal(JSON.parse(await readFile(path.join(root, ".workflow/install-state.json"), "utf8")).source_release, "0.3.0-beta.1");

  const rolledBack = run(["rollback", `--transaction=${result.transaction_id}`, "--yes", "--json", `--target=${root}`], root);
  assert.equal(rolledBack.status, 0, `${rolledBack.stdout}\n${rolledBack.stderr}`);
  assert.equal(JSON.parse(rolledBack.stdout).rolled_back, true);
  assert.deepEqual(await projectSnapshot(root), before);
});

test("a mutating upgrade acquires the project lock before discovery", async () => {
  const { root, source } = await upgradeFixture();
  const lock = await acquireProjectUpdateLock({ root, transactionId: "20260830T160021Z-0011223344556677" });
  try {
    await writeFile(path.join(root, ".workflow/install-state.json"), "not json\n");
    const result = run(["upgrade", "--to=0.3.1", "--force", "--yes", "--json", `--source=${source}`, `--target=${root}`], root);
    assert.equal(result.status, 1, `${result.stdout}\n${result.stderr}`);
    assert.equal(JSON.parse(result.stdout).diagnostics[0].code, "HKT444");
  } finally {
    await lock.release();
  }
});

test("confirmed rollback recovers its matching dead project lock", async () => {
  const { root, source } = await upgradeFixture();
  const original = await projectSnapshot(root);
  const applied = run(["upgrade", "--to=0.3.1", "--force", "--yes", "--json", `--source=${source}`, `--target=${root}`], root);
  assert.equal(applied.status, 0, `${applied.stdout}\n${applied.stderr}`);
  const transactionId = JSON.parse(applied.stdout).transaction_id;
  const exited = spawnSync(process.execPath, ["-e", "process.exit(0)"]);
  assert.equal(exited.status, 0);
  await writeFile(path.join(root, ".workflow/update.lock"), `${JSON.stringify({ schema_version: 1, transaction_id: transactionId, pid: exited.pid })}\n`);

  const rollback = run(["rollback", `--transaction=${transactionId}`, "--yes", "--json", `--target=${root}`], root);
  assert.equal(rollback.status, 0, `${rollback.stdout}\n${rollback.stderr}`);
  assert.equal(JSON.parse(rollback.stdout).rolled_back, true);
  assert.deepEqual(await projectSnapshot(root), original);
});

test("rollback preserves post-upgrade user edits without partial mutation", async () => {
  const root = await historicalFixture();
  const applied = run(["upgrade", "--to=0.3.0", "--force", "--yes", "--json", `--source=${repositoryRoot}`, `--target=${root}`], root);
  assert.equal(applied.status, 0, `${applied.stdout}\n${applied.stderr}`);
  const transactionId = JSON.parse(applied.stdout).transaction_id;
  const configPath = path.join(root, ".workflow/config.yml");
  const edited = Buffer.from("user-edited-after-upgrade\n");
  await writeFile(configPath, edited);
  const postEdit = await projectSnapshot(root);

  const rollback = run(["rollback", `--transaction=${transactionId}`, "--yes", "--json", `--target=${root}`], root);
  assert.equal(rollback.status, 1, `${rollback.stdout}\n${rollback.stderr}`);
  const result = JSON.parse(rollback.stdout);
  assert.equal(result.rolled_back, false);
  assert.deepEqual(result.actions, []);
  assert.deepEqual(result.conflicts, [{ path: ".workflow/config.yml", reason: "current bytes do not match after_hash" }]);
  assert.deepEqual(await projectSnapshot(root), postEdit);
  assert.deepEqual(await readFile(configPath), edited);
  const journal = JSON.parse(await readFile(path.join(root, `.workflow/transactions/${transactionId}/operation-journal.json`), "utf8"));
  assert.equal(journal.status, "rollback_conflict");
});

test("cleanup explicitly removes a complete terminal transaction bundle", async () => {
  const root = await historicalFixture();
  const applied = run(["upgrade", "--to=0.3.0", "--force", "--yes", "--json", `--source=${repositoryRoot}`, `--target=${root}`], root);
  assert.equal(applied.status, 0, `${applied.stdout}\n${applied.stderr}`);
  const transactionId = JSON.parse(applied.stdout).transaction_id;
  const backupRoot = path.join(root, `.workflow/backups/${transactionId}`);
  await mkdir(backupRoot, { recursive: true });
  await writeFile(path.join(backupRoot, "recovery-sentinel.txt"), "backup evidence\n");

  const dryRun = run(["cleanup", `--transaction=${transactionId}`, "--dry-run", "--json", `--target=${root}`], root);
  assert.equal(dryRun.status, 0, `${dryRun.stdout}\n${dryRun.stderr}`);
  const planned = JSON.parse(dryRun.stdout);
  assert.equal(planned.status, "committed");
  assert.equal(planned.actions.length, 3);
  await readFile(path.join(root, `.workflow/transactions/${transactionId}/operation-journal.json`));

  const refused = run(["cleanup", `--transaction=${transactionId}`, "--json", `--target=${root}`], root);
  assert.equal(refused.status, 1);
  assert.equal(JSON.parse(refused.stdout).diagnostics[0].code, "HKT902");

  const cleaned = run(["cleanup", `--transaction=${transactionId}`, "--yes", "--json", `--target=${root}`], root);
  assert.equal(cleaned.status, 0, `${cleaned.stdout}\n${cleaned.stderr}`);
  assert.equal(JSON.parse(cleaned.stdout).cleaned, true);
  await assert.rejects(readFile(path.join(root, `.workflow/transactions/${transactionId}/operation-journal.json`)));
  const repeated = run(["cleanup", `--transaction=${transactionId}`, "--yes", "--json", `--target=${root}`], root);
  assert.equal(repeated.status, 0, `${repeated.stdout}\n${repeated.stderr}`);
  assert.equal(JSON.parse(repeated.stdout).status, "absent");
});

test("upgrade CLI imports a supported historical installation transactionally", async () => {
  const root = await historicalFixture();
  const applied = run(["upgrade", "--to=0.3.0", "--force", "--yes", "--json", `--source=${repositoryRoot}`, `--target=${root}`], root);
  assert.equal(applied.status, 0, `${applied.stdout}\n${applied.stderr}`);
  const result = JSON.parse(applied.stdout);
  assert.equal(result.ok, true);
  assert.equal(result.preservation.unresolved, 0);
  assert.equal(JSON.parse(await readFile(path.join(root, ".workflow/install-state.json"), "utf8")).source_release, "0.3.0");
  assert.equal(JSON.parse(await readFile(path.join(root, `.workflow/transactions/${result.transaction_id}/operation-journal.json`), "utf8")).status, "committed");
});

for (const variant of [
  { name: "v0.1.0-beta.1", fixture: "v0.1.0-beta.1" },
  { name: "v0.2.0-beta.1", fixture: "v0.2.0-beta.1" },
  { name: "v0.2.0-beta.1 CRLF Unicode", fixture: "v0.2.0-beta.1", crlf: true }
]) {
  test(`historical ${variant.name} supports dry-run, repeat, and offline rollback`, async () => {
    const root = await historicalFixture(variant.fixture, "hekate-cli-matrix-");
    if (variant.crlf) {
      const target = path.join(root, ".workflow/workflow.yml");
      const source = await readFile(target, "utf8");
      await writeFile(target, `${source.replaceAll("\r\n", "\n").replaceAll("\n", "\r\n")}\r\n# Unicode fixture: Привет\r\n`);
    }
    const original = await projectSnapshot(root);
    const common = ["--to=0.3.0", "--force", "--json", `--source=${repositoryRoot}`, `--target=${root}`];
    const dryRun = run(["upgrade", ...common.slice(0, 2), "--dry-run", ...common.slice(2)], root);
    assert.equal(dryRun.status, 0, `${dryRun.stdout}\n${dryRun.stderr}`);
    assert.deepEqual(await projectSnapshot(root), original);

    const first = run(["upgrade", ...common.slice(0, 2), "--yes", ...common.slice(2)], root);
    assert.equal(first.status, 0, `${first.stdout}\n${first.stderr}`);
    const firstResult = JSON.parse(first.stdout);
    const upgraded = await projectSnapshot(root);
    const second = run(["upgrade", ...common.slice(0, 2), "--yes", ...common.slice(2)], root);
    assert.equal(second.status, 0, `${second.stdout}\n${second.stderr}`);
    assert.deepEqual(await projectSnapshot(root), upgraded);

    const rollback = run(["rollback", `--transaction=${firstResult.transaction_id}`, "--yes", "--json", `--target=${root}`], root);
    assert.equal(rollback.status, 0, `${rollback.stdout}\n${rollback.stderr}`);
    assert.deepEqual(await projectSnapshot(root), original);
  });
}

test("partially applied legacy migration upgrades transactionally", async () => {
  const root = await historicalFixture("v0.1.0-beta.1", "hekate-cli-partial-migration-");
  const orchestrationPath = path.join(root, ".workflow/orchestration.yml");
  const partiallyMigrated = (await readFile(orchestrationPath, "utf8"))
    .replace("schema_version: 1", "schema_version: 2")
    .replace("default_harness: pi\n", "default_harness: pi\ndefault_profile: null\n")
    .replace("harnesses:\n", "profiles:\n\nharnesses:\n");
  await writeFile(orchestrationPath, partiallyMigrated);
  await writeFile(path.join(root, ".workflow/state.yml"), `install:
  tool: hekate
  installed_ref: 862cf69257a966a3d1c478fe9ccd686968738125
  adapters:
    - claude
schema:
  state_version: 2
  applied_migrations:
    - 001-add-three-branch-model
    - 002-add-status-index
    - 003-add-cross-harness-orchestration
`);
  const statusBytes = await readFile(path.join(root, ".workflow/status.yml"));
  assert.equal(statusBytes.includes(Buffer.from("default_profile")), false);
  const imported = await importLegacyProject({ root });
  assert.deepEqual(imported.diagnostics, []);
  assert.deepEqual(imported.imported.selected_adapters, ["claude"]);
  assert.equal(imported.imported.archived["orchestration.yml"].schema_version, 2);
  assert.equal(imported.imported.archived["orchestration.yml"].profiles, null);
  assert.deepEqual(imported.imported.archived["state.yml"].schema.applied_migrations, [
    "001-add-three-branch-model",
    "002-add-status-index",
    "003-add-cross-harness-orchestration"
  ]);
  assert.equal(imported.report.summary.unresolved, 0);
  const original = await projectSnapshot(root);
  const common = ["--to=0.3.0", "--force", "--json", `--source=${repositoryRoot}`, `--target=${root}`];

  const dryRun = run(["upgrade", ...common.slice(0, 2), "--dry-run", ...common.slice(2)], root);
  assert.equal(dryRun.status, 0, `${dryRun.stdout}\n${dryRun.stderr}`);
  assert.deepEqual(JSON.parse(dryRun.stdout).preservation, imported.report.summary);
  assert.deepEqual(await projectSnapshot(root), original);

  const first = run(["upgrade", ...common.slice(0, 2), "--yes", ...common.slice(2)], root);
  assert.equal(first.status, 0, `${first.stdout}\n${first.stderr}`);
  const firstResult = JSON.parse(first.stdout);
  const migrationRoot = path.join(root, `.workflow/migration/${firstResult.transaction_id}`);
  assert.deepEqual(await readFile(path.join(migrationRoot, "import.json")), imported.importBytes);
  assert.deepEqual(await readFile(path.join(migrationRoot, "report.json")), imported.reportBytes);
  const installedState = JSON.parse(await readFile(path.join(root, ".workflow/install-state.json"), "utf8"));
  assert.deepEqual(installedState.selected_adapters, ["claude"]);
  const compiled = await compileProject({ root, mode: "check" });
  assert.equal(compiled.lockStatus, "current");
  const upgraded = await projectSnapshot(root);

  const second = run(["upgrade", ...common.slice(0, 2), "--yes", ...common.slice(2)], root);
  assert.equal(second.status, 0, `${second.stdout}\n${second.stderr}`);
  assert.deepEqual(await projectSnapshot(root), upgraded);

  const rollback = run(["rollback", `--transaction=${firstResult.transaction_id}`, "--yes", "--json", `--target=${root}`], root);
  assert.equal(rollback.status, 0, `${rollback.stdout}\n${rollback.stderr}`);
  assert.deepEqual(await projectSnapshot(root), original);
});

for (const profile of ["fast", "medium", "full"]) {
  test(`released ${profile} preset survives forced upgrade and offline rollback`, async () => {
    const root = await historicalFixture("v0.2.0-beta.1", "hekate-cli-preset-");
    const workflowPath = path.join(root, ".workflow/workflow.yml");
    await writeFile(workflowPath, (await readFile(workflowPath, "utf8")).replace("  preset: null", `  preset: ${profile}`));
    const imported = await importLegacyProject({ root });
    assert.deepEqual(imported.diagnostics, []);
    assert.equal(imported.imported.config.workflow.profile, profile);
    const original = await projectSnapshot(root);
    const common = ["--to=0.3.0", "--force", "--json", `--source=${repositoryRoot}`, `--target=${root}`];

    const dryRun = run(["upgrade", ...common.slice(0, 2), "--dry-run", ...common.slice(2)], root);
    assert.equal(dryRun.status, 0, `${dryRun.stdout}\n${dryRun.stderr}`);
    assert.deepEqual(await projectSnapshot(root), original);

    const first = run(["upgrade", ...common.slice(0, 2), "--yes", ...common.slice(2)], root);
    assert.equal(first.status, 0, `${first.stdout}\n${first.stderr}`);
    const firstResult = JSON.parse(first.stdout);
    assert.match(await readFile(path.join(root, ".workflow/config.yml"), "utf8"), new RegExp(`^  profile: ${profile}$`, "m"));
    const lock = JSON.parse(await readFile(path.join(root, ".workflow/status.lock.json"), "utf8"));
    assert.equal(lock.resolved_policy.profile, profile);
    assert.deepEqual(lock.resolved_policy.tdd, { mode: "require-test-evidence" });
    assert.deepEqual(lock.resolved_policy.history, { enabled: true });
    const upgraded = await projectSnapshot(root);

    const second = run(["upgrade", ...common.slice(0, 2), "--yes", ...common.slice(2)], root);
    assert.equal(second.status, 0, `${second.stdout}\n${second.stderr}`);
    assert.deepEqual(await projectSnapshot(root), upgraded);

    const rollback = run(["rollback", `--transaction=${firstResult.transaction_id}`, "--yes", "--json", `--target=${root}`], root);
    assert.equal(rollback.status, 0, `${rollback.stdout}\n${rollback.stderr}`);
    assert.deepEqual(await projectSnapshot(root), original);
  });
}

test("customized legacy facts survive dry-run, upgrade, repeat, and offline rollback", async () => {
  const root = await historicalFixture("v0.2.0-beta.1", "hekate-cli-custom-facts-");
  await writeFile(path.join(root, ".workflow/stack.yml"), `meta:
  project_name: "H\u00e9kate: Core #1"
  project_kind: service
  description: "Migration fixture with quotes: '#safe'"
languages:
  - name: typescript
    version: "5.9"
    package_manager: npm
runtimes:
  - name: node
    version: "24"
frameworks:
  backend: [fastify]
  frontend: []
  testing: [node-test]
dependencies: [yaml, ajv]
datastores:
  primary: "postgres: 17"
  cache: ""
  search: ""
  other: []
build_and_run:
  install: npm ci
  dev: npm run dev
  format: npm run format
  lint: [npm run lint, npm run lint:types]
  test: 'node --test "test:#1.js"'
  typecheck: npm run typecheck
  build: npm run build
  validate: npm run validate
`);
  await writeFile(path.join(root, ".workflow/architecture.yml"), `style: hexagonal
style_notes: |-
  Ports own boundaries: adapters do not own domain policy.
  Unicode rule: \u03bb remains project-authored.
layers: []
modules: []
dependency_rules:
  - domain does not import infrastructure
patterns: [ports-and-adapters]
anti_patterns: []
extension_points: []
`);
  await writeFile(path.join(root, ".workflow/conventions.yml"), `code_style:
  formatter: prettier
  linter: eslint
  max_line_length: 100
  indent: spaces-2
  enforce_on_save: true
naming:
  files: kebab-case
tests:
  required: true
  coverage_min: 90
commits:
  preset: conventional
  subject_max_length: 72
branches:
  default: main
review_checklist: ["tests pass", "docs: current # verified"]
documentation:
  readme_required: true
  changelog: keep-a-changelog
  api_docs: typedoc
`);

  const imported = await importLegacyProject({ root });
  assert.deepEqual(imported.diagnostics, []);
  assert.deepEqual(imported.imported.project.identity.name, { state: "known", value: "H\u00e9kate: Core #1" });
  assert.deepEqual(imported.imported.project.verification.lint, { state: "known", value: ["npm run lint", "npm run lint:types"] });
  assert.equal(imported.imported.project.extensions["legacy.hekate"].stack.build_and_run.typecheck, "npm run typecheck");
  assert.equal(imported.imported.project.extensions["legacy.hekate"].conventions.tests.coverage_min, 90);
  assert.equal(imported.report.summary.unresolved, 0);
  const original = await projectSnapshot(root);
  const common = ["--to=0.3.0", "--force", "--json", "--components=legacy-workflow-files", `--source=${repositoryRoot}`, `--target=${root}`];

  const dryRun = run(["upgrade", ...common.slice(0, 2), "--dry-run", ...common.slice(2)], root);
  assert.equal(dryRun.status, 0, `${dryRun.stdout}\n${dryRun.stderr}`);
  assert.deepEqual(JSON.parse(dryRun.stdout).preservation, imported.report.summary);
  assert.deepEqual(await projectSnapshot(root), original);

  const first = run(["upgrade", ...common.slice(0, 2), "--yes", ...common.slice(2)], root);
  assert.equal(first.status, 0, `${first.stdout}\n${first.stderr}`);
  const firstResult = JSON.parse(first.stdout);
  assert.deepEqual(await readFile(path.join(root, `.workflow/migration/${firstResult.transaction_id}/import.json`)), imported.importBytes);
  assert.deepEqual(await readFile(path.join(root, `.workflow/migration/${firstResult.transaction_id}/report.json`)), imported.reportBytes);
  assert.equal((await compileProject({ root, check: true })).ok, true);
  const upgraded = await projectSnapshot(root);

  const second = run(["upgrade", ...common.slice(0, 2), "--yes", ...common.slice(2)], root);
  assert.equal(second.status, 0, `${second.stdout}\n${second.stderr}`);
  assert.deepEqual(await projectSnapshot(root), upgraded);

  const rollback = run(["rollback", `--transaction=${firstResult.transaction_id}`, "--yes", "--json", `--target=${root}`], root);
  assert.equal(rollback.status, 0, `${rollback.stdout}\n${rollback.stderr}`);
  assert.deepEqual(await projectSnapshot(root), original);
});

for (const gate of [
  { name: "disabled Hekate", hekate: false, workflow: true, expected: "off" },
  { name: "disabled workflow module", hekate: true, workflow: false, expected: "workflow_disabled" }
]) {
  test(`${gate.name} survives forced upgrade and offline rollback`, async () => {
    const root = await historicalFixture("v0.2.0-beta.1", "hekate-cli-disabled-");
    const workflowPath = path.join(root, ".workflow/workflow.yml");
    await writeFile(workflowPath, `${await readFile(workflowPath, "utf8")}\nhekate:\n  enabled: ${gate.hekate}\n  modules:\n    workflow: ${gate.workflow}\n`);
    const original = await projectSnapshot(root);
    const common = ["--to=0.3.0", "--force", "--json", `--source=${repositoryRoot}`, `--target=${root}`];

    const dryRun = run(["upgrade", ...common.slice(0, 2), "--dry-run", ...common.slice(2)], root);
    assert.equal(dryRun.status, 0, `${dryRun.stdout}\n${dryRun.stderr}`);
    assert.deepEqual(await projectSnapshot(root), original);

    const first = run(["upgrade", ...common.slice(0, 2), "--yes", ...common.slice(2)], root);
    assert.equal(first.status, 0, `${first.stdout}\n${first.stderr}`);
    const firstResult = JSON.parse(first.stdout);
    assert.equal((await checkProject({ root })).gateState, gate.expected);
    const upgraded = await projectSnapshot(root);

    const second = run(["upgrade", ...common.slice(0, 2), "--yes", ...common.slice(2)], root);
    assert.equal(second.status, 0, `${second.stdout}\n${second.stderr}`);
    assert.deepEqual(await projectSnapshot(root), upgraded);

    const rollback = run(["rollback", `--transaction=${firstResult.transaction_id}`, "--yes", "--json", `--target=${root}`], root);
    assert.equal(rollback.status, 0, `${rollback.stdout}\n${rollback.stderr}`);
    assert.deepEqual(await projectSnapshot(root), original);
  });
}

test("custom orchestration survives forced upgrade as private deprecated configuration", async () => {
  const root = await historicalFixture("v0.2.0-beta.1", "hekate-cli-orchestration-");
  const secretKey = "private_harness_token";
  const secret = "HKT_ORCHESTRATION_SECRET_91b2";
  const orchestrationPath = path.join(root, ".workflow/orchestration.yml");
  const customized = (await readFile(orchestrationPath, "utf8"))
    .replace("default_profile: null", "default_profile: bespoke-review")
    .replace("profiles:\n", `profiles:\n  bespoke-review:\n    harness: team-cli\n    model: fixture/model-v2\n    effort: medium\n`)
    .replace("harnesses:\n", `harnesses:\n  team-cli:\n    enabled: true\n    command: team-agent\n    prompt_delivery: stdin\n    args: [\"--model\", \"{model}\"]\n    ${secretKey}: ${secret}\n`);
  await writeFile(orchestrationPath, customized);
  const imported = await importLegacyProject({ root });
  assert.deepEqual(imported.diagnostics, []);
  const archived = imported.imported.archived["orchestration.yml"];
  assert.equal(archived.default_profile, "bespoke-review");
  assert.deepEqual(archived.profiles["bespoke-review"], { harness: "team-cli", model: "fixture/model-v2", effort: "medium" });
  assert.equal(archived.harnesses["team-cli"][secretKey], secret);
  const orchestrationEntries = imported.report.entries.filter((entry) => entry.source_file === ".workflow/orchestration.yml");
  assert.ok(orchestrationEntries.length > 0);
  assert.equal(orchestrationEntries.every((entry) => entry.critical && entry.disposition === "deprecated"), true);
  assert.equal(imported.reportBytes.includes(Buffer.from("bespoke-review")), false);
  assert.equal(imported.reportBytes.includes(Buffer.from("team-cli")), false);
  assert.equal(imported.reportBytes.includes(Buffer.from(secretKey)), false);
  assert.equal(imported.reportBytes.includes(Buffer.from(secret)), false);
  const original = await projectSnapshot(root);
  const common = ["--to=0.3.0", "--force", "--json", `--source=${repositoryRoot}`, `--target=${root}`];

  const dryRun = run(["upgrade", ...common.slice(0, 2), "--dry-run", ...common.slice(2)], root);
  assert.equal(dryRun.status, 0, `${dryRun.stdout}\n${dryRun.stderr}`);
  assert.equal(`${dryRun.stdout}\n${dryRun.stderr}`.includes(secret), false);
  assert.deepEqual(await projectSnapshot(root), original);

  const first = run(["upgrade", ...common.slice(0, 2), "--yes", ...common.slice(2)], root);
  assert.equal(first.status, 0, `${first.stdout}\n${first.stderr}`);
  assert.equal(`${first.stdout}\n${first.stderr}`.includes(secret), false);
  const firstResult = JSON.parse(first.stdout);
  const migrationRoot = path.join(root, `.workflow/migration/${firstResult.transaction_id}`);
  assert.deepEqual(await readFile(path.join(migrationRoot, "import.json")), imported.importBytes);
  assert.deepEqual(await readFile(path.join(migrationRoot, "report.json")), imported.reportBytes);
  const compiled = await compileProject({ root, mode: "check" });
  assert.equal(compiled.lockStatus, "current");
  const upgraded = await projectSnapshot(root);

  const second = run(["upgrade", ...common.slice(0, 2), "--yes", ...common.slice(2)], root);
  assert.equal(second.status, 0, `${second.stdout}\n${second.stderr}`);
  assert.equal(`${second.stdout}\n${second.stderr}`.includes(secret), false);
  assert.deepEqual(await projectSnapshot(root), upgraded);

  const rollback = run(["rollback", `--transaction=${firstResult.transaction_id}`, "--yes", "--json", `--target=${root}`], root);
  assert.equal(rollback.status, 0, `${rollback.stdout}\n${rollback.stderr}`);
  assert.deepEqual(await projectSnapshot(root), original);
});

test("malformed non-critical extension and secrets survive the forced-upgrade protocol", async () => {
  const root = await historicalFixture("v0.2.0-beta.1", "hekate-cli-malformed-extension-");
  const secret = "not-a-real-private-token";
  const relative = ".workflow/orchestration.local.yml";
  const malformed = Buffer.from(`extensions:\n  private_token: ${secret}\n  broken: [\n`);
  await writeFile(path.join(root, relative), malformed);
  const imported = await importLegacyProject({ root });
  assert.deepEqual(imported.diagnostics, []);
  assert.equal(imported.report.summary.unresolved, 1);
  assert.equal(imported.reportBytes.includes(Buffer.from(secret)), false);
  const original = await projectSnapshot(root);
  const common = ["--to=0.3.0", "--force", "--json", `--source=${repositoryRoot}`, `--target=${root}`];

  const dryRun = run(["upgrade", ...common.slice(0, 2), "--dry-run", ...common.slice(2)], root);
  assert.equal(dryRun.status, 0, `${dryRun.stdout}\n${dryRun.stderr}`);
  assert.equal(`${dryRun.stdout}\n${dryRun.stderr}`.includes(secret), false);
  assert.match(JSON.parse(dryRun.stdout).plan, /^unresolved critical: 0 settings$/m);
  assert.match(JSON.parse(dryRun.stdout).plan, /^unresolved non-critical: 1 settings$/m);
  assert.deepEqual(await projectSnapshot(root), original);

  const first = run(["upgrade", ...common.slice(0, 2), "--yes", ...common.slice(2)], root);
  assert.equal(first.status, 0, `${first.stdout}\n${first.stderr}`);
  assert.equal(`${first.stdout}\n${first.stderr}`.includes(secret), false);
  const firstResult = JSON.parse(first.stdout);
  const migrationRoot = path.join(root, `.workflow/migration/${firstResult.transaction_id}`);
  const reportBytes = await readFile(path.join(migrationRoot, "report.json"));
  assert.equal(reportBytes.includes(Buffer.from(secret)), false);
  const privateImport = JSON.parse(await readFile(path.join(migrationRoot, "import.json"), "utf8"));
  const archived = privateImport.archived["orchestration.local.yml"];
  assert.deepEqual(Buffer.from(archived.bytes, archived.encoding), malformed);
  const compiled = await compileProject({ root, mode: "check" });
  assert.equal(compiled.lockStatus, "current");
  assert.equal(compiled.gateState, "needs_configuration");
  const upgraded = await projectSnapshot(root);

  const second = run(["upgrade", ...common.slice(0, 2), "--yes", ...common.slice(2)], root);
  assert.equal(second.status, 0, `${second.stdout}\n${second.stderr}`);
  assert.equal(`${second.stdout}\n${second.stderr}`.includes(secret), false);
  assert.deepEqual(await projectSnapshot(root), upgraded);

  const rollback = run(["rollback", `--transaction=${firstResult.transaction_id}`, "--yes", "--json", `--target=${root}`], root);
  assert.equal(rollback.status, 0, `${rollback.stdout}\n${rollback.stderr}`);
  assert.equal(`${rollback.stdout}\n${rollback.stderr}`.includes(secret), false);
  assert.deepEqual(await projectSnapshot(root), original);
});

test("a customized installation never loses unowned files to an unattended upgrade", async () => {
  const root = await historicalFixture("v0.2.0-beta.1", "hekate-cli-custom-");
  // Hekate has no record of installing this file, so it may be the user's own.
  const authored = "# House rules\n\nThis file was written by the project, not by Hekate.\n";
  await writeFile(path.join(root, "AGENTS.md"), authored);
  const original = await projectSnapshot(root);
  const common = ["--to=0.3.0", "--force", "--json", `--source=${repositoryRoot}`, `--target=${root}`];

  const planned = run(["upgrade", ...common.slice(0, 2), "--dry-run", ...common.slice(2)], root);
  assert.equal(planned.status, 0, `${planned.stdout}\n${planned.stderr}`);
  const plan = JSON.parse(planned.stdout);
  assert.deepEqual(plan.unowned_replacements, ["AGENTS.md"]);
  assert.match(plan.plan, /^replace unowned: AGENTS\.md$/m);
  assert.match(plan.plan, /^backup: \.workflow\/backups\/.+\/$/m);
  for (const line of ["preserved", "transformed", "deprecated and archived", "unresolved critical"]) {
    assert.match(plan.plan, new RegExp(`^${line}: \\d+ settings$`, "m"));
  }
  assert.deepEqual(await projectSnapshot(root), original);

  const unattended = run(["upgrade", ...common.slice(0, 2), "--yes", ...common.slice(2)], root);
  assert.equal(unattended.status, 1, `${unattended.stdout}\n${unattended.stderr}`);
  const refused = JSON.parse(unattended.stdout);
  assert.equal(refused.ok, false);
  assert.equal(refused.diagnostics[0].code, "HKT903");
  assert.match(refused.diagnostics[0].message, /AGENTS\.md/);
  assert.deepEqual(await projectSnapshot(root), original, "a refused upgrade must not touch the project");

  const approved = run(["upgrade", ...common.slice(0, 2), "--yes", "--replace-unowned", ...common.slice(2)], root);
  assert.equal(approved.status, 0, `${approved.stdout}\n${approved.stderr}`);
  const applied = JSON.parse(approved.stdout);
  assert.deepEqual(applied.unowned_replacements, ["AGENTS.md"]);
  assert.notEqual(await readFile(path.join(root, "AGENTS.md"), "utf8"), authored);

  const rollback = run(["rollback", `--transaction=${applied.transaction_id}`, "--yes", "--json", `--target=${root}`], root);
  assert.equal(rollback.status, 0, `${rollback.stdout}\n${rollback.stderr}`);
  assert.deepEqual(await projectSnapshot(root), original, "rollback must restore the authored file");
});

test("recorded managed adapter files are replaced transactionally and restored offline", async () => {
  const root = await historicalFixture("v0.2.0-beta.1", "hekate-cli-managed-prompts-");
  const imported = run(["upgrade", "--to=0.3.0", "--force", "--yes", "--json", `--source=${repositoryRoot}`, `--target=${root}`], root);
  assert.equal(imported.status, 0, `${imported.stdout}\n${imported.stderr}`);
  const common = ["--to=0.3.0", "--force", "--yes", "--json", "--adapters=claude,pi", `--source=${repositoryRoot}`, `--target=${root}`];
  const installed = run(["upgrade", ...common], root);
  assert.equal(installed.status, 0, `${installed.stdout}\n${installed.stderr}`);

  const assets = [
    ["CLAUDE.md", "templates/adapters/claude/CLAUDE.md"],
    [".claude/commands/analyze.md", "templates/prompts/analyze.md"],
    [".claude/commands/init-workflow.md", "templates/prompts/init-workflow.md"],
    [".claude/commands/plan.md", "templates/prompts/plan.md"],
    [".pi/prompts/analyze.md", "templates/prompts/analyze.md"],
    [".pi/prompts/init-workflow.md", "templates/prompts/init-workflow.md"],
    [".pi/prompts/plan.md", "templates/prompts/plan.md"]
  ];
  const customized = new Map();
  for (const [index, [destination]] of assets.entries()) {
    const bytes = Buffer.from(`# Project adapter file ${index + 1}\n\nKeep this local customization.\n`);
    customized.set(destination, bytes);
    await writeFile(path.join(root, destination), bytes);
  }
  const beforeReplacement = await projectSnapshot(root);

  const dryRun = run(["upgrade", ...common.slice(0, 2), "--dry-run", ...common.slice(3)], root);
  assert.equal(dryRun.status, 0, `${dryRun.stdout}\n${dryRun.stderr}`);
  assert.deepEqual(JSON.parse(dryRun.stdout).unowned_replacements, []);
  assert.deepEqual(await projectSnapshot(root), beforeReplacement);

  const replacement = run(["upgrade", ...common], root);
  assert.equal(replacement.status, 0, `${replacement.stdout}\n${replacement.stderr}`);
  const result = JSON.parse(replacement.stdout);
  const journal = JSON.parse(await readFile(path.join(root, `.workflow/transactions/${result.transaction_id}/operation-journal.json`), "utf8"));
  for (const [destination, source] of assets) {
    const operation = journal.operations.find((item) => item.path === destination);
    assert.equal(operation.operation, "replace", destination);
    assert.equal(operation.ownership, "template-managed", destination);
    assert.deepEqual(await readFile(path.join(root, operation.backup_path)), customized.get(destination), destination);
    assert.deepEqual(await readFile(path.join(root, destination)), await readFile(path.join(repositoryRoot, source)), destination);
  }

  const rollback = run(["rollback", `--transaction=${result.transaction_id}`, "--yes", "--json", `--target=${root}`], root);
  assert.equal(rollback.status, 0, `${rollback.stdout}\n${rollback.stderr}`);
  assert.deepEqual(await projectSnapshot(root), beforeReplacement);
});

test("an aborted import leaves its machine-readable report on disk", async () => {
  const root = await historicalFixture("v0.2.0-beta.1", "hekate-cli-abort-");
  // A critical legacy file that cannot be parsed must abort the upgrade.
  await writeFile(path.join(root, ".workflow/workflow.yml"), "workflow: {enabled: true\n");
  const original = await projectSnapshot(root);

  const aborted = run(["upgrade", "--to=0.3.0", "--force", "--yes", "--json", `--source=${repositoryRoot}`, `--target=${root}`], root);
  assert.equal(aborted.status, 1, `${aborted.stdout}\n${aborted.stderr}`);
  const result = JSON.parse(aborted.stdout);
  assert.equal(result.ok, false);
  assert.ok(result.diagnostics.length > 0);
  assert.match(result.migration_report, /^\.workflow\/migration\/.+$/);
  const report = JSON.parse(await readFile(path.join(root, result.migration_report, "report.json"), "utf8"));
  assert.equal(report.schema_version, 1);
  assert.ok(report.entries.length > 0, "the aborted report records no evidence");
  assert.deepEqual(await projectSnapshot(root), original, "an aborted import must not change the project");
});

test("optional components are requested by name and preserved across upgrades", async () => {
  const root = await historicalFixture("v0.2.0-beta.1", "hekate-cli-optional-");
  const common = ["--to=0.3.0", "--force", "--yes", "--json", `--source=${repositoryRoot}`, `--target=${root}`];

  const rejected = run(["upgrade", ...common, "--components=not-a-component"], root);
  assert.equal(rejected.status, 1);
  assert.equal(JSON.parse(rejected.stdout).diagnostics[0].code, "HKT414");

  // A default upgrade carries no legacy project-fact files or preset registry.
  const legacyPaths = [".workflow/stack.yml", ".workflow/architecture.yml", ".workflow/conventions.yml", ".workflow/presets.yml"];
  const optIn = run(["upgrade", ...common, "--components=legacy-workflow-files"], root);
  assert.equal(optIn.status, 0, `${optIn.stdout}\n${optIn.stderr}`);
  const state = JSON.parse(await readFile(path.join(root, ".workflow/install-state.json"), "utf8"));
  assert.ok(state.selected_components.includes("legacy-workflow-files"));

  // Omitting --components keeps the recorded opt-in rather than removing it.
  const repeat = run(["upgrade", ...common], root);
  assert.equal(repeat.status, 0, `${repeat.stdout}\n${repeat.stderr}`);
  const repeated = JSON.parse(await readFile(path.join(root, ".workflow/install-state.json"), "utf8"));
  assert.ok(repeated.selected_components.includes("legacy-workflow-files"));
  for (const relativePath of legacyPaths) {
    assert.ok(repeated.assets.some((asset) => asset.destination === relativePath), `${relativePath} left the installed ledger`);
  }
});
