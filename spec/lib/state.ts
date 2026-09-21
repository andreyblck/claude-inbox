/**
 * The design contract from DESIGN.md, in code.
 *
 * Every user-visible string and every icon comes from here. Views may compose
 * these values but must never invent a label, a colour or a truncation of their
 * own — that is the one rule that keeps the menu bar from turning into mush.
 */
/**
 * Semantic names, not a toolkit's enum. The UI layer decides what a `lock` looks
 * like — an SF Symbol, an asset, a glyph in a menu — and this file stays true
 * whichever one is asking.
 */
export type Tint = "yellow" | "orange" | "blue" | "green" | "red" | "secondary";
export type Glyph = "lock" | "question" | "plan" | "alert" | "busy" | "speech" | "done" | "failed";

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
  icon: Glyph;
  tint: Tint;
  group: StateGroup;
  /** Sort key inside a group: lower comes first. */
  rank: number;
};

export const STATES: Record<InboxState, StateMeta> = {
  "blocked.permission": { label: "Permission", icon: "lock", tint: "yellow", group: "waiting", rank: 0 },
  "blocked.question": { label: "Question", icon: "question", tint: "yellow", group: "waiting", rank: 1 },
  "blocked.plan": { label: "Plan", icon: "plan", tint: "yellow", group: "waiting", rank: 2 },
  // Trust and MCP-consent dialogs cannot be answered anywhere but the terminal,
  // so they are orange, not yellow: the only useful action is "take me there".
  "blocked.dialog": { label: "Needs terminal", icon: "alert", tint: "orange", group: "waiting", rank: 3 },
  working: { label: "Working", icon: "busy", tint: "blue", group: "running", rank: 0 },
  // A finished turn is not the same kind of quiet as a busy one: the session said
  // something and is waiting for it to be read. That is the whole reason this
  // product exists — knowing what came back without visiting twelve terminals —
  // and it spent its life buried in "Running" as a grey dot.
  idle: { label: "Answered", icon: "speech", tint: "secondary", group: "answered", rank: 0 },
  done: { label: "Done", icon: "done", tint: "green", group: "finished", rank: 0 },
  failed: { label: "Failed", icon: "failed", tint: "red", group: "finished", rank: 1 },
};

const GROUP_ORDER: Record<StateGroup, number> = { waiting: 0, answered: 1, running: 2, finished: 3 };

export const GROUP_TITLES: Record<StateGroup, string> = {
  waiting: "Waiting for You",
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
  /**
   * Characters of the "what it wants" phrase for a blocked session.
   *
   * Written for a menu row, which was 28. A panel is wider and its cards wrap,
   * so a decision gets enough room to be read without opening anything — and the
   * decision is the one thing here that must never need a second click.
   */
  ask: 40,
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
  /** The tracker issue the session is working on, e.g. "SKY-5463". */
  issue?: string | null;
  /** A short generated name for a session that named no issue: "GSC". */
  label?: string | null;
  /** The tool call a blocked session is stopped on, in the model's own words. */
  asking?: string | null;
  /** Whether the turn ended by asking the person for something. See `parseAsk`. */
  needs_you?: boolean;
  /** What it asks for, or — when it asks nothing — what landed. One line. */
  line?: string | null;
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
export function askPhrase(item: PendingItem, max: number = LIMITS.ask): string {
  const input = item.tool_input ?? {};
  const str = (key: string) => (typeof input[key] === "string" ? (input[key] as string) : undefined);

  switch (item.kind) {
    case "question": {
      // Its own words, not "pick one of 3". The question is the thing being
      // asked and the card has room for it; the count says nothing at all.
      const first = askedOf(item)[0];
      if (!first) return "answer a question";
      const rest = askedOf(item).length - 1;
      const head = oneLine(first.question);
      return truncate(rest > 0 ? `${head} (+${rest} more)` : head, max);
    }
    case "plan":
      return "Approve the plan?";
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
export function userPrompt(prompt?: string | null): string | undefined {
  const text = prompt?.trim();
  if (!text) return undefined;
  // Claude Code delivers system events through UserPromptSubmit too — task
  // notifications, monitor events, re-wakes. They arrive in the same field as a
  // person's words and they are not a person's words; showing one as the subject
  // of a row is showing plumbing.
  if (/^<[a-z][a-z0-9-]*>/i.test(text)) return undefined;
  return text;
}

/**
 * The tracker issue a session is working on: `SKY-5463`.
 *
 * A link first, because it cannot be anything else; a bare key second, because
 * that is how a follow-up names it. Three digits at least — "F3 WI-10 5427" is a
 * real prompt, and a label that lies is worse than a folder name.
 */
export function issueOf(raw?: string | null): string | undefined {
  const prompt = userPrompt(raw);
  if (!prompt) return undefined;
  const match =
    /linear\.app\/[^/\s]+\/issue\/([a-z][a-z0-9]*-\d+)/i.exec(prompt) ??
    /\b([A-Z][A-Z0-9]{1,9}-\d{3,})\b/.exec(prompt);
  return match?.[1].toUpperCase();
}

/**
 * Which session a row is. Five sessions in one checkout are `skyaccess-ef`,
 * `-a1`, `-62` — names nobody chose. The issue is what the person calls the work.
 */
export function labelOf(session: SessionRecord): string {
  if (session.issue) return truncate(session.issue, LIMITS.project);
  if (session.label) return truncate(session.label, LIMITS.project);
  return projectName(session.cwd, session.session_id, session.name);
}

/**
 * A model's reading of a turn's last message: does it need the person, and the
 * one line that says what for.
 *
 * `Stop` says a turn ended and nothing else. A session standing there with five
 * decisions it needs looks exactly like one that is done, and was filed under
 * Answered. The reply is asked for as two lines — YES or NO, then the line — and
 * anything else is refused: a guess at urgency is the error this vocabulary
 * exists to prevent.
 */
export function parseAsk(
  raw?: string | null,
): { needs_you: boolean; line: string; replies?: string[] } | undefined {
  const lines = (raw ?? "").split("\n").map((l) => l.trim()).filter((l) => l.length > 0);
  if (lines.length < 2) return undefined;
  const verdict = /^[\s*_`"'#]*(yes|no|да|нет)\b/i.exec(lines[0])?.[1].toLowerCase();
  if (!verdict) return undefined;
  const line = plainText(lines[1].replace(/^\s*\d+[.)]\s*/, ""));
  if (!line) return undefined;
  const needs_you = verdict === "yes" || verdict === "да";
  // Up to three short answers the person is likely to give. They draft a reply;
  // they never send one.
  const offered = lines.slice(2).map((l) => /^[\s*_`]*repl(?:y|ies)\s*:\s*(.+)$/i.exec(l)?.[1]).find(Boolean);
  const replies = needs_you
    ? (offered ?? "").split("|").map((r) => plainText(r)).filter((r) => r.length > 0 && r.length <= 48).slice(0, 3)
    : [];
  return replies.length ? { needs_you, line, replies } : { needs_you, line };
}

/**
 * Where a session belongs once its last message has been read. Only a turn that
 * has ended can be promoted: a session that moved on is no longer asking.
 */
export function stateOf(session: SessionRecord): InboxState {
  if (session.state === "idle" && session.needs_you && session.line) return "blocked.dialog";
  return session.state;
}

/**
 * The one line of a session row.
 *
 * A blocked session is read for what it wants, and "Claude needs your
 * permission" is not that — it is the same sentence for every request there has
 * ever been. The tool call it is stopped on says it. Only a blocked row is read
 * this way: the registry's "input needed" on a session that is working would
 * otherwise wipe out the sentence about the work.
 */
export function headlineOf(session: SessionRecord, max: number = LIMITS.subject): string {
  const group = STATES[session.state].group;
  if (group !== "waiting") {
    // A turn that ended has been read, and the reading is a better line than the
    // first eighty characters of a message that opens with a status header.
    if (group === "answered" && session.line) return truncate(session.line, max);
    return subjectOf(session, max);
  }
  if (session.asking) return truncate(plainText(session.asking), max);
  if (session.needs_you && session.line) return truncate(session.line, max);
  return session.waiting_for ? truncate(session.waiting_for, max) : subjectOf(session, max);
}

/**
 * What a model hands back when asked for a name, made safe to show.
 *
 * It is asked for one to three words and mostly obliges. When it does not — it
 * answers the prompt instead of naming it — the result is a sentence, and a
 * sentence in the label's place is worse than the session name it would replace.
 */
export function cleanLabel(raw?: string | null): string | undefined {
  const first = raw?.split("\n").map((l) => l.trim()).find((l) => l.length > 0);
  if (!first) return undefined;
  const text = oneLine(first.replace(/^[\s"'`*«»“”#-]+|[\s"'`*«»“”.!]+$/g, ""));
  if (!text || text.length > 32 || text.split(" ").length > 4) return undefined;
  return text;
}

/**
 * A path a person can read.
 *
 * `/private/var/folders/sz/n9zh8s2x…/T/tmp.3nRfVq8Ruf` is four lines of noise and
 * one useful word. Home becomes `~`, the system temp becomes `tmp`, and what is
 * left is the part someone would have said out loud.
 */
export function shortPath(path: string, home = process.env.HOME ?? ""): string {
  let text = path.replace(/\/var\/folders\/[^/]+\/[^/]+\/T\//, "tmp/__KEEP__").replace(/^.*tmp\/__KEEP__/, "tmp/");
  text = text.replace(/^\/private/, "");
  if (home && text.startsWith(home)) text = "~" + text.slice(home.length);
  return text;
}

/**
 * Claude Code's own slash commands, read out of the 2.1.278 binary rather than
 * remembered — regenerate from the command/category map inside it.
 *
 * `/model` is something a person types in the middle of a task, not a step of
 * work. It mattered once the step began to be kept across turns: shown once it
 * was noise, kept it sat on the row for the rest of the session.
 */
const BUILT_IN_COMMANDS = new Set(
  `add-dir advisor agents ant-trace artifacts auto-mode-setup autocompact autofix-pr autopilot
   background branch brief btw bug bugfix cd channel chrome claim-credit clear cloud-plugins color
   compact config context copy daemon dashboard debug-tool-call design-consent design-login
   design-revoke desktop diff docs effort env exit experiments export extra-usage fast feedback
   focus fork goal heapdump help hooks ide import input-debug install-github-app install-slack-app
   investigate issue keybindings limit-reset list-agents login logout loops low-priority mcp memory
   mobile mock-limits model oauth-refresh onboarding output-style passes pause-memory perf-issue
   permissions plan plugin plugin-types powerup privacy-settings pro-trial-expired radio
   rate-limit-options recap release-notes reload-plugins reload-skills remote-control remote-env
   remote-workflow rename render-debug reset-limits resume rewind sandbox schedule scroll-speed
   session settings-review setup-bedrock setup-vertex simulate-usage skill-doctor skills status
   stickers stop subtask tasks teleport terminal-setup theme thrash tui ultraplan ultrareview
   update upgrade usage usage-credits version vim voice web-setup wellbeing workflow-launch-exec
   workflows`.split(/\s+/),
);

/** One question, flattened for a form to draw. */
export type Asked = { question: string; header: string; multiSelect: boolean; options: string[] };

export function askedOf(item: PendingItem): Asked[] {
  const raw = item.tool_input?.questions;
  if (!Array.isArray(raw)) return [];
  const out: Asked[] = [];
  for (const q of raw) {
    if (typeof q !== "object" || q === null) continue;
    const r = q as Record<string, unknown>;
    if (typeof r.question !== "string" || !r.question) continue;
    const options = (Array.isArray(r.options) ? r.options : [])
      .map((o) => (typeof o === "object" && o !== null ? (o as Record<string, unknown>).label : undefined))
      .filter((l): l is string => typeof l === "string");
    out.push({
      question: r.question,
      header: typeof r.header === "string" ? r.header : "",
      multiSelect: r.multiSelect === true,
      options,
    });
  }
  return out;
}

/**
 * The answer to a question, in the one shape Claude Code accepts.
 *
 * `AskUserQuestion` declares `requiresUserInteraction()`, and a bare allow for
 * such a tool is dropped — the answer *is* the decision, and it rides in
 * `updatedInput`. That input is validated hard: every key it shows must come
 * back untouched, and `answers` is one of the few a sender may add, keyed by the
 * question's own text. Anything else is refused, so this refuses first rather
 * than sending it and hoping.
 */
export function answerInput(
  item: PendingItem,
  answers: Record<string, string | string[]>,
): Record<string, unknown> | undefined {
  const input = item.tool_input;
  if (!input || "answers" in input) return undefined;
  const asked = new Map(askedOf(item).map((a) => [a.question, a]));
  if (!asked.size || !Object.keys(answers).length) return undefined;

  const out: Record<string, string | string[]> = {};
  for (const [question, value] of Object.entries(answers)) {
    const a = asked.get(question);
    if (!a) return undefined;
    if (typeof value === "string") {
      if (!value.trim()) return undefined;
      out[question] = value;
      continue;
    }
    // A list is only ever valid for a multiSelect, and never longer than the
    // options plus one — the slot free text goes in.
    if (!a.multiSelect || !value.length || value.length > a.options.length + 1) return undefined;
    if (value.some((v) => typeof v !== "string" || !v.trim())) return undefined;
    out[question] = value;
  }
  return { ...input, answers: out };
}

/**
 * A grant Claude Code offered on the request: trust this directory, accept edits,
 * allow this tool. One press answers the request and removes the next dozen.
 *
 * We never build one. A malformed entry makes Claude Code drop the whole array
 * with a warning nobody sees ("malformed updatedPermissions ignored"), so the
 * only safe move is to recognise what it sent, label it, and hand the same object
 * back.
 */
export type Grant = { label: string; suggestion: Record<string, unknown> };

const DESTINATIONS = new Set(["userSettings", "projectSettings", "localSettings", "session", "cliArg"]);

export function grantsOf(item: PendingItem, max = 3): Grant[] {
  const out: Grant[] = [];
  for (const raw of item.permission_suggestions ?? []) {
    if (out.length >= max) break;
    if (typeof raw !== "object" || raw === null) continue;
    const s = raw as Record<string, unknown>;
    const destination = typeof s.destination === "string" ? s.destination : "";
    if (!DESTINATIONS.has(destination)) continue;

    let what: string | undefined;
    if (s.type === "setMode" && typeof s.mode === "string") {
      what = s.mode === "acceptEdits" ? "Accept edits" : `Switch to ${s.mode}`;
    } else if (s.type === "addDirectories" && Array.isArray(s.directories) && s.directories.length) {
      const dirs = s.directories.filter((d): d is string => typeof d === "string");
      if (!dirs.length) continue;
      what = dirs.length === 1 ? `Trust ${shortPath(dirs[0])}` : `Trust ${dirs.length} directories`;
    } else if (s.type === "addRules" && Array.isArray(s.rules) && s.rules.length && typeof s.behavior === "string") {
      if (s.behavior !== "allow") continue;
      const names = s.rules
        .map((r) => (typeof r === "object" && r !== null ? (r as Record<string, unknown>).toolName : undefined))
        .filter((n): n is string => typeof n === "string");
      if (!names.length) continue;
      what = names.length === 1 ? `Allow ${names[0]}` : `Allow ${names.length} tools`;
    }
    if (!what) continue;
    // How far a press reaches is half of what is being agreed to, so it is in the
    // label: "for this session", "in this project", or nothing hedged at all.
    const label =
      destination === "userSettings" ? `Always ${what[0].toLowerCase()}${what.slice(1)}`
      : destination === "projectSettings" || destination === "localSettings" ? `${what} in this project`
      : `${what} for this session`;
    out.push({ label, suggestion: s });
  }
  return out;
}

export function phaseOf(raw?: string | null): string | undefined {
  const prompt = userPrompt(raw);
  if (!prompt) return undefined;
  const match = /^\s*\/([a-z0-9:_-]+)/i.exec(prompt);
  if (!match) return undefined;
  const name = match[1].split(":").pop();
  if (!name) return undefined;
  // A plugin's `/morgan:track` is a step; Claude Code's own `/model` is not.
  if (!match[1].includes(":") && BUILT_IN_COMMANDS.has(name.toLowerCase())) return undefined;
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
        [userPrompt(session.last_prompt), false],
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
