import { createHash, randomBytes } from "node:crypto";
import { constants } from "node:fs";
import { chmod, lstat, mkdir, open, readFile, readdir, realpath, rename, rm, rmdir, unlink } from "node:fs/promises";
import path from "node:path";
import { canonicalBytes } from "./canonical-json.js";
import { validateOperationJournal } from "./journal.js";
import { validateMigrationReport } from "./legacy-importer.js";
import { validateSchema } from "./validator.js";

const projectUpdateLocks = new WeakMap();
const TRANSACTION_ID_PATTERN = /^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{16}$/;

function diagnostic(code, message, pathValue = "") {
  return { code, severity: "error", file: "prepared-transaction.json", path: pathValue, message };
}

function hash(bytes) {
  return `sha256:${createHash("sha256").update(bytes).digest("hex")}`;
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

async function inspectPath(root, relative) {
  if (!safeRelative(relative)) throw new Error("path is not a safe project-relative path");
  const parts = relative.split("/");
  let current = root;
  for (let index = 0; index < parts.length; index += 1) {
    current = path.join(current, parts[index]);
    let metadata;
    try { metadata = await lstat(current); }
    catch (error) {
      if (error.code === "ENOENT") return null;
      throw error;
    }
    if (metadata.isSymbolicLink()) throw new Error("path contains a symbolic link");
    if (index < parts.length - 1 && !metadata.isDirectory()) throw new Error("path parent is not a directory");
    if (index === parts.length - 1) {
      if (!metadata.isFile()) throw new Error("path is not a regular file");
      const handle = await open(current, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0));
      try {
        const openedMetadata = await handle.stat();
        if (!openedMetadata.isFile()) throw new Error("path changed while it was opened");
        return { bytes: await handle.readFile(), mode: openedMetadata.mode & 0o777 };
      } finally {
        await handle.close();
      }
    }
  }
  return null;
}

async function inspectArtifactTree(root, relative) {
  if (!safeRelative(relative)) throw new Error("artifact directory is not a safe project-relative path");
  let current = root;
  for (const part of relative.split("/")) {
    current = path.join(current, part);
    let metadata;
    try { metadata = await lstat(current); }
    catch (error) {
      if (error.code === "ENOENT") return null;
      throw error;
    }
    if (metadata.isSymbolicLink() || !metadata.isDirectory()) throw new Error(`unsafe artifact directory: ${relative}`);
  }
  let files = 0;
  let bytes = 0;
  const walk = async (directory) => {
    for (const entry of await readdir(directory, { withFileTypes: true })) {
      const destination = path.join(directory, entry.name);
      const metadata = await lstat(destination);
      if (metadata.isSymbolicLink()) throw new Error(`artifact tree contains a symbolic link: ${relative}`);
      if (metadata.isDirectory()) await walk(destination);
      else if (metadata.isFile()) { files += 1; bytes += metadata.size; }
      else throw new Error(`artifact tree contains a special file: ${relative}`);
    }
  };
  await walk(current);
  return { absolute: current, files, bytes };
}

async function ensureDirectory(root, relative) {
  if (!safeRelative(relative)) throw new Error("directory is not a safe project-relative path");
  let current = root;
  for (const part of relative.split("/")) {
    current = path.join(current, part);
    try {
      const metadata = await lstat(current);
      if (metadata.isSymbolicLink() || !metadata.isDirectory()) throw new Error(`unsafe transaction directory: ${relative}`);
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
      let created = false;
      try { await mkdir(current, { mode: 0o700 }); created = true; }
      catch (mkdirError) {
        if (mkdirError.code !== "EEXIST") throw mkdirError;
      }
      const metadata = await lstat(current);
      if (metadata.isSymbolicLink() || !metadata.isDirectory()) throw new Error(`unsafe transaction directory: ${relative}`);
      if (created) await syncDirectory(path.dirname(current));
    }
  }
  return current;
}

async function createExclusiveDirectory(root, relative) {
  const parent = path.posix.dirname(relative);
  if (parent !== ".") await ensureDirectory(root, parent);
  const destination = path.join(root, ...relative.split("/"));
  await mkdir(destination, { mode: 0o700 });
  await chmod(destination, 0o700);
  await syncDirectory(path.dirname(destination));
  return destination;
}

async function syncDirectory(directory) {
  let handle;
  try {
    handle = await open(directory, constants.O_RDONLY);
    await handle.sync();
  } catch (error) {
    if (!["EINVAL", "ENOTSUP", "EPERM", "EISDIR"].includes(error.code)) throw error;
  } finally {
    if (handle) await handle.close();
  }
}

async function writeExclusive(root, relative, bytes, mode = 0o600) {
  const parentRelative = path.posix.dirname(relative);
  if (parentRelative !== ".") await ensureDirectory(root, parentRelative);
  const destination = path.join(root, ...relative.split("/"));
  const handle = await open(destination, constants.O_CREAT | constants.O_EXCL | constants.O_WRONLY | (constants.O_NOFOLLOW ?? 0), mode);
  try {
    await handle.writeFile(bytes);
    await handle.sync();
  } finally {
    await handle.close();
  }
  await chmod(destination, mode);
  await syncDirectory(path.dirname(destination));
}

async function atomicPublish(root, relative, bytes) {
  const parentRelative = path.posix.dirname(relative);
  if (parentRelative !== ".") await ensureDirectory(root, parentRelative);
  const destination = path.join(root, ...relative.split("/"));
  const temporary = `${destination}.tmp-${process.pid}-${randomBytes(8).toString("hex")}`;
  let handle;
  let published = false;
  try {
    handle = await open(temporary, constants.O_CREAT | constants.O_EXCL | constants.O_WRONLY, 0o600);
    await handle.writeFile(bytes);
    await handle.sync();
    await handle.close();
    handle = null;
    try { await lstat(destination); throw new Error(`transaction artifact already exists: ${relative}`); }
    catch (error) { if (error.code !== "ENOENT") throw error; }
    await rename(temporary, destination);
    published = true;
    await chmod(destination, 0o600);
    await syncDirectory(path.dirname(destination));
  } finally {
    if (handle) await handle.close().catch(() => {});
    if (!published) await unlink(temporary).catch(() => {});
  }
}

async function atomicReplace(root, relative, bytes, mode = 0o600) {
  const existing = await inspectPath(root, relative);
  if (existing === null) throw new Error(`transaction artifact is missing: ${relative}`);
  const destination = path.join(root, ...relative.split("/"));
  const temporary = `${destination}.tmp-${process.pid}-${randomBytes(8).toString("hex")}`;
  let handle;
  let replaced = false;
  try {
    handle = await open(temporary, constants.O_CREAT | constants.O_EXCL | constants.O_WRONLY, mode);
    await handle.writeFile(bytes);
    await handle.sync();
    await handle.close();
    handle = null;
    await chmod(temporary, mode);
    await rename(temporary, destination);
    replaced = true;
    await syncDirectory(path.dirname(destination));
  } finally {
    if (handle) await handle.close().catch(() => {});
    if (!replaced) await unlink(temporary).catch(() => {});
  }
}

async function atomicInstall(root, relative, bytes, mode) {
  const destination = path.join(root, ...relative.split("/"));
  const temporary = `${destination}.hekate-${process.pid}-${randomBytes(8).toString("hex")}`;
  let handle;
  let installed = false;
  try {
    handle = await open(temporary, constants.O_CREAT | constants.O_EXCL | constants.O_WRONLY | (constants.O_NOFOLLOW ?? 0), mode);
    await handle.writeFile(bytes);
    await handle.sync();
    await handle.close();
    handle = null;
    await chmod(temporary, mode);
    await rename(temporary, destination);
    installed = true;
    await syncDirectory(path.dirname(destination));
  } finally {
    if (handle) await handle.close().catch(() => {});
    if (!installed) await unlink(temporary).catch(() => {});
  }
}

async function missingParentPaths(root, operationPaths) {
  const missing = new Set();
  for (const operationPath of operationPaths) {
    const parent = path.posix.dirname(operationPath);
    if (parent === ".") continue;
    let current = root;
    let parentMissing = false;
    let relative = "";
    for (const part of parent.split("/")) {
      relative = relative ? `${relative}/${part}` : part;
      current = path.join(current, part);
      if (parentMissing) { missing.add(relative); continue; }
      try {
        const metadata = await lstat(current);
        if (metadata.isSymbolicLink() || !metadata.isDirectory()) throw new Error(`unsafe operation parent: ${relative}`);
      } catch (error) {
        if (error.code !== "ENOENT") throw error;
        parentMissing = true;
        missing.add(relative);
      }
    }
  }
  return [...missing].sort((left, right) => left.split("/").length - right.split("/").length || left.localeCompare(right, "en"));
}

function journalWithStatus(journal, status) {
  return { ...journal, status };
}

function orderedOperations(journal, prepared) {
  return journal.operations.map((operation, index) => ({ operation, metadata: prepared.operations[index], index }))
    .sort((left, right) => {
      const rank = (item) => item.operation.path === ".workflow/install-state.json" ? 2 : item.operation.path === ".workflow/status.lock.json" ? 1 : 0;
      return rank(left) - rank(right) || left.index - right.index;
    });
}

function validateApplyState(applyState, transactionId, journal) {
  const diagnostics = validateSchema("apply-state", applyState, "apply-state.json");
  if (diagnostics.length || applyState.transaction_id !== transactionId) throw new Error("apply state is invalid");
  const allowed = new Set();
  for (const operation of journal.operations.filter((item) => item.operation !== "delete")) {
    const parts = operation.path.split("/").slice(0, -1);
    for (let index = 1; index <= parts.length; index += 1) allowed.add(parts.slice(0, index).join("/"));
  }
  if (applyState.created_parent_paths.some((item) => !safeRelative(item) || !allowed.has(item))) throw new Error("apply state contains an unrelated parent path");
  return applyState;
}

function plannedJournalHash(journal) {
  return hash(canonicalBytes(journalWithStatus(journal, "planned")));
}

async function loadPreparedTransaction(root, transactionId) {
  const transactionBase = `.workflow/transactions/${transactionId}`;
  const journalFile = await inspectPath(root, `${transactionBase}/operation-journal.json`);
  const preparedFile = await inspectPath(root, `${transactionBase}/prepared-transaction.json`);
  if (!journalFile || !preparedFile) throw new Error("prepared transaction artifacts are missing");
  let journal;
  let prepared;
  try {
    journal = JSON.parse(journalFile.bytes.toString("utf8"));
    prepared = JSON.parse(preparedFile.bytes.toString("utf8"));
  } catch { throw new Error("prepared transaction artifacts are malformed JSON"); }
  const diagnostics = [...validateOperationJournal(journal), ...validatePreparedTransaction(prepared)];
  if (diagnostics.length) throw new Error(`prepared transaction is invalid: ${diagnostics[0].message}`);
  if (journal.transaction_id !== transactionId || prepared.transaction_id !== transactionId) throw new Error("prepared transaction identity does not match its path");
  if (prepared.journal_hash !== plannedJournalHash(journal)) throw new Error("prepared transaction journal hash does not match");
  if (journal.operations.length !== prepared.operations.length) throw new Error("prepared operation count does not match the journal");
  for (let index = 0; index < journal.operations.length; index += 1) {
    const left = journal.operations[index];
    const right = prepared.operations[index];
    for (const key of ["operation", "path", "ownership", "before_hash", "after_hash", "backup_path"]) {
      if (left[key] !== right[key]) throw new Error("prepared operation does not match the journal");
    }
  }
  return { journal, prepared, transactionBase };
}

async function verifyPreparedBytes(root, journal, prepared) {
  const material = new Map();
  for (let index = 0; index < journal.operations.length; index += 1) {
    const operation = journal.operations[index];
    const metadata = prepared.operations[index];
    const current = await inspectPath(root, operation.path);
    if (operation.operation === "create") {
      if (current !== null) throw new Error(`create target already exists: ${operation.path}`);
    } else if (!current || hash(current.bytes) !== operation.before_hash) {
      throw new Error(`operation target no longer matches before_hash: ${operation.path}`);
    }
    let staged = null;
    if (metadata.staged_path !== null) {
      staged = await inspectPath(root, metadata.staged_path);
      if (!staged || hash(staged.bytes) !== operation.after_hash) throw new Error(`staged bytes no longer match after_hash: ${operation.path}`);
    }
    let backup = null;
    if (operation.backup_path !== null) {
      backup = await inspectPath(root, operation.backup_path);
      if (!backup || hash(backup.bytes) !== operation.before_hash) throw new Error(`backup no longer matches before_hash: ${operation.path}`);
    }
    material.set(operation.path, { staged, backup });
  }
  return material;
}

function parseArtifact(bytes, kind, file) {
  if (!Buffer.isBuffer(bytes)) return { value: null, diagnostics: [diagnostic("HKT446", `${file} must be supplied as bytes.`)] };
  let value;
  try { value = JSON.parse(bytes.toString("utf8")); }
  catch { return { value: null, diagnostics: [diagnostic("HKT446", `${file} is malformed JSON.`)] }; }
  return { value, diagnostics: validateSchema(kind, value, file) };
}

export function validatePreparedTransaction(value) {
  const diagnostics = validateSchema("prepared-transaction", value, "prepared-transaction.json");
  if (diagnostics.length) return diagnostics;
  const paths = new Set();
  for (const [index, operation] of value.operations.entries()) {
    const pointer = `/operations/${index}`;
    if (!safeRelative(operation.path)) diagnostics.push(diagnostic("HKT447", "Prepared operation path is unsafe.", `${pointer}/path`));
    if ([".workflow/backups", ".workflow/migration", ".workflow/transactions"].some((prefix) => operation.path === prefix || operation.path.startsWith(`${prefix}/`)) || operation.path === ".workflow/update.lock") {
      diagnostics.push(diagnostic("HKT447", "Prepared operation targets transaction-owned state.", `${pointer}/path`));
    }
    const key = operation.path.toLowerCase();
    if (paths.has(key)) diagnostics.push(diagnostic("HKT447", "Prepared operation paths collide.", `${pointer}/path`));
    paths.add(key);
    const expectedBackup = operation.operation === "create" ? null : `.workflow/backups/${value.transaction_id}/${operation.path}`;
    const expectedStage = operation.operation === "delete" ? null : `.workflow/transactions/${value.transaction_id}/stage/${operation.path}`;
    if (operation.backup_path !== expectedBackup) diagnostics.push(diagnostic("HKT447", "Prepared backup path is not derived from the transaction.", `${pointer}/backup_path`));
    if (operation.staged_path !== expectedStage) diagnostics.push(diagnostic("HKT447", "Prepared staged path is not derived from the transaction.", `${pointer}/staged_path`));
    const shapeIsValid = operation.operation === "create"
      ? operation.before_hash === null && operation.before_mode === null && operation.after_hash !== null && operation.target_mode !== null
      : operation.operation === "delete"
        ? operation.before_hash !== null && operation.before_mode !== null && operation.after_hash === null && operation.target_mode === null
        : operation.before_hash !== null && operation.before_mode !== null && operation.after_hash !== null && operation.target_mode !== null;
    if (!shapeIsValid) diagnostics.push(diagnostic("HKT447", "Prepared operation metadata is incomplete.", pointer));
  }
  const sortedPaths = [...value.operations].map((operation) => operation.path).sort((left, right) => left.localeCompare(right, "en"));
  if (value.operations.some((operation, index) => operation.path !== sortedPaths[index])) {
    diagnostics.push(diagnostic("HKT447", "Prepared operations are not in canonical path order.", "/operations"));
  }
  return diagnostics;
}

export async function acquireProjectUpdateLock({ root, transactionId }) {
  if (!TRANSACTION_ID_PATTERN.test(transactionId)) throw new TypeError("invalid transaction ID");
  const projectRoot = await realpath(root);
  const workflow = await lstat(path.join(projectRoot, ".workflow"));
  if (workflow.isSymbolicLink() || !workflow.isDirectory()) throw new Error(".workflow must be a real directory");
  const relative = ".workflow/update.lock";
  const destination = path.join(projectRoot, ".workflow", "update.lock");
  const token = canonicalBytes({ schema_version: 1, transaction_id: transactionId, pid: process.pid });
  let handle;
  let created = false;
  try {
    handle = await open(destination, constants.O_CREAT | constants.O_EXCL | constants.O_WRONLY | (constants.O_NOFOLLOW ?? 0), 0o600);
    created = true;
    await handle.writeFile(token);
    await handle.sync();
    await handle.close();
    handle = null;
    await syncDirectory(path.dirname(destination));
  } catch (error) {
    if (handle) await handle.close().catch(() => {});
    if (created) {
      await unlink(destination).catch(() => {});
      await syncDirectory(path.dirname(destination)).catch(() => {});
    }
    throw error;
  }
  const state = { projectRoot, transactionId, released: false };
  const lock = {
    path: relative,
    async release() {
      if (state.released) return;
      const current = await readFile(destination);
      if (!current.equals(token)) throw new Error("project update lock changed ownership");
      await unlink(destination);
      await syncDirectory(path.dirname(destination));
      state.released = true;
    }
  };
  projectUpdateLocks.set(lock, state);
  return lock;
}

function useProjectUpdateLock(updateLock, projectRoot, transactionId) {
  if (updateLock === null) return null;
  const state = projectUpdateLocks.get(updateLock);
  if (!state || state.released || state.projectRoot !== projectRoot || state.transactionId !== transactionId) {
    throw new Error("project update lock does not belong to this transaction");
  }
  return updateLock;
}

export async function recoverProjectUpdateLock({ root, transactionId }) {
  if (!TRANSACTION_ID_PATTERN.test(transactionId)) throw new TypeError("invalid transaction ID");
  const projectRoot = await realpath(root);
  const lockFile = await inspectPath(projectRoot, ".workflow/update.lock");
  if (!lockFile) return false;
  let lock;
  try { lock = JSON.parse(lockFile.bytes.toString("utf8")); }
  catch { throw new Error("project update lock is malformed; refusing recovery"); }
  const keys = lock && typeof lock === "object" && !Array.isArray(lock) ? Object.keys(lock).sort() : [];
  if (keys.join(",") !== "pid,schema_version,transaction_id" || lock.schema_version !== 1 || typeof lock.transaction_id !== "string" || !Number.isSafeInteger(lock.pid) || lock.pid < 1) {
    throw new Error("project update lock is malformed; refusing recovery");
  }
  if (lock.transaction_id !== transactionId) {
    throw new Error("project update lock ownership does not match; refusing recovery");
  }
  try {
    process.kill(lock.pid, 0);
    throw new Error("project update lock owner is still running; refusing recovery");
  } catch (error) {
    if (error.code !== "ESRCH") throw error;
  }
  await unlink(path.join(projectRoot, ".workflow", "update.lock"));
  await syncDirectory(path.join(projectRoot, ".workflow"));
  return true;
}

// The machine-readable migration report is evidence in its own right, so it is
// persisted for runs that never reach transaction preparation: an aborted
// import and a dry run both leave it under the migration run directory.
export async function writeMigrationReport({ root, runId, importBytes = null, reportBytes = null }) {
  if (importBytes === null && reportBytes === null) return { written: null, diagnostics: [] };
  const projectRoot = await realpath(root);
  const directory = `.workflow/migration/${runId}`;
  await createExclusiveDirectory(projectRoot, directory);
  if (importBytes !== null) await writeExclusive(projectRoot, `${directory}/import.json`, importBytes);
  if (reportBytes !== null) await writeExclusive(projectRoot, `${directory}/report.json`, reportBytes);
  return { written: directory, diagnostics: [] };
}

export async function prepareOperationTransaction({ root, journal, contentByPath = new Map(), modeByPath = new Map(), importBytes = null, reportBytes = null, recoveryFiles = new Map(), updateLock = null }) {
  journal = structuredClone(journal);
  contentByPath = contentByPath instanceof Map
    ? new Map([...contentByPath].map(([key, bytes]) => [key, Buffer.isBuffer(bytes) ? Buffer.from(bytes) : bytes]))
    : contentByPath;
  modeByPath = modeByPath instanceof Map ? new Map(modeByPath) : modeByPath;
  if (Buffer.isBuffer(importBytes)) importBytes = Buffer.from(importBytes);
  if (Buffer.isBuffer(reportBytes)) reportBytes = Buffer.from(reportBytes);
  recoveryFiles = recoveryFiles instanceof Map
    ? new Map([...recoveryFiles].map(([key, bytes]) => [key, Buffer.isBuffer(bytes) ? Buffer.from(bytes) : bytes]))
    : recoveryFiles;
  const diagnostics = validateOperationJournal(journal);
  if (diagnostics.length) return { prepared: null, diagnostics };
  if (journal.status !== "planned") return { prepared: null, diagnostics: [diagnostic("HKT440", "Only a planned journal can be prepared.", "/status")] };
  if (!(contentByPath instanceof Map) || !(modeByPath instanceof Map)) {
    return { prepared: null, diagnostics: [diagnostic("HKT440", "Transaction content and modes must be supplied as maps.")] };
  }
  if (!(recoveryFiles instanceof Map)) return { prepared: null, diagnostics: [diagnostic("HKT440", "Recovery runtime files must be supplied as a map.")] };
  for (const [relative, bytes] of recoveryFiles) {
    if (!/^(?:SHA256SUMS|src\/hekate-cli\.mjs|schemas\/[a-z-]+\.schema\.json)$/.test(relative) || !Buffer.isBuffer(bytes)) {
      diagnostics.push(diagnostic("HKT440", "Recovery runtime contains an invalid file.", relative));
    }
  }
  if ((importBytes === null) !== (reportBytes === null)) {
    return { prepared: null, diagnostics: [diagnostic("HKT446", "Private import and public report artifacts must be supplied together.")] };
  }
  if (importBytes !== null) {
    const imported = parseArtifact(importBytes, "legacy-import", "import.json");
    const report = parseArtifact(reportBytes, "migration-report", "report.json");
    diagnostics.push(...imported.diagnostics, ...report.diagnostics);
    if (report.value) diagnostics.push(...validateMigrationReport(report.value));
    if (diagnostics.length) return { prepared: null, diagnostics };
  }

  let projectRoot;
  try { projectRoot = await realpath(root); }
  catch (error) { return { prepared: null, diagnostics: [diagnostic("HKT440", `Cannot resolve transaction root: ${error.message}`)] }; }

  const expectedContent = new Set(journal.operations.filter((operation) => operation.operation !== "delete").map((operation) => operation.path));
  for (const key of contentByPath.keys()) {
    if (!expectedContent.has(key)) diagnostics.push(diagnostic("HKT442", "Transaction contains unplanned staged content.", key));
  }
  if (diagnostics.length) return { prepared: null, diagnostics };

  let lock;
  let ownsLock = false;
  try {
    lock = useProjectUpdateLock(updateLock, projectRoot, journal.transaction_id);
    if (!lock) {
      lock = await acquireProjectUpdateLock({ root: projectRoot, transactionId: journal.transaction_id });
      ownsLock = true;
    }
  } catch (error) {
    return { prepared: null, diagnostics: [diagnostic("HKT444", `Cannot acquire project update lock: ${error.message}`)] };
  }

  try {
    const inspected = new Map();
    for (const [index, operation] of journal.operations.entries()) {
      const pointer = `/operations/${index}`;
      const expectedBackup = operation.operation === "create" ? null : `.workflow/backups/${journal.transaction_id}/${operation.path}`;
      if (operation.backup_path !== expectedBackup) diagnostics.push(diagnostic("HKT443", "Backup path does not belong to this transaction.", `${pointer}/backup_path`));
      let current;
      try { current = await inspectPath(projectRoot, operation.path); }
      catch (error) { diagnostics.push(diagnostic("HKT441", `Cannot safely inspect operation target: ${error.message}`, `${pointer}/path`)); continue; }
      if (operation.operation === "create") {
        if (current !== null) diagnostics.push(diagnostic("HKT442", "Create target already exists.", `${pointer}/path`));
      } else if (current === null) {
        diagnostics.push(diagnostic("HKT442", "Operation target is missing.", `${pointer}/path`));
      } else if (hash(current.bytes) !== operation.before_hash) {
        diagnostics.push(diagnostic("HKT442", "Operation target no longer matches before_hash.", `${pointer}/before_hash`));
      }
      const stagedBytes = contentByPath.get(operation.path);
      if (operation.operation !== "delete") {
        if (!Buffer.isBuffer(stagedBytes)) diagnostics.push(diagnostic("HKT442", "Operation is missing staged bytes.", `${pointer}/after_hash`));
        else if (hash(stagedBytes) !== operation.after_hash) diagnostics.push(diagnostic("HKT442", "Staged bytes do not match after_hash.", `${pointer}/after_hash`));
      }
      const requestedMode = modeByPath.get(operation.path);
      if (requestedMode !== undefined && (!Number.isInteger(requestedMode) || requestedMode < 0 || requestedMode > 0o777)) {
        diagnostics.push(diagnostic("HKT442", "Target mode must be an integer between 0000 and 0777.", pointer));
      }
      inspected.set(operation.path, { current, stagedBytes, targetMode: requestedMode ?? current?.mode ?? 0o600 });
    }
    if (diagnostics.length) return { prepared: null, diagnostics };

    const transactionBase = `.workflow/transactions/${journal.transaction_id}`;
    const backupBase = `.workflow/backups/${journal.transaction_id}`;
    const journalBytes = canonicalBytes(journal);
    const preparingMarker = canonicalBytes({
      schema_version: 1,
      transaction_id: journal.transaction_id,
      journal_hash: hash(journalBytes)
    });
    await createExclusiveDirectory(projectRoot, transactionBase);
    await writeExclusive(projectRoot, `${transactionBase}/preparing.json`, preparingMarker);
    for (const [relative, bytes] of recoveryFiles) {
      await writeExclusive(projectRoot, `${transactionBase}/runtime/${relative}`, bytes, relative === "src/hekate-cli.mjs" ? 0o700 : 0o600);
    }
    if (journal.operations.some((operation) => operation.operation !== "create")) await createExclusiveDirectory(projectRoot, backupBase);
    if (importBytes !== null) await createExclusiveDirectory(projectRoot, `.workflow/migration/${journal.transaction_id}`);

    const preparedOperations = [];
    for (const operation of journal.operations) {
      const { current, stagedBytes, targetMode } = inspected.get(operation.path);
      const stagedPath = operation.operation === "delete" ? null : `${transactionBase}/stage/${operation.path}`;
      if (operation.backup_path !== null) await writeExclusive(projectRoot, operation.backup_path, current.bytes);
      if (stagedPath !== null) await writeExclusive(projectRoot, stagedPath, stagedBytes);
      preparedOperations.push({
        operation: operation.operation,
        path: operation.path,
        ownership: operation.ownership,
        before_hash: operation.before_hash,
        after_hash: operation.after_hash,
        backup_path: operation.backup_path,
        staged_path: stagedPath,
        before_mode: current?.mode ?? null,
        target_mode: operation.operation === "delete" ? null : targetMode
      });
    }
    if (importBytes !== null) {
      await writeExclusive(projectRoot, `.workflow/migration/${journal.transaction_id}/import.json`, importBytes);
      await writeExclusive(projectRoot, `.workflow/migration/${journal.transaction_id}/report.json`, reportBytes);
    }

    const prepared = {
      schema_version: 1,
      transaction_id: journal.transaction_id,
      journal_hash: hash(journalBytes),
      operations: preparedOperations
    };
    const preparedDiagnostics = validatePreparedTransaction(prepared);
    if (preparedDiagnostics.length) return { prepared: null, diagnostics: preparedDiagnostics };
    await atomicPublish(projectRoot, `${transactionBase}/prepared-transaction.json`, canonicalBytes(prepared));
    await atomicPublish(projectRoot, `${transactionBase}/operation-journal.json`, journalBytes);
    await atomicReplace(projectRoot, `${transactionBase}/preparing.json`, canonicalBytes({
      schema_version: 1,
      transaction_id: journal.transaction_id,
      journal_hash: hash(journalBytes),
      published: true
    }));
    await unlink(path.join(projectRoot, ...`${transactionBase}/preparing.json`.split("/"))).catch(() => {});
    await syncDirectory(path.join(projectRoot, ...transactionBase.split("/"))).catch(() => {});
    return {
      prepared,
      journal_path: `${transactionBase}/operation-journal.json`,
      metadata_path: `${transactionBase}/prepared-transaction.json`,
      recovery_runtime: recoveryFiles.size ? `${transactionBase}/runtime/src/hekate-cli.mjs` : null,
      diagnostics: []
    };
  } catch (error) {
    return { prepared: null, diagnostics: [diagnostic("HKT445", `Cannot prepare transaction: ${error.message}`)] };
  } finally {
    if (ownsLock) await lock.release();
  }
}

export async function applyPreparedTransaction({ root, transactionId, verify, operationApplied = null, updateLock = null }) {
  if (typeof verify !== "function") {
    return { applied: false, diagnostics: [diagnostic("HKT450", "Apply requires a target verification function.")] };
  }
  let projectRoot;
  try { projectRoot = await realpath(root); }
  catch (error) { return { applied: false, diagnostics: [diagnostic("HKT450", `Cannot resolve transaction root: ${error.message}`)] }; }
  let lock;
  let ownsLock = false;
  try {
    lock = useProjectUpdateLock(updateLock, projectRoot, transactionId);
    if (!lock) {
      lock = await acquireProjectUpdateLock({ root: projectRoot, transactionId });
      ownsLock = true;
    }
  }
  catch (error) { return { applied: false, diagnostics: [diagnostic("HKT444", `Cannot acquire project update lock: ${error.message}`)] }; }

  let loaded;
  let journalPath;
  try {
    loaded = await loadPreparedTransaction(projectRoot, transactionId);
    if (loaded.journal.status !== "planned") throw new Error(`transaction is not planned: ${loaded.journal.status}`);
    journalPath = `${loaded.transactionBase}/operation-journal.json`;
    const material = await verifyPreparedBytes(projectRoot, loaded.journal, loaded.prepared);
    const createdParents = await missingParentPaths(projectRoot, loaded.journal.operations
      .filter((operation) => operation.operation !== "delete")
      .map((operation) => operation.path));
    loaded.journal = journalWithStatus(loaded.journal, "applying");
    await atomicReplace(projectRoot, journalPath, canonicalBytes(loaded.journal));
    const applyStatePath = `${loaded.transactionBase}/apply-state.json`;
    // Publish cleanup intent before mkdir so a crash cannot orphan an empty
    // transaction-created directory that rollback does not know about.
    const applyState = { schema_version: 1, transaction_id: transactionId, created_parent_paths: createdParents };
    validateApplyState(applyState, transactionId, loaded.journal);
    await atomicPublish(projectRoot, applyStatePath, canonicalBytes(applyState));
    for (const relative of createdParents) {
      const destination = path.join(projectRoot, ...relative.split("/"));
      await mkdir(destination, { mode: 0o755 });
      await syncDirectory(path.dirname(destination));
    }

    const ordered = orderedOperations(loaded.journal, loaded.prepared);
    for (const { operation, metadata } of ordered) {
      const current = await inspectPath(projectRoot, operation.path);
      if (operation.operation === "create") {
        if (current !== null) throw new Error(`create target changed during apply: ${operation.path}`);
      } else if (!current || hash(current.bytes) !== operation.before_hash || current.mode !== metadata.before_mode) {
        throw new Error(`operation target changed during apply: ${operation.path}`);
      }
      if (operation.operation === "delete") {
        await unlink(path.join(projectRoot, ...operation.path.split("/")));
        await syncDirectory(path.dirname(path.join(projectRoot, ...operation.path.split("/"))));
      } else {
        await atomicInstall(projectRoot, operation.path, material.get(operation.path).staged.bytes, metadata.target_mode);
      }
      if (operationApplied) await operationApplied({ operation: structuredClone(operation), root: projectRoot });
    }

    const verification = await verify({ root: projectRoot, journal: structuredClone(loaded.journal), prepared: structuredClone(loaded.prepared) });
    if (verification !== true && verification?.ok !== true) {
      const error = new Error("post-apply verification failed");
      error.verificationDiagnostics = Array.isArray(verification?.diagnostics) ? verification.diagnostics : [];
      throw error;
    }
    loaded.journal = journalWithStatus(loaded.journal, "committed");
    await atomicReplace(projectRoot, journalPath, canonicalBytes(loaded.journal));
    return { applied: true, journal: loaded.journal, diagnostics: [] };
  } catch (error) {
    if (loaded && journalPath && loaded.journal.status === "applying") {
      loaded.journal = journalWithStatus(loaded.journal, "failed");
      await atomicReplace(projectRoot, journalPath, canonicalBytes(loaded.journal)).catch(() => {});
    }
    return { applied: false, diagnostics: [diagnostic("HKT451", `Cannot apply transaction: ${error.message}`), ...(error.verificationDiagnostics ?? [])] };
  } finally {
    if (ownsLock) await lock.release();
  }
}

export async function cleanupTransactionBundle({ root, transactionId, dryRun = false, removeArtifact = null }) {
  if (!TRANSACTION_ID_PATTERN.test(transactionId)) {
    return { cleaned: false, status: null, actions: [], removed: [], diagnostics: [diagnostic("HKT454", "Cannot clean transaction: invalid transaction ID")] };
  }
  let projectRoot;
  try { projectRoot = await realpath(root); }
  catch (error) { return { cleaned: false, status: null, actions: [], removed: [], diagnostics: [diagnostic("HKT454", `Cannot resolve cleanup root: ${error.message}`)] }; }
  let lock = null;
  if (dryRun) {
    try {
      if (await inspectPath(projectRoot, ".workflow/update.lock")) {
        return { cleaned: false, status: null, actions: [], removed: [], diagnostics: [diagnostic("HKT444", "Cannot inspect cleanup while the project update lock is held.")] };
      }
    } catch (error) {
      return { cleaned: false, status: null, actions: [], removed: [], diagnostics: [diagnostic("HKT444", `Cannot inspect project update lock: ${error.message}`)] };
    }
  } else {
    try { lock = await acquireProjectUpdateLock({ root: projectRoot, transactionId }); }
    catch (error) { return { cleaned: false, status: null, actions: [], removed: [], diagnostics: [diagnostic("HKT444", `Cannot acquire project update lock: ${error.message}`)] }; }
  }

  let status = null;
  let actions = [];
  const removed = [];
  let result;
  try {
    const relatives = [
      `.workflow/backups/${transactionId}`,
      `.workflow/migration/${transactionId}`,
      `.workflow/transactions/${transactionId}`
    ];
    const trees = new Map();
    for (const relative of relatives) {
      const tree = await inspectArtifactTree(projectRoot, relative);
      if (tree) trees.set(relative, tree);
    }
    if (!trees.size) {
      result = { cleaned: false, status: "absent", actions: [], removed: [], diagnostics: [] };
    } else {
      const transactionBase = relatives[2];
      status = "orphaned";
      if (trees.has(transactionBase)) {
        const journal = await inspectPath(projectRoot, `${transactionBase}/operation-journal.json`);
        if (journal) {
          const loaded = await loadPreparedTransaction(projectRoot, transactionId);
          status = loaded.journal.status;
          if (!["committed", "rolled_back"].includes(status)) throw new Error(`transaction cannot be cleaned from status: ${status}`);
        } else {
          const markerFile = await inspectPath(projectRoot, `${transactionBase}/preparing.json`);
          if (!markerFile) throw new Error("transaction journal is missing without an unpublished preparation marker");
          const marker = JSON.parse(markerFile.bytes.toString("utf8"));
          const keys = marker && typeof marker === "object" && !Array.isArray(marker) ? Object.keys(marker).sort() : [];
          if (keys.join(",") !== "journal_hash,schema_version,transaction_id"
            || marker.schema_version !== 1
            || marker.transaction_id !== transactionId
            || !/^sha256:[0-9a-f]{64}$/.test(marker.journal_hash)
            || !canonicalBytes(marker).equals(markerFile.bytes)) {
            throw new Error("unpublished preparation marker is malformed");
          }
          const preparedFile = await inspectPath(projectRoot, `${transactionBase}/prepared-transaction.json`);
          if (preparedFile) {
            const prepared = JSON.parse(preparedFile.bytes.toString("utf8"));
            const diagnostics = validatePreparedTransaction(prepared);
            if (diagnostics.length || prepared.transaction_id !== transactionId || prepared.journal_hash !== marker.journal_hash) {
              throw new Error("unpublished transaction metadata does not match its preparation marker");
            }
          }
        }
      } else {
        throw new Error("transaction tree is missing; orphan provenance cannot be verified");
      }
      actions = relatives.filter((relative) => trees.has(relative)).map((relative) => {
        const tree = trees.get(relative);
        return { operation: "remove", path: relative, files: tree.files, bytes: tree.bytes };
      });
      if (dryRun) {
        result = { cleaned: false, status, actions, removed, diagnostics: [] };
      } else {
        for (const action of actions) {
          const tree = await inspectArtifactTree(projectRoot, action.path);
          if (!tree) continue;
          if (removeArtifact) await removeArtifact({ path: action.path, absolute: tree.absolute });
          else await rm(tree.absolute, { recursive: true, force: false, maxRetries: 3, retryDelay: 100 });
          await syncDirectory(path.dirname(tree.absolute));
          removed.push(action.path);
        }
        result = { cleaned: true, status, actions, removed, diagnostics: [] };
      }
    }
  } catch (error) {
    result = { cleaned: false, status, actions, removed, diagnostics: [diagnostic("HKT454", `Cannot clean transaction: ${error.message}`)] };
  }
  if (lock) {
    try { await lock.release(); }
    catch (error) {
      result.cleaned = false;
      result.diagnostics.push(diagnostic("HKT444", `Cannot release project update lock: ${error.message}`));
    }
  }
  return result;
}

export async function rollbackPreparedTransaction({ root, transactionId, dryRun = false, operationRolledBack = null }) {
  let projectRoot;
  try { projectRoot = await realpath(root); }
  catch (error) { return { rolled_back: false, conflicts: [], actions: [], diagnostics: [diagnostic("HKT453", `Cannot resolve transaction root: ${error.message}`)] }; }
  let lock = null;
  if (dryRun) {
    try {
      if (await inspectPath(projectRoot, ".workflow/update.lock")) {
        return { rolled_back: false, conflicts: [], actions: [], diagnostics: [diagnostic("HKT444", "Cannot inspect rollback while the project update lock is held.")] };
      }
    } catch (error) {
      return { rolled_back: false, conflicts: [], actions: [], diagnostics: [diagnostic("HKT444", `Cannot inspect project update lock: ${error.message}`)] };
    }
  } else {
    try { lock = await acquireProjectUpdateLock({ root: projectRoot, transactionId }); }
    catch (error) { return { rolled_back: false, conflicts: [], actions: [], diagnostics: [diagnostic("HKT444", `Cannot acquire project update lock: ${error.message}`)] }; }
  }

  let loaded;
  let journalPath;
  try {
    loaded = await loadPreparedTransaction(projectRoot, transactionId);
    if (!["applying", "failed", "committed", "rolling_back", "rollback_conflict"].includes(loaded.journal.status)) {
      throw new Error(`transaction cannot be rolled back from status: ${loaded.journal.status}`);
    }
    journalPath = `${loaded.transactionBase}/operation-journal.json`;
    const applyStateFile = await inspectPath(projectRoot, `${loaded.transactionBase}/apply-state.json`);
    const applyState = applyStateFile
      ? validateApplyState(JSON.parse(applyStateFile.bytes.toString("utf8")), transactionId, loaded.journal)
      : { schema_version: 1, transaction_id: transactionId, created_parent_paths: [] };
    const actions = [];
    const conflicts = [];
    const material = new Map();
    for (let index = 0; index < loaded.journal.operations.length; index += 1) {
      const operation = loaded.journal.operations[index];
      const metadata = loaded.prepared.operations[index];
      let current;
      try { current = await inspectPath(projectRoot, operation.path); }
      catch (error) { conflicts.push({ path: operation.path, reason: error.message }); continue; }
      const currentHash = current ? hash(current.bytes) : null;
      if (operation.operation === "create") {
        if (currentHash === operation.after_hash && current.mode === metadata.target_mode) actions.push({ operation: "remove", path: operation.path, metadata });
        else if (current !== null) conflicts.push({ path: operation.path, reason: "current bytes do not match after_hash" });
      } else if (operation.operation === "delete") {
        if (current === null) actions.push({ operation: "restore", path: operation.path, metadata });
        else if (currentHash !== operation.before_hash || current.mode !== metadata.before_mode) conflicts.push({ path: operation.path, reason: "deleted path was recreated or changed" });
      } else if (currentHash === operation.after_hash && current.mode === metadata.target_mode) {
        actions.push({ operation: "restore", path: operation.path, metadata });
      } else if (currentHash !== operation.before_hash || current.mode !== metadata.before_mode) {
        conflicts.push({ path: operation.path, reason: "current bytes match neither before_hash nor after_hash" });
      }
    }
    for (const action of actions.filter((item) => item.operation === "restore")) {
      const backup = await inspectPath(projectRoot, action.metadata.backup_path);
      if (!backup || hash(backup.bytes) !== action.metadata.before_hash) throw new Error(`rollback backup is invalid: ${action.path}`);
      material.set(action.path, backup.bytes);
    }
    if (dryRun) return { rolled_back: false, conflicts, actions: actions.map(({ operation, path: actionPath }) => ({ operation, path: actionPath })), diagnostics: [] };
    if (conflicts.length) {
      loaded.journal = journalWithStatus(loaded.journal, "rollback_conflict");
      await atomicReplace(projectRoot, journalPath, canonicalBytes(loaded.journal));
      return { rolled_back: false, conflicts, actions: [], diagnostics: [] };
    }

    loaded.journal = journalWithStatus(loaded.journal, "rolling_back");
    await atomicReplace(projectRoot, journalPath, canonicalBytes(loaded.journal));
    const actionByPath = new Map(actions.map((action) => [action.path, action]));
    const rollbackActions = orderedOperations(loaded.journal, loaded.prepared).reverse()
      .map(({ operation }) => actionByPath.get(operation.path))
      .filter(Boolean);
    for (const action of rollbackActions) {
      const destination = path.join(projectRoot, ...action.path.split("/"));
      const current = await inspectPath(projectRoot, action.path);
      if (action.operation === "remove") {
        if (!current || hash(current.bytes) !== action.metadata.after_hash || current.mode !== action.metadata.target_mode) throw new Error(`rollback target changed: ${action.path}`);
        await unlink(destination);
        await syncDirectory(path.dirname(destination));
      } else {
        const journalOperation = loaded.journal.operations.find((operation) => operation.path === action.path);
        const expectedCurrent = journalOperation.operation === "delete" ? current === null : current && hash(current.bytes) === action.metadata.after_hash && current.mode === action.metadata.target_mode;
        if (!expectedCurrent) throw new Error(`rollback target changed: ${action.path}`);
        await atomicInstall(projectRoot, action.path, material.get(action.path), action.metadata.before_mode);
      }
      if (operationRolledBack) await operationRolledBack({ operation: action.operation, path: action.path, root: projectRoot });
    }
    for (const relative of [...applyState.created_parent_paths].sort((left, right) => right.split("/").length - left.split("/").length || right.localeCompare(left, "en"))) {
      await rmdir(path.join(projectRoot, ...relative.split("/"))).catch((error) => {
        if (!["ENOENT", "ENOTEMPTY", "EEXIST"].includes(error.code)) throw error;
      });
    }
    loaded.journal = journalWithStatus(loaded.journal, "rolled_back");
    await atomicReplace(projectRoot, journalPath, canonicalBytes(loaded.journal));
    return { rolled_back: true, conflicts: [], actions: actions.map(({ operation, path: actionPath }) => ({ operation, path: actionPath })), journal: loaded.journal, diagnostics: [] };
  } catch (error) {
    if (loaded && journalPath && loaded.journal.status === "rolling_back") {
      loaded.journal = journalWithStatus(loaded.journal, "rollback_conflict");
      await atomicReplace(projectRoot, journalPath, canonicalBytes(loaded.journal)).catch(() => {});
    }
    return { rolled_back: false, conflicts: [], actions: [], diagnostics: [diagnostic("HKT453", `Cannot roll back transaction: ${error.message}`)] };
  } finally {
    if (lock) await lock.release();
  }
}
