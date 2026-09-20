/**
 * A row gets one line. Spending it on "working" says nothing that the icon has
 * not already said — which is what made the first version unreadable at a glance,
 * and a glance is the only way this product is ever used.
 */
import { strict as assert } from "node:assert";
import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, it } from "node:test";
import { readSessionSummary } from "../src/lib/inbox";
import { phaseOf, subjectOf, type InboxState, type SessionRecord } from "../src/lib/state";

function session(over: Partial<SessionRecord> & { state: InboxState }): SessionRecord {
  return { session_id: "s", ts: Math.round(Date.now() / 1000), ...over };
}

describe("the step a session declared", () => {
  it("reads a plugin skill as its bare name", () => {
    assert.equal(phaseOf("/morgan:track fix the icon"), "track");
  });
  it("reads a plain slash command", () => {
    assert.equal(phaseOf("/clean"), "clean");
  });
  it("makes a hyphenated command readable", () => {
    assert.equal(phaseOf("/code-review the diff"), "code review");
  });
  it("says nothing when nothing was declared", () => {
    // Inventing a step from prose would be a guess wearing a label's clothes.
    assert.equal(phaseOf("почини иконку в меню баре"), undefined);
    assert.equal(phaseOf(""), undefined);
    assert.equal(phaseOf(undefined), undefined);
  });
});

describe("what a session is about", () => {
  it("prefers the sentence the model wrote about what it is doing", () => {
    // It is already there, already in the person's language, and it describes
    // this moment rather than summarising the session's opening line.
    const row = session({
      state: "working",
      saying: "Закрываю тестами.",
      title: "Давай давай давай",
      last_prompt: "давай доделывай",
      activity: ["running npm test"],
    });
    assert.equal(subjectOf(row), "Закрываю тестами.");
  });

  it("falls back to what was asked, without repeating the slash command", () => {
    // The command is already shown as the step; repeating it costs the
    // characters that carry the actual request.
    const row = session({ state: "working", last_prompt: "/morgan:pull дособери фичу" });
    assert.equal(subjectOf(row), "дособери фичу");
  });

  it("prefers the request over the generated title", () => {
    // The title summarises how the session opened; the prompt is what it is on
    // now. When they disagree, the newer one is the truer one.
    const row = session({ state: "working", title: "Иконка в меню бар", last_prompt: "теперь почини уведомления" });
    assert.equal(subjectOf(row), "теперь почини уведомления");
  });

  it("falls back to what it is touching, when nothing was said or asked", () => {
    // A session deep in a run of tool calls has no sentence in its tail. The
    // tool is thin, but it beats repeating the icon.
    const row = session({ state: "working", activity: ["editing state.ts"] });
    assert.equal(subjectOf(row), "editing state.ts");
  });

  it("a finished session says what landed, not what it was doing", () => {
    // Nothing there is in flight; the only question anyone asks of that section
    // is what came out of it.
    const row = session({
      state: "done",
      last_message: "Shipped. Tests pass, PR opened.",
      saying: "Запускаю сборку.",
      activity: ["running npm test"],
      last_prompt: "доделай",
    });
    assert.equal(subjectOf(row), "Shipped. Tests pass, PR opened.");
  });

  it("says the state only when it knows nothing else", () => {
    assert.equal(subjectOf(session({ state: "working" })), "working");
  });

  it("keeps it to one line and inside the budget", () => {
    const row = session({ state: "working", saying: "a".repeat(200) });
    assert.ok(subjectOf(row).length <= 48, `${subjectOf(row).length} chars`);
    const wrapped = session({ state: "working", saying: "first line\nsecond    line" });
    assert.equal(subjectOf(wrapped), "first line second line");
  });
});

describe("reading a transcript for the title and the current move", () => {
  async function transcript(lines: unknown[]) {
    const dir = await mkdtemp(join(tmpdir(), "claude-transcript-"));
    const path = join(dir, `${Math.random()}.jsonl`);
    await writeFile(path, lines.map((l) => JSON.stringify(l)).join("\n") + "\n", "utf8");
    return path;
  }
  const toolUse = (name: string, input: Record<string, unknown>) => ({
    type: "assistant",
    message: { content: [{ type: "tool_use", name, input }] },
  });

  const says = (text: string) => ({ type: "assistant", message: { content: [{ type: "text", text }] } });

  it("finds the newest of everything in one pass", async () => {
    const path = await transcript([
      { type: "ai-title", aiTitle: "Старый заголовок" },
      toolUse("Read", { file_path: "/Users/me/work/api/state.ts" }),
      { type: "ai-title", aiTitle: "Иконка в меню бар" },
      { type: "last-prompt", lastPrompt: "почини иконку" },
      says("Закрываю тестами."),
      toolUse("Bash", { command: "npm test" }),
    ]);
    assert.deepEqual(await readSessionSummary(path), {
      title: "Иконка в меню бар",
      prompt: "почини иконку",
      saying: "Закрываю тестами.",
      doing: "running npm test",
    });
  });

  it("does not mistake the user's own words for the model's", async () => {
    const path = await transcript([
      { type: "user", message: { content: [{ type: "text", text: "сделай это" }] } },
      toolUse("Bash", { command: "ls" }),
    ]);
    assert.equal((await readSessionSummary(path)).saying, undefined);
  });

  it("takes the newest sentence when a turn has several", async () => {
    const path = await transcript([says("Сначала это."), toolUse("Bash", { command: "ls" }), says("Теперь то.")]);
    assert.equal((await readSessionSummary(path)).saying, "Теперь то.");
  });

  it("drops the cd that every command starts with", async () => {
    // The path is the project, which the row already says. What is left is the
    // part worth reading.
    const path = await transcript([toolUse("Bash", { command: "cd /Users/me/work/very/long/path && npm run build" })]);
    assert.equal((await readSessionSummary(path)).doing, "running npm run build");
  });

  it("collapses a heredoc to the interpreter", async () => {
    const path = await transcript([toolUse("Bash", { command: "python3 - <<'PY'\nimport re\nprint(1)\nPY" })]);
    assert.equal((await readSessionSummary(path)).doing, "running python3 -");
  });

  it("describes edits and reads by file, not by tool", async () => {
    assert.equal(
      (await readSessionSummary(await transcript([toolUse("Edit", { file_path: "/a/b/install.sh" })]))).doing,
      "editing install.sh",
    );
    assert.equal(
      (await readSessionSummary(await transcript([toolUse("Read", { file_path: "/a/b/DESIGN.md" })]))).doing,
      "reading DESIGN.md",
    );
  });

  it("names the integration behind an MCP tool", async () => {
    const path = await transcript([toolUse("mcp__linear__create_issue", {})]);
    assert.equal((await readSessionSummary(path)).doing, "using linear");
  });

  it("returns nothing rather than throwing on a file that is not there", async () => {
    assert.deepEqual(await readSessionSummary("/nope/nothing.jsonl"), {});
    assert.deepEqual(await readSessionSummary(undefined), {});
  });
});
