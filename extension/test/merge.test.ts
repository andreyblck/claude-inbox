/**
 * `mergeRows` decides what every row in the product says. Three sources see
 * different halves of the truth and each is confidently wrong about the other
 * half, so the cases below are the ones where a fixed pecking order lies.
 */
import { strict as assert } from "node:assert";
import { describe, it } from "node:test";
import { mergeRows, type LiveRegistry } from "../src/lib/inbox";
import { bySeverity, STATES, type InboxState, type SessionRecord } from "../src/lib/state";

const NOW = Math.round(Date.now() / 1000);

function session(over: Partial<SessionRecord> & { session_id: string; state: InboxState }): SessionRecord {
  return { ts: NOW, cwd: "/Users/me/work/skyaccess-api", ...over };
}
function live(sessions: SessionRecord[]): LiveRegistry {
  return { sessions, observed: true };
}
function states(rows: ReturnType<typeof mergeRows>) {
  return Object.fromEntries(rows.map((r) => [r.id, r.state]));
}

describe("a running session is not reported idle", () => {
  it("a newer live 'busy' beats the Stop the bridge recorded earlier", () => {
    // The shape of every session past its first answer: Stop wrote idle at the
    // end of turn one, and the registry has since seen the process go busy.
    const rows = mergeRows(
      [],
      [session({ session_id: "s1", state: "idle", ts: NOW - 300 })],
      live([session({ session_id: "s1", state: "working", ts: NOW - 5 })]),
    );
    assert.deepEqual(states(rows), { s1: "working" });
  });

  it("a newer bridge 'idle' still beats a stale live 'busy'", () => {
    const rows = mergeRows(
      [],
      [session({ session_id: "s1", state: "idle", ts: NOW - 5 })],
      live([session({ session_id: "s1", state: "working", ts: NOW - 300 })]),
    );
    assert.deepEqual(states(rows), { s1: "idle" });
  });

  it("SessionEnd wins over a live process, whatever the timestamps say", () => {
    // /clear and /logout end the session without ending the process. The registry
    // will happily call it busy for the rest of the day.
    const rows = mergeRows(
      [],
      [session({ session_id: "s1", state: "done", ts: NOW - 300 })],
      live([session({ session_id: "s1", state: "working", ts: NOW - 1 })]),
    );
    assert.deepEqual(states(rows), { s1: "done" });
  });
});

describe("a session that ends is finished, not gone", () => {
  it("a killed session shows as finished even though no SessionEnd fired", () => {
    // ⌘W on the terminal: the last thing written was Stop's `idle`, and the pid
    // is gone. Dropping this made rows evaporate mid-poll instead of landing in
    // Recently finished.
    const rows = mergeRows([], [session({ session_id: "s1", state: "idle", ts: NOW - 60 })], live([]));
    assert.deepEqual(states(rows), { s1: "done" });
  });

  it("a clean SessionEnd keeps its own state", () => {
    const rows = mergeRows([], [session({ session_id: "s1", state: "done", ts: NOW - 60 })], live([]));
    assert.deepEqual(states(rows), { s1: "done" });
  });

  it("an hour later it is history, not a row", () => {
    const rows = mergeRows([], [session({ session_id: "s1", state: "idle", ts: NOW - 4000 })], live([]));
    assert.deepEqual(rows, []);
  });
});

describe("an unreadable registry degrades, it does not empty the inbox", () => {
  it("with no registry at all, the last thing the hooks heard stands", () => {
    // What a custom CLAUDE_CONFIG_DIR used to do: liveness unreadable, every
    // running session dropped, a blank inbox with a dozen sessions in flight.
    const rows = mergeRows(
      [],
      [
        session({ session_id: "s1", state: "working", ts: NOW - 10 }),
        session({ session_id: "s2", state: "idle", ts: NOW - 20 }),
      ],
      { sessions: [], observed: false },
    );
    assert.deepEqual(states(rows), { s1: "working", s2: "idle" });
  });
});

describe("a pending request outranks the session it belongs to", () => {
  it("the session row is replaced, not duplicated", () => {
    const rows = mergeRows(
      [
        {
          req: "r1",
          kind: "permission",
          state: "blocked.permission",
          ts: NOW,
          session_id: "s1",
          tool_name: "Bash",
          tool_input: { command: "rm -rf dist" },
        },
      ],
      [session({ session_id: "s1", state: "idle", ts: NOW - 5 })],
      live([session({ session_id: "s1", state: "working", ts: NOW - 1 })]),
    );
    assert.equal(rows.length, 1);
    assert.equal(rows[0].kind, "pending");
    assert.equal(rows[0].state, "blocked.permission");
  });
});

describe("hook-only detail survives the merge", () => {
  it("the transcript, phase and last message come from the hooks", () => {
    const rows = mergeRows(
      [],
      [session({ session_id: "s1", state: "idle", ts: NOW - 5, phase: "track", transcript_path: "/t.jsonl" })],
      live([session({ session_id: "s1", state: "working", ts: NOW - 1, name: "skyaccess-c8" })]),
    );
    assert.equal(rows[0].kind, "session");
    const row = rows[0] as Extract<(typeof rows)[number], { kind: "session" }>;
    assert.equal(row.session.phase, "track");
    assert.equal(row.session.transcript_path, "/t.jsonl");
    assert.equal(row.session.name, "skyaccess-c8", "the registry still owns the name");
  });
});

describe("sort order", () => {
  it("waiting first, then running, then finished", () => {
    const rows = mergeRows(
      [],
      [
        session({ session_id: "fin", state: "done", ts: NOW - 60 }),
        session({ session_id: "run", state: "working", ts: NOW - 60 }),
      ],
      { sessions: [], observed: false },
    ).sort(bySeverity);
    assert.deepEqual(
      rows.map((r) => STATES[r.state].group),
      ["running", "finished"],
    );
  });

  it("waiting is oldest-first: the one kept waiting longest is on top", () => {
    const ask = (req: string, ts: number) =>
      ({ req, kind: "permission", state: "blocked.permission", ts, session_id: req }) as const;
    const rows = mergeRows([ask("old", NOW - 600), ask("new", NOW - 10)], [], { sessions: [], observed: false }).sort(
      bySeverity,
    );
    assert.deepEqual(
      rows.map((r) => r.id),
      ["old", "new"],
    );
  });

  it("finished is newest-first: the only question there is what just landed", () => {
    const rows = mergeRows(
      [],
      [
        session({ session_id: "older", state: "done", ts: NOW - 600 }),
        session({ session_id: "newer", state: "done", ts: NOW - 10 }),
      ],
      live([]),
    ).sort(bySeverity);
    assert.deepEqual(
      rows.map((r) => r.id),
      ["newer", "older"],
    );
  });
});
