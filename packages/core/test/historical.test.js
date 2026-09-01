import assert from "node:assert/strict";
import { cp, mkdtemp, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { importLegacyProject } from "../src/index.js";

const fixturesRoot = new URL("./fixtures/historical/", import.meta.url);
const releases = [
  { release: "v0.1.0-beta.1", commit: "862cf69" },
  { release: "v0.2.0-beta.1", commit: "ee5ba34" }
];

for (const expected of releases) {
  test(`legacy importer matches ${expected.release} golden artifacts`, async () => {
    const fixtureRoot = new URL(`${expected.release}/`, fixturesRoot);
    const metadata = JSON.parse(await readFile(new URL("fixture.json", fixtureRoot), "utf8"));
    assert.equal(metadata.schema_version, 1);
    assert.equal(metadata.release, expected.release);
    assert.ok(metadata.commit.startsWith(expected.commit));
    assert.ok(metadata.files.includes(".workflow/orchestration.yml"));

    const root = await mkdtemp(path.join(tmpdir(), "hekate-historical-"));
    await cp(new URL("input/", fixtureRoot), root, { recursive: true });
    const imported = await importLegacyProject({ root });
    assert.deepEqual(imported.diagnostics, []);
    assert.deepEqual(imported.importBytes, await readFile(new URL("import.json", fixtureRoot)));
    assert.deepEqual(imported.reportBytes, await readFile(new URL("report.json", fixtureRoot)));
  });
}
