import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");

function lexicalUpperBound(text) {
  return text.match(/\p{L}+|\p{N}+|[^\s\p{L}\p{N}]/gu)?.length ?? 0;
}

async function text(relativePath) {
  return readFile(path.join(root, relativePath), "utf8");
}

function promptVisible(relativePath, content) {
  // YAML adapter configuration reaches the model only through its data, not its
  // comment lines; Markdown adapters reach it in full.
  if (/\.ya?ml$/.test(relativePath)) {
    return content.split(/\r?\n/).filter((line) => !/^\s*#/.test(line)).join("\n");
  }
  return content;
}

function frontMatter(content) {
  const match = /^---\r?\n([\s\S]*?)\r?\n---/.exec(content);
  return match ? match[1] : "";
}

test("portable prompt surface stays within deterministic context budgets", async () => {
  const agents = await text("templates/AGENTS.md");
  assert.ok(lexicalUpperBound(agents) <= 1000, "AGENTS.md exceeds its 1,000-token lexical upper bound");

  // Every file the portable preflight in AGENTS.md requires before any task.
  const alwaysLoaded = [agents];
  for (const preflightFile of ["templates/.workflow/status.yml", "templates/.workflow/workflow.yml"]) {
    alwaysLoaded.push(await text(preflightFile));
  }
  assert.ok(
    lexicalUpperBound(alwaysLoaded.join("\n")) <= 1500,
    "normal instructions and preflight state exceed 1,500 lexical units"
  );
});

test("every installed adapter stays within its 100-unit overhead budget", async () => {
  const manifest = JSON.parse(await text("distribution/install-manifest.json"));
  const adapterComponents = new Set(manifest.adapters);
  const adapterAssets = manifest.assets.filter(
    (asset) => adapterComponents.has(asset.component) && !asset.destination.includes("/skills/")
  );
  const overhead = adapterAssets.filter((asset) => !/\/(commands|prompts)\//.test(asset.destination));
  assert.ok(overhead.length >= 5, "adapter overhead budget covers no adapters");

  for (const asset of overhead) {
    const content = await text(asset.source);
    const visible = promptVisible(asset.source, content);
    assert.ok(
      lexicalUpperBound(visible) <= 100,
      `${asset.source} exceeds 100 lexical units of adapter overhead`
    );
    assert.match(content, /AGENTS\.md/);
    assert.doesNotMatch(content, /## Adaptive Workflow|## Tests And Evidence|## Scope Control/);
  }
});

test("installed skill metadata stays within 100 units per skill", async () => {
  const manifest = JSON.parse(await text("distribution/install-manifest.json"));
  const skillAssets = manifest.assets.filter((asset) => asset.destination.endsWith("/SKILL.md"));
  assert.ok(skillAssets.length > 0, "no installed skills found");
  for (const asset of skillAssets) {
    const metadata = frontMatter(await text(asset.source));
    assert.ok(metadata.length > 0, `${asset.source} has no skill metadata block`);
    assert.ok(
      lexicalUpperBound(metadata) <= 100,
      `${asset.source} metadata exceeds 100 lexical units`
    );
  }
});

test("default adapter components install only narrow on-demand skills", async () => {
  const manifest = JSON.parse(await text("distribution/install-manifest.json"));
  const skillAssets = manifest.assets.filter((asset) => asset.destination.includes("/skills/"));
  assert.deepEqual([...new Set(skillAssets.map((asset) => path.basename(path.dirname(asset.destination))))], ["workflow"]);
  assert.ok(skillAssets.every((asset) => !asset.component.startsWith("core")));

  const snippet = await text("templates/gitignore.snippet");
  for (const localPath of [".workflow/history/", ".workflow/backups/", ".workflow/migration/", ".workflow/transactions/", ".workflow/update.lock", ".workflow/runs/"]) {
    assert.ok(snippet.split(/\r?\n/).includes(localPath), `missing local artifact exclusion: ${localPath}`);
  }
});

test("Pi adapter uses generic prompts and never owns project settings", async () => {
  const manifest = JSON.parse(await text("distribution/install-manifest.json"));
  assert.ok(manifest.adapters.includes("pi"));
  const piAssets = manifest.assets.filter((asset) => asset.component === "pi");
  assert.deepEqual(piAssets.map((asset) => asset.destination).sort(), [
    ".pi/prompts/analyze.md",
    ".pi/prompts/init-workflow.md",
    ".pi/prompts/plan.md"
  ]);
  assert.ok(piAssets.every((asset) => asset.source.startsWith("templates/prompts/")));
  assert.ok(manifest.assets.every((asset) => asset.destination !== ".pi/settings.json"));
  assert.equal(manifest.assets.find((asset) => asset.asset_id === "claude-command-analyze").source, "templates/prompts/analyze.md");
});

test("pinned Pi package exposes the documented runtime APIs", async () => {
  const packageJson = JSON.parse(await text("package.json"));
  assert.equal(packageJson.devDependencies["@earendil-works/pi-coding-agent"], "0.84.4");
  const pi = await import("@earendil-works/pi-coding-agent");
  for (const exported of ["createAgentSessionRuntime", "InteractiveMode", "runPrintMode", "runRpcMode", "DefaultResourceLoader", "SettingsManager"]) {
    assert.ok(exported in pi, `pinned Pi is missing ${exported}`);
  }
});
