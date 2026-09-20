/**
 * Reading and writing the bridge's directory. The whole IPC surface lives here:
 * views never touch the filesystem themselves.
 */
import { getPreferenceValues } from "@raycast/api";
import { execFileSync } from "child_process";
import { open as fsOpen, mkdir, readdir, readFile, rename, writeFile } from "fs/promises";
import { homedir } from "os";
import { basename, join } from "path";
import { oneLine, phaseOf, type InboxState, type PendingItem, type SessionRecord } from "./state";

export type UsageRecord = {
  ts: number;
  config_dir: string;
  session_id?: string;
  model?: string | null;
  rate_limits?: {
    five_hour?: { used_percentage?: number | null; resets_at?: number | null } | null;
    seven_day?: { used_percentage?: number | null; resets_at?: number | null } | null;
    spend_limit?: { used_percentage?: number | null; resets_at?: number | null } | null;
  } | null;
  // Every one of these is null in a real payload before the first API response.
  context?: { used_percentage?: number | null; context_window_size?: number | null } | null;
  cost?: { total_cost_usd?: number | null } | null;
};

function expandHome(path: string): string {
  return path.replace(/^~(?=$|\/)/, homedir());
}

export function inboxDir(): string {
  const pref = getPreferenceValues<{ inboxDir?: string }>().inboxDir?.trim();
  if (pref) return expandHome(pref);
  return join(homedir(), ".claude", "inbox");
}

/**
 * Every Claude Code config directory the bridge was installed into.
 *
 * An account is a config directory, and each keeps its own session registry.
 * Assuming `~/.claude` is wrong the moment someone runs with CLAUDE_CONFIG_DIR:
 * their sessions live elsewhere, the registry reads empty, and the inbox goes
 * blank while a dozen sessions are running. So install.sh records where it went
 * and we read that. The default is the fallback, never the assumption.
 */
export async function configDirs(): Promise<string[]> {
  const dirs = new Set<string>();
  try {
    const listed = await readFile(join(inboxDir(), "config-dirs"), "utf8");
    for (const line of listed.split("\n")) {
      const dir = line.trim();
      if (dir) dirs.add(expandHome(dir));
    }
  } catch {
    // bridge not installed, or installed before it recorded this
  }
  if (!dirs.size) dirs.add(join(homedir(), ".claude"));
  return [...dirs];
}

/**
 * Has the bridge ever been installed? An empty inbox and an absent one look the
 * same to a reader, and "Nothing needs you" over a bridge that was never set up
 * is a screen that lies calmly.
 */
export async function bridgeInstalled(): Promise<boolean> {
  try {
    await readFile(join(inboxDir(), "config-dirs"), "utf8");
    return true;
  } catch {
    return false;
  }
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
export function liveSessionsDir(configDir: string): string {
  return join(configDir, "sessions");
}

/**
 * Claude Code's own status vocabulary, from the 2.1.278 validator:
 *   ["busy", "shell", "idle", "waiting"]
 * A status outside it belongs to a version we don't know: render it as running
 * rather than invent a state, but never as something that needs the human.
 */
type LiveStatus = "busy" | "shell" | "idle" | "waiting";

/** The two kinds a person is actually having a session with. The rest is machinery. */
const HUMAN_KINDS = new Set(["interactive", "bg"]);

type LiveSession = {
  sessionId?: string;
  kind?: string;
  name?: string;
  cwd?: string;
  status?: string;
  /** What a `waiting` session is waiting for, e.g. "input needed". */
  waitingFor?: string;
  pid?: number;
  /**
   * Process start time as a bare local-looking string in UTC — not comparable to
   * anything without knowing that. `startedAt` below is what we actually use.
   */
  procStart?: string;
  /** Epoch milliseconds. Zone-free, and within seconds of the process start. */
  startedAt?: number;
  statusUpdatedAt?: number;
};

function liveState(status?: string): InboxState {
  switch (status as LiveStatus) {
    // Something wants the human but the bridge has no request for it, so it is a
    // dialog only the terminal can answer.
    case "waiting":
      return "blocked.dialog";
    // "shell" is idle with the user at a ! prompt. Blue here would leave a
    // Working row standing for as long as someone sits in their shell.
    case "shell":
    case "idle":
      return "idle";
    default:
      return "working";
  }
}

/**
 * Is this pid still the process the registry recorded?
 *
 * The pid alone answers "does something exist with this number", which after a
 * reboot is a coin flip — and a wrong answer is a ghost row that never leaves.
 *
 * Compare start *times*, not the strings: the registry writes `procStart` in UTC
 * with no zone marker ("Sun Sep 20 08:28:05 2026") while `ps -o lstart=` prints
 * local time ("Sun Sep 20 11:28:05 2026"). Those never match anywhere but UTC, and
 * a comparison that can only fail reports every live session as dead — an empty
 * inbox with a dozen sessions running. `startedAt` is epoch milliseconds and has
 * no such problem, so that is the side we compare against.
 *
 * Every uncertainty resolves to alive. Being slow to drop a finished row costs a
 * line of stale text; being wrong the other way hides the whole product.
 */
const PROC_START_TOLERANCE_MS = 120_000;

function alive(pid?: number, startedAt?: number): boolean {
  if (!pid) return false;
  try {
    process.kill(pid, 0); // signal 0 only tests for existence
  } catch (error) {
    // EPERM means it exists and belongs to someone else — alive, just not ours.
    return (error as NodeJS.ErrnoException)?.code === "EPERM";
  }
  if (!startedAt) return true;
  try {
    const lstart = execFileSync("/bin/ps", ["-o", "lstart=", "-p", String(pid)], {
      encoding: "utf8",
      timeout: 2000,
    }).trim();
    const procStarted = Date.parse(lstart);
    if (!lstart || Number.isNaN(procStarted)) return true;
    // A session is registered a moment after its process starts, never before.
    return Math.abs(procStarted - startedAt) < PROC_START_TOLERANCE_MS;
  } catch {
    return true; // ps is not worth dropping a row over
  }
}

/**
 * Claude Code keeps the transcript beside the project, keyed by the cwd with
 * every non-alphanumeric character replaced by a dash. Deriving it means a
 * session that started before the bridge was installed still gets a detail pane
 * — which is the whole reason the live registry is read at all.
 */
export function transcriptPathFor(configDir: string, cwd?: string, sessionId?: string): string | undefined {
  if (!cwd || !sessionId) return undefined;
  return join(configDir, "projects", cwd.replace(/[^a-zA-Z0-9]/g, "-"), `${sessionId}.jsonl`);
}

export type LiveRegistry = {
  sessions: SessionRecord[];
  /**
   * False when no registry directory could be read at all. Liveness is then
   * unknown, and treating "absent from the registry" as "the process is gone"
   * would mark every running session finished.
   */
  observed: boolean;
};

/**
 * Sessions as Claude Code itself sees them. This needs no hooks and works on
 * sessions that were already running before the bridge was installed, which is
 * the normal case: hooks are read at startup.
 */
export async function readLiveSessions(): Promise<LiveRegistry> {
  const out: SessionRecord[] = [];
  let observed = false;

  for (const configDir of await configDirs()) {
    const dir = liveSessionsDir(configDir);
    try {
      await readdir(dir);
      observed = true;
    } catch {
      continue; // this account has never started a session
    }
    for (const row of await readJsonDir<LiveSession>(dir)) {
      if (!row.sessionId) continue;
      if (row.kind && !HUMAN_KINDS.has(row.kind)) continue; // daemons are not sessions
      if (!alive(row.pid, row.startedAt)) continue; // stale file from a closed session
      out.push({
        session_id: row.sessionId,
        state: liveState(row.status),
        ts: Math.round((row.statusUpdatedAt ?? row.startedAt ?? Date.now()) / 1000),
        cwd: row.cwd,
        name: row.name,
        pid: row.pid,
        waiting_for: row.waitingFor,
        config_dir: configDir,
        transcript_path: transcriptPathFor(configDir, row.cwd, row.sessionId),
      });
    }
  }
  return { sessions: out, observed };
}

/**
 * Tell the waiting hooks that somebody is on this end.
 *
 * A permission hook blocks for its whole timeout waiting for a verdict. With
 * Raycast quit that is a dead freeze before every prompt, for an answer that was
 * never coming — so the hook checks this stamp and gives up immediately instead.
 * Both commands write it, and the menu bar's 10s interval keeps it fresh.
 */
export async function touchHeartbeat(source: "inbox" | "menubar"): Promise<void> {
  try {
    const dir = inboxDir();
    const now = String(Math.round(Date.now() / 1000));
    await mkdir(dir, { recursive: true });
    await writeFile(join(dir, "heartbeat"), now, "utf8");
    // Raycast refuses a background deeplink to a command the user has not
    // enabled — and says so in an error toast, once per nudge. Only the menu bar
    // command can prove it is enabled, by having run at all.
    if (source === "menubar") await writeFile(join(dir, "heartbeat-menubar"), now, "utf8");
  } catch {
    // a heartbeat we could not write is a slower hook, not a broken one
  }
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

/** Read the last `bytes` of a file as text. Transcripts reach hundreds of MB. */
async function readTail(path: string, bytes: number): Promise<string | undefined> {
  try {
    const fh = await fsOpen(path, "r");
    try {
      const { size } = await fh.stat();
      const start = Math.max(0, size - bytes);
      const chunk = Buffer.alloc(Math.min(bytes, size));
      await fh.read(chunk, 0, chunk.length, start);
      return chunk.toString("utf8");
    } finally {
      await fh.close();
    }
  } catch {
    return undefined;
  }
}

/**
 * Claude Code writes its own generated title for a session into the transcript,
 * as a line of `{"type": "ai-title", "aiTitle": "…"}`. It rewrites it as the
 * session goes on, so the newest one is near the end — measured at 0.7–3.7 KB
 * from the end across real transcripts, including one of 4.5 MB.
 *
 * This is the difference between a row that reads "skyaccess-48 · working" and
 * one that reads "skyaccess-48 · Optics для pricing review email".
 */
// A single Read result can fill 64 KB on its own, and then the tail holds no
// sentence at all — which is how a row ends up reading `running sed -n 70,78p`
// instead of what the session is actually up to. The 20s cache pays for this.
const SUMMARY_TAIL = 256 * 1024;
const SUMMARY_TTL_MS = 20_000;

export type SessionSummary = {
  title?: string;
  doing?: string;
  /**
   * The model's own sentence about what it is doing, written just before it acts.
   * Nothing we could generate beats it: it is already there, already in the
   * person's language, and costs neither a token nor a millisecond.
   */
  saying?: string;
  /**
   * What was last asked. The bridge captures this on UserPromptSubmit, but only
   * for sessions that started after it was installed — and the transcript has it
   * for every session, in the same tail we are already reading.
   */
  prompt?: string;
};

const summaryCache = new Map<string, { at: number; summary: SessionSummary }>();

/**
 * The interesting half of a shell command.
 *
 * Commands arrive as `cd /long/absolute/path && npm test`, and the path is the
 * part nobody needs: it is the project, which the row already says. What is left
 * is what the session is actually doing.
 */
function commandGist(command: string): string {
  // A heredoc is a whole script on one line; the interpreter is the only part of
  // it that reads as anything.
  const head = command.split(/<<[-~]?['"]?\w/)[0];
  const parts = oneLine(head)
    .split(/&&|;|\|\|/)
    .map((part) => part.trim())
    .filter((part) => part && !/^cd\s/.test(part) && !/^(export|source|\.)\s/.test(part));
  return parts[0] || oneLine(head) || oneLine(command);
}

/** `Bash · npm test` -> "running npm test". A row is read, not parsed. */
function describeTool(name: string, input?: Record<string, unknown>): string {
  const str = (key: string) => (typeof input?.[key] === "string" ? (input[key] as string) : undefined);
  const file = () => str("file_path")?.split("/").pop();
  switch (name) {
    case "Bash": {
      const command = str("command");
      return `running ${command ? commandGist(command) : "a command"}`;
    }
    case "Read":
      return `reading ${file() ?? "a file"}`;
    case "Edit":
    case "Write":
    case "NotebookEdit":
      return `editing ${file() ?? "a file"}`;
    case "Grep":
    case "Glob":
      return `searching for ${oneLine(str("pattern") ?? "something")}`;
    case "WebSearch":
    case "WebFetch":
      return "looking something up";
    case "Task":
    case "Agent":
      return `running ${oneLine(str("description") ?? "an agent")}`;
    default:
      return name.startsWith("mcp__") ? `using ${name.split("__")[1] ?? "an integration"}` : `using ${name}`;
  }
}

/**
 * What a session is about, and what it is doing — from one read of the tail.
 *
 * Claude Code writes its own generated title into the transcript as a line of
 * `{"type": "ai-title", "aiTitle": "…"}` and rewrites it as the session goes on,
 * so the newest one sits near the end: measured at 0.7–3.7 KB from the end across
 * real transcripts, including one of 4.5 MB. The newest `tool_use` is right there
 * too, which is the difference between a row that reads "skyaccess-48 · working"
 * and one that reads "skyaccess-48 · Optics для pricing review email".
 */
export async function readSessionSummary(transcriptPath?: string): Promise<SessionSummary> {
  if (!transcriptPath) return {};
  const cached = summaryCache.get(transcriptPath);
  // Every row wants this on every poll; re-reading a dozen transcripts once a
  // second buys nothing, because neither value changes that fast.
  if (cached && Date.now() - cached.at < SUMMARY_TTL_MS) return cached.summary;

  const summary: SessionSummary = {};
  const buf = await readTail(transcriptPath, SUMMARY_TAIL);
  if (buf) {
    const lines = buf.split("\n");
    for (let i = lines.length - 1; i >= 0 && !(summary.title && summary.doing && summary.saying && summary.prompt); i--) {
      const line = lines[i].trim();
      if (!line.startsWith("{")) continue;
      try {
        const row = JSON.parse(line) as {
          type?: string;
          aiTitle?: string;
          lastPrompt?: string;
          message?: { content?: { length: number; [index: number]: unknown } };
        };
        if (!summary.title && row.type === "ai-title" && row.aiTitle) summary.title = row.aiTitle;
        if (!summary.prompt && row.type === "last-prompt" && row.lastPrompt) summary.prompt = row.lastPrompt;
        if (Array.isArray(row.message?.content)) {
          for (let j = row.message.content.length - 1; j >= 0; j--) {
            const block = row.message.content[j] as {
              type?: string;
              name?: string;
              text?: string;
              input?: Record<string, unknown>;
            };
            if (!summary.doing && block.type === "tool_use" && block.name) {
              summary.doing = describeTool(block.name, block.input);
            }
            if (!summary.saying && row.type === "assistant" && block.type === "text" && block.text?.trim()) {
              summary.saying = oneLine(block.text).trim() || undefined;
            }
          }
        }
      } catch {
        // truncated first line of the window, expected
      }
    }
  }
  summaryCache.set(transcriptPath, { at: Date.now(), summary });
  return summary;
}

/**
 * The last few things a session did, for the detail pane.
 * Transcripts grow to hundreds of megabytes, so only the tail is read.
 */
export async function readRecentActivity(transcriptPath?: string, maxTools = 6): Promise<string[]> {
  if (!transcriptPath) return [];
  const buf = await readTail(transcriptPath, 192 * 1024);
  if (!buf) return [];

  const tools: string[] = [];
  const lines = buf.split("\n");
  for (let i = lines.length - 1; i >= 0 && tools.length < maxTools; i--) {
    const line = lines[i].trim();
    if (!line.startsWith("{")) continue;
    try {
      const row = JSON.parse(line) as { message?: { content?: unknown } };
      const content = row.message?.content;
      if (!Array.isArray(content)) continue;
      // Backwards here too: the list reads newest first, and one assistant
      // message can carry several tool calls.
      for (let j = content.length - 1; j >= 0 && tools.length < maxTools; j--) {
        const block = content[j] as { type?: string; name?: string; input?: Record<string, unknown> };
        if (block.type !== "tool_use" || !block.name) continue;
        const arg =
          typeof block.input?.command === "string"
            ? String(block.input.command).split("\n")[0]
            : typeof block.input?.file_path === "string"
              ? basename(String(block.input.file_path))
              : undefined;
        tools.push(arg ? `${block.name} · ${arg}` : block.name);
      }
    } catch {
      // truncated first line of the tail window, expected
    }
  }
  return tools;
}

/**
 * Fill in what makes a row readable: the session's own title, and the step it
 * declared. Both views need this, so neither gets to do it its own way.
 */
export async function enrichRows(rows: Row[]): Promise<Row[]> {
  return Promise.all(
    rows.map(async (row) => {
      if (row.kind !== "session") return row;
      const summary = await readSessionSummary(row.session.transcript_path);
      const title = row.session.title ?? summary.title;
      const activity = summary.doing ? [summary.doing] : row.session.activity;
      const last_prompt = row.session.last_prompt ?? summary.prompt;
      const phaseFromPrompt = row.session.phase ?? phaseOf(last_prompt);
      return {
        ...row,
        session: { ...row.session, title, phase: phaseFromPrompt, activity, last_prompt, saying: summary.saying },
      };
    }),
  );
}

export type Row =
  | { kind: "pending"; id: string; state: InboxState; ts: number; pending: PendingItem }
  | { kind: "session"; id: string; state: InboxState; ts: number; session: SessionRecord };

const FINISHED_TTL_S = 60 * 60;

/**
 * One row per session, from three sources that each know something the others
 * don't: the live registry knows who is alive, the hooks know the phase and the
 * last message, and a pending request outranks both.
 *
 * The rule for state is **the freshest observation wins**, not a fixed pecking
 * order. Both sources timestamp what they saw, and each is blind to half of it:
 * the registry does not know a session ended cleanly, and the hooks do not know
 * a new turn started until the next event fires. Hard-coding either as the
 * winner pins rows to a state that stopped being true minutes ago.
 */
export function mergeRows(
  pending: PendingItem[],
  hookSessions: SessionRecord[],
  live: LiveRegistry | SessionRecord[] = { sessions: [], observed: false },
): Row[] {
  const registry: LiveRegistry = Array.isArray(live) ? { sessions: live, observed: true } : live;
  const merged = new Map<string, SessionRecord>();
  for (const session of registry.sessions) merged.set(session.session_id, session);

  const nowS = Date.now() / 1000;
  for (const hooked of hookSessions) {
    const alive = merged.get(hooked.session_id);
    if (alive) {
      // SessionEnd is a fact the registry cannot contradict: the session is over
      // even if the process lingers. Otherwise, whoever saw the session most
      // recently is describing it best.
      const terminal = hooked.state === "done" || hooked.state === "failed";
      const useHooked = terminal || hooked.ts >= alive.ts;
      merged.set(hooked.session_id, {
        ...alive,
        // The hooks are the only source for any of these.
        phase: hooked.phase ?? alive.phase,
        last_message: hooked.last_message ?? alive.last_message,
        transcript_path: hooked.transcript_path ?? alive.transcript_path,
        permission_mode: hooked.permission_mode ?? alive.permission_mode,
        state: useHooked ? hooked.state : alive.state,
        ts: useHooked ? hooked.ts : alive.ts,
      });
      continue;
    }

    // Not in the live registry. If we could read the registry at all, the process
    // is gone and the session is over — including the common case where it was
    // killed or the window was closed, which fires no SessionEnd and leaves the
    // record on whatever Stop last wrote. Dropping those made sessions vanish
    // rather than finish. If we could NOT read the registry, liveness is unknown
    // and the last thing we heard stands.
    if (!registry.observed) {
      merged.set(hooked.session_id, hooked);
      continue;
    }
    if (hooked.demo) {
      merged.set(hooked.session_id, hooked);
      continue;
    }
    if (nowS - hooked.ts >= FINISHED_TTL_S) continue; // old news, not a finished session
    const finished = hooked.state === "done" || hooked.state === "failed";
    merged.set(hooked.session_id, finished ? hooked : { ...hooked, state: "done" });
  }

  const blocked = new Set(pending.map((p) => p.session_id));
  return [
    ...pending.map<Row>((p) => ({ kind: "pending", id: p.req, state: p.state, ts: p.ts, pending: p })),
    ...[...merged.values()]
      .filter((s) => !blocked.has(s.session_id))
      .map<Row>((s) => ({ kind: "session", id: s.session_id, state: s.state, ts: s.ts, session: s })),
  ];
}
