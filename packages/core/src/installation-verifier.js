import { createHash } from "node:crypto";
import { constants } from "node:fs";
import { lstat, open, realpath } from "node:fs/promises";
import path from "node:path";
import { canonicalBytes } from "./canonical-json.js";
import { compileProject } from "./compiler.js";
import { loadInstalledState, validateManifestRelations } from "./install-planner.js";
import { validateMigrationReport } from "./legacy-importer.js";
import { parseYaml } from "./parser.js";
import { validateSchema } from "./validator.js";

function diagnostic(code, file, message, pathValue = "") {
  return { code, severity: "error", file, path: pathValue, message };
}

function digest(bytes) {
  return `sha256:${createHash("sha256").update(bytes).digest("hex")}`;
}

async function readSafe(root, relative) {
  const parts = relative.split("/");
  let current = root;
  for (const [index, part] of parts.entries()) {
    current = path.join(current, part);
    const metadata = await lstat(current);
    if (metadata.isSymbolicLink()) throw new Error("path contains a symbolic link");
    if (index < parts.length - 1 && !metadata.isDirectory()) throw new Error("path parent is not a directory");
    if (index === parts.length - 1 && !metadata.isFile()) throw new Error("path is not a regular file");
  }
  const handle = await open(current, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0));
  try { return await handle.readFile(); }
  finally { await handle.close(); }
}

function sameValues(actual, expected) {
  return actual.length === expected.length && actual.every((value, index) => value === expected[index]);
}

export async function verifyInstalledProject({ root, sourceRoot, manifest, expectedAdapters = [], expectedComponents = [], targetRelease = null, imported = null, report = null }) {
  const diagnostics = validateSchema("manifest", manifest, "install-manifest.json");
  if (diagnostics.length === 0) diagnostics.push(...validateManifestRelations(manifest).map((item) => ({ severity: "error", ...item })));
  if (!Array.isArray(expectedAdapters)) diagnostics.push(diagnostic("HKT470", "adapters", "Expected adapters must be an array."));
  if ((imported === null) !== (report === null)) diagnostics.push(diagnostic("HKT470", "migration", "Imported values and preservation report must be supplied together."));
  if (diagnostics.length) return { ok: false, diagnostics };

  let projectRoot;
  let templatesRoot;
  try {
    projectRoot = await realpath(root);
    templatesRoot = await realpath(sourceRoot);
  } catch (error) {
    return { ok: false, diagnostics: [diagnostic("HKT470", "root", `Cannot resolve verification root: ${error.message}`)] };
  }
  const adapters = [...new Set(expectedAdapters)].sort();
  if (adapters.length !== expectedAdapters.length || adapters.some((adapter) => !manifest.adapters.includes(adapter))) {
    diagnostics.push(diagnostic("HKT471", "adapters", "Expected adapters are unknown or duplicated."));
  }
  // Opt-in components are requested by name and belong to the expected set.
  const requestedComponents = new Set(expectedComponents);
  const selected = manifest.components
    .filter((component) => component.default
      || component.adapters.some((adapter) => adapters.includes(adapter))
      || (!component.default && component.adapters.length === 0 && requestedComponents.has(component.id)))
    .map((component) => component.id)
    .sort();
  const selectedSet = new Set(selected);

  const loaded = await loadInstalledState(projectRoot, manifest);
  diagnostics.push(...loaded.diagnostics.map((item) => ({ severity: "error", ...item })));
  const state = loaded.state;
  if (!state && loaded.diagnostics.length === 0) diagnostics.push(diagnostic("HKT472", ".workflow/install-state.json", "Installed state is missing."));
  if (state) {
    if (state.manifest_version !== manifest.manifest_version) diagnostics.push(diagnostic("HKT472", ".workflow/install-state.json", "Installed state manifest version is not current.", "/manifest_version"));
    if (targetRelease !== null && state.source_release !== targetRelease) diagnostics.push(diagnostic("HKT472", ".workflow/install-state.json", "Installed state release does not match the transaction target.", "/source_release"));
    if (!sameValues(state.selected_adapters, adapters)) diagnostics.push(diagnostic("HKT472", ".workflow/install-state.json", "Installed adapters do not match the requested adapters.", "/selected_adapters"));
    if (!sameValues(state.selected_components, selected)) diagnostics.push(diagnostic("HKT472", ".workflow/install-state.json", "Installed components do not match the requested adapters and components.", "/selected_components"));
    const expectedAssets = manifest.assets.filter((asset) => selectedSet.has(asset.component)).map((asset) => asset.asset_id).sort();
    const stateAssets = state.assets.map((asset) => asset.asset_id).sort();
    if (!sameValues(stateAssets, expectedAssets)) diagnostics.push(diagnostic("HKT472", ".workflow/install-state.json", "Installed asset ledger is incomplete or contains unselected assets.", "/assets"));
    for (const [index, asset] of state.assets.entries()) {
      const manifestAsset = manifest.assets.find((item) => item.asset_id === asset.asset_id);
      if (manifestAsset?.source !== null && asset.installed_source_hash === null) diagnostics.push(diagnostic("HKT473", ".workflow/install-state.json", "Installed source hash is missing from the ownership ledger.", `/assets/${index}/installed_source_hash`));
      if (asset.destination_hash === null) {
        if (manifestAsset && manifestAsset.destination !== ".workflow/install-state.json" && manifestAsset.ownership !== "user-owned") diagnostics.push(diagnostic("HKT473", ".workflow/install-state.json", "Installed destination hash is missing from the ownership ledger.", `/assets/${index}/destination_hash`));
        continue;
      }
      try {
        const bytes = await readSafe(projectRoot, asset.destination);
        if (digest(bytes) !== asset.destination_hash) diagnostics.push(diagnostic("HKT473", asset.destination, "Installed asset bytes do not match the ownership ledger.", `/assets/${index}/destination_hash`));
      } catch (error) {
        diagnostics.push(diagnostic("HKT473", asset.destination, `Cannot verify installed asset: ${error.message}`, `/assets/${index}/destination`));
      }
    }
  }

  const compiler = await compileProject({ root: projectRoot, mode: "check" });
  const safelyGatedInstallation = (imported !== null || state !== null)
    && compiler.lockStatus === "current"
    && ["off", "workflow_disabled", "needs_configuration", "needs_confirmation"].includes(compiler.gateState);
  if (!compiler.ok && !safelyGatedInstallation) diagnostics.push(...(compiler.diagnostics.length ? compiler.diagnostics : [diagnostic("HKT474", ".workflow/status.lock.json", "Compiler check did not reach an accepted current state.")]));

  if (imported !== null) {
    const importDiagnostics = validateSchema("legacy-import", imported, "import.json");
    const reportDiagnostics = validateMigrationReport(report);
    diagnostics.push(...importDiagnostics, ...reportDiagnostics);
    if (importDiagnostics.length === 0 && reportDiagnostics.length === 0) {
      if (report.entries.some((entry) => entry.critical && entry.disposition === "unresolved")) diagnostics.push(diagnostic("HKT475", "report.json", "Critical legacy settings remain unresolved.", "/entries"));
      if (!sameValues(imported.selected_adapters, adapters)) diagnostics.push(diagnostic("HKT475", "import.json", "Imported adapters do not match the requested adapters.", "/selected_adapters"));
      for (const [relative, expected, kind] of [[".workflow/config.yml", imported.config, "config"], [".workflow/project.yml", imported.project, "project"]]) {
        try {
          const parsed = parseYaml(await readSafe(projectRoot, relative), relative);
          diagnostics.push(...parsed.diagnostics);
          if (parsed.value) {
            diagnostics.push(...validateSchema(kind, parsed.value, relative));
            const comparableExpected = structuredClone(expected);
            if (kind === "project") comparableExpected.confirmation = structuredClone(parsed.value.confirmation);
            if (!canonicalBytes(parsed.value).equals(canonicalBytes(comparableExpected))) diagnostics.push(diagnostic("HKT475", relative, "Migrated target does not preserve the normalized imported values."));
          }
        } catch (error) {
          diagnostics.push(diagnostic("HKT475", relative, `Cannot verify migrated target: ${error.message}`));
        }
      }
    }
  }

  const gitignoreAsset = manifest.assets.find((asset) => selectedSet.has(asset.component) && asset.destination === ".gitignore" && asset.ownership === "shared-merge");
  if (gitignoreAsset) {
    try {
      const required = (await readSafe(templatesRoot, gitignoreAsset.source)).toString("utf8").split(/\r?\n/).map((line) => line.trim()).filter((line) => line && !line.startsWith("#"));
      const actual = new Set((await readSafe(projectRoot, ".gitignore")).toString("utf8").split(/\r?\n/).map((line) => line.trim()).filter(Boolean));
      if (required.some((line) => !actual.has(line))) diagnostics.push(diagnostic("HKT476", ".gitignore", "Required Hekate local-artifact ignore entries are missing."));
    } catch (error) {
      diagnostics.push(diagnostic("HKT476", ".gitignore", `Cannot verify local-artifact ignore rules: ${error.message}`));
    }
  }

  return { ok: diagnostics.length === 0, compiler, state, diagnostics };
}
