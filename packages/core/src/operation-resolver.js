import { createHash } from "node:crypto";
import { lstat, open, realpath } from "node:fs/promises";
import { constants } from "node:fs";
import path from "node:path";
import { validateManifestRelations } from "./install-planner.js";
import { createOperationJournal } from "./journal.js";
import { validateSchema } from "./validator.js";

function diagnostic(code, message, pathValue = "") {
  return { code, severity: "error", file: "install-plan.json", path: pathValue, message };
}

function digest(bytes) {
  return `sha256:${createHash("sha256").update(bytes).digest("hex")}`;
}

function safeRelative(value) {
  if (typeof value !== "string" || path.isAbsolute(value) || value.includes("\\")) return false;
  return value.split("/").every((part) => part
    && part !== "."
    && part !== ".."
    && !/[:<>"|?*]/.test(part)
    && !/[. ]$/.test(part)
    && !/[\u0000-\u001f]/.test(part)
    && !/^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)/i.test(part));
}

const protectedOwnership = ["local-seed", "project-seed", "shared-merge", "user-owned"];

function archiveDestination(destination) {
  return `.workflow/archived/${destination.split("/").at(-1)}`;
}

async function readSafeSource(root, relative) {
  if (!safeRelative(relative)) throw new Error("source is not a safe relative path");
  let current = root;
  for (const [index, part] of relative.split("/").entries()) {
    current = path.join(current, part);
    const metadata = await lstat(current);
    if (metadata.isSymbolicLink()) throw new Error("source path contains a symbolic link");
    if (index < relative.split("/").length - 1 && !metadata.isDirectory()) throw new Error("source parent is not a directory");
    if (index === relative.split("/").length - 1 && !metadata.isFile()) throw new Error("source is not a regular file");
  }
  const handle = await open(current, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0));
  try { return await handle.readFile(); }
  finally { await handle.close(); }
}

export async function resolveInstallationOperations({
  sourceRoot,
  plan,
  manifest,
  transactionId,
  sourceRelease = null,
  targetRelease,
  resolvedContentByAssetId = new Map(),
  approvedReplacementCandidates = []
}) {
  const diagnostics = [
    ...validateSchema("plan", plan, "install-plan.json"),
    ...validateSchema("manifest", manifest, "install-manifest.json")
  ];
  if (manifest && validateSchema("manifest", manifest, "install-manifest.json").length === 0) {
    diagnostics.push(...validateManifestRelations(manifest).map((item) => ({ severity: "error", ...item })));
  }
  if (!(resolvedContentByAssetId instanceof Map)) diagnostics.push(diagnostic("HKT460", "Resolved asset content must be supplied as a map."));
  if (!Array.isArray(approvedReplacementCandidates)) diagnostics.push(diagnostic("HKT460", "Replacement candidate approvals must be an array."));
  if (plan?.diagnostics?.length) diagnostics.push(diagnostic("HKT460", "A plan with diagnostics cannot be resolved.", "/diagnostics"));
  if (plan?.manifest_version !== manifest?.manifest_version) diagnostics.push(diagnostic("HKT461", "Plan and manifest versions do not match.", "/manifest_version"));
  if (diagnostics.length) return { journal: null, contentByPath: null, modeByPath: null, diagnostics };

  const assets = new Map(manifest.assets.map((asset) => [asset.asset_id, asset]));
  if (assets.size !== manifest.assets.length) diagnostics.push(diagnostic("HKT461", "Manifest asset IDs are not unique."));
  const plannedIds = new Set(plan.assets.map((asset) => asset.asset_id));
  if (plannedIds.size !== plan.assets.length) diagnostics.push(diagnostic("HKT461", "Plan asset IDs are not unique."));
  const selectedAdapters = new Set(plan.selected_adapters);
  const requiredComponents = new Set(manifest.components.filter((component) => component.default || component.adapters.some((adapter) => selectedAdapters.has(adapter))).map((component) => component.id));
  // Components that no adapter selects and that are not installed by default
  // are opt-in, so a plan may legitimately carry them in addition.
  const optionalComponents = new Set(manifest.components.filter((component) => !component.default && component.adapters.length === 0).map((component) => component.id));
  const expectedComponents = new Set(requiredComponents);
  for (const component of plan.selected_components) {
    if (optionalComponents.has(component)) expectedComponents.add(component);
  }
  if (expectedComponents.size !== plan.selected_components.length || plan.selected_components.some((component) => !expectedComponents.has(component))) {
    diagnostics.push(diagnostic("HKT461", "Selected components do not match selected adapters and optional components.", "/selected_components"));
  }
  for (const asset of manifest.assets.filter((item) => expectedComponents.has(item.component))) {
    if (!plannedIds.has(asset.asset_id)) diagnostics.push(diagnostic("HKT461", "Plan omits an asset from a selected component.", asset.asset_id));
  }
  for (const assetId of resolvedContentByAssetId.keys()) {
    if (!plannedIds.has(assetId)) diagnostics.push(diagnostic("HKT461", "Resolved content references an asset outside the plan.", assetId));
  }
  const approved = new Set(approvedReplacementCandidates);
  for (const assetId of approved) {
    if (!plannedIds.has(assetId)) diagnostics.push(diagnostic("HKT461", "Replacement approval references an asset outside the plan.", assetId));
    else if (plan.assets.find((asset) => asset.asset_id === assetId).disposition !== "replace-candidate") diagnostics.push(diagnostic("HKT461", "Replacement approval does not reference a replacement candidate.", assetId));
  }

  let templatesRoot;
  try { templatesRoot = await realpath(sourceRoot); }
  catch (error) { return { journal: null, contentByPath: null, modeByPath: null, diagnostics: [diagnostic("HKT462", `Cannot resolve template root: ${error.message}`)] }; }
  const operations = [];
  const contentByPath = new Map();
  const modeByPath = new Map();

  for (const [index, planned] of plan.assets.entries()) {
    const pointer = `/assets/${index}`;
    const asset = assets.get(planned.asset_id);
    if (!asset || asset.destination !== planned.destination || asset.ownership !== planned.ownership) {
      diagnostics.push(diagnostic("HKT461", "Planned asset does not match the manifest.", pointer));
      continue;
    }
    const selected = plan.selected_components.includes(asset.component);
    if (!selected && !["remove", "merge", "preserve"].includes(planned.disposition)) {
      diagnostics.push(diagnostic("HKT461", "Planned asset belongs to an unselected component.", pointer));
      continue;
    }
    if (!selected && planned.provenance !== "recorded") {
      diagnostics.push(diagnostic("HKT467", "Unselected assets require recorded installation provenance.", pointer));
      continue;
    }
    if (planned.disposition === "remove") {
      if (selected || planned.provenance !== "recorded" || planned.current_hash === null || planned.target_hash !== null || !["remove-if-unmodified", "remove-if-generated", "archive"].includes(asset.remove_strategy)) {
        diagnostics.push(diagnostic("HKT467", "Asset is not eligible for safe removal.", pointer));
        continue;
      }
      if (asset.remove_strategy === "archive") {
        const archivePath = archiveDestination(planned.destination);
        const archiveBytes = resolvedContentByAssetId.get(planned.asset_id);
        if (protectedOwnership.includes(planned.ownership)) {
          diagnostics.push(diagnostic("HKT468", "Archived removal requires an ownership class that permits deletion.", pointer));
          continue;
        }
        if (!Buffer.isBuffer(archiveBytes)) {
          diagnostics.push(diagnostic("HKT468", "Archived removal requires the current bytes of the asset.", pointer));
          continue;
        }
        if (digest(archiveBytes) !== planned.current_hash) {
          diagnostics.push(diagnostic("HKT468", "Archived bytes do not match the recorded current content.", pointer));
          continue;
        }
        if (!safeRelative(archivePath) || contentByPath.has(archivePath)) {
          diagnostics.push(diagnostic("HKT468", "Archive destination is unsafe or already claimed.", pointer));
          continue;
        }
        operations.push({
          operation: "create",
          path: archivePath,
          before_hash: null,
          after_hash: digest(archiveBytes),
          backup_path: null,
          ownership: planned.ownership
        });
        contentByPath.set(archivePath, Buffer.from(archiveBytes));
        modeByPath.set(archivePath, Number.parseInt(asset.mode, 8));
      }
      operations.push({
        operation: "delete",
        path: planned.destination,
        before_hash: planned.current_hash,
        after_hash: null,
        backup_path: `.workflow/backups/${transactionId}/${planned.destination}`,
        ownership: planned.ownership
      });
      continue;
    }
    if (!selected && planned.disposition === "merge" && (asset.remove_strategy !== "remove-contribution" || planned.ownership !== "shared-merge" || planned.current_hash === null || planned.target_hash !== null || !resolvedContentByAssetId.has(planned.asset_id))) {
      diagnostics.push(diagnostic("HKT467", "Contribution removal requires explicit merged bytes for a recorded shared asset.", pointer));
      continue;
    }
    if (!selected && planned.disposition === "preserve" && resolvedContentByAssetId.has(planned.asset_id)) {
      diagnostics.push(diagnostic("HKT467", "Preserved assets from unselected components cannot be mutated.", pointer));
      continue;
    }
    if (["current", "preserve"].includes(planned.disposition) && !resolvedContentByAssetId.has(planned.asset_id)) continue;
    if (resolvedContentByAssetId.has(planned.asset_id) && ["local-seed", "user-owned"].includes(planned.ownership)) {
      diagnostics.push(diagnostic("HKT465", "Resolved content cannot mutate local-seed or user-owned assets.", pointer));
      continue;
    }
    if (asset.update_strategy === "preserve") {
      diagnostics.push(diagnostic("HKT468", "Assets with a preserve update strategy are never written.", pointer));
      continue;
    }
    if (asset.update_strategy === "create-only" && planned.current_hash !== null) {
      diagnostics.push(diagnostic("HKT468", "Create-only assets cannot overwrite an existing file.", pointer));
      continue;
    }
    if (asset.update_strategy !== "three-way" && ["replace", "replace-candidate"].includes(planned.disposition)) {
      diagnostics.push(diagnostic("HKT468", "Only three-way assets may be replaced from the template.", pointer));
      continue;
    }
    if (planned.disposition === "replace-candidate" && !approved.has(planned.asset_id)) {
      diagnostics.push(diagnostic("HKT463", "Unowned replacement candidate requires explicit approval.", pointer));
      continue;
    }

    const explicitlyResolved = resolvedContentByAssetId.has(planned.asset_id);
    let targetBytes = resolvedContentByAssetId.get(planned.asset_id);
    if (targetBytes !== undefined && !Buffer.isBuffer(targetBytes)) {
      diagnostics.push(diagnostic("HKT464", "Resolved asset content must be bytes.", pointer));
      continue;
    }
    if (targetBytes === undefined && ["merge", "regenerate"].includes(planned.disposition)) {
      diagnostics.push(diagnostic("HKT464", `${planned.disposition} requires explicit resolved bytes.`, pointer));
      continue;
    }
    if (targetBytes === undefined) {
      if (asset.source === null) {
        diagnostics.push(diagnostic("HKT464", "Asset has no source or resolved bytes.", pointer));
        continue;
      }
      try { targetBytes = await readSafeSource(templatesRoot, asset.source); }
      catch (error) { diagnostics.push(diagnostic("HKT462", `Cannot safely read asset source: ${error.message}`, pointer)); continue; }
    } else {
      targetBytes = Buffer.from(targetBytes);
    }
    if (!explicitlyResolved && planned.target_hash !== digest(targetBytes)) {
      diagnostics.push(diagnostic("HKT466", "Template source changed after the plan was created.", pointer));
      continue;
    }

    const operation = planned.current_hash === null
      ? "create"
      : planned.disposition === "merge" || ["structured-merge", "typed-migration", "create-only", "preserve"].includes(asset.update_strategy)
        ? "merge"
        : "replace";
    const backupPath = operation === "create" ? null : `.workflow/backups/${transactionId}/${planned.destination}`;
    operations.push({
      operation,
      path: planned.destination,
      before_hash: planned.current_hash,
      after_hash: digest(targetBytes),
      backup_path: backupPath,
      ownership: planned.ownership
    });
    contentByPath.set(planned.destination, targetBytes);
    modeByPath.set(planned.destination, Number.parseInt(asset.mode, 8));
  }
  if (diagnostics.length) return { journal: null, contentByPath: null, modeByPath: null, diagnostics };
  const created = createOperationJournal({
    transactionId,
    manifestVersion: manifest.manifest_version,
    sourceRelease,
    targetRelease,
    operations
  });
  return created.diagnostics.length
    ? { journal: null, contentByPath: null, modeByPath: null, diagnostics: created.diagnostics }
    : { journal: created.journal, journalBytes: created.bytes, contentByPath, modeByPath, diagnostics: [] };
}
