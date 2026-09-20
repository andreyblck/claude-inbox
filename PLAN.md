# Slices

Each slice is shippable on its own and leaves the machine in a working state.
Nothing here touches the user-scope settings until S1 passes.

> **Done:** S0, S1, S1.5, S2, S3 — the permission round trip works end to end against
> real Claude Code and is covered by `bridge/e2e.sh`, `bridge/install-test.sh`,
> `bridge/selftest.sh` and `extension/test/`. S4 is unblocked: see S0.2/S0.3 below.
> **Next:** S4, then S5.

## S0 — Spikes (no extension code) — DONE

Verify the three mechanisms the whole product rests on. Hooks are installed
**project-scoped** in `.claude/settings.json` here, so only sessions started in this
folder are affected. Real work sessions are untouched.

- **S0.1 Payload capture** — record the real stdin shape of `PreToolUse`
  (`AskUserQuestion`, `ExitPlanMode`), `PermissionRequest`, `Notification`, `Stop`,
  `SessionStart`. Docs do not print these; build against ground truth, not guesses.
- **S0.2 Question interception** — `PreToolUse` on `AskUserQuestion` returning
  `deny` + `permissionDecisionReason: "user picked <option>"`. Does the model take
  the answer and move on, or does it apologise and re-ask? This decides whether the
  modal is a feature or a gimmick.
- **S0.3 Plan interception** — same for `ExitPlanMode`.
- **S0.4 Late answer** — `Stop` with `asyncRewake: true`, exiting 2 minutes later.
  Does the session actually wake with the text? Fallback if not: synchronous `Stop`
  with a 60–90s window.

Exit criteria: four notes in `spikes/README.md`, each with the captured payload and
a verdict of works / does not work / works with caveat.

**Result.** All four answered in `spikes/README.md`, against the 2.1.278 binary.
The one that mattered: the decision is an **object** (`{"behavior": "allow"}`), not a
string — and a wrong shape fails silently, falling through to the normal prompt so it
reads as a timeout. S0.2/S0.3 work, with the caveat that `AskUserQuestion` and
`ExitPlanMode` declare `requiresUserInteraction()`, so a bare allow is dropped: the
answer has to ride in `updatedInput`. That is S4's design, and it is settled.

## S1 — Protocol + permission round trip — DONE

`hook-permission.sh`: write `pending/<req>.json`, poll `verdicts/<req>.json`, return
the decision. Verdict written by hand (`echo`) — no UI yet. Proves the block-and-return
path end to end and pins the file format.

Two things this slice should have demanded and did not, both now in place:

- **The test has to drive real Claude Code.** `selftest.sh` asserted the shape the
  hook emitted, so it stayed green while nothing worked. `e2e.sh` runs a real
  `claude -p` session and checks whether the tool ran.
- **The pending file has to say who is holding it.** A hook killed with SIGKILL runs
  no trap, and nothing else ever removed a pending file — one `kill -9` left a row
  that could never be cleared. Every pending record now carries its holder's pid.

## S1.5 — Design system (no feature code) — DONE

DESIGN.md is the contract: the state vocabulary, the menu-bar rules, the inbox
layout, the copy rules. Land it as `extension/src/lib/state.ts` (the eight states,
their icons and tints, the formatters for project name / ask phrase / relative time)
before any view is written, so both views read from one place and cannot drift.

Exit criteria: every string a user can see comes from a formatter, not from a
template literal inside a component.

## S2 — Raycast inbox — DONE

Two-pane `List` per DESIGN.md: sections Waiting / Running / Finished, tinted state
icons, accessories for phase and age, detail pane with the ask, the command, what the
session just did, and a metadata block. Actions: Approve ⌘↵, Deny ⌘⌫, Copy command,
Reveal transcript. Empty state is a designed screen, not a blank list.

## S3 — Menu bar — DONE

`mode: menu-bar`, `interval: 10s` as a safety net; real refresh is the hook kicking a
`launchType=background` deeplink. Raycast refuses that deeplink until the user has
activated the command, and says so in an error toast — once per turn, per session. The
hook therefore nudges only after the menu bar command has run at least once and left
its heartbeat. Monochrome glyph plus a count and nothing else in the
bar; dropdown follows the three-section, five-row, one-line-per-row rules in DESIGN.md.
⌘1…⌘9 approve without reading.

## S4 — Questions as a modal — NEXT

`AskUserQuestion` / `ExitPlanMode` interception from S0.2/S0.3 wired to a Raycast
form: options 1..4 plus a free-text field.

Settled by S0: a bare allow is dropped for both tools, so the answer rides in
`decision.updatedInput` — echo `questions` back with an `answers` map for
`AskUserQuestion`; the plan text is already injected into `ExitPlanMode`'s input
before hooks see it. Gated behind a preference
(always / only when away / never) because interception is exclusive — while the hook
waits, the terminal cannot answer.

## S5 — Native notifications with buttons

Fired by the hook process (it is the one with time to wait). Needs a notifier binary
and the Alerts notification style; the notification is a shortcut to the inbox, never
the only way in.

## S6 — Dispatch

New task without a terminal: `claude --bg`, cwd from recent projects. Plus
`screencapture -i` -> same path, so a bug on screen becomes a task in three seconds.

## S7 — Phase board

Sessions report a phase (Morgan already names them: scope, track, pull, clean).
Menu bar renders the pipeline, so a glance answers "who is where".

## S8 — Doctor (partly absorbed)

Much of what this was meant to catch is now caught at install time — `install.sh`
validates its arguments, refuses a settings.json it cannot parse, keeps every backup,
and recognises its own entries by script name so a moved repo does not leave a dead
hook behind (`install-test.sh` covers all of it). What is left for a doctor is the
part that needs the running system: notification permission and style, whether the
menu bar command was ever activated, and bridge health across accounts — plus
repairing an install someone has since edited by hand.

---

Both slices below are independent of S4–S8 and cheap, so they may jump the queue
once S3 lands. Neither needs the question/answer machinery.

## S9 — Usage

`bridge/statusline.sh` is installed as the `statusLine` command and writes
`inbox/usage/<config-dir>.json` on every assistant message, then hands the same
stdin to whatever status line was configured before — installing the bridge must
never cost someone their own status line.

The payload is first-party and needs no parsing of internals:
`rate_limits.five_hour.used_percentage`, `rate_limits.seven_day.used_percentage`,
both `resets_at`, `context_window.used_percentage`, `cost.total_cost_usd`.

Two honest constraints shape the UI:

- `rate_limits` exists only for Pro/Max accounts, and only after the first API
  response of a session.
- The number moves only while some session is talking. With nothing running it is
  as old as the last message, so **every display carries the age of the number**.
  Firing a probe request to refresh it would spend quota to measure quota; we don't.

Exit criteria: 5h and 7d rings with reset countdowns, visible age, and a threshold
that changes the menu bar glyph.

## S10 — Accounts

An account is a config directory. Verified: `CLAUDE_CONFIG_DIR=<dir> claude auth
status --json` reports that directory and its own login state, so an account is a
per-process environment variable, not a global logout/login dance.

- `inbox/accounts.json`: label, config dir, cached `claude auth status --json`.
- Dispatch (S6) launches with the selected account's `CLAUDE_CONFIG_DIR`.
- Each config directory is a **separate** Claude Code config — its own settings,
  projects and plugins — so `install.sh` must install the bridge into each one.
  `inbox/` itself stays shared: it hangs off `$HOME`, not off the config dir.
- Switching affects **new sessions only**. A running session is bound to the auth it
  started with; the dozen already in flight finish on their own account.

Default behaviour is a warning at the threshold plus one-click switch for the next
task. Silent rotation stays an opt-in preference, off by default — see the note in
DESIGN.md.
