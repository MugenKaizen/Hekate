import assert from "node:assert/strict";
import { cp, lstat, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import test from "node:test";

const repositoryRoot = fileURLToPath(new URL("../", import.meta.url));
const workspaceNames = ["@hekate/core", "@hekate/subagents", "@hekate/pi-extension", "@hekate/cli"];
const bun = Boolean(process.versions.bun);

function run(command, args, cwd, timeout = 120_000) {
  return spawnSync(command, args, { cwd, encoding: "utf8", timeout });
}

function assertSucceeded(result, context) {
  assert.equal(result.status, 0, `${context}\nstdout:\n${result.stdout}\nstderr:\n${result.stderr}`);
}

function runCli(cli, args, cwd) {
  return run(process.execPath, [cli, ...args], cwd);
}

function packWorkspace(workspace, tarballRoot) {
  if (!bun) return run("npm", ["pack", `--workspace=${workspace}`, `--pack-destination=${tarballRoot}`, "--json"], repositoryRoot);
  const packageName = workspace.slice("@hekate/".length);
  return run("bun", ["pm", "pack", "--destination", tarballRoot, "--quiet"], path.join(repositoryRoot, "packages", packageName));
}

test("published workspace tarballs install and run outside the monorepo", { timeout: 300_000 }, async (t) => {
  const sandbox = await mkdtemp(path.join(tmpdir(), "hekate-package-smoke-"));
  t.after(() => rm(sandbox, { recursive: true, force: true }));
  const tarballRoot = path.join(sandbox, "tarballs");
  const consumerRoot = path.join(sandbox, "consumer");
  const absentRoot = path.join(sandbox, "absent");
  const projectRoot = path.join(sandbox, "project");
  await Promise.all([
    mkdir(tarballRoot),
    mkdir(consumerRoot),
    mkdir(absentRoot),
    cp(path.join(repositoryRoot, "packages/core/test/fixtures/historical/v0.2.0-beta.1/input"), projectRoot, { recursive: true })
  ]);

  const tarballs = [];
  const rootPackage = JSON.parse(await readFile(path.join(repositoryRoot, "package.json"), "utf8"));
  for (const workspace of workspaceNames) {
    const packageName = workspace.slice("@hekate/".length);
    const manifest = JSON.parse(await readFile(path.join(repositoryRoot, "packages", packageName, "package.json"), "utf8"));
    assert.equal(manifest.version, rootPackage.version, `${workspace} version must match the release version`);
    for (const [dependency, version] of Object.entries(manifest.dependencies ?? {})) {
      if (dependency.startsWith("@hekate/")) assert.equal(version, rootPackage.version, `${workspace} must pin ${dependency} to the release version`);
    }
    const packed = packWorkspace(workspace, tarballRoot);
    assertSucceeded(packed, `packing ${workspace}`);
    const filename = bun
      ? packed.stdout.split("\n").map((line) => line.trim()).findLast((line) => line.endsWith(".tgz"))
      : JSON.parse(packed.stdout)[0].filename;
    assert.ok(filename, `packing ${workspace} did not report a tarball`);
    const tarball = path.isAbsolute(filename) ? filename : path.join(tarballRoot, filename);
    const inventory = run("tar", ["-tf", tarball], repositoryRoot);
    assertSucceeded(inventory, `inspecting ${workspace} tarball`);
    assert.match(inventory.stdout, /(?:^|\n)package\/README\.md(?:\n|$)/);
    assert.match(inventory.stdout, /(?:^|\n)package\/LICENSE(?:\n|$)/);
    tarballs.push(tarball);
  }

  const consumerPackage = { name: "hekate-package-smoke", private: true };
  if (bun) {
    consumerPackage.dependencies = Object.fromEntries(workspaceNames.map((workspace, index) => [workspace, `file:${tarballs[index]}`]));
    // Bun resolves exact transitive package names before considering sibling
    // tarballs, so unpublished release candidates need explicit local overrides.
    consumerPackage.overrides = { ...consumerPackage.dependencies };
  }
  await writeFile(path.join(consumerRoot, "package.json"), `${JSON.stringify(consumerPackage)}\n`);
  const installed = bun
    ? run("bun", ["install", "--ignore-scripts", "--omit=optional"], consumerRoot, 300_000)
    : run("npm", ["install", "--ignore-scripts", "--omit=optional", "--no-audit", "--no-fund", ...tarballs], consumerRoot, 300_000);
  assertSucceeded(installed, "installing packed workspaces");
  for (const workspace of workspaceNames) {
    assert.equal((await lstat(path.join(consumerRoot, "node_modules", ...workspace.split("/")))).isSymbolicLink(), false);
  }

  const cli = path.join(consumerRoot, "node_modules/@hekate/cli/bin/hekate.js");
  const absent = runCli(cli, ["check", "--json"], absentRoot);
  assertSucceeded(absent, "running installed check");
  assert.equal(JSON.parse(absent.stdout).gate_state, "absent");

  const upgraded = runCli(cli, ["upgrade", `--to=${rootPackage.version}`, "--force", "--yes", "--json", `--target=${projectRoot}`], consumerRoot);
  assertSucceeded(upgraded, "running installed upgrade with packaged payload");
  const upgradeResult = JSON.parse(upgraded.stdout);
  assert.equal(upgradeResult.ok, true);
  assert.equal(JSON.parse(await readFile(path.join(projectRoot, ".workflow/install-state.json"), "utf8")).source_release, rootPackage.version);

  const rolledBack = runCli(cli, ["rollback", `--transaction=${upgradeResult.transaction_id}`, "--yes", "--json", `--target=${projectRoot}`], consumerRoot);
  assertSucceeded(rolledBack, "running installed rollback");
  assert.equal(JSON.parse(rolledBack.stdout).rolled_back, true);

  const cleaned = runCli(cli, ["cleanup", `--transaction=${upgradeResult.transaction_id}`, "--yes", "--json", `--target=${projectRoot}`], consumerRoot);
  assertSucceeded(cleaned, "running installed cleanup");
  assert.equal(JSON.parse(cleaned.stdout).cleaned, true);

  const unavailableAgent = runCli(cli, ["agent", "--invalid"], consumerRoot);
  assert.equal(unavailableAgent.status, 2);
  assert.match(unavailableAgent.stderr, /^HKT950: Pi agent runtime is unavailable:/);

  if (process.env.HEKATE_PACKAGE_SMOKE_PI === "1") {
    const piVersion = rootPackage.devDependencies["@earendil-works/pi-coding-agent"];
    const installedPi = bun
      ? run("bun", ["add", "--ignore-scripts", "--no-save", `@earendil-works/pi-coding-agent@${piVersion}`], consumerRoot, 300_000)
      : run("npm", ["install", "--ignore-scripts", "--no-audit", "--no-fund", `@earendil-works/pi-coding-agent@${piVersion}`], consumerRoot, 300_000);
    assertSucceeded(installedPi, "installing the optional Pi runtime");
    const availableAgent = runCli(cli, ["agent", "--invalid"], consumerRoot);
    assert.equal(availableAgent.status, 2);
    assert.doesNotMatch(availableAgent.stderr, /HKT950/);
    assert.match(availableAgent.stderr, /^usage:/);
  }
});
