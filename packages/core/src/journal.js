import { randomBytes } from "node:crypto";
import path from "node:path";
import { canonicalBytes } from "./canonical-json.js";
import { validateSchema } from "./validator.js";

function diagnostic(code, message, pathValue = "") {
  return { code, severity: "error", file: "operation-journal.json", path: pathValue, message };
}

function safeRelative(value) {
  if (typeof value !== "string" || path.isAbsolute(value) || value.includes("\\")) return false;
  return value.split("/").every((part) => part
    && part !== "."
    && part !== ".."
    && !part.includes(":")
    && !/[<>"|?*]/.test(part)
    && !/[. ]$/.test(part)
    && !/[\u0000-\u001f]/.test(part)
    && !/^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)/i.test(part));
}

export function createTransactionId(date = new Date(), entropy = randomBytes(8)) {
  if (!(date instanceof Date) || Number.isNaN(date.valueOf()) || !Buffer.isBuffer(entropy) || entropy.length !== 8) {
    throw new TypeError("Transaction IDs require a valid date and 8 bytes of entropy");
  }
  return `${date.toISOString().replaceAll("-", "").replaceAll(":", "").replace(/\.\d{3}Z$/, "Z")}-${entropy.toString("hex")}`;
}

export function validateOperationJournal(journal) {
  const diagnostics = validateSchema("journal", journal, "operation-journal.json");
  if (diagnostics.length) return diagnostics;
  const paths = new Set();
  const backupPaths = new Set();
  for (const [index, operation] of journal.operations.entries()) {
    const pointer = `/operations/${index}`;
    if (!safeRelative(operation.path)) diagnostics.push(diagnostic("HKT430", "Journal operation path is unsafe.", `${pointer}/path`));
    if (operation.backup_path !== null && !safeRelative(operation.backup_path)) diagnostics.push(diagnostic("HKT430", "Journal backup path is unsafe.", `${pointer}/backup_path`));
    const key = operation.path.toLowerCase();
    if (paths.has(key)) diagnostics.push(diagnostic("HKT431", "Journal contains duplicate operation paths.", `${pointer}/path`));
    paths.add(key);
    if ([".workflow/backups", ".workflow/migration", ".workflow/transactions"].some((prefix) => operation.path === prefix || operation.path.startsWith(`${prefix}/`)) || operation.path === ".workflow/update.lock") {
      diagnostics.push(diagnostic("HKT430", "Journal operation targets transaction-owned state.", `${pointer}/path`));
    }
    if (operation.backup_path !== null) {
      const backupKey = operation.backup_path.toLowerCase();
      if (backupPaths.has(backupKey)) diagnostics.push(diagnostic("HKT431", "Journal contains duplicate backup paths.", `${pointer}/backup_path`));
      backupPaths.add(backupKey);
    }
    const shapeIsValid = operation.operation === "create"
      ? operation.before_hash === null && operation.after_hash !== null && operation.backup_path === null
      : operation.operation === "delete"
        ? operation.before_hash !== null && operation.after_hash === null && operation.backup_path !== null
        : operation.before_hash !== null && operation.after_hash !== null && operation.backup_path !== null;
    if (!shapeIsValid) diagnostics.push(diagnostic("HKT432", `Invalid hash or backup fields for ${operation.operation} operation.`, pointer));
    if (["replace", "delete"].includes(operation.operation) && ["local-seed", "project-seed", "shared-merge", "user-owned"].includes(operation.ownership)) {
      diagnostics.push(diagnostic("HKT433", "Journal operation would replace or delete protected ownership wholesale.", pointer));
    }
    if (operation.ownership === "user-owned") diagnostics.push(diagnostic("HKT433", "Journal operation would mutate user-owned content.", pointer));
  }
  for (const [index, operation] of journal.operations.entries()) {
    if (operation.backup_path !== null && paths.has(operation.backup_path.toLowerCase())) {
      diagnostics.push(diagnostic("HKT431", "Journal backup path collides with an operation path.", `/operations/${index}/backup_path`));
    }
  }
  return diagnostics;
}

export function createOperationJournal({ transactionId = createTransactionId(), manifestVersion, sourceRelease = null, targetRelease, operations }) {
  const journal = {
    schema_version: 1,
    transaction_id: transactionId,
    status: "planned",
    manifest_version: manifestVersion,
    source_release: sourceRelease,
    target_release: targetRelease,
    operations: [...operations].sort((left, right) => left.path.localeCompare(right.path, "en"))
  };
  const diagnostics = validateOperationJournal(journal);
  return { journal: diagnostics.length ? null : journal, bytes: diagnostics.length ? null : canonicalBytes(journal), diagnostics };
}
