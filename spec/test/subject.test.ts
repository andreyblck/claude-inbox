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
import { readCommand, readIssue, readSessionSummary, readTurnNarration } from "../lib/inbox";
import {
  bySeverity,
  cleanLabel,
  headlineOf,
  issueOf,
  labelOf,
  lastSentence,
  parseAsk,
  phaseOf,
  plainText,
  STATES,
  stateOf,
  userPrompt,
  subjectOf,
  type InboxState,
  type SessionRecord,
} from "../lib/state";

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

describe("the issue a session is working on", () => {
  it("reads the key out of a tracker link", () => {
    // 1550 of 16832 prompts on this machine carry one, and the slug after the key
    // is the part nobody says out loud.
    assert.equal(
      issueOf("/track https://linear.app/skyaccess/issue/SKY-5463/6-hide-single-pilot-legs это готово?"),
      "SKY-5463",
    );
  });
  it("reads a bare key, which is how a follow-up names it", () => {
    assert.equal(issueOf("доделай SKY-4483 и запушь"), "SKY-4483");
  });
  it("finds it inside pasted content", () => {
    assert.equal(
      issueOf('<pasted_content id="439d">\nhttps://linear.app/skyaccess/issue/SKY-5968/sync\n</pasted_content id="439d">\n\n вот тебе еще'),
      "SKY-5968",
    );
  });
  it("prefers the link when a prompt has both", () => {
    assert.equal(issueOf("как в SKY-1000, но для https://linear.app/skyaccess/issue/SKY-2000/x"), "SKY-2000");
  });
  it("does not mistake a code for an issue", () => {
    // "F3 WI-10 5427" is a real prompt. A label that lies is worse than a folder name.
    assert.equal(issueOf("F2 3986, F3 WI-10 5427"), undefined);
    assert.equal(issueOf("перекодируй в UTF-8"), undefined);
    assert.equal(issueOf("почини иконку в меню баре"), undefined);
    assert.equal(issueOf(undefined), undefined);
  });
  it("is not read out of a system event", () => {
    assert.equal(issueOf("<task-notification>agent on SKY-9999 finished</task-notification>"), undefined);
  });
});

describe("which session a row is", () => {
  it("is the issue when there is one", () => {
    // Five sessions in one checkout are skyaccess-ef, -a1, -62: names nobody
    // chose and nobody remembers. The issue is what the person calls the work.
    const s = session({ state: "working", cwd: "/Users/me/work/skyaccess", name: "skyaccess-ef", issue: "SKY-5463" });
    assert.equal(labelOf(s), "SKY-5463");
  });
  it("is a generated name when no issue was named", () => {
    // "skyaccess-d5" against "GSC": one of these is how the person thinks of it.
    const s = session({ state: "working", cwd: "/Users/me/work/skyaccess", name: "skyaccess-d5", label: "GSC" });
    assert.equal(labelOf(s), "GSC");
    assert.equal(labelOf({ ...s, issue: "SKY-1234" }), "SKY-1234");
  });
  it("falls back to the session name, then the folder", () => {
    assert.equal(labelOf(session({ state: "working", cwd: "/Users/me/work/skyaccess", name: "skyaccess-ef" })), "skyaccess-ef");
    assert.equal(labelOf(session({ state: "working", cwd: "/Users/me/work/skyaccess" })), "skyaccess");
  });
});

describe("a turn that ended by asking", () => {
  // Stop says a turn ended. It cannot say whether the session is done or is
  // standing there with five decisions it needs — "Нужно твоё решение (без него
  // «полный» не наступит)" was filed under Answered. Only the message knows, so
  // a model reads it, once, and answers in two lines.
  it("reads the verdict and the line", () => {
    assert.deepEqual(parseAsk("YES\nНужно решение по 5 пунктам: promote R20 на прод, operator_name…"), {
      needs_you: true,
      line: "Нужно решение по 5 пунктам: promote R20 на прод, operator_name…",
    });
    assert.deepEqual(parseAsk("NO\nОба PR в CI, красный прогон на старом коде доказан."), {
      needs_you: false,
      line: "Оба PR в CI, красный прогон на старом коде доказан.",
    });
  });
  it("carries the answers a person is likely to give, so one tap drafts the reply", () => {
    // "го" is most of what gets typed back. The replies only ever fill the
    // draft — a tap never sends — because an approval sent by a stray click is
    // a tool call nobody approved.
    assert.deepEqual(parseAsk("YES\nНужно «го» на план из трёх фаз\nREPLIES: Го по всем фазам | Только фаза 1 | Подожди, есть вопросы"), {
      needs_you: true,
      line: "Нужно «го» на план из трёх фаз",
      replies: ["Го по всем фазам", "Только фаза 1", "Подожди, есть вопросы"],
    });
    // Nothing to answer, nothing to offer — whatever the model appended.
    assert.deepEqual(parseAsk("NO\nCI is running.\nREPLIES: ok"), { needs_you: false, line: "CI is running." });
  });
  it("forgives the wrapping a model adds", () => {
    assert.deepEqual(parseAsk("**Yes.**\n\n2) Нужно твоё «го» на сборку"), { needs_you: true, line: "Нужно твоё «го» на сборку" });
  });
  it("refuses what it cannot read, rather than guess at urgency", () => {
    assert.equal(parseAsk("Сессия занимается синхронизацией HubSpot."), undefined);
    assert.equal(parseAsk("YES"), undefined);
    assert.equal(parseAsk(""), undefined);
  });
  it("moves the session to where a person looks first, saying what it needs", () => {
    const s = session({ state: "idle", last_message: "Статус на 07:55Z — работа идёт…", needs_you: true, line: "Нужно решение по 5 пунктам" });
    assert.equal(STATES[stateOf(s)].group, "waiting");
    assert.equal(headlineOf({ ...s, state: stateOf(s) }), "Нужно решение по 5 пунктам");
  });
  it("leaves a finished turn that asks nothing where it was, with a better line", () => {
    const s = session({ state: "idle", last_message: "Статус на 07:55Z — работа идёт. ## Заголовок", needs_you: false, line: "Оба PR в CI." });
    assert.equal(stateOf(s), "idle");
    assert.equal(headlineOf(s), "Оба PR в CI.");
  });
  it("never overrides a session that has moved on", () => {
    const s = session({ state: "working", needs_you: true, line: "Нужно решение" , saying: "Закрываю тестами." });
    assert.equal(stateOf(s), "working");
    assert.equal(headlineOf(s), "Закрываю тестами.");
  });
});

describe("the line of a blocked session", () => {
  it("says what it wants, not that it wants something", () => {
    const s = session({
      state: "blocked.dialog",
      waiting_for: "Claude needs your permission",
      asking: "Prod: apply the approved heal on 22 Thrive legs",
      saying: "Сейчас применю.",
    });
    assert.equal(headlineOf(s), "Prod: apply the approved heal on 22 Thrive legs");
  });
  it("falls back to the sentence Claude Code gave", () => {
    assert.equal(headlineOf(session({ state: "blocked.dialog", waiting_for: "Claude needs your permission" })), "Claude needs your permission");
  });
  it("leaves a working session its own sentence", () => {
    // The live registry says "input needed" about sessions that are not blocked.
    const s = session({ state: "working", waiting_for: "input needed", saying: "Закрываю тестами." });
    assert.equal(headlineOf(s), "Закрываю тестами.");
  });
});

describe("what a model hands back when asked for a name", () => {
  it("keeps the name and drops the wrapping", () => {
    assert.equal(cleanLabel("GSC"), "GSC");
    assert.equal(cleanLabel('"Pricing email".'), "Pricing email");
    assert.equal(cleanLabel("**Иконка меню**\n"), "Иконка меню");
  });
  it("takes the first line, because the rest is the model talking", () => {
    assert.equal(cleanLabel("Разница pricing\n\nЯ не имею доступа к Linear, чтобы проверить статус."), "Разница pricing");
  });
  it("refuses a sentence, which is an answer and not a name", () => {
    // A wrong label is worse than the session name it would replace.
    assert.equal(cleanLabel("Я не имею доступа к Linear, чтобы проверить статус задачи"), undefined);
    assert.equal(cleanLabel(""), undefined);
    assert.equal(cleanLabel(undefined), undefined);
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

describe("a system envelope is not something a person said", () => {
  // Claude Code delivers task notifications and monitor wakes through the same
  // field a person types into. A row that reads "<task-notification>" is showing
  // plumbing, and a step parsed out of one is a step nobody declared.
  const notification = "<task-notification>\n<task-id>abc</task-id>\n</task-notification>";

  it("is not a prompt", () => {
    assert.equal(userPrompt(notification), undefined);
    assert.equal(userPrompt("<system-reminder>be careful</system-reminder>"), undefined);
    assert.equal(userPrompt("  "), undefined);
    assert.equal(userPrompt(undefined), undefined);
  });

  it("leaves real words alone, including ones with angle brackets in them", () => {
    assert.equal(userPrompt("почини <div> в шапке"), "почини <div> в шапке");
    assert.equal(userPrompt("/morgan:pull дособери"), "/morgan:pull дособери");
  });

  it("declares no step", () => {
    assert.equal(phaseOf(notification), undefined);
  });

  it("never becomes the subject of a row", () => {
    const row = session({ state: "working", last_prompt: notification });
    assert.equal(subjectOf(row), "working");
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

  it("finds the issue a session was given before anyone was keeping it", async () => {
    // The link is in the first prompt and the follow-ups never repeat it, so by
    // the time the bridge learns to keep it the record has already lost it.
    const path = await transcript([
      { type: "last-prompt", lastPrompt: "/track https://linear.app/skyaccess/issue/SKY-4483/10-resolve-pricing это готово?" },
      toolUse("Bash", { command: "linear issue view SKY-1111" }),
      // A tool result names other issues all day; none of them is this session.
      { type: "user", message: { content: [{ type: "tool_result", content: "related: https://linear.app/skyaccess/issue/SKY-7777/x" }] } },
      { type: "last-prompt", lastPrompt: "да, пуш" },
    ]);
    assert.equal(await readIssue(path), "SKY-4483");
    assert.equal(await readIssue(await transcript([{ type: "last-prompt", lastPrompt: "почини иконку" }])), undefined);
    assert.equal(await readIssue(undefined), undefined);
  });

  it("finds the command a session was opened with", async () => {
    // A bare slash command is not a `last-prompt` row — that row says null — so
    // the one declaration of intent in the file is in a place nothing was reading.
    const path = await transcript([
      { type: "last-prompt", lastPrompt: null },
      { type: "user", message: { content: "<command-message>sky-verify-mine</command-message>\n<command-name>/sky-verify-mine</command-name>" } },
      { type: "user", message: { content: [{ type: "text", text: "# /sky-verify-mine\n\nTake every issue assigned…" }] } },
      { type: "last-prompt", lastPrompt: "доделывай всё что быстро" },
    ]);
    assert.equal(await readCommand(path), "/sky-verify-mine");
    const withArgs = await transcript([
      { type: "user", message: { content: "<command-name>/morgan:track</command-name>\n<command-args>fix the icon</command-args>" } },
    ]);
    assert.equal(await readCommand(withArgs), "/morgan:track fix the icon");
    assert.equal(await readCommand(await transcript([{ type: "last-prompt", lastPrompt: "hi" }])), undefined);
  });

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

  it("says a command the way the model said it", async () => {
    // Every Bash call carries a description the model wrote — 185 of 185 on the
    // day this was checked — and the command beside it read
    // `running SP=/private/tmp/claude-501/…`.
    const path = await transcript([
      toolUse("Bash", { command: "SP=/private/tmp/x; cd $SP\ncat > p7.sh <<'EOF'\nls\nEOF", description: "Prod read-only: confirm deployed guards" }),
    ]);
    assert.equal((await readSessionSummary(path)).doing, "Prod read-only: confirm deployed guards");
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

  describe("everything the session has said since you last spoke", () => {
    // Truncating this is what kept sending people back to the terminal: the row
    // said a session had answered, and then would not show the answer.
    const userSays = (text: string) => ({ type: "user", message: { content: [{ type: "text", text }] } });
    const toolResult = () => ({ type: "user", message: { content: [{ type: "tool_result", content: "ok" }] } });

    it("joins the whole turn, oldest first", async () => {
      const path = await transcript([
        userSays("сделай"),
        says("Начинаю."),
        toolUse("Bash", { command: "ls" }),
        toolResult(),
        says("Готово."),
      ]);
      assert.equal(await readTurnNarration(path), "Начинаю.\n\nГотово.");
    });

    it("stops at your message, not at a tool result", async () => {
      // A tool result is also a "user" row. Treating it as the boundary would
      // cut the turn at the first command it ran.
      const path = await transcript([says("Старый ход."), userSays("теперь другое"), says("Новый ход.")]);
      assert.equal(await readTurnNarration(path), "Новый ход.");
    });

    it("says nothing when the turn has produced no words yet", async () => {
      const path = await transcript([userSays("сделай"), toolUse("Bash", { command: "ls" })]);
      assert.equal(await readTurnNarration(path), undefined);
      assert.equal(await readTurnNarration(undefined), undefined);
    });
  });
});
