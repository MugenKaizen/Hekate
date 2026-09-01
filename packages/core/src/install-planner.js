import { createHash } from "node:crypto";
import { lstat, readFile, realpath } from "node:fs/promises";
import path from "node:path";
import { validateSchema } from "./validator.js";

const defaultManifestUrl = new URL("../../../distribution/install-manifest.json", import.meta.url);

function diagnostic(code, file, message, pathValue = "") {
  return { code, file, path: pathValue, message };
}

function hash(bytes) {
  return `sha256:${createHash("sha256").update(bytes).digest("hex")}`;
}

function isSafeRelative(value) {
  return typeof value === "string"
    && !path.isAbsolute(value)
    && !value.includes("\\")
    && value.split("/").every((part) => part && part !== "." && part !== "..");
}

async function inspectFile(root, relative) {
  if (!isSafeRelative(relative)) throw new Error("path is not a safe project-relative path");
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
    if (index === parts.length - 1 && !metadata.isFile()) throw new Error("path is not a regular file");
  }
  return readFile(current);
}

export function validateManifestRelations(manifest) {
  const diagnostics = [];
  const adapters = new Set(manifest.adapters);
  const componentIds = new Set();
  for (const [index, component] of manifest.components.entries()) {
    if (componentIds.has(component.id)) diagnostics.push(diagnostic("HKT401", "install-manifest.json", "Duplicate component ID.", `/components/${index}/id`));
    componentIds.add(component.id);
    for (const adapter of component.adapters) {
      if (!adapters.has(adapter)) diagnostics.push(diagnostic("HKT402", "install-manifest.json", "Component references an unknown adapter.", `/components/${index}/adapters`));
    }
  }
  const assetIds = new Set();
  const destinations = new Set();
  for (const [index, asset] of manifest.assets.entries()) {
    if (assetIds.has(asset.asset_id)) diagnostics.push(diagnostic("HKT403", "install-manifest.json", "Duplicate asset ID.", `/assets/${index}/asset_id`));
    assetIds.add(asset.asset_id);
    if (!componentIds.has(asset.component)) diagnostics.push(diagnostic("HKT404", "install-manifest.json", "Asset references an unknown component.", `/assets/${index}/component`));
    if (!isSafeRelative(asset.destination)) diagnostics.push(diagnostic("HKT405", "install-manifest.json", "Asset destination is unsafe.", `/assets/${index}/destination`));
    if (asset.source !== null && !isSafeRelative(asset.source)) diagnostics.push(diagnostic("HKT405", "install-manifest.json", "Asset source is unsafe.", `/assets/${index}/source`));
    const destinationKey = asset.destination.toLowerCase();
    if (destinations.has(destinationKey)) diagnostics.push(diagnostic("HKT406", "install-manifest.json", "Asset destinations collide on a case-insensitive filesystem.", `/assets/${index}/destination`));
    destinations.add(destinationKey);
    if (asset.ownership === "generated" && asset.source !== null) diagnostics.push(diagnostic("HKT407", "install-manifest.json", "Generated assets must not have template sources.", `/assets/${index}/source`));
    if (asset.ownership !== "generated" && asset.source === null) diagnostics.push(diagnostic("HKT407", "install-manifest.json", "Non-generated assets require template sources.", `/assets/${index}/source`));
  }
  return diagnostics;
}

export function validateInstalledState(state, manifest) {
  const diagnostics = validateSchema("install-state", state, ".workflow/install-state.json").map(({ severity: _severity, ...item }) => item);
  if (diagnostics.length) return diagnostics;
  if (state.manifest_version > manifest.manifest_version) {
    diagnostics.push(diagnostic("HKT420", ".workflow/install-state.json", "Installed state uses a future manifest version.", "/manifest_version"));
  }
  const manifestAssets = new Map(manifest.assets.map((asset) => [asset.asset_id, asset]));
  const seen = new Set();
  for (const [index, installed] of state.assets.entries()) {
    if (seen.has(installed.asset_id)) diagnostics.push(diagnostic("HKT421", ".workflow/install-state.json", "Duplicate installed asset ID.", `/assets/${index}/asset_id`));
    seen.add(installed.asset_id);
    const expected = manifestAssets.get(installed.asset_id);
    if (!expected) {
      diagnostics.push(diagnostic("HKT422", ".workflow/install-state.json", "Installed state references an unknown asset.", `/assets/${index}/asset_id`));
    } else if (expected.destination !== installed.destination || expected.ownership !== installed.ownership) {
      diagnostics.push(diagnostic("HKT423", ".workflow/install-state.json", "Installed asset ownership does not match the manifest.", `/assets/${index}`));
    }
  }
  return diagnostics;
}

export async function loadInstallManifest(url = defaultManifestUrl) {
  let manifest;
  try { manifest = JSON.parse(await readFile(url, "utf8")); }
  catch (error) { return { manifest: null, diagnostics: [diagnostic("HKT400", "install-manifest.json", `Cannot read install manifest: ${error.message}`)] }; }
  const diagnostics = validateSchema("manifest", manifest, "install-manifest.json").map(({ severity: _severity, ...item }) => item);
  if (diagnostics.length === 0) diagnostics.push(...validateManifestRelations(manifest));
  return { manifest: diagnostics.length ? null : manifest, diagnostics };
}

export async function loadInstalledState(root, manifest) {
  let bytes;
  try { bytes = await inspectFile(await realpath(root), ".workflow/install-state.json"); }
  catch (error) { return { state: null, diagnostics: [diagnostic("HKT424", ".workflow/install-state.json", `Cannot safely read installed state: ${error.message}`)] }; }
  if (bytes === null) return { state: null, diagnostics: [] };
  let state;
  try { state = JSON.parse(bytes.toString("utf8")); }
  catch { return { state: null, diagnostics: [diagnostic("HKT425", ".workflow/install-state.json", "Installed state is malformed JSON.")] }; }
  const diagnostics = validateInstalledState(state, manifest);
  return { state: diagnostics.length ? null : state, diagnostics };
}

export async function planInstallation({ root, sourceRoot, adapters = [], components = [], manifest: suppliedManifest, installedState: suppliedState }) {
  let manifest = suppliedManifest;
  let diagnostics = [];
  if (!manifest) {
    const loaded = await loadInstallManifest();
    manifest = loaded.manifest;
    diagnostics = loaded.diagnostics;
  } else {
    diagnostics = validateSchema("manifest", manifest, "install-manifest.json").map(({ severity: _severity, ...item }) => item);
    if (diagnostics.length === 0) diagnostics.push(...validateManifestRelations(manifest));
  }
  if (!manifest || diagnostics.length) return { plan: null, diagnostics };

  const selectedAdapters = [...new Set(adapters)].sort();
  const unknownAdapters = selectedAdapters.filter((adapter) => !manifest.adapters.includes(adapter));
  if (unknownAdapters.length) {
    return { plan: null, diagnostics: unknownAdapters.map((adapter) => diagnostic("HKT410", "adapters", `Unknown adapter: ${adapter}`)) };
  }
  // Components that no adapter selects and that are not installed by default
  // are opt-in and must be requested by name.
  const requestedComponents = [...new Set(components)].sort();
  const optionalComponentIds = new Set(
    manifest.components.filter((component) => !component.default && component.adapters.length === 0).map((component) => component.id)
  );
  const unknownComponents = requestedComponents.filter((component) => !optionalComponentIds.has(component));
  if (unknownComponents.length) {
    return { plan: null, diagnostics: unknownComponents.map((component) => diagnostic("HKT414", "components", `Unknown optional component: ${component}`)) };
  }

  let projectRoot;
  let templatesRoot;
  try {
    projectRoot = await realpath(root);
    templatesRoot = await realpath(sourceRoot);
  } catch (error) {
    return { plan: null, diagnostics: [diagnostic("HKT411", "root", `Cannot resolve planning root: ${error.message}`)] };
  }
  let installedState = suppliedState;
  if (installedState === undefined) {
    const loadedState = await loadInstalledState(projectRoot, manifest);
    if (loadedState.diagnostics.length) return { plan: null, diagnostics: loadedState.diagnostics };
    installedState = loadedState.state;
  } else if (installedState !== null) {
    const stateDiagnostics = validateInstalledState(installedState, manifest);
    if (stateDiagnostics.length) return { plan: null, diagnostics: stateDiagnostics };
  }
  const installedAssets = new Map((installedState?.assets ?? []).map((asset) => [asset.asset_id, asset]));
  const selectedSet = new Set(selectedAdapters);
  const requestedSet = new Set(requestedComponents);
  const selectedComponents = manifest.components
    .filter((component) => component.default || component.adapters.some((adapter) => selectedSet.has(adapter)) || requestedSet.has(component.id))
    .map((component) => component.id)
    .sort();
  const componentSet = new Set(selectedComponents);
  const plannedAssets = [];

  for (const asset of manifest.assets.filter((item) => componentSet.has(item.component)).sort((left, right) => left.asset_id.localeCompare(right.asset_id, "en"))) {
    let currentBytes = null;
    let targetBytes = null;
    let unsafe = false;
    try { currentBytes = await inspectFile(projectRoot, asset.destination); }
    catch (error) {
      diagnostics.push(diagnostic("HKT412", asset.destination, `Unsafe managed destination: ${error.message}`));
      unsafe = true;
    }
    if (asset.source !== null) {
      try { targetBytes = await inspectFile(templatesRoot, asset.source); }
      catch (error) {
        diagnostics.push(diagnostic("HKT413", asset.source, `Unsafe or missing manifest source: ${error.message}`));
        unsafe = true;
      }
      if (targetBytes === null) {
        diagnostics.push(diagnostic("HKT413", asset.source, "Manifest source is missing."));
        unsafe = true;
      }
    }

    let disposition;
    const provenance = installedAssets.has(asset.asset_id) ? "recorded"
      : asset.ownership === "generated" ? "not-applicable" : "unrecorded";
    if (unsafe) disposition = "preserve";
    else if (asset.ownership === "user-owned") disposition = "preserve";
    else if (asset.update_strategy === "preserve") disposition = "preserve";
    else if (asset.update_strategy === "regenerate" && asset.ownership === "generated") disposition = "regenerate";
    else if (asset.update_strategy === "structured-merge" && asset.ownership === "shared-merge") disposition = "merge";
    else if (currentBytes === null) disposition = "create";
    else if (targetBytes !== null && currentBytes.equals(targetBytes)) disposition = "current";
    else if (asset.update_strategy === "three-way" && asset.ownership === "template-managed") disposition = provenance === "recorded" ? "replace" : "replace-candidate";
    else disposition = "preserve";

    plannedAssets.push({
      asset_id: asset.asset_id,
      destination: asset.destination,
      ownership: asset.ownership,
      provenance,
      disposition,
      current_hash: currentBytes === null ? null : hash(currentBytes),
      target_hash: targetBytes === null ? null : hash(targetBytes)
    });
  }

  for (const asset of manifest.assets.filter((item) => !componentSet.has(item.component) && installedAssets.has(item.asset_id)).sort((left, right) => left.asset_id.localeCompare(right.asset_id, "en"))) {
    const installed = installedAssets.get(asset.asset_id);
    let currentBytes = null;
    let unsafe = false;
    try { currentBytes = await inspectFile(projectRoot, asset.destination); }
    catch (error) {
      diagnostics.push(diagnostic("HKT412", asset.destination, `Unsafe managed destination: ${error.message}`));
      unsafe = true;
    }
    const currentHash = currentBytes === null ? null : hash(currentBytes);
    const unmodified = currentHash !== null && installed.destination_hash !== null && currentHash === installed.destination_hash;
    let disposition = "preserve";
    if (!unsafe && unmodified && ["remove-if-unmodified", "remove-if-generated"].includes(asset.remove_strategy)) disposition = "remove";
    else if (!unsafe && currentBytes !== null && asset.remove_strategy === "remove-contribution") disposition = "merge";
    else if (!unsafe && currentBytes !== null && asset.remove_strategy === "archive") disposition = "remove";
    plannedAssets.push({
      asset_id: asset.asset_id,
      destination: asset.destination,
      ownership: asset.ownership,
      provenance: "recorded",
      disposition,
      current_hash: currentHash,
      target_hash: null
    });
  }

  plannedAssets.sort((left, right) => left.asset_id.localeCompare(right.asset_id, "en"));

  const plan = {
    schema_version: 1,
    manifest_version: manifest.manifest_version,
    selected_adapters: selectedAdapters,
    selected_components: selectedComponents,
    assets: plannedAssets,
    diagnostics
  };
  const planDiagnostics = validateSchema("plan", plan, "install-plan.json").map(({ severity: _severity, ...item }) => item);
  return planDiagnostics.length ? { plan: null, diagnostics: [...diagnostics, ...planDiagnostics] } : { plan, diagnostics };
}
