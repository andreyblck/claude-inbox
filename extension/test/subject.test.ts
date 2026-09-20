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
import {
  bySeverity,
  lastSentence,
  phaseOf,
  plainText,
  STATES,
  subjectOf,
  type InboxState,
  type SessionRecord,
} from "../src/lib/state";

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

describe("cutting a sentence out of a narration", () => {
  it("takes the last sentence, because that is the current move", () => {
    // The model writes "<what just happened>. <what I am doing now>", so the
    // front is history. Cutting at a character count keeps the history.
    assert.equal(lastSentence("Все четыре строки читаются. Закрываю тестами."), "Закрываю тестами.");
  });

  it("keeps a result that is too short to stand alone", () => {
    assert.equal(
      lastSentence("44 из 44. Обновляю DESIGN под новый порядок источников."),
      "Обновляю DESIGN под новый порядок источников.",
    );
    assert.equal(lastSentence("Готово. Всё."), "Готово. Всё.");
  });

  it("does not break on a full stop inside a quote, an aside or code", () => {
    // `Tests pass…»), а не в конце.` is what came out before this was handled.
    assert.equal(
      lastSentence("Итог стоит в начале («Shipped. Tests pass»), а не в конце."),
      "Итог стоит в начале («Shipped. Tests pass»), а не в конце.",
    );
    assert.equal(lastSentence("Запускаю `npm run a.b.c` сейчас."), "Запускаю `npm run a.b.c` сейчас.");
  });

  it("leaves a single sentence alone", () => {
    assert.equal(lastSentence("Чиню класс, а не экземпляр."), "Чиню класс, а не экземпляр.");
  });
});

describe("a menu row is not a document", () => {
  it("strips the markdown the model writes in", () => {
    assert.equal(plainText("**Раз:** правлю `state.ts` и _тесты_"), "Раз: правлю state.ts и тесты");
  });
  it("strips bullets, quotes and links", () => {
    assert.equal(plainText("- see [the docs](https://x.y) first"), "see the docs first");
    assert.equal(plainText("> цитата"), "цитата");
  });
  it("drops a fenced block: it is quoted output, not the sentence", () => {
    // Left in, a row shows a fragment of whatever the session happened to print.
    assert.equal(plainText("Смотрите:\n\u0060\u0060\u0060\nidle  Статус: собрано\n\u0060\u0060\u0060\nГотово."), "Смотрите: Готово.");
  });

  it("reaches the row, not just the helper", () => {
    const row = session({ state: "working", saying: "Готово. Правлю `state.ts` и **тесты**." });
    assert.equal(subjectOf(row), "Правлю state.ts и тесты.");
  });
});

describe("a finished turn is an answer, not idleness", () => {
  it("an idle session is grouped as answered, not as running", () => {
    // The whole point of the product is knowing what came back without visiting
    // twelve terminals. This spent its life as a grey dot under "Running".
    assert.equal(STATES.idle.group, "answered");
    assert.equal(STATES.idle.label, "Answered");
    assert.equal(STATES.working.group, "running");
  });

  it("sections run: needs you, answered you, still going, done", () => {
    const order = (["done", "working", "idle", "blocked.permission"] as InboxState[])
      .map((state) => ({ state, ts: 0 }))
      .sort(bySeverity)
      .map((row) => STATES[row.state].group);
    assert.deepEqual(order, ["waiting", "answered", "running", "finished"]);
  });

  it("an answered row shows what it said", () => {
    const row = session({
      state: "idle",
      last_message: "Ожидаю два ревью (BE и FE).",
      saying: "Запускаю сборку.",
      activity: ["running npm test"],
    });
    assert.equal(subjectOf(row), "Ожидаю два ревью (BE и FE).");
  });

  it("newest answer first: it is a result to read, not a queue to clear", () => {
    const rows = (
      [
        { state: "idle" as InboxState, ts: 100 },
        { state: "idle" as InboxState, ts: 900 },
      ]
    ).sort(bySeverity);
    assert.deepEqual(rows.map((r) => r.ts), [900, 100]);
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

  it("prefers the title over the last thing said to it", () => {
    // Tried it the other way first, on the theory that newer is truer. It is
    // not: the title names the work, while the newest prompt is usually an
    // aside — "без отправок в лс", "давай доделывай" — and a row that shows the
    // aside instead of the job is worse than one that shows neither.
    const row = session({ state: "working", title: "Optics для pricing review", last_prompt: "без отправок в лс" });
    assert.equal(subjectOf(row), "Optics для pricing review");
  });

  it("takes the current move over the session's subject", () => {
    // What it is doing now beats what it is about, when we have both.
    const row = session({ state: "working", saying: "Закрываю тестами.", title: "Иконка в меню бар" });
    assert.equal(subjectOf(row), "Закрываю тестами.");
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

  it("shows the step rather than the word the icon already says", () => {
    // "working" beside a glyph that means working is a row spent on nothing.
    assert.equal(subjectOf(session({ state: "working", phase: "qa" })), "qa");
  });

  it("says the state only when it knows nothing at all", () => {
    assert.equal(subjectOf(session({ state: "working" })), "working");
  });

  it("keeps it to one line and inside the budget", () => {
    const row = session({ state: "working", saying: "a".repeat(200) });
    assert.ok(subjectOf(row).length <= 60, `${subjectOf(row).length} chars`);
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
