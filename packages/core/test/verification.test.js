import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import {
  applyPreparedTransaction,
  compileProject,
  materializeInstallationContent,
  loadInstallManifest,
  planInstallation,
  prepareOperationTransaction,
  resolveInstallationOperations,
  verifyInstalledProject
} from "../src/index.js";
import { parseYaml } from "../src/parser.js";

const repositoryRoot = fileURLToPath(new URL("../../../", import.meta.url));
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

function digest(bytes) {
  return `sha256:${createHash("sha256").update(bytes).digest("hex")}`;
}

async function verificationFixture(configTransform = (value) => value) {
  const root = await mkdtemp(path.join(tmpdir(), "hekate-verification-"));
  await mkdir(path.join(root, ".workflow"));
  const config = Buffer.from(configTransform(await readFile(path.join(repositoryRoot, "templates/.workflow/config.yml"), "utf8")));
  const projectBytes = Buffer.from(project);
  const gitignore = await readFile(path.join(repositoryRoot, "templates/gitignore.snippet"));
  await writeFile(path.join(root, ".workflow/config.yml"), config);
  await writeFile(path.join(root, ".workflow/project.yml"), projectBytes);
  await writeFile(path.join(root, ".gitignore"), gitignore);
  assert.equal((await compileProject({ root })).ok, true);
  const lock = await readFile(path.join(root, ".workflow/status.lock.json"));
  const { manifest, diagnostics } = await loadInstallManifest();
  assert.deepEqual(diagnostics, []);
  manifest.adapters = [];
  manifest.components = [{ id: "core", default: true, adapters: [] }];
  manifest.assets = manifest.assets.filter((asset) => ["workflow-config", "workflow-project", "project-gitignore", "generated-lock", "install-state"].includes(asset.asset_id));
  const hashes = new Map([
    ["workflow-config", digest(config)],
    ["workflow-project", digest(projectBytes)],
    ["project-gitignore", digest(gitignore)],
    ["generated-lock", digest(lock)]
  ]);
  const sourceHashes = new Map();
  for (const asset of manifest.assets.filter((asset) => asset.source !== null)) sourceHashes.set(asset.asset_id, digest(await readFile(path.join(repositoryRoot, asset.source))));
  const state = {
    schema_version: 1,
    manifest_version: manifest.manifest_version,
    source_release: "0.3.0",
    selected_components: ["core"],
    selected_adapters: [],
    assets: manifest.assets.filter((asset) => asset.component === "core").map((asset) => ({
      asset_id: asset.asset_id,
      destination: asset.destination,
      ownership: asset.ownership,
      installed_source_hash: sourceHashes.get(asset.asset_id) ?? null,
      destination_hash: hashes.get(asset.asset_id) ?? null
    }))
  };
  await writeFile(path.join(root, ".workflow/install-state.json"), `${JSON.stringify(state, null, 2)}\n`);
  return { root, manifest, config, projectBytes };
}

test("full installation verification checks compiler, ownership state, migration preservation, and local ignores", async () => {
  const { root, manifest, config, projectBytes } = await verificationFixture();
  const imported = {
    schema_version: 1,
    source_layout: "legacy-0.x",
    selected_adapters: [],
    config: parseYaml(config, ".workflow/config.yml").value,
    project: parseYaml(projectBytes, ".workflow/project.yml").value,
    archived: {}
  };
  const report = { schema_version: 1, source_layout: "legacy-0.x", summary: { preserved: 0, transformed: 0, deprecated: 0, unresolved: 0 }, entries: [] };
  const verified = await verifyInstalledProject({ root, sourceRoot: repositoryRoot, manifest, expectedAdapters: [], targetRelease: "0.3.0", imported, report });
  assert.equal(verified.ok, true);
  assert.deepEqual(verified.diagnostics, []);

  await writeFile(path.join(root, ".gitignore"), "user-entry\n");
  const invalid = await verifyInstalledProject({ root, sourceRoot: repositoryRoot, manifest, expectedAdapters: [], targetRelease: "0.3.0", imported, report });
  assert.equal(invalid.ok, false);
  assert.ok(invalid.diagnostics.some((item) => item.code === "HKT473"));
  assert.ok(invalid.diagnostics.some((item) => item.code === "HKT476"));
});

test("full installation verification rejects incomplete state and changed migrated values", async () => {
  const { root, manifest, config, projectBytes } = await verificationFixture();
  const statePath = path.join(root, ".workflow/install-state.json");
  const state = JSON.parse(await readFile(statePath, "utf8"));
  state.assets.pop();
  await writeFile(statePath, `${JSON.stringify(state)}\n`);
  const imported = {
    schema_version: 1,
    source_layout: "legacy-0.x",
    selected_adapters: [],
    config: { ...parseYaml(config, ".workflow/config.yml").value, extensions: { "example.changed": true } },
    project: parseYaml(projectBytes, ".workflow/project.yml").value,
    archived: {}
  };
  const report = { schema_version: 1, source_layout: "legacy-0.x", summary: { preserved: 0, transformed: 0, deprecated: 0, unresolved: 0 }, entries: [] };
  const result = await verifyInstalledProject({ root, sourceRoot: repositoryRoot, manifest, expectedAdapters: [], imported, report });
  assert.equal(result.ok, false);
  assert.ok(result.diagnostics.some((item) => item.code === "HKT472"));
  assert.ok(result.diagnostics.some((item) => item.code === "HKT475"));
});

for (const gate of [
  { name: "disabled Hekate", replace: ["hekate:\n  enabled: true", "hekate:\n  enabled: false"], expected: "off" },
  { name: "disabled workflow", replace: ["workflow:\n  enabled: true", "workflow:\n  enabled: false"], expected: "workflow_disabled" }
]) {
  test(`full installation verification accepts ${gate.name}`, async () => {
    const { root, manifest } = await verificationFixture((config) => config.replace(...gate.replace));
    const verified = await verifyInstalledProject({ root, sourceRoot: repositoryRoot, manifest, expectedAdapters: [], targetRelease: "0.3.0" });
    assert.equal(verified.ok, true);
    assert.equal(verified.compiler.gateState, gate.expected);
    assert.deepEqual(verified.diagnostics, []);
  });
}

test("v1 desired state materializes into a verified transaction", async () => {
  const { root, manifest } = await verificationFixture();
  const planned = await planInstallation({ root, sourceRoot: repositoryRoot, adapters: [], manifest });
  assert.deepEqual(planned.diagnostics, []);
  const materialized = await materializeInstallationContent({ root, sourceRoot: repositoryRoot, manifest, plan: planned.plan, targetRelease: "0.3.0" });
  assert.deepEqual(materialized.diagnostics, []);
  assert.ok(materialized.resolvedContentByAssetId.has("generated-lock"));
  assert.ok(materialized.resolvedContentByAssetId.has("install-state"));
  const transactionId = "20260830T180000Z-0011223344556677";
  const resolved = await resolveInstallationOperations({
    sourceRoot: repositoryRoot,
    plan: planned.plan,
    manifest,
    transactionId,
    sourceRelease: "0.3.0",
    targetRelease: "0.3.0",
    resolvedContentByAssetId: materialized.resolvedContentByAssetId
  });
  assert.deepEqual(resolved.diagnostics, []);
  const prepared = await prepareOperationTransaction({ root, journal: resolved.journal, contentByPath: resolved.contentByPath, modeByPath: resolved.modeByPath });
  assert.deepEqual(prepared.diagnostics, []);
  const applied = await applyPreparedTransaction({
    root,
    transactionId,
    verify: () => verifyInstalledProject({ root, sourceRoot: repositoryRoot, manifest, expectedAdapters: [], targetRelease: "0.3.0" })
  });
  assert.equal(applied.applied, true);
  assert.deepEqual(applied.diagnostics, []);
});
