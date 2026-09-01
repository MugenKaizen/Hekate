import { cp, mkdir, rm } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";

const packageRoot = fileURLToPath(new URL("../", import.meta.url));
const repositoryRoot = fileURLToPath(new URL("../../../", import.meta.url));
const payloadRoot = path.join(packageRoot, "payload");

await rm(payloadRoot, { recursive: true, force: true });
await mkdir(payloadRoot, { recursive: true });
await cp(path.join(repositoryRoot, "distribution"), path.join(payloadRoot, "distribution"), { recursive: true });
await cp(path.join(repositoryRoot, "templates"), path.join(payloadRoot, "templates"), { recursive: true });
