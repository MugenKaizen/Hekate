import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { access, copyFile, mkdir, mkdtemp, readFile, rm, stat, symlink, unlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import {
  acquireProjectUpdateLock,
  applyPreparedTransaction,
  cleanupTransactionBundle,
  createOperationJournal,
  importLegacyProject,
  prepareOperationTransaction,
  recoverProjectUpdateLock,
  rollbackPreparedTransaction,
  validatePreparedTransaction
} from "../src/index.js";

function digest(bytes) {
  return `sha256:${createHash("sha256").update(bytes).digest("hex")}`;
}

async function transactionFixture() {
  const root = await mkdtemp(path.join(tmpdir(), "hekate-transaction-"));
  await mkdir(path.join(root, ".workflow"));
  await mkdir(path.join(root, "managed"));
  await writeFile(path.join(root, "managed", "replace.txt"), "replace-before\n", { mode: 0o640 });
  await writeFile(path.join(root, "managed", "delete.txt"), "delete-before\n", { mode: 0o600 });
  await writeFile(path.join(root, "managed", "merge.txt"), "user=true\n", { mode: 0o644 });
  return root;
}

function operationJournal(transactionId) {
  const replaceBefore = Buffer.from("replace-before\n");
  const deleteBefore = Buffer.from("delete-before\n");
  const mergeBefore = Buffer.from("user=true\n");
  const createAfter = Buffer.from("created\n");
  const replaceAfter = Buffer.from("replace-after\n");
  const mergeAfter = Buffer.from("user=true\nhekate=true\n");
  const result = createOperationJournal({
    transactionId,
    manifestVersion: 1,
    sourceRelease: "0.2.0-beta.1",
    targetRelease: "0.3.0",
    operations: [
      { operation: "merge", path: "managed/merge.txt", before_hash: digest(mergeBefore), after_hash: digest(mergeAfter), backup_path: `.workflow/backups/${transactionId}/managed/merge.txt`, ownership: "shared-merge" },
      { operation: "create", path: "new/deep/create.txt", before_hash: null, after_hash: digest(createAfter), backup_path: null, ownership: "template-managed" },
      { operation: "delete", path: "managed/delete.txt", before_hash: digest(deleteBefore), after_hash: null, backup_path: `.workflow/backups/${transactionId}/managed/delete.txt`, ownership: "template-managed" },
      { operation: "replace", path: "managed/replace.txt", before_hash: digest(replaceBefore), after_hash: digest(replaceAfter), backup_path: `.workflow/backups/${transactionId}/managed/replace.txt`, ownership: "template-managed" }
    ]
  });
  assert.deepEqual(result.diagnostics, []);
  return {
    journal: result.journal,
    content: new Map([
      ["new/deep/create.txt", createAfter],
      ["managed/replace.txt", replaceAfter],
      ["managed/merge.txt", mergeAfter]
    ])
  };
}

test("transaction preparation snapshots and stages every inverse without live mutation", async () => {
  const root = await transactionFixture();
  const transactionId = "20260830T160000Z-0011223344556677";
  const { journal, content } = operationJournal(transactionId);
  const result = await prepareOperationTransaction({ root, journal, contentByPath: content });
  assert.deepEqual(result.diagnostics, []);
  assert.deepEqual(validatePreparedTransaction(result.prepared), []);

  await assert.rejects(access(path.join(root, "new", "deep", "create.txt")));
  assert.equal(await readFile(path.join(root, "managed", "replace.txt"), "utf8"), "replace-before\n");
  assert.equal(await readFile(path.join(root, "managed", "delete.txt"), "utf8"), "delete-before\n");
  assert.equal(await readFile(path.join(root, "managed", "merge.txt"), "utf8"), "user=true\n");

  assert.equal(await readFile(path.join(root, `.workflow/backups/${transactionId}/managed/replace.txt`), "utf8"), "replace-before\n");
  assert.equal(await readFile(path.join(root, `.workflow/backups/${transactionId}/managed/delete.txt`), "utf8"), "delete-before\n");
  assert.equal(await readFile(path.join(root, `.workflow/backups/${transactionId}/managed/merge.txt`), "utf8"), "user=true\n");
  assert.equal(await readFile(path.join(root, `.workflow/transactions/${transactionId}/stage/new/deep/create.txt`), "utf8"), "created\n");
  assert.equal(await readFile(path.join(root, `.workflow/transactions/${transactionId}/stage/managed/replace.txt`), "utf8"), "replace-after\n");
  assert.equal(await readFile(path.join(root, `.workflow/transactions/${transactionId}/stage/managed/merge.txt`), "utf8"), "user=true\nhekate=true\n");

  assert.equal(result.prepared.operations.find((operation) => operation.path === "managed/replace.txt").before_mode, 0o640);
  assert.deepEqual(JSON.parse(await readFile(path.join(root, result.journal_path), "utf8")), journal);
  const unsafeMetadata = structuredClone(result.prepared);
  unsafeMetadata.operations[0].staged_path = "../../outside";
  assert.ok(validatePreparedTransaction(unsafeMetadata).some((item) => item.code === "HKT447"));
  await assert.rejects(access(path.join(root, ".workflow/update.lock")));
  if (process.platform !== "win32") {
    assert.equal((await stat(path.join(root, `.workflow/backups/${transactionId}/managed/replace.txt`))).mode & 0o777, 0o600);
    assert.equal((await stat(path.join(root, `.workflow/transactions/${transactionId}`))).mode & 0o777, 0o700);
  }
});

test("transaction preparation rejects stale hashes and unsafe targets before artifacts", async () => {
  const root = await transactionFixture();
  const transactionId = "20260830T160001Z-0011223344556677";
  const { journal, content } = operationJournal(transactionId);
  journal.operations.find((operation) => operation.path === "managed/replace.txt").before_hash = digest(Buffer.from("stale\n"));
  const stale = await prepareOperationTransaction({ root, journal, contentByPath: content });
  assert.equal(stale.prepared, null);
  assert.ok(stale.diagnostics.some((item) => item.code === "HKT442"));
  await assert.rejects(access(path.join(root, ".workflow/transactions")));

  const unsafeRoot = await transactionFixture();
  const unsafeId = "20260830T160002Z-0011223344556677";
  const unsafe = operationJournal(unsafeId);
  await writeFile(path.join(unsafeRoot, "outside.txt"), "replace-before\n");
  await unlink(path.join(unsafeRoot, "managed", "replace.txt"));
  await symlink(path.join(unsafeRoot, "outside.txt"), path.join(unsafeRoot, "managed", "replace.txt"));
  const symlinked = await prepareOperationTransaction({ root: unsafeRoot, journal: unsafe.journal, contentByPath: unsafe.content });
  assert.equal(symlinked.prepared, null);
  assert.ok(symlinked.diagnostics.some((item) => item.code === "HKT441"));
  assert.equal(await readFile(path.join(unsafeRoot, "outside.txt"), "utf8"), "replace-before\n");
});

test("project update locks are exclusive and transaction IDs cannot overlay artifacts", async () => {
  const root = await transactionFixture();
  const transactionId = "20260830T160003Z-0011223344556677";
  const lock = await acquireProjectUpdateLock({ root, transactionId });
  await assert.rejects(acquireProjectUpdateLock({ root, transactionId }), (error) => error.code === "EEXIST");
  await lock.release();

  const { journal, content } = operationJournal(transactionId);
  const first = await prepareOperationTransaction({ root, journal, contentByPath: content });
  assert.deepEqual(first.diagnostics, []);
  const second = await prepareOperationTransaction({ root, journal, contentByPath: content });
  assert.equal(second.prepared, null);
  assert.ok(second.diagnostics.some((item) => item.code === "HKT445"));
});

test("one project update lock spans transaction preparation, apply, and verification", async () => {
  const root = await transactionFixture();
  const transactionId = "20260830T160019Z-0011223344556677";
  const competingId = "20260830T160020Z-0011223344556677";
  const { journal, content } = operationJournal(transactionId);
  const updateLock = await acquireProjectUpdateLock({ root, transactionId });
  try {
    const prepared = await prepareOperationTransaction({ root, journal, contentByPath: content, updateLock });
    assert.deepEqual(prepared.diagnostics, []);
    assert.equal(JSON.parse(await readFile(path.join(root, ".workflow/update.lock"), "utf8")).transaction_id, transactionId);
    await assert.rejects(acquireProjectUpdateLock({ root, transactionId: competingId }), (error) => error.code === "EEXIST");
    await assert.rejects(access(path.join(root, `.workflow/transactions/${competingId}`)));

    const applied = await applyPreparedTransaction({
      root,
      transactionId,
      updateLock,
      verify: async () => {
        assert.equal(JSON.parse(await readFile(path.join(root, ".workflow/update.lock"), "utf8")).transaction_id, transactionId);
        return true;
      }
    });
    assert.equal(applied.applied, true);
  } finally {
    await updateLock.release();
  }
  await assert.rejects(access(path.join(root, ".workflow/update.lock")));
});

test("transaction preparation validates staged hashes and backup ownership", async () => {
  const root = await transactionFixture();
  const transactionId = "20260830T160004Z-0011223344556677";
  const { journal, content } = operationJournal(transactionId);
  content.set("new/deep/create.txt", Buffer.from("wrong\n"));
  const badContent = await prepareOperationTransaction({ root, journal, contentByPath: content });
  assert.equal(badContent.prepared, null);
  assert.ok(badContent.diagnostics.some((item) => item.code === "HKT442"));

  const wrongBackup = operationJournal("20260830T160005Z-0011223344556677");
  wrongBackup.journal.operations.find((operation) => operation.path === "managed/delete.txt").backup_path = ".workflow/backups/another-run/managed/delete.txt";
  const rejected = await prepareOperationTransaction({ root, journal: wrongBackup.journal, contentByPath: wrongBackup.content });
  assert.equal(rejected.prepared, null);
  assert.ok(rejected.diagnostics.some((item) => item.code === "HKT443"));

  const devicePath = operationJournal("20260830T160007Z-0011223344556677");
  devicePath.journal.operations[0].path = "managed/CON";
  const unsafeJournal = await prepareOperationTransaction({ root, journal: devicePath.journal, contentByPath: devicePath.content });
  assert.equal(unsafeJournal.prepared, null);
  assert.ok(unsafeJournal.diagnostics.some((item) => item.code === "HKT430"));
});

test("transaction preparation writes importer artifacts privately without changing bytes", async () => {
  const root = await transactionFixture();
  for (const file of ["workflow.yml", "stack.yml", "architecture.yml", "conventions.yml", "presets.yml", "status.yml"]) {
    await copyFile(new URL(`../../../templates/.workflow/${file}`, import.meta.url), path.join(root, ".workflow", file));
  }
  await writeFile(path.join(root, ".workflow/orchestration.yml"), "schema_version: 2\nprofiles:\n  sk_live_private_value: {harness: claude}\n");
  const imported = await importLegacyProject({ root });
  assert.deepEqual(imported.diagnostics, []);
  assert.equal(imported.reportBytes.includes(Buffer.from("sk_live_private_value")), false);

  const transactionId = "20260830T160006Z-0011223344556677";
  const { journal, content } = operationJournal(transactionId);
  const result = await prepareOperationTransaction({
    root,
    journal,
    contentByPath: content,
    importBytes: imported.importBytes,
    reportBytes: imported.reportBytes
  });
  assert.deepEqual(result.diagnostics, []);
  const migrationRoot = path.join(root, `.workflow/migration/${transactionId}`);
  assert.deepEqual(await readFile(path.join(migrationRoot, "import.json")), imported.importBytes);
  assert.deepEqual(await readFile(path.join(migrationRoot, "report.json")), imported.reportBytes);
  if (process.platform !== "win32") {
    assert.equal((await stat(migrationRoot)).mode & 0o777, 0o700);
    assert.equal((await stat(path.join(migrationRoot, "import.json"))).mode & 0o777, 0o600);
    assert.equal((await stat(path.join(migrationRoot, "report.json"))).mode & 0o777, 0o600);
  }
});

async function preparedFixture(transactionId) {
  const root = await transactionFixture();
  const { journal, content } = operationJournal(transactionId);
  const prepared = await prepareOperationTransaction({ root, journal, contentByPath: content });
  assert.deepEqual(prepared.diagnostics, []);
  return { root, journal, prepared };
}

test("prepared transactions apply atomically and roll back fully offline", async () => {
  const transactionId = "20260830T160010Z-0011223344556677";
  const { root } = await preparedFixture(transactionId);
  const order = [];
  const applied = await applyPreparedTransaction({
    root,
    transactionId,
    verify: async () => true,
    operationApplied: async ({ operation }) => order.push(operation.path)
  });
  assert.equal(applied.applied, true);
  assert.deepEqual(applied.diagnostics, []);
  assert.equal(await readFile(path.join(root, "new/deep/create.txt"), "utf8"), "created\n");
  assert.equal(await readFile(path.join(root, "managed/replace.txt"), "utf8"), "replace-after\n");
  await assert.rejects(access(path.join(root, "managed/delete.txt")));
  assert.equal(await readFile(path.join(root, "managed/merge.txt"), "utf8"), "user=true\nhekate=true\n");
  assert.deepEqual(order, ["managed/delete.txt", "managed/merge.txt", "managed/replace.txt", "new/deep/create.txt"]);

  const dryRun = await rollbackPreparedTransaction({ root, transactionId, dryRun: true });
  assert.equal(dryRun.rolled_back, false);
  assert.deepEqual(dryRun.conflicts, []);
  assert.equal(dryRun.actions.length, 4);
  assert.equal(await readFile(path.join(root, "managed/replace.txt"), "utf8"), "replace-after\n");

  const rolledBack = await rollbackPreparedTransaction({ root, transactionId });
  assert.equal(rolledBack.rolled_back, true);
  assert.deepEqual(rolledBack.diagnostics, []);
  await assert.rejects(access(path.join(root, "new")));
  assert.equal(await readFile(path.join(root, "managed/replace.txt"), "utf8"), "replace-before\n");
  assert.equal(await readFile(path.join(root, "managed/delete.txt"), "utf8"), "delete-before\n");
  assert.equal(await readFile(path.join(root, "managed/merge.txt"), "utf8"), "user=true\n");
  assert.equal(JSON.parse(await readFile(path.join(root, `.workflow/transactions/${transactionId}/operation-journal.json`), "utf8")).status, "rolled_back");
});

for (let failAfter = 1; failAfter <= 4; failAfter += 1) {
  test(`partial apply after operation ${failAfter} remains recoverable from local transaction artifacts`, async () => {
    const transactionId = `20260830T160011Z-001122334455667${failAfter}`;
    const { root } = await preparedFixture(transactionId);
    let completed = 0;
    const applied = await applyPreparedTransaction({
      root,
      transactionId,
      verify: async () => true,
      operationApplied: async () => {
        completed += 1;
        if (completed === failAfter) throw new Error("injected apply failure");
      }
    });
    assert.equal(applied.applied, false);
    assert.ok(applied.diagnostics[0].message.includes("injected apply failure"));
    assert.equal(JSON.parse(await readFile(path.join(root, `.workflow/transactions/${transactionId}/operation-journal.json`), "utf8")).status, "failed");

    assert.equal((await rollbackPreparedTransaction({ root, transactionId })).rolled_back, true);
    await assert.rejects(access(path.join(root, "new")));
    assert.equal(await readFile(path.join(root, "managed/delete.txt"), "utf8"), "delete-before\n");
    assert.equal(await readFile(path.join(root, "managed/merge.txt"), "utf8"), "user=true\n");
    assert.equal(await readFile(path.join(root, "managed/replace.txt"), "utf8"), "replace-before\n");
  });
}

test("failed post-apply verification preserves structured diagnostics and remains recoverable", async () => {
  const transactionId = "20260830T160018Z-0011223344556677";
  const { root } = await preparedFixture(transactionId);
  const applied = await applyPreparedTransaction({
    root,
    transactionId,
    verify: async () => ({ ok: false, diagnostics: [{ code: "HKT476", severity: "error", file: ".gitignore", path: "", message: "missing ignore entry" }] })
  });
  assert.equal(applied.applied, false);
  assert.ok(applied.diagnostics.some((item) => item.code === "HKT476"));
  assert.equal(JSON.parse(await readFile(path.join(root, `.workflow/transactions/${transactionId}/operation-journal.json`), "utf8")).status, "failed");
  assert.equal((await rollbackPreparedTransaction({ root, transactionId })).rolled_back, true);
});

test("rollback detects user edits before making any inverse mutation", async () => {
  const transactionId = "20260830T160012Z-0011223344556677";
  const { root } = await preparedFixture(transactionId);
  const applied = await applyPreparedTransaction({ root, transactionId, verify: async () => true });
  assert.equal(applied.applied, true);
  await writeFile(path.join(root, "managed/replace.txt"), "user-edited-after-upgrade\n");

  const rollback = await rollbackPreparedTransaction({ root, transactionId });
  assert.equal(rollback.rolled_back, false);
  assert.equal(rollback.conflicts[0].path, "managed/replace.txt");
  assert.equal(await readFile(path.join(root, "new/deep/create.txt"), "utf8"), "created\n");
  await assert.rejects(access(path.join(root, "managed/delete.txt")));
  assert.equal(await readFile(path.join(root, "managed/replace.txt"), "utf8"), "user-edited-after-upgrade\n");
  assert.equal(JSON.parse(await readFile(path.join(root, `.workflow/transactions/${transactionId}/operation-journal.json`), "utf8")).status, "rollback_conflict");
});

test("rollback validates every backup before making the first inverse mutation", async () => {
  const transactionId = "20260830T160013Z-0011223344556677";
  const { root } = await preparedFixture(transactionId);
  assert.equal((await applyPreparedTransaction({ root, transactionId, verify: async () => true })).applied, true);
  await writeFile(path.join(root, `.workflow/backups/${transactionId}/managed/delete.txt`), "corrupt\n");

  const rollback = await rollbackPreparedTransaction({ root, transactionId });
  assert.equal(rollback.rolled_back, false);
  assert.ok(rollback.diagnostics[0].message.includes("rollback backup is invalid"));
  assert.equal(await readFile(path.join(root, "new/deep/create.txt"), "utf8"), "created\n");
  assert.equal(await readFile(path.join(root, "managed/replace.txt"), "utf8"), "replace-after\n");
  await assert.rejects(access(path.join(root, "managed/delete.txt")));
});

test("rollback resumes a durable rolling_back state", async () => {
  const transactionId = "20260830T160014Z-0011223344556677";
  const { root } = await preparedFixture(transactionId);
  assert.equal((await applyPreparedTransaction({ root, transactionId, verify: async () => true })).applied, true);
  const journalPath = path.join(root, `.workflow/transactions/${transactionId}/operation-journal.json`);
  const journal = JSON.parse(await readFile(journalPath, "utf8"));
  journal.status = "rolling_back";
  await writeFile(journalPath, `${JSON.stringify(journal)}\n`);

  const rollback = await rollbackPreparedTransaction({ root, transactionId });
  assert.equal(rollback.rolled_back, true);
  assert.equal(JSON.parse(await readFile(journalPath, "utf8")).status, "rolled_back");
});

for (let failAfter = 1; failAfter <= 4; failAfter += 1) {
  test(`partial rollback after inverse ${failAfter} converges on retry`, async () => {
    const transactionId = `20260830T160019Z-001122334455667${failAfter}`;
    const { root } = await preparedFixture(transactionId);
    assert.equal((await applyPreparedTransaction({ root, transactionId, verify: async () => true })).applied, true);
    let completed = 0;
    const interrupted = await rollbackPreparedTransaction({
      root,
      transactionId,
      operationRolledBack: async () => {
        completed += 1;
        if (completed === failAfter) throw new Error("injected rollback failure");
      }
    });
    assert.equal(interrupted.rolled_back, false);
    assert.ok(interrupted.diagnostics[0].message.includes("injected rollback failure"));
    assert.equal((await rollbackPreparedTransaction({ root, transactionId })).rolled_back, true);
    await assert.rejects(access(path.join(root, "new")));
    assert.equal(await readFile(path.join(root, "managed/delete.txt"), "utf8"), "delete-before\n");
    assert.equal(await readFile(path.join(root, "managed/merge.txt"), "utf8"), "user=true\n");
    assert.equal(await readFile(path.join(root, "managed/replace.txt"), "utf8"), "replace-before\n");
  });
}

test("apply orders generated lock before installation state", async () => {
  const root = await transactionFixture();
  const transactionId = "20260830T160015Z-0011223344556677";
  const contents = new Map([
    ["z-authored.txt", Buffer.from("authored\n")],
    [".workflow/status.lock.json", Buffer.from("{}\n")],
    [".workflow/install-state.json", Buffer.from("{}\n")]
  ]);
  const created = createOperationJournal({
    transactionId,
    manifestVersion: 1,
    targetRelease: "0.3.0",
    operations: [...contents].map(([operationPath, bytes]) => ({
      operation: "create",
      path: operationPath,
      before_hash: null,
      after_hash: digest(bytes),
      backup_path: null,
      ownership: operationPath === "z-authored.txt" ? "template-managed" : "generated"
    }))
  });
  assert.deepEqual(created.diagnostics, []);
  assert.deepEqual((await prepareOperationTransaction({ root, journal: created.journal, contentByPath: contents })).diagnostics, []);
  const order = [];
  const applied = await applyPreparedTransaction({ root, transactionId, verify: async () => true, operationApplied: async ({ operation }) => order.push(operation.path) });
  assert.equal(applied.applied, true);
  assert.deepEqual(order, ["z-authored.txt", ".workflow/status.lock.json", ".workflow/install-state.json"]);
});

test("stale update locks require matching explicit recovery", async () => {
  const root = await transactionFixture();
  const transactionId = "20260830T160016Z-0011223344556677";
  await writeFile(path.join(root, ".workflow/update.lock"), `${JSON.stringify({ schema_version: 1, transaction_id: transactionId, pid: 999999 })}\n`, { mode: 0o600 });
  await assert.rejects(recoverProjectUpdateLock({ root, transactionId: "20260830T160017Z-0011223344556677" }), /ownership does not match/);
  assert.equal(await recoverProjectUpdateLock({ root, transactionId }), true);
  await assert.rejects(access(path.join(root, ".workflow/update.lock")));
  assert.equal(await recoverProjectUpdateLock({ root, transactionId }), false);
});

test("explicit cleanup removes complete terminal transaction bundles", async () => {
  const transactionId = "20260830T160020Z-0011223344556677";
  const { root } = await preparedFixture(transactionId);
  assert.equal((await applyPreparedTransaction({ root, transactionId, verify: async () => true })).applied, true);
  const live = await readFile(path.join(root, "managed/replace.txt"));

  const planned = await cleanupTransactionBundle({ root, transactionId, dryRun: true });
  assert.equal(planned.status, "committed");
  assert.equal(planned.actions.length, 2);
  assert.equal(planned.cleaned, false);
  assert.equal((await cleanupTransactionBundle({ root, transactionId })).cleaned, true);
  await assert.rejects(access(path.join(root, `.workflow/transactions/${transactionId}`)));
  await assert.rejects(access(path.join(root, `.workflow/backups/${transactionId}`)));
  assert.deepEqual(await readFile(path.join(root, "managed/replace.txt")), live);
  assert.equal((await cleanupTransactionBundle({ root, transactionId })).status, "absent");
});

test("cleanup refuses nonterminal recovery bundles", async () => {
  const transactionId = "20260830T160021Z-0011223344556677";
  const { root } = await preparedFixture(transactionId);
  const result = await cleanupTransactionBundle({ root, transactionId });
  assert.equal(result.cleaned, false);
  assert.equal(result.diagnostics[0].code, "HKT454");
  await access(path.join(root, `.workflow/transactions/${transactionId}/operation-journal.json`));
  await access(path.join(root, `.workflow/backups/${transactionId}/managed/replace.txt`));
});

test("cleanup reports partial removal and converges on retry", async () => {
  const transactionId = "20260830T160022Z-0011223344556677";
  const { root } = await preparedFixture(transactionId);
  assert.equal((await applyPreparedTransaction({ root, transactionId, verify: async () => true })).applied, true);
  const interrupted = await cleanupTransactionBundle({
    root,
    transactionId,
    removeArtifact: async ({ path: relative, absolute }) => {
      if (relative.includes("/transactions/")) throw new Error("injected cleanup interruption");
      await rm(absolute, { recursive: true });
    }
  });
  assert.equal(interrupted.cleaned, false);
  assert.equal(interrupted.status, "committed");
  assert.equal(interrupted.actions.length, 2);
  assert.deepEqual(interrupted.removed, [`.workflow/backups/${transactionId}`]);
  assert.match(interrupted.diagnostics[0].message, /injected cleanup interruption/);
  await access(path.join(root, `.workflow/transactions/${transactionId}/operation-journal.json`));
  const retried = await cleanupTransactionBundle({ root, transactionId });
  assert.equal(retried.cleaned, true);
  assert.deepEqual(retried.removed, [`.workflow/transactions/${transactionId}`]);
});

test("cleanup requires durable provenance for unpublished orphan bundles", async () => {
  const transactionId = "20260830T160023Z-0011223344556677";
  const { root } = await preparedFixture(transactionId);
  const transactionRoot = path.join(root, `.workflow/transactions/${transactionId}`);
  const prepared = JSON.parse(await readFile(path.join(transactionRoot, "prepared-transaction.json"), "utf8"));
  await unlink(path.join(transactionRoot, "operation-journal.json"));
  const refused = await cleanupTransactionBundle({ root, transactionId });
  assert.equal(refused.cleaned, false);
  assert.match(refused.diagnostics[0].message, /missing without an unpublished preparation marker/);

  const marker = { journal_hash: prepared.journal_hash, schema_version: 1, transaction_id: transactionId };
  await writeFile(path.join(transactionRoot, "preparing.json"), `${JSON.stringify(marker)}\n`);
  const cleaned = await cleanupTransactionBundle({ root, transactionId });
  assert.equal(cleaned.cleaned, true);
  assert.equal(cleaned.status, "orphaned");
});
