import { constants } from "node:fs";
import { lstat, open, realpath } from "node:fs/promises";
import path from "node:path";
import { stringify } from "yaml";
import { resolveProjectLock } from "./compiler.js";
import { createInstalledState } from "./install-state.js";
import { validateSchema } from "./validator.js";

function diagnostic(code, message, pathValue = "") {
  return { code, severity: "error", file: "install-plan.json", path: pathValue, message };
}

async function readSafe(root, relative, optional = false) {
  const parts = relative.split("/");
  let current = root;
  for (const [index, part] of parts.entries()) {
    current = path.join(current, part);
    let metadata;
    try { metadata = await lstat(current); }
    catch (error) { if (optional && error.code === "ENOENT") return null; throw error; }
    if (metadata.isSymbolicLink()) throw new Error("path contains a symbolic link");
    if (index < parts.length - 1 && !metadata.isDirectory()) throw new Error("path parent is not a directory");
    if (index === parts.length - 1 && !metadata.isFile()) throw new Error("path is not a regular file");
  }
  const handle = await open(current, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0));
  try { return await handle.readFile(); }
  finally { await handle.close(); }
}

function yamlBytes(value) {
  // Imported facts can share object identity; aliases are forbidden by the
  // authored-data parser, so serialize an equivalent tree with unique nodes.
  return Buffer.from(stringify(JSON.parse(JSON.stringify(value)), { lineWidth: 0 }));
}

function mergeLines(currentBytes, contributionBytes, remove) {
  const current = currentBytes?.toString("utf8") ?? "";
  const contribution = contributionBytes.toString("utf8").split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
  if (remove) {
    const removed = new Set(contribution);
    const retained = current.split(/\r?\n/).filter((line) => !removed.has(line.trim()));
    while (retained.at(-1) === "") retained.pop();
    return Buffer.from(retained.length ? `${retained.join("\n")}\n` : "");
  }
  const present = new Set(current.split(/\r?\n/).map((line) => line.trim()));
  const missing = contribution.filter((line) => !present.has(line));
  if (missing.length === 0) return Buffer.from(currentBytes ?? Buffer.alloc(0));
  const separator = current.length === 0 || current.endsWith("\n") ? "" : "\n";
  return Buffer.from(`${current}${separator}${missing.join("\n")}\n`);
}

export async function materializeInstallationContent({ root, sourceRoot, manifest, plan, targetRelease, imported = null, resolvedContentByAssetId = new Map() }) {
  const diagnostics = [
    ...validateSchema("manifest", manifest, "install-manifest.json"),
    ...validateSchema("plan", plan, "install-plan.json")
  ];
  if (!(resolvedContentByAssetId instanceof Map)) diagnostics.push(diagnostic("HKT490", "Resolved content must be supplied as a map."));
  if (imported !== null) diagnostics.push(...validateSchema("legacy-import", imported, "import.json"));
  if (diagnostics.length) return { resolvedContentByAssetId: null, diagnostics };
  let projectRoot;
  let templatesRoot;
  try {
    projectRoot = await realpath(root);
    templatesRoot = await realpath(sourceRoot);
  } catch (error) {
    return { resolvedContentByAssetId: null, diagnostics: [diagnostic("HKT490", `Cannot resolve content roots: ${error.message}`)] };
  }
  const resolved = new Map([...resolvedContentByAssetId].map(([key, bytes]) => [key, Buffer.isBuffer(bytes) ? Buffer.from(bytes) : bytes]));
  for (const [assetId, bytes] of resolved) {
    if (!Buffer.isBuffer(bytes)) diagnostics.push(diagnostic("HKT490", "Resolved content must be bytes.", assetId));
  }
  const byDestination = new Map(plan.assets.map((asset) => [asset.destination, asset]));
  const manifestById = new Map(manifest.assets.map((asset) => [asset.asset_id, asset]));
  if (imported) {
    for (const [destination, value] of [[".workflow/config.yml", imported.config], [".workflow/project.yml", imported.project]]) {
      const item = byDestination.get(destination);
      if (!item) diagnostics.push(diagnostic("HKT491", "Imported target is absent from the installation plan.", destination));
      else resolved.set(item.asset_id, yamlBytes(value));
    }
  }

  for (const [index, item] of plan.assets.entries()) {
    if (item.disposition !== "merge" || resolved.has(item.asset_id)) continue;
    const asset = manifestById.get(item.asset_id);
    if (!asset || asset.ownership !== "shared-merge" || asset.source === null) {
      diagnostics.push(diagnostic("HKT491", "Shared merge requires a manifest contribution or explicit bytes.", `/assets/${index}`));
      continue;
    }
    try {
      const current = await readSafe(projectRoot, item.destination, true);
      const contribution = await readSafe(templatesRoot, asset.source);
      const remove = !plan.selected_components.includes(asset.component);
      resolved.set(item.asset_id, mergeLines(current, contribution, remove));
    } catch (error) {
      diagnostics.push(diagnostic("HKT491", `Cannot materialize shared contribution: ${error.message}`, `/assets/${index}`));
    }
  }

  async function targetAuthoredBytes(destination) {
    const item = byDestination.get(destination);
    if (!item) return null;
    if (resolved.has(item.asset_id)) return resolved.get(item.asset_id);
    const asset = manifestById.get(item.asset_id);
    if (["create", "replace", "replace-candidate"].includes(item.disposition)) return readSafe(templatesRoot, asset.source);
    return readSafe(projectRoot, destination);
  }

  const lockAsset = manifest.assets.find((asset) => asset.destination === ".workflow/status.lock.json" && plan.selected_components.includes(asset.component));
  if (lockAsset && !resolved.has(lockAsset.asset_id)) {
    try {
      const configBytes = await targetAuthoredBytes(".workflow/config.yml");
      const projectBytes = await targetAuthoredBytes(".workflow/project.yml");
      const lock = await resolveProjectLock({ root: projectRoot, configBytes, projectBytes });
      if (!lock.ok || !lock.bytes) diagnostics.push(...lock.diagnostics, diagnostic("HKT492", "Target authored state cannot produce a valid generated lock.", lockAsset.asset_id));
      else resolved.set(lockAsset.asset_id, lock.bytes);
    } catch (error) {
      diagnostics.push(diagnostic("HKT492", `Cannot materialize generated lock: ${error.message}`, lockAsset.asset_id));
    }
  }
  for (const asset of manifest.assets.filter((item) => item.ownership === "generated" && plan.selected_components.includes(item.component) && ![".workflow/status.lock.json", ".workflow/install-state.json"].includes(item.destination))) {
    if (!resolved.has(asset.asset_id)) diagnostics.push(diagnostic("HKT492", "Generated asset requires explicit bytes.", asset.asset_id));
  }
  if (diagnostics.length) return { resolvedContentByAssetId: null, diagnostics };

  const stateAsset = manifest.assets.find((asset) => asset.destination === ".workflow/install-state.json" && plan.selected_components.includes(asset.component));
  if (stateAsset) {
    const installed = createInstalledState({ manifest, plan, targetRelease, resolvedContentByAssetId: resolved });
    diagnostics.push(...installed.diagnostics);
    if (installed.bytes) resolved.set(stateAsset.asset_id, installed.bytes);
  }
  return diagnostics.length ? { resolvedContentByAssetId: null, diagnostics } : { resolvedContentByAssetId: resolved, diagnostics: [] };
}
