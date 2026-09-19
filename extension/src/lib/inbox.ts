/**
 * Reading and writing the bridge's directory. The whole IPC surface lives here:
 * views never touch the filesystem themselves.
 */
import { getPreferenceValues } from "@raycast/api";
import { open as fsOpen, mkdir, readdir, readFile, rename, writeFile } from "fs/promises";
import { homedir } from "os";
import { basename, join } from "path";
import type { InboxState, PendingItem, SessionRecord } from "./state";

export type UsageRecord = {
  ts: number;
  config_dir: string;
  session_id?: string;
  model?: string | null;
  rate_limits?: {
    five_hour?: { used_percentage?: number; resets_at?: number };
    seven_day?: { used_percentage?: number; resets_at?: number };
    spend_limit?: { used_percentage?: number; resets_at?: number };
  } | null;
  context?: { used_percentage?: number; context_window_size?: number } | null;
  cost?: { total_cost_usd?: number } | null;
};

export function inboxDir(): string {
  const pref = getPreferenceValues<{ inboxDir?: string }>().inboxDir?.trim();
  if (pref) return pref.replace(/^~(?=$|\/)/, homedir());
  return join(homedir(), ".claude", "inbox");
}

async function readJsonDir<T>(dir: string): Promise<T[]> {
  let names: string[];
  try {
    names = await readdir(dir);
  } catch {
    return []; // bridge not installed yet — an empty inbox, not an error
  }
  const out: T[] = [];
  for (const name of names) {
    if (!name.endsWith(".json")) continue;
    try {
      out.push(JSON.parse(await readFile(join(dir, name), "utf8")) as T);
    } catch {
      // a half-written or hand-edited file is skipped, never fatal
    }
  }
  return out;
}

export async function readPending(): Promise<PendingItem[]> {
  return readJsonDir<PendingItem>(join(inboxDir(), "pending"));
}

export async function readSessions(): Promise<SessionRecord[]> {
  return readJsonDir<SessionRecord>(join(inboxDir(), "sessions"));
}

export async function readUsage(): Promise<UsageRecord[]> {
  const all = await readJsonDir<UsageRecord>(join(inboxDir(), "usage"));
  // One row per account. Several sessions on one account write the same numbers;
  // the freshest reading is the true one, and duplicates would collide as keys.
  const byAccount = new Map<string, UsageRecord>();
  for (const record of all) {
    const seen = byAccount.get(record.config_dir);
    if (!seen || record.ts > seen.ts) byAccount.set(record.config_dir, record);
  }
  return [...byAccount.values()];
}

/** Claude Code's own registry of sessions running right now. */
export function liveSessionsDir(): string {
  return join(homedir(), ".claude", "sessions");
}

type LiveSession = {
  sessionId?: string;
  kind?: string;
  name?: string;
  cwd?: string;
  status?: string;
  pid?: number;
  startedAt?: number;
  statusUpdatedAt?: number;
};

function alive(pid?: number): boolean {
  if (!pid) return false;
  try {
    process.kill(pid, 0); // signal 0 only tests for existence
    return true;
  } catch {
    return false;
  }
}

/**
 * Sessions as Claude Code itself sees them. This needs no hooks and works on
 * sessions that were already running before the bridge was installed, which is
 * the normal case: hooks are read at startup.
 */
export async function readLiveSessions(): Promise<SessionRecord[]> {
  const rows = await readJsonDir<LiveSession>(liveSessionsDir());
  const out: SessionRecord[] = [];
  for (const row of rows) {
    if (!row.sessionId || !alive(row.pid)) continue; // stale file from a closed session
    out.push({
      session_id: row.sessionId,
      // "waiting" means something wants the human but the bridge has no request
      // for it, so it is a dialog only the terminal can answer.
      state: row.status === "waiting" ? "blocked.dialog" : row.status === "idle" ? "idle" : "working",
      ts: Math.round((row.statusUpdatedAt ?? row.startedAt ?? Date.now()) / 1000),
      cwd: row.cwd,
      name: row.name,
      pid: row.pid,
    });
  }
  return out;
}

/** Atomic, because a hook is polling for this exact file in a tight loop. */
export async function writeVerdict(req: string, decision: "allow" | "deny", reason?: string): Promise<void> {
  const dir = join(inboxDir(), "verdicts");
  await mkdir(dir, { recursive: true });
  const dest = join(dir, `${req}.json`);
  const tmp = `${dest}.${process.pid}.tmp`;
  await writeFile(tmp, JSON.stringify({ decision, reason: reason ?? "Answered in Raycast" }), "utf8");
  await rename(tmp, dest);
}

/** Label for an account: the config directory is the account. */
export function accountLabel(configDir: string): string {
  const base = basename(configDir.replace(/\/+$/, ""));
  return base === ".claude" ? "default" : base.replace(/^\.?claude-?/, "") || base;
}

/**
 * The last few things a session did, for the detail pane.
 * Transcripts grow to hundreds of megabytes, so only the tail is read.
 */
export async function readRecentActivity(transcriptPath?: string, maxTools = 6): Promise<string[]> {
  if (!transcriptPath) return [];
  const TAIL = 192 * 1024;
  let buf: string;
  try {
    const fh = await fsOpen(transcriptPath, "r");
    try {
      const { size } = await fh.stat();
      const start = Math.max(0, size - TAIL);
      const chunk = Buffer.alloc(Math.min(TAIL, size));
      await fh.read(chunk, 0, chunk.length, start);
      buf = chunk.toString("utf8");
    } finally {
      await fh.close();
    }
  } catch {
    return [];
  }

  const tools: string[] = [];
  const lines = buf.split("\n");
  for (let i = lines.length - 1; i >= 0 && tools.length < maxTools; i--) {
    const line = lines[i].trim();
    if (!line.startsWith("{")) continue;
    try {
      const row = JSON.parse(line) as { message?: { content?: unknown } };
      const content = row.message?.content;
      if (!Array.isArray(content)) continue;
      for (const part of content) {
        const block = part as { type?: string; name?: string; input?: Record<string, unknown> };
        if (block.type !== "tool_use" || !block.name) continue;
        const arg =
          typeof block.input?.command === "string"
            ? String(block.input.command).split("\n")[0]
            : typeof block.input?.file_path === "string"
              ? basename(String(block.input.file_path))
              : undefined;
        tools.push(arg ? `${block.name} · ${arg}` : block.name);
        if (tools.length >= maxTools) break;
      }
    } catch {
      // truncated first line of the tail window, expected
    }
  }
  return tools;
}

export type Row =
  | { kind: "pending"; id: string; state: InboxState; ts: number; pending: PendingItem }
  | { kind: "session"; id: string; state: InboxState; ts: number; session: SessionRecord };

const FINISHED_TTL_S = 60 * 60;

/**
 * One row per session, from three sources that each know something the others
 * don't: the live registry knows who is alive, the hooks know the phase and the
 * last message, and a pending request outranks both.
 */
export function mergeRows(
  pending: PendingItem[],
  hookSessions: SessionRecord[],
  liveSessions: SessionRecord[] = [],
): Row[] {
  const merged = new Map<string, SessionRecord>();
  for (const live of liveSessions) merged.set(live.session_id, live);

  const nowS = Date.now() / 1000;
  for (const hooked of hookSessions) {
    const live = merged.get(hooked.session_id);
    if (live) {
      // Live wins on liveness and name; hooks win on what the session is doing.
      merged.set(hooked.session_id, {
        ...live,
        phase: hooked.phase ?? live.phase,
        last_message: hooked.last_message ?? live.last_message,
        transcript_path: hooked.transcript_path ?? live.transcript_path,
        permission_mode: hooked.permission_mode ?? live.permission_mode,
        state: hooked.state === "idle" ? "idle" : live.state,
      });
      continue;
    }
    // Not in the live registry: the process is gone. Finished states linger
    // briefly so you can see what landed; anything else is simply over.
    const finished = hooked.state === "done" || hooked.state === "failed";
    if (hooked.demo || (finished && nowS - hooked.ts < FINISHED_TTL_S)) {
      merged.set(hooked.session_id, hooked);
    }
  }

  const blocked = new Set(pending.map((p) => p.session_id));
  return [
    ...pending.map<Row>((p) => ({ kind: "pending", id: p.req, state: p.state, ts: p.ts, pending: p })),
    ...[...merged.values()]
      .filter((s) => !blocked.has(s.session_id))
      .map<Row>((s) => ({ kind: "session", id: s.session_id, state: s.state, ts: s.ts, session: s })),
  ];
}
