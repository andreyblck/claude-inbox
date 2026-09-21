# claude-inbox

A macOS menu bar app plus a set of Claude Code hooks: every session on the machine
that is waiting for you, in one place, answerable without finding the terminal.

## Commands

```bash
# App (from app/)
swift build                        # debug build into .build/
./package.sh [--dmg]               # universal release build with bridge/ inside the bundle, installs into
                                   # /Applications (kills the running copy); --dmg also writes build/ClaudeInbox.dmg
.build/debug/ClaudeInbox --dump                                # what the panel would show, as text
.build/debug/ClaudeInbox --snapshot out.png [--light] [--open N] # the panel drawn to a file

# Spec (from spec/)
npm install && npm test            # the rules the app is ported from — 91 cases

# Bridge (from bridge/)
./install.sh                       # hooks + status line into ${CLAUDE_CONFIG_DIR:-~/.claude}
./install.sh --uninstall
./selftest.sh                      # the hooks' own logic, throwaway inbox
./install-test.sh                  # install.sh against throwaway config dirs
./e2e.sh [--deny|--silent]         # a REAL `claude -p` session; the test that matters. Run after any bridge change.
./demo.sh [--clear]                # invented sessions for judging the UI and for screenshots
```

Screenshots from the demo without touching the real inbox: point `CLAUDE_INBOX_DIR` at a
scratch dir holding a `config-dirs` file that names an empty config dir, run `demo.sh`,
then `--snapshot`. The README's images were made that way.

## Structure

- `bridge/` — bash hooks, `/usr/bin/jq` only; `install.sh` needs `/usr/bin/python3` (command line
  tools). Shipped inside the app at `Contents/Resources/bridge`, and `Bridge.swift` runs it from
  there — so a downloaded copy installs its own hooks. `lib.sh` holds the shared rules;
  `hook-session.sh` keeps the session record; `hook-permission.sh` blocks and decides.
- `app/Sources/ClaudeInbox/` — Swift. `State.swift` is the vocabulary, `Format.swift`
  every user-visible string, `Transcript.swift` the transcript reader, `Inbox.swift` the
  filesystem, `Store.swift` the one place rows are assembled, `InboxView.swift` the panel.
  `ClaudeCLI.swift` asks the local `claude`; `Labels.swift` (names) and `Asks.swift`
  (readings of a finished turn) use it, cached on disk.
- `spec/lib/` — the same rules in TypeScript, with tests. A rule changes here first, then
  is ported. There is no Swift test target; `--dump` and `--snapshot` are the check.
- `DESIGN.md` — the contract for anything a person sees. `NATIVE.md` — why Swift.
  `spikes/README.md` — verified hook payloads for Claude Code 2.1.278.

## Status

- Working and used daily: permission round trip, reading answers, notes back into a
  session, starting sessions, accounts, names, readings of a finished turn with one-tap
  replies, Linear links, native design in both appearances.
- Not built: answering questions and plans from the panel (S4 in `PLAN.md`) — note `AskUserQuestion`
  does not exist in `claude -p`, so its e2e has to drive an interactive session (`expect` + a pty); a permission
  whose hook timed out shows without its command; "Go to Terminal" raises the app, not
  the tab.

## Next

Public at github.com/andreyblck/claude-inbox with a DMG on the releases page (unsigned: Gatekeeper
needs Open Anyway once; a Developer ID would remove that). Then S4 — `AskUserQuestion` and `ExitPlanMode` both require the answer to ride
in `decision.updatedInput`; see `PLAN.md` and the spike.

## Context

- **A `Row.id` is composed** (`session:<id>`, `pending:<req>`) while a notification carries the
  bare id. Match with `Row.answers(to:)`, never `== row.id` — that mismatch is why a tapped
  banner did nothing for two releases.
- **The sweep must read the turn, not the record.** Claude Code fires a `Notification` about the
  very request the hook is waiting on. Treating any newer session record as "answered elsewhere"
  deleted every question card the instant it appeared. Only `UserPromptSubmit`, `Stop` and
  `SessionEnd` mean the turn moved on.
- **A question is not a permission.** 20s is a liveness budget for "may I run this"; a question
  is read and thought about. `CLAUDE_INBOX_ANSWER_TIMEOUT` (300s) covers question/plan, and the
  hook entry's `timeout` in settings.json has to cover the longer of the two or Claude Code kills
  the hook first. Changing either means re-running `install.sh` — an installed settings.json
  keeps the numbers it was written with.
- **The output shape is the whole ballgame.** A `PermissionRequest` decision is an object.
  A string there fails validation *quietly* and looks exactly like a timeout. Check
  `spikes/README.md` before touching hook output, and run `e2e.sh` after.
- **`Notification` is two things.** `notification_type` is `permission_prompt` (a block)
  or `idle_prompt` (a minute of nobody typing after a turn ended; the session may be busy
  with agents or CI). The first version filed both under "waiting for you", and its test
  passed because the fixture omitted the field. Test with the captured payloads.
- **Two sources, neither authoritative.** The live registry knows liveness; the hooks
  know intent. The merge takes the freshest observation. Compare `startedAt` (epoch ms),
  never the `procStart` string.
- **Do not watch your own writes.** The store watches `sessions/ pending/ usage/`, not the
  inbox root: watching the root included the heartbeat the store itself writes on every
  read, and the app reloaded four times a second at a third of a core.
- **No repeating `symbolEffect`.** It redraws every frame for as long as the view exists,
  panel open or closed. Anything that moves is a `TimelineView` gated on
  `store.panelVisible`.
- **One-shot `claude` calls** go through `ClaudeCLI.ask`: `--tools ""` (a link in the
  prompt otherwise sends Haiku for a tool and `--max-turns 1` ends it with no text),
  `--setting-sources local` (the person's `"language"` setting otherwise decides the
  answer's language), `CLAUDE_INBOX_DIR` pointed at scratch, and a scratch `cwd` whose
  name (`claude-inbox-ask-…`) is how the registry reader skips our own runs. `--bare`
  cannot be used: it reads neither OAuth nor the keychain.
- **A bare slash command is not a `last-prompt` row.** Claude Code writes it as a user
  row wrapped in `<command-name>`; anything reading "what was asked" from the transcript
  has to read both.
- **Sessions on a thinking model narrate less.** Opus wrote a text block in 17 of 100
  assistant rows, Fable in 8. The "free sentence" tier is often empty; that is why names
  and readings are generated.
- `.camp/track-rows-say-nothing.md` has the full trace of the row/notification diagnosis,
  with the reproduction commands and the theories ruled out.
