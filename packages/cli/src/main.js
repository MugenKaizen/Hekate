import { createInterface } from "node:readline/promises";
import { createHash } from "node:crypto";
import { existsSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { fileURLToPath, pathToFileURL } from "node:url";
import path from "node:path";
import {
  acquireProjectUpdateLock,
  applyPreparedTransaction,
  checkProject,
  cleanupTransactionBundle,
  compileProject,
  createTransactionId,
  importLegacyProject,
  loadInstalledState,
  loadInstallManifest,
  materializeInstallationContent,
  planInstallation,
  prepareOperationTransaction,
  recoverProjectUpdateLock,
  resolveInstallationOperations,
  rollbackPreparedTransaction,
  verifyInstalledProject,
  writeMigrationReport
} from "@hekate/core";

const packagedPayload = new URL("../payload/", import.meta.url);
const defaultSourceRoot = existsSync(new URL("distribution/install-manifest.json", packagedPayload))
  ? fileURLToPath(packagedPayload)
  : fileURLToPath(new URL("../../../", import.meta.url));
const schemaNames = ["apply-state", "config", "install-state", "journal", "legacy-import", "lock", "manifest", "migration-report", "plan", "prepared-transaction", "project"];

async function loadRecoveryRuntime() {
  const runtimeRoot = process.env.HEKATE_RECOVERY_RUNTIME_ROOT;
  if (!runtimeRoot) return new Map();
  const files = ["src/hekate-cli.mjs", ...schemaNames.map((name) => `schemas/${name}.schema.json`)];
  const payload = new Map(await Promise.all(files.map(async (relative) => [relative, await readFile(path.join(runtimeRoot, ...relative.split("/")))])));
  const checksumBytes = await readFile(path.join(runtimeRoot, "SHA256SUMS"));
  const checksums = new Map(checksumBytes.toString("utf8").trimEnd().split("\n").map((line) => {
    const match = line.match(/^([0-9a-f]{64})  (src\/hekate-cli\.mjs|schemas\/[a-z-]+\.schema\.json)$/);
    if (!match) throw new Error("SHA256SUMS is malformed");
    return [match[2], match[1]];
  }));
  if (checksums.size !== files.length || files.some((relative) => !checksums.has(relative))) throw new Error("SHA256SUMS inventory is incomplete");
  for (const [relative, bytes] of payload) {
    if (createHash("sha256").update(bytes).digest("hex") !== checksums.get(relative)) throw new Error(`runtime checksum mismatch: ${relative}`);
  }
  payload.set("SHA256SUMS", checksumBytes);
  return payload;
}

function usage() {
  return "usage: hekate check [--json] | hekate compile [--check] [--json] | hekate upgrade --to=<release> --force [--yes] [--replace-unowned] [--dry-run] [--adapters=<list>] [--components=<list>] [--target=<path>] [--source=<path>] [--json] | hekate rollback --transaction=<id> [--yes] [--dry-run] [--target=<path>] [--json] | hekate cleanup --transaction=<id> [--yes] [--dry-run] [--target=<path>] [--json] | hekate agent [--mode=tui|print|json|rpc] [--prompt=<text>] [--no-session] [--subagents] [--no-context-files] [--trust-project|--no-trust-project]";
}

function diagnostic(code, message, file = "") {
  return { code, severity: "error", file, path: "", message };
}

function outputCompiler(result, command, json) {
  const document = { command, ok: result.ok, gate_state: result.gateState, source_state: result.sourceState, lock_status: result.lockStatus, wrote: result.wrote, diagnostics: result.diagnostics };
  if (json) process.stdout.write(`${JSON.stringify(document)}\n`);
  else {
    process.stdout.write(`${result.gateState}\n`);
    for (const item of result.diagnostics) process.stdout.write(`${item.code} ${item.file}${item.path ? ` ${item.path}` : ""}: ${item.message}\n`);
    if (command === "compile") process.stdout.write(result.wrote ? "wrote status.lock.json\n" : "status.lock.json unchanged\n");
  }
}

function parseUpgrade(args) {
  const options = { to: null, force: false, yes: false, dryRun: false, json: false, replaceUnowned: false, adapters: null, components: null, target: null, source: null };
  for (let index = 0; index < args.length; index += 1) {
    const argument = args[index];
    if (["--force", "--yes", "--dry-run", "--json", "--replace-unowned"].includes(argument)) {
      const key = { "--force": "force", "--yes": "yes", "--dry-run": "dryRun", "--json": "json", "--replace-unowned": "replaceUnowned" }[argument];
      if (options[key]) return null;
      options[key] = true;
      continue;
    }
    const match = argument.match(/^--(to|adapters|components|target|source)=(.*)$/);
    if (match && options[match[1]] === null && match[2]) { options[match[1]] = match[2]; continue; }
    if (["--to", "--adapters", "--components", "--target", "--source"].includes(argument) && options[argument.slice(2)] === null && args[index + 1] && !args[index + 1].startsWith("--")) {
      options[argument.slice(2)] = args[index + 1];
      index += 1;
      continue;
    }
    return null;
  }
  return options;
}

function printUpgrade(result, json) {
  if (json) {
    process.stdout.write(`${JSON.stringify(result)}\n`);
    return;
  }
  if (result.summary) {
    process.stdout.write(`transaction: ${result.transaction_id}\n`);
    if (result.recovery_runtime) process.stdout.write(`offline recovery runtime: ${result.recovery_runtime}\n`);
    if (result.plan) process.stdout.write(result.plan);
    for (const [operation, count] of Object.entries(result.summary)) process.stdout.write(`${operation}: ${count}\n`);
  }
  for (const item of result.diagnostics) process.stdout.write(`${item.code} ${item.file}${item.path ? ` ${item.path}` : ""}: ${item.message}\n`);
  if (result.ok) process.stdout.write(result.dry_run ? "dry run; no files changed\n" : "upgrade committed\n");
}

export function formatUpgradePlan({ summary, preservation, unresolvedCritical = preservation?.unresolved ?? 0, unownedPaths, migratedPaths, transactionId }) {
  const lines = [];
  if (preservation) {
    lines.push(`preserved: ${preservation.preserved} settings`);
    lines.push(`transformed: ${preservation.transformed} settings`);
    lines.push(`deprecated and archived: ${preservation.deprecated} settings`);
    lines.push(`unresolved critical: ${unresolvedCritical} settings`);
    if (preservation.unresolved > unresolvedCritical) lines.push(`unresolved non-critical: ${preservation.unresolved - unresolvedCritical} settings`);
  }
  lines.push(`template files to replace: ${summary.replace + summary.merge}`);
  lines.push(`project files to migrate: ${migratedPaths.length}`);
  lines.push(`files to create: ${summary.create}`);
  lines.push(`files to delete: ${summary.delete}`);
  lines.push(`backup: .workflow/backups/${transactionId}/`);
  for (const relativePath of migratedPaths) lines.push(`migrate: ${relativePath}`);
  // Files Hekate did not record installing are the only ones a forced upgrade
  // can overwrite without provenance, so each is named before confirmation.
  for (const relativePath of unownedPaths) lines.push(`replace unowned: ${relativePath}`);
  return `${lines.join("\n")}\n`;
}

async function confirmUpgrade(summary, plan) {
  if (!process.stdin.isTTY || !process.stdout.isTTY) return false;
  const total = Object.values(summary).reduce((sum, count) => sum + count, 0);
  process.stdout.write(plan);
  const terminal = createInterface({ input: process.stdin, output: process.stdout });
  try { return /^y(?:es)?$/i.test((await terminal.question(`Apply ${total} transactional file operation(s)? [y/N] `)).trim()); }
  finally { terminal.close(); }
}

async function upgrade(args, invocationRoot) {
  const options = parseUpgrade(args);
  if (!options || !options.to || !options.force) return { usage: true, exitCode: 2 };
  const root = path.resolve(options.target ?? invocationRoot);
  const sourceRoot = path.resolve(options.source ?? defaultSourceRoot);
  const loadedManifest = await loadInstallManifest(pathToFileURL(path.join(sourceRoot, "distribution/install-manifest.json")));
  if (!loadedManifest.manifest) return { result: { command: "upgrade", ok: false, dry_run: options.dryRun, transaction_id: null, summary: null, diagnostics: loadedManifest.diagnostics }, json: options.json, exitCode: 1 };
  const manifest = loadedManifest.manifest;
  const transactionId = createTransactionId();
  let updateLock = null;
  if (!options.dryRun) {
    try { updateLock = await acquireProjectUpdateLock({ root, transactionId }); }
    catch (error) {
      return { result: { command: "upgrade", ok: false, dry_run: false, transaction_id: transactionId, summary: null, diagnostics: [diagnostic("HKT444", `Cannot acquire project update lock: ${error.message}`)] }, json: options.json, exitCode: 1 };
    }
  }
  try {
  const loadedState = await loadInstalledState(root, manifest);
  if (loadedState.diagnostics.length) return { result: { command: "upgrade", ok: false, dry_run: options.dryRun, transaction_id: null, summary: null, diagnostics: loadedState.diagnostics }, json: options.json, exitCode: 1 };
  let imported = null;
  let report = null;
  let importBytes = null;
  let reportBytes = null;
  if (!loadedState.state) {
    const hasTypedSource = [".workflow/config.yml", ".workflow/project.yml"].some((relative) => existsSync(path.join(root, relative)));
    if (hasTypedSource) {
      const typed = await compileProject({ root, mode: "check" });
      if (!typed.candidate || ["invalid", "unsupported_schema"].includes(typed.sourceState)) {
        return { result: { command: "upgrade", ok: false, dry_run: options.dryRun, transaction_id: null, summary: null, preservation: null, diagnostics: typed.diagnostics }, json: options.json, exitCode: 1 };
      }
    } else {
      const legacy = await importLegacyProject({ root });
      if (!legacy.imported) {
        // An aborted import still produced evidence; keep it on disk so the
        // failure can be inspected offline.
        const written = options.dryRun ? { written: null } : await writeMigrationReport({ root, runId: transactionId, importBytes: legacy.importBytes, reportBytes: legacy.reportBytes });
        return { result: { command: "upgrade", ok: false, dry_run: options.dryRun, transaction_id: null, migration_report: written.written, summary: null, preservation: legacy.report?.summary ?? null, diagnostics: legacy.diagnostics }, json: options.json, exitCode: 1 };
      }
      imported = legacy.imported;
      report = legacy.report;
      importBytes = legacy.importBytes;
      reportBytes = legacy.reportBytes;
    }
  }
  const adapters = options.adapters === null
    ? (loadedState.state?.selected_adapters ?? imported?.selected_adapters ?? [])
    : options.adapters.split(",").filter(Boolean);
  // Optional components are preserved across upgrades exactly like adapters.
  const optionalComponentIds = new Set(
    manifest.components.filter((component) => !component.default && component.adapters.length === 0).map((component) => component.id)
  );
  const components = options.components === null
    ? (loadedState.state?.selected_components ?? []).filter((component) => optionalComponentIds.has(component))
    : options.components.split(",").filter(Boolean);
  const planned = await planInstallation({ root, sourceRoot, adapters, components, manifest, installedState: loadedState.state });
  if (!planned.plan || planned.diagnostics.length) return { result: { command: "upgrade", ok: false, dry_run: options.dryRun, transaction_id: null, summary: null, preservation: report?.summary ?? null, diagnostics: planned.diagnostics }, json: options.json, exitCode: 1 };
  const targetImport = imported ? structuredClone(imported) : null;
  if (targetImport) targetImport.project.confirmation.state = "confirmed";
  const materialized = await materializeInstallationContent({ root, sourceRoot, manifest, plan: planned.plan, targetRelease: options.to, imported: targetImport });
  if (!materialized.resolvedContentByAssetId) return { result: { command: "upgrade", ok: false, dry_run: options.dryRun, transaction_id: null, summary: null, preservation: report?.summary ?? null, diagnostics: materialized.diagnostics }, json: options.json, exitCode: 1 };
  // A replacement candidate is a template-managed file Hekate has no record of
  // installing, so it may be the user's own. It is replaced only after the
  // plan naming it has been shown and accepted.
  const candidateAssets = planned.plan.assets.filter((asset) => asset.disposition === "replace-candidate");
  const candidates = candidateAssets.map((asset) => asset.asset_id);
  const unownedPaths = candidateAssets.map((asset) => asset.destination).sort();
  const migratedPaths = planned.plan.assets
    .filter((asset) => asset.ownership === "project-seed" && asset.disposition !== "current")
    .map((asset) => asset.destination)
    .sort();
  const resolved = await resolveInstallationOperations({
    sourceRoot,
    plan: planned.plan,
    manifest,
    transactionId,
    sourceRelease: loadedState.state?.source_release ?? null,
    targetRelease: options.to,
    resolvedContentByAssetId: materialized.resolvedContentByAssetId,
    approvedReplacementCandidates: candidates
  });
  if (!resolved.journal) return { result: { command: "upgrade", ok: false, dry_run: options.dryRun, transaction_id: transactionId, summary: null, preservation: report?.summary ?? null, diagnostics: resolved.diagnostics }, json: options.json, exitCode: 1 };
  const summary = { create: 0, replace: 0, merge: 0, delete: 0 };
  for (const operation of resolved.journal.operations) summary[operation.operation] += 1;
  const preservation = report?.summary ?? null;
  const unresolvedCritical = report?.entries.filter((entry) => entry.critical && entry.disposition === "unresolved").length ?? 0;
  const plan = formatUpgradePlan({ summary, preservation, unresolvedCritical, unownedPaths, migratedPaths, transactionId });
  const base = { command: "upgrade", ok: true, dry_run: options.dryRun, transaction_id: transactionId, summary, preservation, unowned_replacements: unownedPaths, migrated_paths: migratedPaths, plan, diagnostics: [] };
  // A dry run stays byte-neutral, so the report is returned rather than written.
  if (options.dryRun) return { result: { ...base, migration_report: null }, json: options.json, exitCode: 0 };
  if (options.yes && unownedPaths.length && !options.replaceUnowned) {
    return {
      result: { ...base, ok: false, diagnostics: [diagnostic("HKT903", `Unowned files would be replaced without review: ${unownedPaths.join(", ")}. Re-run interactively or add --replace-unowned.`)] },
      json: options.json,
      exitCode: 1
    };
  }
  if (!options.yes && !await confirmUpgrade(summary, plan)) {
    return { result: { ...base, ok: false, diagnostics: [diagnostic("HKT902", "Upgrade confirmation is required; use --yes for non-interactive execution.")] }, json: options.json, exitCode: 1 };
  }
  let recoveryFiles;
  try { recoveryFiles = await loadRecoveryRuntime(); }
  catch (error) {
    return { result: { ...base, ok: false, diagnostics: [diagnostic("HKT904", `Cannot load offline recovery runtime: ${error.message}`)] }, json: options.json, exitCode: 1 };
  }
  const prepared = await prepareOperationTransaction({ root, journal: resolved.journal, contentByPath: resolved.contentByPath, modeByPath: resolved.modeByPath, importBytes, reportBytes, recoveryFiles, updateLock });
  if (!prepared.prepared) return { result: { ...base, ok: false, diagnostics: prepared.diagnostics }, json: options.json, exitCode: 1 };
  const applied = await applyPreparedTransaction({
    root,
    transactionId,
    updateLock,
    verify: () => verifyInstalledProject({ root, sourceRoot, manifest, expectedAdapters: adapters, expectedComponents: components, targetRelease: options.to, imported, report })
  });
  return { result: { ...base, ok: applied.applied, recovery_runtime: prepared.recovery_runtime, diagnostics: applied.diagnostics }, json: options.json, exitCode: applied.applied ? 0 : 1 };
  } finally {
    if (updateLock) await updateLock.release();
  }
}

function parseRollback(args) {
  const options = { transaction: null, target: null, yes: false, dryRun: false, json: false };
  for (let index = 0; index < args.length; index += 1) {
    const argument = args[index];
    if (["--yes", "--dry-run", "--json"].includes(argument)) {
      const key = { "--yes": "yes", "--dry-run": "dryRun", "--json": "json" }[argument];
      if (options[key]) return null;
      options[key] = true;
      continue;
    }
    const match = argument.match(/^--(transaction|target)=(.+)$/);
    if (match && options[match[1]] === null) { options[match[1]] = match[2]; continue; }
    if (["--transaction", "--target"].includes(argument) && options[argument.slice(2)] === null && args[index + 1] && !args[index + 1].startsWith("--")) {
      options[argument.slice(2)] = args[index + 1];
      index += 1;
      continue;
    }
    return null;
  }
  return options.transaction ? options : null;
}

async function rollback(args, invocationRoot) {
  const options = parseRollback(args);
  if (!options) return { usage: true, exitCode: 2 };
  if (!options.dryRun && !options.yes) {
    return {
      result: { command: "rollback", ok: false, rolled_back: false, transaction_id: options.transaction, actions: [], conflicts: [], diagnostics: [diagnostic("HKT902", "Rollback confirmation is required; use --yes for non-interactive execution.")] },
      json: options.json,
      exitCode: 1
    };
  }
  const root = path.resolve(options.target ?? invocationRoot);
  if (!options.dryRun) {
    try { await recoverProjectUpdateLock({ root, transactionId: options.transaction }); }
    catch (error) {
      return {
        result: { command: "rollback", ok: false, rolled_back: false, transaction_id: options.transaction, actions: [], conflicts: [], diagnostics: [diagnostic("HKT444", `Cannot recover project update lock: ${error.message}`)] },
        json: options.json,
        exitCode: 1
      };
    }
  }
  const result = await rollbackPreparedTransaction({ root, transactionId: options.transaction, dryRun: options.dryRun });
  return {
    result: { command: "rollback", ok: options.dryRun ? result.diagnostics.length === 0 : result.rolled_back, transaction_id: options.transaction, ...result },
    json: options.json,
    exitCode: (options.dryRun ? result.diagnostics.length === 0 : result.rolled_back) ? 0 : 1
  };
}

function printRollback(result, json) {
  if (json) { process.stdout.write(`${JSON.stringify(result)}\n`); return; }
  for (const action of result.actions) process.stdout.write(`${action.operation}: ${action.path}\n`);
  for (const conflict of result.conflicts) process.stdout.write(`conflict: ${conflict.path}: ${conflict.reason}\n`);
  for (const item of result.diagnostics) process.stdout.write(`${item.code}: ${item.message}\n`);
  if (result.rolled_back) process.stdout.write("rollback committed\n");
}

async function cleanup(args, invocationRoot) {
  const options = parseRollback(args);
  if (!options) return { usage: true, exitCode: 2 };
  if (!options.dryRun && !options.yes) {
    return {
      result: { command: "cleanup", ok: false, dry_run: false, cleaned: false, transaction_id: options.transaction, status: null, actions: [], removed: [], diagnostics: [diagnostic("HKT902", "Cleanup confirmation is required; use --yes for non-interactive execution.")] },
      json: options.json,
      exitCode: 1
    };
  }
  const root = path.resolve(options.target ?? invocationRoot);
  if (!options.dryRun) {
    try { await recoverProjectUpdateLock({ root, transactionId: options.transaction }); }
    catch (error) {
      return {
        result: { command: "cleanup", ok: false, dry_run: false, cleaned: false, transaction_id: options.transaction, status: null, actions: [], removed: [], diagnostics: [diagnostic("HKT444", `Cannot recover project update lock: ${error.message}`)] },
        json: options.json,
        exitCode: 1
      };
    }
  }
  const result = await cleanupTransactionBundle({ root, transactionId: options.transaction, dryRun: options.dryRun });
  const ok = result.diagnostics.length === 0 && (options.dryRun || result.cleaned || result.status === "absent");
  return { result: { command: "cleanup", ok, dry_run: options.dryRun, transaction_id: options.transaction, ...result }, json: options.json, exitCode: ok ? 0 : 1 };
}

function printCleanup(result, json) {
  if (json) { process.stdout.write(`${JSON.stringify(result)}\n`); return; }
  for (const action of result.actions) process.stdout.write(`${action.operation}: ${action.path} (${action.files} files, ${action.bytes} bytes)\n`);
  for (const item of result.diagnostics) process.stdout.write(`${item.code}: ${item.message}\n`);
  if (result.ok) process.stdout.write(result.dry_run
    ? "dry run; offline rollback remains available\n"
    : result.status === "absent"
      ? "transaction bundle already absent\n"
      : "transaction bundle cleaned; offline rollback is no longer available\n");
}

export async function main(args, root, loadAgent = null) {
  const command = args[0];
  if (command === "agent") {
    let agent;
    try {
      if (!loadAgent) throw new Error("this standalone transaction runtime does not include Pi");
      agent = await loadAgent();
    }
    catch (error) {
      process.stderr.write(`HKT950: Pi agent runtime is unavailable: ${error.message}\n`);
      return 2;
    }
    const { parseAgentOptions, runAgent } = agent;
    const options = parseAgentOptions(args.slice(1));
    if (!options) { process.stderr.write(`${usage()}\n`); return 2; }
    try { return await runAgent(options, root); }
    catch (error) { process.stderr.write(`HKT950: ${error.message}\n`); return 2; }
  }
  if (command === "upgrade") {
    try {
      const response = await upgrade(args.slice(1), root);
      if (response.usage) { process.stderr.write(`${usage()}\n`); return response.exitCode; }
      printUpgrade(response.result, response.json);
      return response.exitCode;
    } catch (error) {
      process.stderr.write(`HKT900: ${error.message}\n`);
      return 2;
    }
  }
  if (command === "rollback") {
    try {
      const response = await rollback(args.slice(1), root);
      if (response.usage) { process.stderr.write(`${usage()}\n`); return response.exitCode; }
      printRollback(response.result, response.json);
      return response.exitCode;
    } catch (error) {
      process.stderr.write(`HKT900: ${error.message}\n`);
      return 2;
    }
  }
  if (command === "cleanup") {
    try {
      const response = await cleanup(args.slice(1), root);
      if (response.usage) { process.stderr.write(`${usage()}\n`); return response.exitCode; }
      printCleanup(response.result, response.json);
      return response.exitCode;
    } catch (error) {
      process.stderr.write(`HKT900: ${error.message}\n`);
      return 2;
    }
  }
  const options = new Set(args.slice(1));
  const allowed = command === "check" ? new Set(["--json"]) : new Set(["--check", "--json"]);
  if (!command || !["check", "compile"].includes(command) || options.size !== args.length - 1 || [...options].some((option) => !allowed.has(option))) {
    process.stderr.write(`${usage()}\n`);
    return 2;
  }
  try {
    const json = options.has("--json");
    const result = command === "check" ? await checkProject({ root }) : await compileProject({ root, mode: options.has("--check") ? "check" : "write" });
    outputCompiler(result, command, json);
    return result.ok ? 0 : 1;
  } catch (error) {
    if (options.has("--json")) process.stdout.write(`${JSON.stringify({ command, ok: false, gate_state: "invalid", diagnostics: [diagnostic("HKT900", error.message)] })}\n`);
    else process.stderr.write(`HKT900: ${error.message}\n`);
    return 2;
  }
}
