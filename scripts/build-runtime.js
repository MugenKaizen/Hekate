import { createHash } from "node:crypto";
import { cp, mkdir, readFile, readdir, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../", import.meta.url));
const runtimeRoot = path.join(root, "distribution/runtime");
const output = path.join(runtimeRoot, "src/hekate-cli.mjs");

await rm(runtimeRoot, { recursive: true, force: true });
await mkdir(path.dirname(output), { recursive: true });
await cp(path.join(root, "packages/core/schemas"), path.join(runtimeRoot, "schemas"), { recursive: true });

const built = spawnSync("bun", [
  "build",
  "packages/cli/bin/transaction-runtime.js",
  "--target=node",
  "--format=esm",
  `--outfile=${output}`
], { cwd: root, encoding: "utf8" });

if (built.status !== 0) {
  process.stderr.write(built.stdout);
  process.stderr.write(built.stderr);
  process.exit(built.status ?? 1);
}

const files = [
  "src/hekate-cli.mjs",
  ...(await readdir(path.join(runtimeRoot, "schemas"))).sort().map((name) => `schemas/${name}`)
];
const checksums = await Promise.all(files.map(async (relative) => {
  const bytes = await readFile(path.join(runtimeRoot, ...relative.split("/")));
  return `${createHash("sha256").update(bytes).digest("hex")}  ${relative}`;
}));
await writeFile(path.join(runtimeRoot, "SHA256SUMS"), `${checksums.join("\n")}\n`);
