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
  /** Set by the Morgan phase reporter: "track", "pull", "clean"… */
  phase?: string;
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
export function bySeverity(a: { state: InboxState; ts: number }, b: { state: InboxState; ts: number }): number {
  const ma = STATES[a.state];
  const mb = STATES[b.state];
  if (ma.group !== mb.group) return GROUP_ORDER[ma.group] - GROUP_ORDER[mb.group];
  if (ma.rank !== mb.rank) return ma.rank - mb.rank;
  return ma.group === "finished" ? b.ts - a.ts : a.ts - b.ts;
}
