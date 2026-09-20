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

export type StateGroup = "waiting" | "answered" | "running" | "finished";

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
  // A finished turn is not the same kind of quiet as a busy one: the session said
  // something and is waiting for it to be read. That is the whole reason this
  // product exists — knowing what came back without visiting twelve terminals —
  // and it spent its life buried in "Running" as a grey dot.
  idle: { label: "Answered", icon: Icon.SpeechBubble, tint: Color.SecondaryText, group: "answered", rank: 0 },
  done: { label: "Done", icon: Icon.CheckCircle, tint: Color.Green, group: "finished", rank: 0 },
  failed: { label: "Failed", icon: Icon.XMarkCircle, tint: Color.Red, group: "finished", rank: 1 },
};

const GROUP_ORDER: Record<StateGroup, number> = { waiting: 0, answered: 1, running: 2, finished: 3 };

export const GROUP_TITLES: Record<StateGroup, string> = {
  waiting: "Waiting for you",
  answered: "Answered",
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
  subject: 60,
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
  /** The model's own sentence about what it is doing, from the transcript. */
  saying?: string;
  permission_mode?: string;
  transcript_path?: string;
  last_message?: string | null;
};

// --- formatters ----------------------------------------------------------------

export function truncate(value: string, max: number): string {
  const s = value.trim();
  return s.length <= max ? s : s.slice(0, max - 1).trimEnd() + "…";
}

/**
 * The last sentence, which in a narration is the current move.
 *
 * The model writes "<what just happened>. <what I am doing now>", so the front of
 * the string is history and the back is the answer. Cutting at a character count
 * keeps the history and throws the answer away — and lands mid-word doing it.
 */
export function lastSentence(value: string): string {
  const text = oneLine(value);
  // A full stop inside «a quote», (an aside) or `code` is not the end of a
  // sentence, and splitting on it leaves a fragment like `Tests pass…»), а не`.
  const OPEN = "«(“[{\u0060";
  const CLOSE = "»)”]}\u0060";
  const starts: number[] = [0];
  let depth = 0;
  for (let i = 0; i < text.length; i++) {
    const char = text[i];
    if (char === "\u0060") depth = depth ? depth - 1 : 1;
    else if (OPEN.includes(char)) depth++;
    else if (CLOSE.includes(char)) depth = Math.max(0, depth - 1);
    else if (depth === 0 && ".!?…".includes(char)) {
      let j = i + 1;
      while (j < text.length && ".!?…".includes(text[j])) j++;
      if (text[j] === " ") starts.push(j + 1);
    }
  }
  const parts = starts
    .map((start, index) => text.slice(start, starts[index + 1] ?? text.length).trim())
    .filter(Boolean);
  if (parts.length < 2) return parts[0] ?? text;
  const last = parts[parts.length - 1];
  // "44 из 44." on its own says nothing; a fragment that short is a result, not
  // an action, so keep the sentence before it as well.
  if (last.length >= 16) return last;
  return `${parts[parts.length - 2]} ${last}`.trim();
}

/** One line, no runs of whitespace. Commands arrive with newlines in them. */
export function oneLine(value: string): string {
  return value.replace(/\s+/g, " ").trim();
}

/**
 * A menu row is not a document. Assistant text is written as markdown — `**Раз:**`,
 * backticks around identifiers, list bullets — and every one of those characters
 * is spent on formatting that nothing here renders.
 */
export function plainText(value: string): string {
  return oneLine(
    value
      // A fenced block is quoted output, not the sentence around it. Left in, a
      // row ends up showing a fragment of whatever the session happened to print.
      .replace(/\u0060{3}[\s\S]*?(\u0060{3}|$)/g, " ")
      .replace(/\u0060{1,3}([^\u0060]*)\u0060{1,3}/g, "$1")
      .replace(/\*\*([^*]+)\*\*/g, "$1")
      .replace(/(^|\s)[*_]([^*_]+)[*_](?=\s|$)/g, "$1$2")
      .replace(/^[\s>#-]+/, "")
      .replace(/\[([^\]]+)\]\([^)]*\)/g, "$1"),
  );
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
  const clean = (value?: string | null, narration = false) => {
    const text = value?.trim();
    if (!text) return undefined;
    // A narration has a front and a back; an instruction is just an instruction.
    if (narration) {
      const sentence = plainText(lastSentence(plainText(text)));
      return sentence || undefined;
    }
    // The slash command is shown as the phase; repeating it here costs the
    // characters that carry the actual request.
    const body = plainText(text.replace(/^\s*\/[a-z0-9:_-]+\s*/i, ""));
    return body || undefined;
  };

  // The model narrates itself before it acts, in the person's own language, and
  // that sentence beats anything derived — a title summarising the first prompt
  // ("Давай давай давай"), a tool name, or the state the icon already shows.
  // Answered and finished are read the same way: the message is the point, and
  // its verdict is at the front. A running session is read for its current move.
  const group = STATES[session.state].group;
  const finished = group === "finished" || group === "answered";
  const candidates: [string | null | undefined, boolean][] = finished
    ? [
        // A closing message is not a narration: the verdict is its first words
        // ("Shipped.", "Готово, тесты зелёные."), and the rest is detail. Taking
        // the last sentence here throws away the answer instead of the history.
        [session.last_message, false],
        [session.saying, true],
        [session.title, false],
        [session.last_prompt, false],
      ]
    : [
        [session.saying, true],
        // The title is what the session is *about*; the prompt is what was said
        // in the last moment, and that is often an aside — "без отправок в лс",
        // "давай доделывай". A row names the work, not the last correction.
        [session.title, false],
        [session.last_prompt, false],
        [session.activity?.[0], false],
      ];

  for (const [candidate, narration] of candidates) {
    const text = clean(candidate, narration);
    if (text) return truncate(text, max);
  }
  // The step is thin, but it is a fact about the work. "working" beside a glyph
  // that already means working is a word spent on nothing.
  if (session.phase) return truncate(session.phase, max);
  return STATES[session.state].label.toLowerCase();
}

export function bySeverity(a: { state: InboxState; ts: number }, b: { state: InboxState; ts: number }): number {
  const ma = STATES[a.state];
  const mb = STATES[b.state];
  if (ma.group !== mb.group) return GROUP_ORDER[ma.group] - GROUP_ORDER[mb.group];
  if (ma.rank !== mb.rank) return ma.rank - mb.rank;
  // Newest first where the row is a result to read; oldest first where it is
  // something that has been kept waiting.
  return ma.group === "finished" || ma.group === "answered" ? b.ts - a.ts : a.ts - b.ts;
}
