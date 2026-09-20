/**
 * Bundle the tests with `@raycast/api` aliased to the stub, then hand them to
 * node's test runner. Bundling is the only way in: the real package resolves to
 * nothing outside Raycast, and lib/ imports it for two enums.
 */
import { build } from "esbuild";
import { mkdtemp, readdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";

const here = dirname(fileURLToPath(import.meta.url));
const out = await mkdtemp(join(tmpdir(), "claude-inbox-test-"));

const tests = (await readdir(here)).filter((f) => f.endsWith(".test.ts"));
if (!tests.length) {
  console.error("no *.test.ts found in", here);
  process.exit(1);
}

const bridge = join(here, "..", "..", "bridge");

await build({
  entryPoints: tests.map((f) => join(here, f)),
  outdir: out,
  bundle: true,
  platform: "node",
  format: "esm",
  target: "node22",
  sourcemap: "inline",
  // node:test is resolved by the runtime, not bundled in
  external: ["node:*"],
  alias: { "@raycast/api": join(here, "raycast-stub.ts") },
  // The bundle runs from a temp dir, so import.meta.dirname points at the temp
  // dir, not at the source tree. Anything on disk has to be baked in here.
  define: { __BRIDGE_DIR__: JSON.stringify(bridge) },
  logLevel: "warning",
});

// `--test <dir>` tries to load the directory as a module; name the files.
const built = tests.map((f) => join(out, f.replace(/\.ts$/, ".js")));
const child = spawn(process.execPath, ["--test", ...built], { stdio: "inherit" });
child.on("exit", async (code) => {
  await rm(out, { recursive: true, force: true });
  process.exit(code ?? 1);
});
