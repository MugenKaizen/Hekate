import { mkdir, readFile, realpath, rm } from "node:fs/promises";
import { spawn } from "node:child_process";
import { execFile } from "node:child_process";
import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

export const DEFAULT_ROLES = Object.freeze({
  researcher: { tools: ["read", "grep", "find", "ls"], writable: false },
  reviewer: { tools: ["read", "grep", "find", "ls"], writable: false },
  verifier: { tools: ["read", "grep", "find", "ls"], writable: false },
  writer: { tools: ["read", "grep", "find", "ls", "edit", "write", "bash"], writable: true }
});

export function processTreeTermination(platform, pid, force = false) {
  if (platform === "win32") return { command: "taskkill", args: ["/pid", String(pid), "/T", ...(force ? ["/F"] : [])] };
  return { pid: -pid, signal: force ? "SIGKILL" : "SIGTERM" };
}

function terminate(child, force = false) {
  if (child.exitCode !== null) return;
  if (child.pid) {
    const termination = processTreeTermination(process.platform, child.pid, force);
    if (termination.command) {
      const killer = spawn(termination.command, termination.args, { stdio: "ignore", windowsHide: true });
      killer.unref();
      return;
    }
    try { process.kill(termination.pid, termination.signal); return; } catch {}
  }
  child.kill(force ? "SIGKILL" : "SIGTERM");
}

export async function executePiChild(task, options = {}) {
  const temporary = await mkdtemp(path.join(tmpdir(), "hekate-subagent-"));
  const promptPath = path.join(temporary, "prompt.md");
  await writeFile(promptPath, String(task.prompt ?? ""), { mode: 0o600 });
  const command = options.command ?? "pi";
  const args = [
    ...(options.commandArgs ?? []),
    "--mode", "json", "--no-session", "--no-context-files",
    "--tools", task.tools.join(","), `@${promptPath}`
  ];
  const child = spawn(command, args, {
    cwd: task.cwd,
    detached: process.platform !== "win32",
    stdio: ["ignore", "pipe", "pipe"]
  });
  const chunks = [];
  const errors = [];
  const outputLimit = options.outputLimit ?? 1024 * 1024;
  let outputBytes = 0;
  let errorBytes = 0;
  let transportTruncated = false;
  let terminationReason = null;
  let escalation;
  const stop = (reason) => {
    terminationReason ??= reason;
    terminate(child);
    escalation ??= setTimeout(() => terminate(child, true), options.terminateGraceMs ?? 2_000);
    escalation.unref?.();
  };
  child.stdout.on("data", (chunk) => {
    const remaining = Math.max(0, outputLimit - outputBytes);
    if (remaining) chunks.push(chunk.subarray(0, remaining));
    outputBytes += chunk.length;
    if (outputBytes > outputLimit) { transportTruncated = true; stop("output_limit"); }
  });
  child.stderr.on("data", (chunk) => {
    const remaining = Math.max(0, outputLimit - errorBytes);
    if (remaining) errors.push(chunk.subarray(0, remaining));
    errorBytes += chunk.length;
    if (errorBytes > outputLimit) { transportTruncated = true; stop("output_limit"); }
  });
  const timeout = setTimeout(() => stop("timeout"), options.timeoutMs ?? 120_000);
  const abort = () => stop("aborted");
  task.signal?.addEventListener("abort", abort, { once: true });
  if (task.signal?.aborted) abort();
  try {
    const result = await new Promise((resolve, reject) => {
      child.once("error", reject);
      child.once("close", (code, signal) => resolve({ code, signal }));
    });
    const stdout = Buffer.concat(chunks).toString("utf8");
    const stderr = Buffer.concat(errors).toString("utf8");
    return {
      ok: result.code === 0,
      output: stdout,
      details: { exitCode: result.code, signal: result.signal, stderr, transportTruncated, outputBytes, terminationReason },
      usage: extractUsage(stdout)
    };
  } finally {
    clearTimeout(timeout);
    clearTimeout(escalation);
    task.signal?.removeEventListener("abort", abort);
    await rm(temporary, { recursive: true, force: true });
  }
}

function numeric(value) {
  const number = Number(value ?? 0);
  return Number.isFinite(number) && number >= 0 ? number : 0;
}

function addUsage(total, usage) {
  total.input += numeric(usage?.input);
  total.output += numeric(usage?.output);
  total.cacheRead += numeric(usage?.cacheRead ?? usage?.cache_read);
  total.cacheWrite += numeric(usage?.cacheWrite ?? usage?.cache_write);
  total.tokens += numeric(usage?.tokens);
  total.cost.total += numeric(usage?.cost?.total ?? usage?.cost);
}

function extractUsage(output) {
  const usage = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, tokens: 0, cost: { total: 0 } };
  let found = false;
  let fallback = null;
  for (const line of output.split(/\r?\n/)) {
    if (!line.trim()) continue;
    try {
      const event = JSON.parse(line);
      if (event.type === "message_end" && event.message?.usage) {
        addUsage(usage, event.message.usage);
        found = true;
      } else if (event.usage) fallback = event.usage;
    } catch {}
  }
  if (!found && fallback) {
    addUsage(usage, fallback);
    found = true;
  }
  return found ? usage : null;
}

function usageTokens(usage) {
  const explicit = numeric(usage?.tokens);
  return explicit || numeric(usage?.input) + numeric(usage?.output) + numeric(usage?.cacheRead ?? usage?.cache_read) + numeric(usage?.cacheWrite ?? usage?.cache_write);
}

function usageCost(usage) {
  return numeric(usage?.cost?.total ?? usage?.cost);
}

function truncateUtf8(value, limit) {
  const bytes = Buffer.from(value);
  if (bytes.length <= limit) return value;
  const decoder = new TextDecoder("utf-8", { fatal: true });
  for (let end = limit; end >= Math.max(0, limit - 3); end -= 1) {
    try { return decoder.decode(bytes.subarray(0, end)); } catch {}
  }
  return "";
}

function fail(code, message) {
  const error = new Error(message);
  error.code = code;
  throw error;
}

async function gitPath(cwd, argument) {
  const { stdout } = await execFileAsync("git", ["-C", cwd, "rev-parse", argument], { encoding: "utf8" });
  return realpath(path.resolve(cwd, stdout.trim()));
}

async function assertWriterWorktree(cwd, parentCwd) {
  let marker;
  try { marker = await readFile(path.join(cwd, ".git"), "utf8"); }
  catch { fail("HKT802", "Writer subagents require a dedicated Git worktree."); }
  if (!marker.trim().startsWith("gitdir:")) fail("HKT802", "Writer subagents require a dedicated Git worktree.");
  try {
    const top = await gitPath(cwd, "--show-toplevel");
    if (top !== cwd) fail("HKT802", "Writer cwd must be the root of a dedicated Git worktree.");
    await gitPath(cwd, "--git-dir");
    const common = await gitPath(cwd, "--git-common-dir");
    if (parentCwd) {
      const parentTop = await gitPath(parentCwd, "--show-toplevel");
      const parentCommon = await gitPath(parentCwd, "--git-common-dir");
      if (parentTop === top || parentCommon !== common) fail("HKT802", "Writer worktree must be isolated from the parent checkout in the same repository.");
    }
  } catch (error) {
    if (error.code === "HKT802") throw error;
    fail("HKT802", "Writer subagents require a Git-authenticated linked worktree.");
  }
}

export async function runSubagents(tasks, options = {}) {
  const roles = options.roles ?? DEFAULT_ROLES;
  const execute = options.execute;
  if (typeof execute !== "function") fail("HKT800", "Subagent executor is required.");
  const depth = options.depth ?? 0;
  if (depth > 0) fail("HKT801", "Subagents cannot recursively delegate.");
  const maxTasks = options.maxTasks ?? 8;
  const concurrency = options.concurrency ?? 2;
  const outputLimit = options.outputLimit ?? 64 * 1024;
  const maxTokens = options.maxTokens ?? Infinity;
  const maxCost = options.maxCost ?? Infinity;
  if (!Array.isArray(tasks) || tasks.length === 0 || tasks.length > maxTasks) fail("HKT803", "Subagent task budget exceeded.");
  if (!Number.isInteger(concurrency) || concurrency < 1 || concurrency > 8) fail("HKT804", "Invalid subagent concurrency.");

  const results = new Array(tasks.length);
  let next = 0;
  let usedTokens = 0;
  let usedCost = 0;
  async function worker() {
    while (next < tasks.length) {
      if (usedTokens >= maxTokens || usedCost >= maxCost) fail("HKT808", "Subagent usage budget exhausted.");
      const index = next++;
      const task = { ...tasks[index], cwd: await realpath(tasks[index].cwd ?? options.cwd ?? process.cwd()) };
      const role = roles[task.role];
      if (!role) fail("HKT805", `Unknown subagent role: ${task.role}`);
      if (task.write && !role.writable) fail("HKT806", `Role ${task.role} cannot mutate.`);
      if (role.writable && task.write !== true) fail("HKT806", `Role ${task.role} requires explicit write authorization.`);
      let leasePath;
      try {
        if (role.writable) {
          await assertWriterWorktree(task.cwd, options.parentCwd ? await realpath(options.parentCwd) : null);
          const leaseRoot = path.join(task.cwd, ".workflow", "leases");
          await mkdir(leaseRoot, { recursive: true });
          const candidate = path.join(leaseRoot, "writer");
          try { await mkdir(candidate, { recursive: false }); }
          catch { fail("HKT807", "Writer worktree lease is already held."); }
          leasePath = candidate;
        }
        const raw = await execute({ ...task, tools: role.tools, depth: depth + 1, signal: options.signal });
        const usage = raw.usage ?? null;
        usedTokens += usageTokens(usage);
        usedCost += usageCost(usage);
        if (usedTokens > maxTokens || usedCost > maxCost) fail("HKT808", "Subagent usage budget exhausted.");
        const output = String(raw.output ?? "");
        results[index] = {
          role: task.role,
          status: raw.ok === false ? "failed" : "review_pending",
          output: truncateUtf8(output, outputLimit),
          truncated: Buffer.byteLength(output) > outputLimit,
          details: raw.details ?? {},
          usage
        };
      } finally {
        if (leasePath) await rm(leasePath, { recursive: true, force: true });
      }
    }
  }
  const budgetedConcurrency = Number.isFinite(maxTokens) || Number.isFinite(maxCost) ? 1 : concurrency;
  await Promise.all(Array.from({ length: Math.min(budgetedConcurrency, tasks.length) }, worker));
  return results;
}
