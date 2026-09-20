/**
 * The live registry is the only source that knows a session is alive, and every
 * running row in the product depends on it. A liveness check that says "no" too
 * eagerly does not degrade the view — it empties it.
 *
 * That is not hypothetical: comparing the registry's `procStart` string against
 * `ps -o lstart=` could never match outside UTC, so on a machine at UTC+3 every
 * session read as dead and both views went blank with four sessions running.
 */
import { strict as assert } from "node:assert";
import { mkdir, mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, it } from "node:test";
import { setPreferences } from "@raycast/api";
import { readLiveSessions, transcriptPathFor } from "../src/lib/inbox";

/** A registry pointing at this very process: alive by construction. */
async function registryWith(rows: Record<string, unknown>[]) {
  const inbox = await mkdtemp(join(tmpdir(), "claude-inbox-live-"));
  const config = await mkdtemp(join(tmpdir(), "claude-config-"));
  await mkdir(join(config, "sessions"), { recursive: true });
  await writeFile(join(inbox, "config-dirs"), `${config}\n`, "utf8");
  for (const row of rows) {
    await writeFile(join(config, "sessions", `${row.pid}.json`), JSON.stringify(row), "utf8");
  }
  setPreferences({ inboxDir: inbox });
  return { inbox, config };
}

/** Within the tolerance: this process really did start before now. */
const startedAt = Date.now() - 5_000;

describe("who is alive", () => {
  it("finds a session whose process is this one", async () => {
    await registryWith([
      { pid: process.pid, sessionId: "s-live", cwd: "/Users/me/work/tarot", kind: "interactive", status: "busy", startedAt },
    ]);
    const { sessions, observed } = await readLiveSessions();
    assert.equal(observed, true);
    assert.equal(sessions.length, 1, "a live session must not be filtered out");
    assert.equal(sessions[0].state, "working");
  });

  it("drops a pid that cannot be running", async () => {
    await registryWith([
      { pid: 999999, sessionId: "s-dead", cwd: "/x", kind: "interactive", status: "busy", startedAt },
    ]);
    assert.deepEqual((await readLiveSessions()).sessions, []);
  });

  it("drops a live pid that started at a different time — a recycled pid", async () => {
    await registryWith([
      { pid: process.pid, sessionId: "s-ghost", cwd: "/x", kind: "interactive", status: "busy", startedAt: startedAt - 86_400_000 },
    ]);
    assert.deepEqual((await readLiveSessions()).sessions, []);
  });

  it("keeps a session the registry gave no start time for", async () => {
    // Every uncertainty resolves to alive: a stale row costs a line of text, a
    // wrongly dropped one costs the whole view.
    await registryWith([
      { pid: process.pid, sessionId: "s-nostart", cwd: "/x", kind: "interactive", status: "busy" },
    ]);
    assert.equal((await readLiveSessions()).sessions.length, 1);
  });

  it("speaks Claude Code's status vocabulary", async () => {
    await registryWith([
      { pid: process.pid, sessionId: "busy", cwd: "/x", kind: "interactive", status: "busy", startedAt },
      { pid: process.ppid, sessionId: "waiting", cwd: "/x", kind: "interactive", status: "waiting", waitingFor: "input needed", startedAt },
    ]);
    const byId = Object.fromEntries((await readLiveSessions()).sessions.map((s) => [s.session_id, s]));
    assert.equal(byId.busy?.state, "working");
    // `waiting` is a dialog only the terminal can answer, and it says what it wants.
    assert.equal(byId.waiting?.state, "blocked.dialog");
    assert.equal(byId.waiting?.waiting_for, "input needed");
  });

  it("leaves daemons out: they are machinery, not sessions", async () => {
    await registryWith([
      { pid: process.pid, sessionId: "worker", cwd: "/x", kind: "daemon-worker", status: "busy", startedAt },
    ]);
    assert.deepEqual((await readLiveSessions()).sessions, []);
  });

  it("says so when there is no registry to read", async () => {
    const inbox = await mkdtemp(join(tmpdir(), "claude-inbox-none-"));
    await writeFile(join(inbox, "config-dirs"), `${join(inbox, "nowhere")}\n`, "utf8");
    setPreferences({ inboxDir: inbox });
    const { sessions, observed } = await readLiveSessions();
    assert.deepEqual(sessions, []);
    assert.equal(observed, false, "unknown liveness must not read as 'everything finished'");
  });

  it("derives the transcript path, so a pre-bridge session still has a detail pane", async () => {
    assert.equal(
      transcriptPathFor("/Users/me/.claude", "/Users/me/work/sky-api", "abc"),
      "/Users/me/.claude/projects/-Users-me-work-sky-api/abc.jsonl",
    );
  });
});
