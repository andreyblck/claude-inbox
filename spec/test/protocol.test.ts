/**
 * The seam where the bug lived: Raycast writes a verdict file, a bash hook reads
 * it and prints a decision to Claude Code. Both halves were self-consistent and
 * both were wrong, because nothing tested them against each other.
 *
 * So this runs the real `bridge/hook-permission.sh` against the real
 * `writeVerdict`, and asserts the shape Claude Code's own validator demands:
 *
 *   {behavior: "allow", updatedInput?: object} | {behavior: "deny", message: string}
 */
import { strict as assert } from "node:assert";
import { spawn } from "node:child_process";
import { mkdtemp, readdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { after, before, describe, it } from "node:test";
import { writeVerdict } from "../lib/inbox";

declare const __BRIDGE_DIR__: string;
const HOOK = resolve(__BRIDGE_DIR__, "hook-permission.sh");

const PAYLOAD = {
  hook_event_name: "PermissionRequest",
  session_id: "s-protocol",
  cwd: "/Users/me/work/skyaccess-api",
  prompt_id: "p-1",
  tool_name: "Bash",
  tool_input: { command: "rm -rf dist", description: "clean the build" },
  permission_mode: "default",
  transcript_path: "/tmp/t.jsonl",
};

let inbox: string;

before(async () => {
  inbox = await mkdtemp(join(tmpdir(), "claude-inbox-protocol-"));
  process.env.CLAUDE_INBOX_DIR = inbox;
});

/** What `touchHeartbeat` writes: without it the hook refuses to block at all. */
async function beat() {
  const { writeFile, mkdir } = await import("node:fs/promises");
  await mkdir(inbox, { recursive: true });
  await writeFile(join(inbox, "heartbeat"), String(Math.round(Date.now() / 1000)), "utf8");
}
after(async () => {
  await rm(inbox, { recursive: true, force: true });
});

/** Run the hook, and answer the request it raises the moment it appears. */
async function roundTrip(answer: null | { decision: "allow" | "deny"; reason?: string }, listening = true) {
  // The tests share one inbox, and a heartbeat stays fresh for a minute — so
  // "nobody is listening" has to be made true, not just left unsaid.
  if (listening) await beat();
  else await rm(join(inbox, "heartbeat"), { force: true });
  const child = spawn(HOOK, {
    env: { ...process.env, CLAUDE_INBOX_DIR: inbox, CLAUDE_INBOX_PERMISSION_TIMEOUT: "10" },
    stdio: ["pipe", "pipe", "pipe"],
  });
  child.stdin.end(JSON.stringify(PAYLOAD));

  let stdout = "";
  let stderr = "";
  child.stdout.on("data", (c) => (stdout += c));
  child.stderr.on("data", (c) => (stderr += c));

  let pending: Record<string, unknown> | undefined;
  if (answer) {
    const deadline = Date.now() + 8000;
    while (Date.now() < deadline) {
      const names = (await readdir(join(inbox, "pending")).catch(() => [])).filter((n) => n.endsWith(".json"));
      if (names.length) {
        const req = names[0].replace(/\.json$/, "");
        const { readFile } = await import("node:fs/promises");
        pending = JSON.parse(await readFile(join(inbox, "pending", names[0]), "utf8"));
        await writeVerdict(req, answer.decision, answer.reason);
        break;
      }
      await new Promise((r) => setTimeout(r, 50));
    }
  }

  const code = await new Promise<number>((r) => child.on("close", (c) => r(c ?? -1)));
  return { code, stdout, stderr, pending };
}

describe("verdict -> hook decision", () => {
  it("an allow is an object keyed by behavior, not the string 'allow'", async () => {
    const { code, stdout } = await roundTrip({ decision: "allow" });
    assert.equal(code, 0);
    const out = JSON.parse(stdout);
    assert.equal(out.hookSpecificOutput.hookEventName, "PermissionRequest");
    assert.equal(typeof out.hookSpecificOutput.decision, "object");
    assert.equal(out.hookSpecificOutput.decision.behavior, "allow");
    // A stray `reason` on an allow is not in the schema; keep the object bare.
    assert.deepEqual(Object.keys(out.hookSpecificOutput.decision), ["behavior"]);
  });

  it("a deny carries the reason in `message`, which is what the model is told", async () => {
    const { stdout } = await roundTrip({ decision: "deny", reason: "not on staging" });
    const { decision } = JSON.parse(stdout).hookSpecificOutput;
    assert.equal(decision.behavior, "deny");
    assert.equal(decision.message, "not on staging");
  });

  it("the pending file carries what the inbox needs to render the ask", async () => {
    const { pending } = await roundTrip({ decision: "allow" });
    assert.ok(pending);
    assert.equal(pending.kind, "permission");
    assert.equal(pending.state, "blocked.permission");
    assert.equal(pending.session_id, PAYLOAD.session_id);
    assert.equal(pending.cwd, PAYLOAD.cwd);
    assert.equal(pending.tool_name, "Bash");
    assert.deepEqual(pending.tool_input, PAYLOAD.tool_input);
    assert.equal(typeof pending.ts, "number");
    assert.match(String(pending.req), /^[0-9a-f]{8}$/);
  });

  it("nobody listening: the hook does not hold the prompt hostage", async () => {
    // Raycast quit. Blocking the full timeout here is a freeze before every
    // prompt, waiting on an answer that was never coming.
    const started = Date.now();
    const { code, stdout } = await roundTrip(null, false);
    assert.equal(code, 0);
    assert.equal(stdout.trim(), "");
    assert.ok(Date.now() - started < 8000, `gave the terminal back in ${Date.now() - started}ms`);
  });

  it("no verdict: silence and exit 0, so the terminal prompts as usual", async () => {
    const { code, stdout } = await roundTrip(null);
    assert.equal(code, 0);
    assert.equal(stdout.trim(), "");
    // A stale pending file would leave a row in the inbox that nothing can clear.
    const left = (await readdir(join(inbox, "pending")).catch(() => [])).filter((n) => n.endsWith(".json"));
    assert.deepEqual(left, []);
  });
});
