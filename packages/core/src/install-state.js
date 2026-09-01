import { createHash } from "node:crypto";
import { canonicalBytes } from "./canonical-json.js";
import { validateInstalledState } from "./install-planner.js";
import { validateSchema } from "./validator.js";

function diagnostic(code, message, pathValue = "") {
  return { code, severity: "error", file: ".workflow/install-state.json", path: pathValue, message };
}

function digest(bytes) {
  return `sha256:${createHash("sha256").update(bytes).digest("hex")}`;
}

export function createInstalledState({ manifest, plan, targetRelease, resolvedContentByAssetId = new Map() }) {
  const diagnostics = [
    ...validateSchema("manifest", manifest, "install-manifest.json"),
    ...validateSchema("plan", plan, "install-plan.json")
  ];
  if (!(resolvedContentByAssetId instanceof Map)) diagnostics.push(diagnostic("HKT480", "Resolved content must be supplied as a map."));
  if (typeof targetRelease !== "string" || targetRelease.length === 0) diagnostics.push(diagnostic("HKT480", "Target release must be a non-empty string.", "/source_release"));
  if (plan?.manifest_version !== manifest?.manifest_version) diagnostics.push(diagnostic("HKT480", "Plan and manifest versions do not match.", "/manifest_version"));
  if (diagnostics.length) return { state: null, bytes: null, diagnostics };

  const selected = new Set(plan.selected_components);
  const planned = new Map(plan.assets.map((asset) => [asset.asset_id, asset]));
  const assets = [];
  for (const [index, asset] of manifest.assets.filter((item) => selected.has(item.component)).sort((left, right) => left.asset_id.localeCompare(right.asset_id, "en")).entries()) {
    const item = planned.get(asset.asset_id);
    if (!item || item.destination !== asset.destination || item.ownership !== asset.ownership) {
      diagnostics.push(diagnostic("HKT481", "Selected manifest asset is missing or inconsistent in the plan.", `/assets/${index}`));
      continue;
    }
    const resolved = resolvedContentByAssetId.get(asset.asset_id);
    if (resolved !== undefined && !Buffer.isBuffer(resolved)) {
      diagnostics.push(diagnostic("HKT481", "Resolved destination content must be bytes.", `/assets/${index}`));
      continue;
    }
    let destinationHash = null;
    if (asset.destination !== ".workflow/install-state.json") {
      if (resolved !== undefined) destinationHash = digest(resolved);
      else if (["create", "replace", "replace-candidate"].includes(item.disposition)) destinationHash = item.target_hash;
      else destinationHash = item.current_hash;
    }
    if (destinationHash === null && asset.destination !== ".workflow/install-state.json" && asset.ownership !== "user-owned") {
      diagnostics.push(diagnostic("HKT481", "Selected asset has no resulting destination hash.", `/assets/${index}/destination_hash`));
    }
    if (asset.source !== null && item.target_hash === null) diagnostics.push(diagnostic("HKT481", "Selected sourced asset has no installed source hash.", `/assets/${index}/installed_source_hash`));
    assets.push({
      asset_id: asset.asset_id,
      destination: asset.destination,
      ownership: asset.ownership,
      installed_source_hash: asset.source === null ? null : item.target_hash,
      destination_hash: destinationHash
    });
  }
  if (diagnostics.length) return { state: null, bytes: null, diagnostics };
  const state = {
    schema_version: 1,
    manifest_version: manifest.manifest_version,
    source_release: targetRelease,
    selected_components: [...plan.selected_components].sort(),
    selected_adapters: [...plan.selected_adapters].sort(),
    assets
  };
  diagnostics.push(...validateInstalledState(state, manifest).map((item) => ({ severity: "error", ...item })));
  return diagnostics.length ? { state: null, bytes: null, diagnostics } : { state, bytes: canonicalBytes(state), diagnostics: [] };
}
