import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import test from "node:test";

const repositoryRoot = fileURLToPath(new URL("../../../", import.meta.url));

test("CLI package contains its transactional upgrade payload", () => {
  const bun = Boolean(process.versions.bun);
  const packed = spawnSync(bun ? "bun" : "npm", bun
    ? ["pm", "pack", "--dry-run"]
    : ["pack", "--workspace=@hekate/cli", "--dry-run", "--json"], {
    cwd: bun ? fileURLToPath(new URL("../", import.meta.url)) : repositoryRoot,
    encoding: "utf8",
    timeout: 120_000
  });
  assert.equal(packed.status, 0, `${packed.stdout}\n${packed.stderr}`);
  const files = bun
    ? new Set(packed.stdout.split("\n").map((line) => line.match(/^packed\s+\S+\s+(.+)$/)?.[1]).filter(Boolean))
    : new Set(JSON.parse(packed.stdout)[0].files.map(({ path }) => path));
  assert.ok(files.has("payload/distribution/install-manifest.json"));
  assert.ok(files.has("payload/templates/.workflow/config.yml"));
  assert.ok(files.has("payload/templates/AGENTS.md"));
  assert.ok(files.has("src/main.js"));
  assert.ok(files.has("bin/hekate.js"));
});
