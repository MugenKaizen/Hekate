import assert from "node:assert/strict";
import { mkdtemp, mkdir, readdir, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { compileProject } from "../src/index.js";
import { parseYaml } from "../src/parser.js";
import { validateSchema } from "../src/validator.js";

const repositoryRoot = new URL("../../../", import.meta.url);

const project = await readFile(new URL("templates/.workflow/project.yml", repositoryRoot), "utf8");

const readyProject = `schema_version: 1
identity:
  name: {state: known, value: Example}
  kind: {state: known, value: cli}
  description: {state: known, value: Example project}
stack:
  languages: {state: known, value: [{name: javascript, version: ES2023, package_manager: npm}]}
  frameworks: {state: known, value: []}
  runtimes: {state: known, value: [{name: node, version: "20"}]}
  dependencies: {state: known, value: []}
verification:
  format: {state: not_applicable}
  lint: {state: not_applicable}
  test: {state: known, value: [npm test]}
  build: {state: not_applicable}
  validate: {state: not_applicable}
architecture:
  references: {state: known, value: []}
  constraints: {state: known, value: []}
confirmation: {state: confirmed}
extensions: {}
`;

function configFor(workflow) {
  return `schema_version: 1
hekate: {enabled: true}
workflow: ${workflow}
policy:
  commit_consent: explicit-request-only
  destructive_actions: explicit-consent
  dependency_changes: explicit-consent
enforcement:
  configuration: block
  destructive_actions: confirm
  dependency_changes: confirm
  generated_lock: protect
extensions: {}
`;
}

async function compileWith(workflow, projectText = readyProject) {
  const root = await mkdtemp(path.join(tmpdir(), "hekate-policy-"));
  await mkdir(path.join(root, ".workflow"));
  await writeFile(path.join(root, ".workflow/config.yml"), configFor(workflow));
  await writeFile(path.join(root, ".workflow/project.yml"), projectText);
  const result = await compileProject({ root });
  let lock = null;
  try {
    lock = JSON.parse(await readFile(path.join(root, ".workflow/status.lock.json"), "utf8"));
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
  return { root, result, lock };
}

test("every released profile resolves to its golden policy", async () => {
  const golden = {
    fast: { tdd: { mode: "off" }, history: { enabled: false } },
    medium: { tdd: { mode: "prefer-test-first" }, history: { enabled: false } },
    full: { tdd: { mode: "require-test-evidence" }, history: { enabled: true } }
  };
  for (const [profile, expected] of Object.entries(golden)) {
    const { result, lock } = await compileWith(`{enabled: true, profile: ${profile}, overrides: {}}`);
    assert.equal(result.gateState, "ready", `${profile} did not reach ready`);
    assert.equal(lock.resolved_policy.profile, profile);
    assert.deepEqual(lock.resolved_policy.tdd, expected.tdd, `${profile} resolved unexpected TDD policy`);
    assert.deepEqual(lock.resolved_policy.history, expected.history, `${profile} resolved unexpected history policy`);
  }
});

test("narrow overrides replace only the keys they name", async () => {
  const { lock } = await compileWith("{enabled: true, profile: full, overrides: {history: {enabled: false}}}");
  assert.deepEqual(lock.resolved_policy.tdd, { mode: "require-test-evidence" }, "profile TDD policy was lost");
  assert.deepEqual(lock.resolved_policy.history, { enabled: false }, "history override was not applied");
});

test("custom profile requires both TDD and history overrides", async () => {
  for (const overrides of ["{}", "{tdd: {mode: off}}", "{history: {enabled: true}}"]) {
    const { result, lock } = await compileWith(`{enabled: true, profile: custom, overrides: ${overrides}}`);
    assert.equal(result.ok, false, `custom profile with overrides ${overrides} must not compile`);
    assert.equal(result.gateState, "invalid");
    assert.equal(result.diagnostics[0].code, "HKT202");
    assert.equal(result.diagnostics[0].path, "/workflow/overrides");
    assert.equal(lock, null, "an invalid custom profile must not write a lock");
  }

  const complete = await compileWith(
    "{enabled: true, profile: custom, overrides: {tdd: {mode: off}, history: {enabled: true}}}"
  );
  assert.equal(complete.result.gateState, "ready");
  assert.deepEqual(complete.lock.resolved_policy.tdd, { mode: "off" });
  assert.deepEqual(complete.lock.resolved_policy.history, { enabled: true });
});

test("every shipped authored template parses strictly", async () => {
  const directory = new URL("templates/.workflow/", repositoryRoot);
  const templates = (await readdir(directory)).filter((name) => name.endsWith(".yml"));
  assert.ok(templates.length > 0, "no shipped templates found");
  for (const name of templates) {
    const file = `.workflow/${name}`;
    const parsed = parseYaml(await readFile(new URL(name, directory)), file);
    assert.deepEqual(parsed.diagnostics, [], `${file} does not parse strictly`);
  }
});

test("authored templates match their schemas and stay unready until configured", async () => {
  for (const kind of ["config", "project"]) {
    const file = `.workflow/${kind}.yml`;
    const parsed = parseYaml(await readFile(new URL(`templates/${file}`, repositoryRoot)), file);
    assert.deepEqual(validateSchema(kind, parsed.value, file), []);
  }

  // The shipped project template answers nothing, so a fresh install must ask
  // for facts rather than report readiness.
  const { result } = await compileWith("{enabled: true, profile: medium, overrides: {}}", project);
  assert.equal(result.gateState, "needs_configuration");
});

test("readiness diagnostics are stable, ordered, and fully shaped", async () => {
  const unknownFacts = readyProject
    .replace("description: {state: known, value: Example project}", "description: {state: unknown}")
    .replace("dependencies: {state: known, value: []}", "dependencies: {state: unknown}")
    .replace("constraints: {state: known, value: []}", "constraints: {state: unknown}");
  const first = await compileWith("{enabled: true, profile: medium, overrides: {}}", unknownFacts);
  assert.deepEqual(first.result.diagnostics, [
    { code: "HKT210", severity: "error", file: ".workflow/project.yml", path: "/identity/description", message: "Required project fact is unknown." },
    { code: "HKT210", severity: "error", file: ".workflow/project.yml", path: "/stack/dependencies", message: "Required project fact is unknown." },
    { code: "HKT210", severity: "error", file: ".workflow/project.yml", path: "/architecture/constraints", message: "Required project fact is unknown." }
  ]);
  // The lock keeps the stable identity of each diagnostic and omits its
  // human-readable message, which is not part of the generated contract.
  assert.deepEqual(
    first.lock.gate.diagnostics,
    first.result.diagnostics.map(({ code, file, path: pathValue }) => ({ code, file, path: pathValue })),
    "the lock records different diagnostics than the caller sees"
  );

  const repeat = await compileWith("{enabled: true, profile: medium, overrides: {}}", unknownFacts);
  assert.deepEqual(repeat.result.diagnostics, first.result.diagnostics, "diagnostics are not deterministic");
});
