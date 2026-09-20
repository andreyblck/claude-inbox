/**
 * The design contract from DESIGN.md, in code.
 *
 * Every user-visible string and every icon comes from here. Views may compose
 * these values but must never invent a label, a colour or a truncation of their
 * own — that is the one rule that keeps the menu bar from turning into mush.
 */
import { Color, Icon } from "@raycast/api";

export type InboxState =
  | "blocked.permission"
  | "blocked.question"
  | "blocked.plan"
  | "blocked.dialog"
  | "working"
  | "idle"
  | "done"
  | "failed";

export type StateGroup = "waiting" | "running" | "finished";

type StateMeta = {
  /** Sentence-case, shown as an accessory tag. */
  label: string;
  icon: Icon;
  tint: Color;
  group: StateGroup;
  /** Sort key inside a group: lower comes first. */
  rank: number;
};

export const STATES: Record<InboxState, StateMeta> = {
  "blocked.permission": { label: "Permission", icon: Icon.Lock, tint: Color.Yellow, group: "waiting", rank: 0 },
  "blocked.question": { label: "Question", icon: Icon.QuestionMarkCircle, tint: Color.Yellow, group: "waiting", rank: 1 },
  "blocked.plan": { label: "Plan", icon: Icon.List, tint: Color.Yellow, group: "waiting", rank: 2 },
  // Trust and MCP-consent dialogs cannot be answered anywhere but the terminal,
  // so they are orange, not yellow: the only useful action is "take me there".
  "blocked.dialog": { label: "Needs terminal", icon: Icon.ExclamationMark, tint: Color.Orange, group: "waiting", rank: 3 },
  working: { label: "Working", icon: Icon.CircleFilled, tint: Color.Blue, group: "running", rank: 0 },
  idle: { label: "Idle", icon: Icon.Circle, tint: Color.SecondaryText, group: "running", rank: 1 },
  done: { label: "Done", icon: Icon.CheckCircle, tint: Color.Green, group: "finished", rank: 0 },
  failed: { label: "Failed", icon: Icon.XMarkCircle, tint: Color.Red, group: "finished", rank: 1 },
};

const GROUP_ORDER: Record<StateGroup, number> = { waiting: 0, running: 1, finished: 2 };

export const GROUP_TITLES: Record<StateGroup, string> = {
  waiting: "Waiting for you",
  running: "Running",
  finished: "Recently finished",
};

/** Hard caps. Exceeding one is a design bug, not a display detail. */
export const LIMITS = {
  /** Rows per section in the menu bar; the rest collapse into a submenu. */
  menuSection: 5,
  /** Characters of project name anywhere. */
  project: 18,
  /** Characters of the "what it wants" phrase in a row. */
  ask: 28,
  /**
   * Characters of what a running session is *about*. Longer than `ask` on
   * purpose: "run rm -rf dist" says everything in 15 characters, while a real
   * subject — "Optics для pricing review email" — is the whole value of the row
   * and truncating it to a verb phrase throws that value away.
   */
  subject: 38,
  /** Characters of a command echoed into a single-line row. */
  commandInline: 24,
} as const;

export function isWaiting(state: InboxState): boolean {
  return STATES[state].group === "waiting";
}

// --- shapes written by bridge/ -------------------------------------------------

export type PendingItem = {
  req: string;
  kind: "permission" | "question" | "plan";
  state: InboxState;
  ts: number;
  session_id: string;
  cwd?: string;
  tool_name?: string;
  tool_input?: Record<string, unknown>;
  permission_mode?: string;
  transcript_path?: string;
  /** Claude Code's id for the user turn this request belongs to. */
  prompt_id?: string;
  /**
   * What Claude Code itself offers as a broader grant — trusting the directory,
   * switching to acceptEdits. It arrives ready-made in the hook payload, which
   * is what "allow and stop asking" is built from rather than a rule we invent.
   */
  permission_suggestions?: unknown[];
};

export type SessionRecord = {
  session_id: string;
  state: InboxState;
  ts: number;
  cwd?: string;
  /** Claude Code's own session name, e.g. "skyaccess-c8". Better than a folder name. */
  name?: string;
  /** Present when the session is in Claude Code's live registry. */
  pid?: number;
  /** What a session in `blocked.dialog` is waiting for, when the registry says. */
  waiting_for?: string;
  /** The config directory this session belongs to — an account. */
  config_dir?: string;
  demo?: boolean;
  /** The step the session is on, when it declared one: "track", "pull", "clean". */
  phase?: string;
  /** What the person last asked for. Arrives free on UserPromptSubmit. */
  last_prompt?: string | null;
  /** Claude Code's own generated title for the session, from the transcript. */
  title?: string | null;
  /** The last few things the session did, newest first. */
  activity?: string[];
  permission_mode?: string;
  transcript_path?: string;
  last_message?: string | null;
};

// --- formatters ----------------------------------------------------------------

export function truncate(value: string, max: number): string {
  const s = value.trim();
  return s.length <= max ? s : s.slice(0, max - 1).trimEnd() + "…";
}

/** One line, no runs of whitespace. Commands arrive with newlines in them. */
export function oneLine(value: string): string {
  return value.replace(/\s+/g, " ").trim();
}

/**
 * Never a path, never a UUID. Claude Code's own session name wins when there is
 * one — it is what the person sees in their terminal — then the folder name.
 */
export function projectName(cwd?: string, fallback?: string, name?: string): string {
  if (name) return truncate(name, LIMITS.project);
  const base = cwd?.replace(/\/+$/, "").split("/").pop();
  return truncate(base || fallback || "unknown", LIMITS.project);
}

/**
 * What the session wants, as a lowercase verb phrase.
 * "run rm -rf dist", "write deploy.sh", "pick one of 3".
 */
export function askPhrase(item: PendingItem): string {
  const input = item.tool_input ?? {};
  const str = (key: string) => (typeof input[key] === "string" ? (input[key] as string) : undefined);

  switch (item.kind) {
    case "question": {
      const questions = Array.isArray((input as { questions?: unknown[] }).questions)
        ? ((input as { questions: unknown[] }).questions as unknown[])
        : [];
      const first = questions[0] as { question?: string; options?: unknown[] } | undefined;
      if (first?.options?.length) return truncate(`pick one of ${first.options.length}`, LIMITS.ask);
      return truncate(first?.question ? oneLine(first.question) : "answer a question", LIMITS.ask);
    }
    case "plan":
      return "approve plan";
    case "permission":
    default: {
      const tool = item.tool_name ?? "a tool";
      if (tool === "Bash") {
        const cmd = str("command");
        return truncate(cmd ? `run ${oneLine(cmd)}` : "run a command", LIMITS.ask);
      }
      if (tool === "Write" || tool === "Edit" || tool === "NotebookEdit") {
        const path = str("file_path");
        const file = path?.split("/").pop();
        return truncate(file ? `edit ${file}` : "edit a file", LIMITS.ask);
      }
      if (tool.startsWith("mcp__")) {
        return truncate(`use ${tool.split("__")[1] ?? "an integration"}`, LIMITS.ask);
      }
      return truncate(`use ${tool}`, LIMITS.ask);
    }
  }
}

/** The command or payload, for the detail pane's code block. */
export function askDetail(item: PendingItem): string | undefined {
  const input = item.tool_input ?? {};
  if (typeof input.command === "string") return input.command;
  if (typeof input.file_path === "string") return String(input.file_path);
  return undefined;
}

/** Compact and relative: "2m", "1h", "just now". Menus have no room for dates. */
export function age(ts: number, now = Date.now()): string {
  const secs = Math.max(0, Math.round(now / 1000 - ts));
  if (secs < 45) return "just now";
  const mins = Math.round(secs / 60);
  if (mins < 60) return `${mins}m`;
  const hours = Math.round(mins / 60);
  if (hours < 24) return `${hours}h`;
  return `${Math.round(hours / 24)}d`;
}

/** `project · what it wants` — the one row shape used everywhere. */
export function rowTitle(project: string, ask: string): string {
  return `${project} · ${ask}`;
}

/**
 * Within a group: by rank, then by age — oldest first, because the thing that
 * has been waiting longest is the thing you have kept waiting.
 *
 * "Recently finished" is the exception and reverses it: nothing there is
 * waiting, and the only question a person asks of that section is "what just
 * landed?". Sorting results oldest-first buries the answer.
 */
/**
 * The step a session declared, from the slash command that started the turn:
 * `/morgan:track fix the icon` -> "track".
 *
 * This is the only declaration of intent that exists in the data. Claude Code's
 * todo lists would be better — they carry an explicit current step and what is
 * left — but not one of 225 transcripts on this machine contained one, so
 * building on them would be building on nothing.
 */
export function phaseOf(prompt?: string | null): string | undefined {
  if (!prompt) return undefined;
  const match = /^\s*\/([a-z0-9:_-]+)/i.exec(prompt);
  if (!match) return undefined;
  const name = match[1].split(":").pop();
  if (!name) return undefined;
  return truncate(name.replace(/[-_]+/g, " "), LIMITS.ask);
}

/**
 * What a session is about, in the person's own words.
 *
 * The state is already in the icon, so spending the row's only line on "working"
 * says nothing twice — that was the whole complaint about the first version.
 *
 * Order is by how much each source tells you, and it differs by whether the
 * session is still going. For a running one you want the goal and then the
 * current move; for a finished one the only question is what landed.
 */
export function subjectOf(session: SessionRecord, max: number = LIMITS.subject): string {
  const clean = (value?: string | null) => {
    const text = value?.trim();
    if (!text) return undefined;
    // The slash command is shown as the phase; repeating it here costs the
    // characters that carry the actual request.
    const body = oneLine(text.replace(/^\s*\/[a-z0-9:_-]+\s*/i, ""));
    return body || undefined;
  };

  const finished = STATES[session.state].group === "finished";
  const candidates = finished
    ? [session.title, session.last_message, session.last_prompt]
    : [session.title, session.last_prompt, session.activity?.[0], session.last_message];

  for (const candidate of candidates) {
    const text = clean(candidate);
    if (text) return truncate(text, max);
  }
  return STATES[session.state].label.toLowerCase();
}

export function bySeverity(a: { state: InboxState; ts: number }, b: { state: InboxState; ts: number }): number {
  const ma = STATES[a.state];
  const mb = STATES[b.state];
  if (ma.group !== mb.group) return GROUP_ORDER[ma.group] - GROUP_ORDER[mb.group];
  if (ma.rank !== mb.rank) return ma.rank - mb.rank;
  return ma.group === "finished" ? b.ts - a.ts : a.ts - b.ts;
}
