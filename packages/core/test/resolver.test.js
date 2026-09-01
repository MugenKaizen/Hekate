import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import {
  applyPreparedTransaction,
  createInstalledState,
  planInstallation,
  prepareOperationTransaction,
  resolveInstallationOperations,
  rollbackPreparedTransaction
} from "../src/index.js";

function digest(bytes) {
  return `sha256:${createHash("sha256").update(bytes).digest("hex")}`;
}

function asset(assetId, destination, ownership, source, updateStrategy = "three-way") {
  return {
    asset_id: assetId,
    component: "core",
    source,
    destination,
    ownership,
    update_strategy: updateStrategy,
    remove_strategy: "preserve",
    mode: ownership === "generated" ? "0600" : "0644"
  };
}

test("install plans resolve only explicit ownership-safe operation bytes", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "hekate-resolver-project-"));
  const sourceRoot = await mkdtemp(path.join(tmpdir(), "hekate-resolver-source-"));
  await mkdir(path.join(root, ".workflow"));
  await mkdir(path.join(root, "managed"));
  await mkdir(path.join(sourceRoot, "sources"));
  const current = {
    candidate: Buffer.from("candidate-old\n"),
    merge: Buffer.from("user=true\n"),
    replace: Buffer.from("replace-old\n"),
    seed: Buffer.from("name: old\n"),
    local: Buffer.from("local=true\n")
  };
  for (const [name, bytes] of Object.entries(current)) await writeFile(path.join(root, "managed", `${name}.txt`), bytes);
  const templates = {
    candidate: Buffer.from("candidate-new\n"),
    create: Buffer.from("created\n"),
    replace: Buffer.from("replace-new\n")
  };
  for (const [name, bytes] of Object.entries(templates)) await writeFile(path.join(sourceRoot, "sources", `${name}.txt`), bytes);

  const manifest = {
    schema_version: 1,
    manifest_version: 1,
    adapters: [],
    components: [{ id: "core", default: true, adapters: [] }],
    assets: [
      asset("candidate", "managed/candidate.txt", "template-managed", "sources/candidate.txt"),
      asset("create", "managed/create.txt", "template-managed", "sources/create.txt"),
      asset("generated", ".workflow/status.lock.json", "generated", null, "regenerate"),
      asset("local", "managed/local.txt", "local-seed", "sources/create.txt", "create-only"),
      asset("merge", "managed/merge.txt", "shared-merge", "sources/create.txt", "structured-merge"),
      asset("replace", "managed/replace.txt", "template-managed", "sources/replace.txt"),
      asset("seed", "managed/seed.txt", "project-seed", "sources/create.txt", "typed-migration")
    ]
  };
  const planAsset = (assetId, disposition, currentHash, targetHash, provenance = "recorded") => {
    const item = manifest.assets.find((entry) => entry.asset_id === assetId);
    return { asset_id: assetId, destination: item.destination, ownership: item.ownership, provenance, disposition, current_hash: currentHash, target_hash: targetHash };
  };
  const plan = {
    schema_version: 1,
    manifest_version: 1,
    selected_adapters: [],
    selected_components: ["core"],
    assets: [
      planAsset("candidate", "replace-candidate", digest(current.candidate), digest(templates.candidate), "unrecorded"),
      planAsset("create", "create", null, digest(templates.create), "unrecorded"),
      planAsset("generated", "regenerate", null, null, "not-applicable"),
      planAsset("local", "preserve", digest(current.local), digest(templates.create), "unrecorded"),
      planAsset("merge", "merge", digest(current.merge), digest(templates.create)),
      planAsset("replace", "replace", digest(current.replace), digest(templates.replace)),
      planAsset("seed", "preserve", digest(current.seed), digest(templates.create))
    ],
    diagnostics: []
  };
  const transactionId = "20260830T170000Z-0011223344556677";
  const unresolved = await resolveInstallationOperations({ sourceRoot, plan, manifest, transactionId, targetRelease: "0.3.0" });
  assert.equal(unresolved.journal, null);
  assert.ok(unresolved.diagnostics.some((item) => item.code === "HKT463"));
  assert.ok(unresolved.diagnostics.some((item) => item.code === "HKT464"));

  const resolvedAssets = new Map([
    ["generated", Buffer.from("{\"schema_version\":1}\n")],
    ["merge", Buffer.from("user=true\nhekate=true\n")],
    ["seed", Buffer.from("name: migrated\n")]
  ]);
  const resolved = await resolveInstallationOperations({
    sourceRoot,
    plan,
    manifest,
    transactionId,
    sourceRelease: "0.2.0-beta.1",
    targetRelease: "0.3.0",
    approvedReplacementCandidates: ["candidate"],
    resolvedContentByAssetId: resolvedAssets
  });
  assert.deepEqual(resolved.diagnostics, []);
  assert.deepEqual(resolved.journal.operations.map((operation) => [operation.path, operation.operation]), [
    [".workflow/status.lock.json", "create"],
    ["managed/candidate.txt", "replace"],
    ["managed/create.txt", "create"],
    ["managed/merge.txt", "merge"],
    ["managed/replace.txt", "replace"],
    ["managed/seed.txt", "merge"]
  ]);
  assert.equal(resolved.contentByPath.has("managed/local.txt"), false);
  assert.equal(resolved.modeByPath.get(".workflow/status.lock.json"), 0o600);

  const installed = createInstalledState({ manifest, plan, targetRelease: "0.3.0", resolvedContentByAssetId: resolvedAssets });
  assert.deepEqual(installed.diagnostics, []);
  assert.equal(installed.state.source_release, "0.3.0");
  assert.equal(installed.state.assets.find((item) => item.asset_id === "local").destination_hash, digest(current.local));
  assert.equal(installed.state.assets.find((item) => item.asset_id === "seed").destination_hash, digest(Buffer.from("name: migrated\n")));
  assert.deepEqual(createInstalledState({ manifest, plan, targetRelease: "0.3.0", resolvedContentByAssetId: resolvedAssets }).bytes, installed.bytes);

  const prepared = await prepareOperationTransaction({ root, journal: resolved.journal, contentByPath: resolved.contentByPath, modeByPath: resolved.modeByPath });
  assert.deepEqual(prepared.diagnostics, []);
  assert.equal((await applyPreparedTransaction({ root, transactionId, verify: async () => true })).applied, true);
  assert.equal(await readFile(path.join(root, "managed/seed.txt"), "utf8"), "name: migrated\n");
  assert.equal(await readFile(path.join(root, "managed/local.txt"), "utf8"), "local=true\n");
  assert.equal((await rollbackPreparedTransaction({ root, transactionId })).rolled_back, true);
  assert.equal(await readFile(path.join(root, "managed/seed.txt"), "utf8"), "name: old\n");
});

test("operation resolution rejects attempts to mutate local seeds", async () => {
  const sourceRoot = await mkdtemp(path.join(tmpdir(), "hekate-resolver-source-"));
  const manifest = { schema_version: 1, manifest_version: 1, adapters: [], components: [{ id: "core", default: true, adapters: [] }], assets: [asset("local", "local.yml", "local-seed", "unused.yml", "create-only")] };
  const plan = { schema_version: 1, manifest_version: 1, selected_adapters: [], selected_components: ["core"], assets: [{ asset_id: "local", destination: "local.yml", ownership: "local-seed", provenance: "unrecorded", disposition: "preserve", current_hash: digest(Buffer.from("old")), target_hash: null }], diagnostics: [] };
  const result = await resolveInstallationOperations({
    sourceRoot,
    plan,
    manifest,
    transactionId: "20260830T170001Z-0011223344556677",
    targetRelease: "0.3.0",
    resolvedContentByAssetId: new Map([["local", Buffer.from("new")]])
  });
  assert.equal(result.journal, null);
  assert.ok(result.diagnostics.some((item) => item.code === "HKT465"));
});

test("recorded unmodified assets from deselected components delete and roll back", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "hekate-resolver-remove-"));
  const sourceRoot = await mkdtemp(path.join(tmpdir(), "hekate-resolver-source-"));
  await mkdir(path.join(root, ".workflow"));
  const bytes = Buffer.from("adapter instructions\n");
  await writeFile(path.join(root, "ADAPTER.md"), bytes);
  const manifest = {
    schema_version: 1,
    manifest_version: 1,
    adapters: ["adapter"],
    components: [{ id: "core", default: true, adapters: [] }, { id: "adapter", default: false, adapters: ["adapter"] }],
    assets: [{ ...asset("adapter-file", "ADAPTER.md", "template-managed", "unused.md"), component: "adapter", remove_strategy: "remove-if-unmodified" }]
  };
  const plan = {
    schema_version: 1,
    manifest_version: 1,
    selected_adapters: [],
    selected_components: ["core"],
    assets: [{ asset_id: "adapter-file", destination: "ADAPTER.md", ownership: "template-managed", provenance: "recorded", disposition: "remove", current_hash: digest(bytes), target_hash: null }],
    diagnostics: []
  };
  const transactionId = "20260830T170002Z-0011223344556677";
  const resolved = await resolveInstallationOperations({ sourceRoot, plan, manifest, transactionId, targetRelease: "0.3.0" });
  assert.deepEqual(resolved.diagnostics, []);
  assert.equal(resolved.journal.operations[0].operation, "delete");
  const prepared = await prepareOperationTransaction({ root, journal: resolved.journal, contentByPath: resolved.contentByPath, modeByPath: resolved.modeByPath });
  assert.deepEqual(prepared.diagnostics, []);
  assert.equal((await applyPreparedTransaction({ root, transactionId, verify: async () => true })).applied, true);
  await assert.rejects(readFile(path.join(root, "ADAPTER.md")), { code: "ENOENT" });
  assert.equal((await rollbackPreparedTransaction({ root, transactionId })).rolled_back, true);
  assert.deepEqual(await readFile(path.join(root, "ADAPTER.md")), bytes);
});

test("deselected shared assets require explicit contribution removal bytes", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "hekate-resolver-contribution-"));
  const sourceRoot = await mkdtemp(path.join(tmpdir(), "hekate-resolver-source-"));
  await mkdir(path.join(root, ".workflow"));
  const before = Buffer.from("user-entry\nhekate-entry\n");
  const after = Buffer.from("user-entry\n");
  await writeFile(path.join(root, ".gitignore"), before);
  const manifest = {
    schema_version: 1,
    manifest_version: 1,
    adapters: ["adapter"],
    components: [{ id: "core", default: true, adapters: [] }, { id: "adapter", default: false, adapters: ["adapter"] }],
    assets: [{ ...asset("shared", ".gitignore", "shared-merge", "unused.txt", "structured-merge"), component: "adapter", remove_strategy: "remove-contribution" }]
  };
  const plan = {
    schema_version: 1,
    manifest_version: 1,
    selected_adapters: [],
    selected_components: ["core"],
    assets: [{ asset_id: "shared", destination: ".gitignore", ownership: "shared-merge", provenance: "recorded", disposition: "merge", current_hash: digest(before), target_hash: null }],
    diagnostics: []
  };
  const transactionId = "20260830T170003Z-0011223344556677";
  const unresolved = await resolveInstallationOperations({ sourceRoot, plan, manifest, transactionId, targetRelease: "0.3.0" });
  assert.equal(unresolved.journal, null);
  assert.ok(unresolved.diagnostics.some((item) => item.code === "HKT467"));

  const resolved = await resolveInstallationOperations({ sourceRoot, plan, manifest, transactionId, targetRelease: "0.3.0", resolvedContentByAssetId: new Map([["shared", after]]) });
  assert.deepEqual(resolved.diagnostics, []);
  assert.equal(resolved.journal.operations[0].operation, "merge");
  const prepared = await prepareOperationTransaction({ root, journal: resolved.journal, contentByPath: resolved.contentByPath, modeByPath: resolved.modeByPath });
  assert.deepEqual(prepared.diagnostics, []);
  assert.equal((await applyPreparedTransaction({ root, transactionId, verify: async () => true })).applied, true);
  assert.deepEqual(await readFile(path.join(root, ".gitignore")), after);
  assert.equal((await rollbackPreparedTransaction({ root, transactionId })).rolled_back, true);
  assert.deepEqual(await readFile(path.join(root, ".gitignore")), before);
});

test("update strategies select dispositions independently of ownership alone", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "hekate-strategy-project-"));
  const sourceRoot = await mkdtemp(path.join(tmpdir(), "hekate-strategy-source-"));
  await mkdir(path.join(root, ".workflow"));
  await mkdir(path.join(root, "managed"));
  await mkdir(path.join(sourceRoot, "sources"));
  await writeFile(path.join(sourceRoot, "sources", "template.txt"), Buffer.from("template\n"));
  for (const name of ["three-way", "typed-migration", "create-only", "preserve", "structured-merge"]) {
    await writeFile(path.join(root, "managed", `${name}.txt`), Buffer.from(`local ${name}\n`));
  }
  const manifest = {
    schema_version: 1,
    manifest_version: 1,
    adapters: [],
    components: [{ id: "core", default: true, adapters: [] }],
    assets: [
      asset("three-way", "managed/three-way.txt", "template-managed", "sources/template.txt", "three-way"),
      asset("three-way-absent", "managed/absent.txt", "template-managed", "sources/template.txt", "three-way"),
      asset("typed-migration", "managed/typed-migration.txt", "project-seed", "sources/template.txt", "typed-migration"),
      asset("create-only", "managed/create-only.txt", "local-seed", "sources/template.txt", "create-only"),
      asset("create-only-absent", "managed/create-only-absent.txt", "local-seed", "sources/template.txt", "create-only"),
      asset("preserve", "managed/preserve.txt", "user-owned", "sources/template.txt", "preserve"),
      asset("structured-merge", "managed/structured-merge.txt", "shared-merge", "sources/template.txt", "structured-merge"),
      asset("regenerate", ".workflow/status.lock.json", "generated", null, "regenerate")
    ]
  };
  const planned = await planInstallation({ root, sourceRoot, adapters: [], manifest, installedState: null });
  assert.deepEqual(planned.diagnostics, []);
  const byId = Object.fromEntries(planned.plan.assets.map((item) => [item.asset_id, item.disposition]));
  assert.deepEqual(byId, {
    "create-only": "preserve",
    "create-only-absent": "create",
    preserve: "preserve",
    regenerate: "regenerate",
    "structured-merge": "merge",
    "three-way": "replace-candidate",
    "three-way-absent": "create",
    "typed-migration": "preserve"
  });
});

test("three-way and typed-migration writes keep replace and merge operations", async () => {
  const sourceRoot = await mkdtemp(path.join(tmpdir(), "hekate-strategy-write-source-"));
  await mkdir(path.join(sourceRoot, "sources"));
  const template = Buffer.from("template\n");
  await writeFile(path.join(sourceRoot, "sources", "template.txt"), template);
  const current = Buffer.from("local\n");
  const migrated = Buffer.from("migrated\n");
  const manifest = {
    schema_version: 1,
    manifest_version: 1,
    adapters: [],
    components: [{ id: "core", default: true, adapters: [] }],
    assets: [
      asset("managed", "managed/managed.txt", "template-managed", "sources/template.txt", "three-way"),
      asset("seed", "managed/seed.txt", "project-seed", "sources/template.txt", "typed-migration")
    ]
  };
  const plan = {
    schema_version: 1,
    manifest_version: 1,
    selected_adapters: [],
    selected_components: ["core"],
    assets: [
      { asset_id: "managed", destination: "managed/managed.txt", ownership: "template-managed", provenance: "recorded", disposition: "replace", current_hash: digest(current), target_hash: digest(template) },
      { asset_id: "seed", destination: "managed/seed.txt", ownership: "project-seed", provenance: "recorded", disposition: "preserve", current_hash: digest(current), target_hash: digest(template) }
    ],
    diagnostics: []
  };
  const resolved = await resolveInstallationOperations({
    sourceRoot,
    plan,
    manifest,
    transactionId: "20260830T170004Z-0011223344556677",
    targetRelease: "0.3.0",
    resolvedContentByAssetId: new Map([["seed", migrated]])
  });
  assert.deepEqual(resolved.diagnostics, []);
  assert.deepEqual(resolved.journal.operations.map((operation) => [operation.path, operation.operation]), [
    ["managed/managed.txt", "replace"],
    ["managed/seed.txt", "merge"]
  ]);
  assert.deepEqual(resolved.contentByPath.get("managed/managed.txt"), template);
  assert.deepEqual(resolved.contentByPath.get("managed/seed.txt"), migrated);
});

test("create-only and preserve strategies refuse to overwrite existing files", async () => {
  const sourceRoot = await mkdtemp(path.join(tmpdir(), "hekate-strategy-refuse-"));
  const current = Buffer.from("existing\n");
  const build = (assetId, ownership, strategy, disposition) => ({
    manifest: {
      schema_version: 1,
      manifest_version: 1,
      adapters: [],
      components: [{ id: "core", default: true, adapters: [] }],
      assets: [asset(assetId, `${assetId}.txt`, ownership, "unused.txt", strategy)]
    },
    plan: {
      schema_version: 1,
      manifest_version: 1,
      selected_adapters: [],
      selected_components: ["core"],
      assets: [{ asset_id: assetId, destination: `${assetId}.txt`, ownership, provenance: "recorded", disposition, current_hash: digest(current), target_hash: null }],
      diagnostics: []
    }
  });
  const createOnly = build("seed", "project-seed", "create-only", "preserve");
  const overwrite = await resolveInstallationOperations({
    sourceRoot,
    plan: createOnly.plan,
    manifest: createOnly.manifest,
    transactionId: "20260830T170005Z-0011223344556677",
    targetRelease: "0.3.0",
    resolvedContentByAssetId: new Map([["seed", Buffer.from("new\n")]])
  });
  assert.equal(overwrite.journal, null);
  assert.ok(overwrite.diagnostics.some((item) => item.code === "HKT468" && item.message.includes("Create-only")));

  const preserved = build("kept", "template-managed", "preserve", "preserve");
  const written = await resolveInstallationOperations({
    sourceRoot,
    plan: preserved.plan,
    manifest: preserved.manifest,
    transactionId: "20260830T170006Z-0011223344556677",
    targetRelease: "0.3.0",
    resolvedContentByAssetId: new Map([["kept", Buffer.from("new\n")]])
  });
  assert.equal(written.journal, null);
  assert.ok(written.diagnostics.some((item) => item.code === "HKT468" && item.message.includes("preserve update strategy")));

  const migrating = build("migrated", "project-seed", "typed-migration", "replace");
  const replaced = await resolveInstallationOperations({
    sourceRoot,
    plan: migrating.plan,
    manifest: migrating.manifest,
    transactionId: "20260830T170007Z-0011223344556677",
    targetRelease: "0.3.0",
    resolvedContentByAssetId: new Map([["migrated", Buffer.from("new\n")]])
  });
  assert.equal(replaced.journal, null);
  assert.ok(replaced.diagnostics.some((item) => item.code === "HKT468" && item.message.includes("three-way")));
});

test("deselected archive assets move into the project archive and roll back", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "hekate-resolver-archive-"));
  const sourceRoot = await mkdtemp(path.join(tmpdir(), "hekate-resolver-archive-source-"));
  await mkdir(path.join(root, ".workflow"));
  const bytes = Buffer.from("legacy: true\n");
  await writeFile(path.join(root, ".workflow/legacy.yml"), bytes);
  const manifest = {
    schema_version: 1,
    manifest_version: 1,
    adapters: ["adapter"],
    components: [{ id: "core", default: true, adapters: [] }, { id: "adapter", default: false, adapters: ["adapter"] }],
    assets: [{ ...asset("legacy", ".workflow/legacy.yml", "template-managed", "unused.yml"), component: "adapter", remove_strategy: "archive" }]
  };
  const installedState = {
    schema_version: 1,
    manifest_version: 1,
    source_release: "0.2.0",
    selected_components: ["core", "adapter"],
    selected_adapters: ["adapter"],
    assets: [{ asset_id: "legacy", destination: ".workflow/legacy.yml", ownership: "template-managed", installed_source_hash: digest(bytes), destination_hash: digest(bytes) }]
  };
  const planned = await planInstallation({ root, sourceRoot, adapters: [], manifest, installedState });
  assert.deepEqual(planned.diagnostics, []);
  assert.equal(planned.plan.assets[0].disposition, "remove");

  const transactionId = "20260830T170008Z-0011223344556677";
  const unresolved = await resolveInstallationOperations({ sourceRoot, plan: planned.plan, manifest, transactionId, targetRelease: "0.3.0" });
  assert.equal(unresolved.journal, null);
  assert.ok(unresolved.diagnostics.some((item) => item.code === "HKT468" && item.message.includes("current bytes")));

  const mismatched = await resolveInstallationOperations({ sourceRoot, plan: planned.plan, manifest, transactionId, targetRelease: "0.3.0", resolvedContentByAssetId: new Map([["legacy", Buffer.from("other\n")]]) });
  assert.equal(mismatched.journal, null);
  assert.ok(mismatched.diagnostics.some((item) => item.code === "HKT468" && item.message.includes("do not match")));

  const resolved = await resolveInstallationOperations({ sourceRoot, plan: planned.plan, manifest, transactionId, targetRelease: "0.3.0", resolvedContentByAssetId: new Map([["legacy", bytes]]) });
  assert.deepEqual(resolved.diagnostics, []);
  assert.deepEqual(resolved.journal.operations.map((operation) => [operation.path, operation.operation]), [
    [".workflow/archived/legacy.yml", "create"],
    [".workflow/legacy.yml", "delete"]
  ]);
  const prepared = await prepareOperationTransaction({ root, journal: resolved.journal, contentByPath: resolved.contentByPath, modeByPath: resolved.modeByPath });
  assert.deepEqual(prepared.diagnostics, []);
  assert.equal((await applyPreparedTransaction({ root, transactionId, verify: async () => true })).applied, true);
  assert.deepEqual(await readFile(path.join(root, ".workflow/archived/legacy.yml")), bytes);
  await assert.rejects(readFile(path.join(root, ".workflow/legacy.yml")), { code: "ENOENT" });
  assert.equal((await rollbackPreparedTransaction({ root, transactionId })).rolled_back, true);
  assert.deepEqual(await readFile(path.join(root, ".workflow/legacy.yml")), bytes);
});

test("archive removal refuses ownership classes that cannot be deleted wholesale", async () => {
  const sourceRoot = await mkdtemp(path.join(tmpdir(), "hekate-resolver-archive-refuse-"));
  const bytes = Buffer.from("legacy: true\n");
  const manifest = {
    schema_version: 1,
    manifest_version: 1,
    adapters: ["adapter"],
    components: [{ id: "core", default: true, adapters: [] }, { id: "adapter", default: false, adapters: ["adapter"] }],
    assets: [{ ...asset("legacy", ".workflow/legacy.yml", "project-seed", "unused.yml", "typed-migration"), component: "adapter", remove_strategy: "archive" }]
  };
  const plan = {
    schema_version: 1,
    manifest_version: 1,
    selected_adapters: [],
    selected_components: ["core"],
    assets: [{ asset_id: "legacy", destination: ".workflow/legacy.yml", ownership: "project-seed", provenance: "recorded", disposition: "remove", current_hash: digest(bytes), target_hash: null }],
    diagnostics: []
  };
  const result = await resolveInstallationOperations({
    sourceRoot,
    plan,
    manifest,
    transactionId: "20260830T170009Z-0011223344556677",
    targetRelease: "0.3.0",
    resolvedContentByAssetId: new Map([["legacy", bytes]])
  });
  assert.equal(result.journal, null);
  assert.ok(result.diagnostics.some((item) => item.code === "HKT468" && item.message.includes("permits deletion")));
});
