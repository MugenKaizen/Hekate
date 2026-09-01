import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { mkdir, mkdtemp, readFile } from "node:fs/promises";
import { execFile } from "node:child_process";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { DEFAULT_ROLES, executePiChild, processTreeTermination, runSubagents } from "../src/index.js";

const execFileAsync = promisify(execFile);

async function linkedWorktree(branch) {
  const root = await mkdtemp(path.join(tmpdir(), "hekate-writer-"));
  const worktree = `${root}-${branch}`;
  await execFileAsync("git", ["init", root]);
  await execFileAsync("git", ["-C", root, "-c", "user.name=Hekate Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-m", "initial"]);
  await execFileAsync("git", ["-C", root, "worktree", "add", "-b", branch, worktree]);
  return { root, worktree, leasePath: path.join(worktree, ".workflow", "leases", "writer") };
}

function alive(pid) {
  try { process.kill(pid, 0); return true; } catch { return false; }
}

async function waitFor(predicate, timeoutMs = 5_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return true;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  return false;
}

const HANG = "process.on('SIGTERM', () => {}); setInterval(() => {}, 1000);";

function grandparentProgram(pidFile) {
  return [
    "const { spawn } = require('node:child_process');",
    "const { writeFileSync, renameSync } = require('node:fs');",
    `const grandchild = spawn(process.execPath, ['-e', ${JSON.stringify(HANG)}], { stdio: 'ignore' });`,
    `writeFileSync(${JSON.stringify(`${pidFile}.tmp`)}, String(grandchild.pid));`,
    `renameSync(${JSON.stringify(`${pidFile}.tmp`)}, ${JSON.stringify(pidFile)});`,
    HANG
  ].join("\n");
}

test("subagents reject recursion, excessive tasks, and advisory mutation", async () => {
  const execute = async () => ({ ok: true });
  await assert.rejects(() => runSubagents([{ role: "researcher" }], { execute, depth: 1 }), { code: "HKT801" });
  await assert.rejects(() => runSubagents(Array(9).fill({ role: "researcher" }), { execute, maxTasks: 8 }), { code: "HKT803" });
  await assert.rejects(() => runSubagents([{ role: "reviewer", write: true }], { execute }), { code: "HKT806" });
  const mutationTools = new Set(["bash", "powershell", "edit", "write"]);
  for (const role of Object.values(DEFAULT_ROLES).filter((candidate) => !candidate.writable)) {
    assert.ok(role.tools.every((tool) => !mutationTools.has(tool)));
  }
});

test("bounded parallel children return review-pending structured evidence", async () => {
  let active = 0;
  let peak = 0;
  const execute = async ({ depth, tools }) => {
    active += 1;
    peak = Math.max(peak, active);
    await new Promise((resolve) => setTimeout(resolve, 10));
    active -= 1;
    assert.equal(depth, 1);
    assert.ok(!tools.includes("write"));
    return { ok: true, output: "x".repeat(20), usage: { tokens: 4 }, details: { complete: true } };
  };
  const results = await runSubagents(Array(4).fill({ role: "researcher" }), { execute, concurrency: 2, outputLimit: 8 });
  assert.equal(peak, 2);
  assert.ok(results.every((result) => result.status === "review_pending" && result.truncated && result.output.length === 8));
  assert.deepEqual(results[0].usage, { tokens: 4 });
});

test("aggregate usage budgets fail closed", async () => {
  await assert.rejects(() => runSubagents([
    { role: "researcher", cwd: process.cwd() },
    { role: "researcher", cwd: process.cwd() }
  ], {
    concurrency: 1,
    maxTokens: 5,
    execute: async () => ({ ok: true, usage: { tokens: 6 } })
  }), { code: "HKT808" });
  await assert.rejects(() => runSubagents([{ role: "researcher", cwd: process.cwd() }], {
    maxCost: 0.5,
    execute: async () => ({ ok: true, usage: { input: 1, cacheRead: 2, cost: { total: 0.75 } } })
  }), { code: "HKT808" });
});

test("finite aggregate budgets serialize dispatch and Unicode truncates by byte", async () => {
  let active = 0;
  let peak = 0;
  const results = await runSubagents(Array(2).fill({ role: "researcher", cwd: process.cwd() }), {
    concurrency: 2,
    maxTokens: 100,
    outputLimit: 5,
    execute: async () => {
      active += 1;
      peak = Math.max(peak, active);
      await new Promise((resolve) => setTimeout(resolve, 5));
      active -= 1;
      return { ok: true, output: "ééé", usage: { input: 1, output: 1, cacheRead: 1 } };
    }
  });
  assert.equal(peak, 1);
  assert.equal(Buffer.byteLength(results[0].output), 4);
  assert.equal(results[0].truncated, true);
});

test("process-tree termination plans cover POSIX and Windows", () => {
  assert.deepEqual(processTreeTermination("linux", 42), { pid: -42, signal: "SIGTERM" });
  assert.deepEqual(processTreeTermination("linux", 42, true), { pid: -42, signal: "SIGKILL" });
  assert.deepEqual(processTreeTermination("win32", 42, true), { command: "taskkill", args: ["/pid", "42", "/T", "/F"] });
});

test("writer requires a dedicated worktree and holds an exclusive lease only while its child runs", async () => {
  const { root, worktree, leasePath } = await linkedWorktree("writer-test");
  await assert.rejects(() => runSubagents([{ role: "writer", cwd: root, write: true }], { parentCwd: root, execute: async () => ({ ok: true }) }), { code: "HKT802" });
  assert.equal(existsSync(leasePath), false);
  let heldDuringChild = null;
  let intruder = null;
  const results = await runSubagents([{ role: "writer", cwd: worktree, write: true }], {
    parentCwd: root,
    execute: async () => {
      heldDuringChild = existsSync(leasePath);
      intruder = await runSubagents([{ role: "writer", cwd: worktree, write: true }], {
        parentCwd: root,
        execute: async () => ({ ok: true })
      }).then(() => null, (error) => error);
      return { ok: true, output: "changed" };
    }
  });
  assert.equal(heldDuringChild, true);
  assert.equal(intruder?.code, "HKT807");
  assert.equal(results[0].status, "review_pending");
  assert.equal(existsSync(leasePath), false);
  await mkdir(leasePath);
});

test("racing writers contend for one lease and the loser is rejected", async () => {
  const { root, worktree, leasePath } = await linkedWorktree("writer-race");
  let holders = 0;
  let peakHolders = 0;
  const race = runSubagents([
    { role: "writer", cwd: worktree, write: true },
    { role: "writer", cwd: worktree, write: true }
  ], {
    parentCwd: root,
    concurrency: 2,
    execute: async () => {
      holders += 1;
      peakHolders = Math.max(peakHolders, holders);
      assert.equal(existsSync(leasePath), true);
      await new Promise((resolve) => setTimeout(resolve, 25));
      holders -= 1;
      return { ok: true, output: "changed" };
    }
  });
  await assert.rejects(() => race, { code: "HKT807" });
  // The loser's rejection can win the race against the holder entering its
  // child, so the invariant is that two writers never hold the lease at once.
  assert.ok(peakHolders <= 1, `two writers held the lease at once: ${peakHolders}`);
  assert.ok(await waitFor(() => !existsSync(leasePath)), "the winning writer never released its lease");
});

test("scheduler cancellation terminates the entire child process tree on POSIX", async (t) => {
  if (process.platform === "win32") {
    t.skip("POSIX-only: Windows uses the taskkill /T plan asserted by processTreeTermination");
    return;
  }
  const cwd = await mkdtemp(path.join(tmpdir(), "hekate-tree-"));
  const pidFile = path.join(cwd, "grandchild.pid");
  const controller = new AbortController();
  const run = runSubagents([{ role: "researcher", cwd }], {
    signal: controller.signal,
    execute: (task) => executePiChild(task, {
      command: process.execPath,
      commandArgs: ["-e", grandparentProgram(pidFile), "--"],
      timeoutMs: 10_000,
      terminateGraceMs: 25
    })
  });
  assert.ok(await waitFor(() => existsSync(pidFile)), "the child never reported its grandchild");
  const grandchild = Number(await readFile(pidFile, "utf8"));
  assert.ok(Number.isInteger(grandchild) && alive(grandchild));
  controller.abort();
  const results = await run;
  assert.equal(results[0].status, "failed");
  assert.equal(results[0].details.terminationReason, "aborted");
  try {
    assert.ok(await waitFor(() => !alive(grandchild)), "the grandchild survived process-tree cancellation");
  } finally {
    try { process.kill(grandchild, "SIGKILL"); } catch {}
  }
});

test("native denial or unavailability never spawns an external harness", async () => {
  const spawned = [];
  const spawnChild = (command, args) => { spawned.push({ command, args }); return { ok: true, output: "" }; };
  const execute = async (task) => spawnChild("pi", ["--mode", "json", "--no-session", "--tools", task.tools.join(",")]);
  const cwd = process.cwd();
  await assert.rejects(() => runSubagents([{ role: "designer", cwd }], { execute }), { code: "HKT805" });
  await assert.rejects(() => runSubagents([{ role: "reviewer", cwd, write: true }], { execute }), { code: "HKT806" });
  await assert.rejects(() => runSubagents([{ role: "writer", cwd }], { execute }), { code: "HKT806" });
  await assert.rejects(() => runSubagents([{ role: "writer", cwd, write: true }], { execute, parentCwd: cwd }), { code: "HKT802" });
  await assert.rejects(() => runSubagents([{ role: "researcher", cwd }], { execute, depth: 1 }), { code: "HKT801" });
  await assert.rejects(() => runSubagents([{ role: "researcher", cwd }], {}), { code: "HKT800" });
  assert.deepEqual(spawned, []);
  await runSubagents([{ role: "researcher", cwd }], { execute });
  const external = /^(claude|codex|aider|opencode|gemini|cursor-agent|hekate-agent)(\.\w+)?$/;
  assert.equal(spawned.length, 1);
  assert.ok(spawned.every((call) => call.command === "pi" && !external.test(path.basename(call.command))));
});

test("Pi child transport uses JSON mode, a strict tool allowlist, and private prompt indirection", async () => {
  const fixture = fileURLToPath(new URL("./fake-pi-child.js", import.meta.url));
  const result = await executePiChild({
    cwd: path.dirname(fixture),
    prompt: "private task body",
    tools: ["read", "grep"]
  }, { command: process.execPath, commandArgs: [fixture], timeoutMs: 5_000 });
  assert.equal(result.ok, true);
  const event = JSON.parse(result.output.trim());
  assert.deepEqual(event.message.usage, { input: 3, output: 2, cost: { total: 0.01 } });
  assert.deepEqual(result.usage, { input: 3, output: 2, cacheRead: 0, cacheWrite: 0, tokens: 0, cost: { total: 0.01 } });
  assert.deepEqual(event.args.slice(0, 7), ["--mode", "json", "--no-session", "--no-context-files", "--tools", "read,grep", event.args[6]]);
  assert.match(event.args[6], /^@.*prompt\.md$/);
  assert.doesNotMatch(event.args.join(" "), /private task body/);
});

test("Pi child transport bounds output and escalates ignored termination", async () => {
  const fixture = fileURLToPath(new URL("./fake-pi-child.js", import.meta.url));
  const cwd = path.dirname(fixture);
  const overflow = await executePiChild({ cwd, prompt: "task", tools: ["read"] }, {
    command: process.execPath,
    commandArgs: [fixture, "--overflow"],
    outputLimit: 128,
    timeoutMs: 5_000,
    terminateGraceMs: 25
  });
  assert.equal(Buffer.byteLength(overflow.output), 128);
  assert.equal(overflow.details.transportTruncated, true);
  assert.equal(overflow.details.terminationReason, "output_limit");
  assert.ok(overflow.details.outputBytes > 128);

  if (process.platform !== "win32") {
    const timedOut = await executePiChild({ cwd, prompt: "task", tools: ["read"] }, {
      command: process.execPath,
      commandArgs: [fixture, "--hang"],
      timeoutMs: 100,
      terminateGraceMs: 25
    });
    assert.equal(timedOut.ok, false);
    assert.equal(timedOut.details.signal, "SIGKILL");
    assert.equal(timedOut.details.terminationReason, "timeout");

    const controller = new AbortController();
    controller.abort();
    const aborted = await executePiChild({ cwd, prompt: "task", tools: ["read"], signal: controller.signal }, {
      command: process.execPath,
      commandArgs: [fixture, "--hang"],
      timeoutMs: 5_000,
      terminateGraceMs: 25
    });
    assert.equal(aborted.details.terminationReason, "aborted");
  }
});
