import { execFileSync } from "node:child_process";
import { mkdir, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { importLegacyProject } from "../src/index.js";

const repositoryRoot = fileURLToPath(new URL("../../../", import.meta.url));
const fixturesRoot = fileURLToPath(new URL("./fixtures/historical/", import.meta.url));
const releases = ["v0.1.0-beta.1", "v0.2.0-beta.1"];
const files = [
  "workflow.yml",
  "stack.yml",
  "architecture.yml",
  "conventions.yml",
  "presets.yml",
  "status.yml",
  "orchestration.yml",
  "session.local.yml"
];

function git(...args) {
  return execFileSync("git", args, { cwd: repositoryRoot, stdio: ["ignore", "pipe", "pipe"] });
}

await mkdir(fixturesRoot, { recursive: true });
for (const release of releases) {
  const fixtureRoot = path.join(fixturesRoot, release);
  const workflowRoot = path.join(fixtureRoot, "input", ".workflow");
  await rm(fixtureRoot, { recursive: true, force: true });
  await mkdir(workflowRoot, { recursive: true });
  const included = [];
  for (const file of files) {
    try {
      const bytes = git("show", `${release}:templates/.workflow/${file}`);
      await writeFile(path.join(workflowRoot, file), bytes);
      included.push(`.workflow/${file}`);
    } catch (error) {
      if (error.status !== 128) throw error;
    }
  }
  const imported = await importLegacyProject({ root: path.join(fixtureRoot, "input") });
  if (imported.diagnostics.length || !imported.importBytes || !imported.reportBytes) {
    throw new Error(`${release} import failed: ${JSON.stringify(imported.diagnostics)}`);
  }
  await writeFile(path.join(fixtureRoot, "import.json"), imported.importBytes);
  await writeFile(path.join(fixtureRoot, "report.json"), imported.reportBytes);
  const metadata = {
    schema_version: 1,
    release,
    commit: git("rev-list", "-n", "1", release).toString("utf8").trim(),
    files: included
  };
  await writeFile(path.join(fixtureRoot, "fixture.json"), `${JSON.stringify(metadata, null, 2)}\n`);
}
