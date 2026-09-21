# Claude Inbox

A menu bar app for macOS that shows every Claude Code session on your machine
that is waiting for you — and lets you answer it without finding the terminal.

<p align="center">
  <img src="docs/screenshots/panel-dark.png" width="440" alt="The panel: sessions grouped into Waiting for You, Answered, Running">
</p>

Run a dozen sessions in parallel and the bottleneck stops being the model. It
becomes you: a session blocks on a permission prompt or ends its turn with a
question, and you find out twenty minutes later by accident. The terminal has no
aggregate view, and the system notification says "Claude is waiting for your
input" without saying which session, or for what.

Claude Inbox answers three questions at a glance:

- **Who needs me?** A permission to approve, a decision to make, a question to
  answer — with Approve and Deny right on the row, and on the banner.
- **What did they say?** A finished turn is an answer. Read the whole thing, as
  rendered markdown, in the panel.
- **What is everyone doing?** Every running session, named after the issue it is
  working on, with the model's own sentence about its current move.

## What it looks like

<p align="center">
  <img src="docs/screenshots/decision-dark.png" width="440" alt="An open row: a permission with Approve and Deny, and a decision the session is waiting on, with the full answer under it">
</p>

A session that ended its turn by asking you something moves to **Waiting for You**
with the ask in one line — "Decide: keep legacy_rate one more release, or drop it
now" — and a banner that says the same. Open it and the whole answer is there,
with one-tap replies drafted in the session's language.

<p align="center">
  <img src="docs/screenshots/permission-light.png" width="440" alt="Light appearance: a permission request opened, showing the exact command">
</p>

Sessions are named after the tracker issue they were opened with (`ACME-231`),
or, when there is none, a short name the app asks a model for once ("Onboarding
email", "Docs search"). Answers you have not opened carry the blue dot Mail uses.
Running sessions show the three dots of someone typing.

Everything follows the system: light and dark appearance, your accent colour,
SF Symbols, the fonts and spacing of every other panel on the Mac.

## Install

Needs macOS 15 or later and Claude Code signed in. Two minutes, no terminal.

**1. Download and open.** Get `ClaudeInbox.dmg` from the
[latest release](https://github.com/andreyblck/claude-inbox/releases/latest),
open it, and drag Claude Inbox into Applications.

**2. Open it once past Gatekeeper.** The app is open source and not signed with
an Apple certificate, so the first launch shows *"Apple could not verify
ClaudeInbox is free of malware"*. Click Done, then open **System Settings →
Privacy & Security**, scroll down to the line about ClaudeInbox, and click
**Open Anyway**. Once. (From a terminal, the same thing is
`xattr -d com.apple.quarantine /Applications/ClaudeInbox.app`.)

**3. Click Install Bridge.** A new icon appears in the menu bar. Click it, or
press **⌥Space**:

<p align="center">
  <img src="docs/screenshots/connect-dark.png" width="440" alt="The first screen: Connect to Claude Code, with an Install Bridge button">
</p>

That adds a few hooks to Claude Code's `~/.claude/settings.json` (backed up
first) so every session on this Mac reports in, and wraps your status line if
you have one. Allow notifications when asked — a banner is how a session that
needs you reaches you when the panel is closed. Sessions already running appear
on their next turn.

To take it out again: **… → Uninstall Bridge**, then drag the app to the Trash.

### From source

```bash
git clone https://github.com/andreyblck/claude-inbox.git
cd claude-inbox
./app/package.sh             # builds a universal binary and installs it into /Applications
open /Applications/ClaudeInbox.app   # then Install Bridge, as above
```

Needs the Xcode command line tools (you have them if you have `git`). The
hooks travel inside the app bundle, so a built app installs them the same way a
downloaded one does; `./bridge/install.sh` from the clone works too and points
the hooks at the clone instead.

## Using it

| | |
|---|---|
| **⌥Space** | open or close the panel |
| type | filter by issue, name, or what the session said |
| **↑ ↓ ↵** | move between rows, open one |
| **⌘↵ / ⌘⌫** | approve / deny the focused permission |
| **⌘1…9** | open the n-th waiting row |
| **⌘L** | open the session's issue in Linear |
| **⌘T** | bring the terminal the session runs in to the front |
| **Esc** | clear the filter, then close |
| right-click | copy the answer, the resume command or the issue key; show in Finder; rename |

An open row has a note field. Notes arrive in the session as a message from a
peer session, not as you — Claude Code frames them that way on purpose, so
nothing outside the terminal can impersonate the person at it. **✦** in the
header asks for a digest of everything at once; **+** starts a new session from
the panel.

## How it works

Two halves, talking through a directory. No daemon, no server, no API key.

```
bridge/   Claude Code hooks: bash + jq, nothing else. Installed once at user
          scope, so every session on the machine reports in, whatever terminal
          it runs in.
app/      The menu bar app, Swift + SwiftUI, reading what the hooks wrote.
spec/     The rules the app is ported from — state, merge, how a row gets its
          line — as TypeScript with tests. When a rule changes, it changes here
          first.
```

```
~/.claude/inbox/                 mode 0700
  sessions/<session_id>.json     state, step, issue, what was asked, what it said
  pending/<req_id>.json          a permission waiting for a verdict, and the pid holding it open
  verdicts/<req_id>.json         the verdict, written by the app
  usage/<config_dir>.json        rate limits, context, cost — one per account
  labels.json, asks.json         names and readings the app asked a model for, kept so
                                 they are asked once
```

A `PermissionRequest` hook is its own waiter: the hook process holds the request
open, the app drops a verdict file, the hook prints the decision and the tool
runs. If nothing answers within 20 seconds the hook goes quiet and the terminal
prompts as usual — the worst case of a bug in this app is a 20-second delay,
never a blocked session. With the app not running the hook does not wait at all.

Every hook follows one rule: **never break a session.** On any error, exit 0 and
print nothing. Silence means "no decision" and Claude Code carries on through its
normal flow; the bridge can only ever add a faster path, never take the existing
one away.

### Where the words come from

A row's line is, in order: the sentence the model wrote before its last action
(free, already in your language), what you asked for, Claude Code's own title,
and the tool being used. That covers a running session.

Two things a transcript cannot say are asked of the `claude` already on your
machine, on your own account, with Haiku:

- **A name**, once per session that names no issue. "GSC" beats `skyaccess-d5`.
- **A reading of a finished turn**, once per message: is it waiting for you, and
  for what, in one line — plus up to three replies you are likely to give. A tap
  drafts one into the note field; it never sends. Waiting for CI, agents or
  timers counts as *no*: the session will wake itself.

Each is one small call, cached on disk, run off to the side and never on the way
to a redraw. They answer in the language the session is written in, and they
run with your Claude Code settings left out (`--setting-sources local`), so a
"reply in Russian" preference does not leak into a line about an English session.
Nothing leaves the machine that Claude Code was not already sending.

### Which session is which

Five sessions in one checkout are `skyaccess-ef`, `-a1`, `-62` — names nobody
chose. The issue key is what people call the work, so it is the label: read from
a Linear link in what you typed, or a bare key like `ACME-231` (three digits or
more — `WI-10` is a real string in a real prompt). Named once, kept until a newer
one is named, because a follow-up never repeats it.

## Tests

```bash
cd spec && npm install && npm test   # the rules: state, merge, subject, transcript reading — 91 cases
bridge/selftest.sh                   # the hooks against a throwaway inbox
bridge/install-test.sh               # install.sh against throwaway config dirs
bridge/e2e.sh                        # a real `claude -p` session blocks, a verdict file decides it
```

`e2e.sh` is the one that earns its keep: it drives real Claude Code. A test that
asserts what the hook emits proves nothing about what Claude Code accepts — the
first version of the permission decision had the wrong shape, passed its own
tests for a day, and could not approve anything.

The Swift port has no test target of its own. `ClaudeInbox --dump` prints what
the panel would show, so the port can be diffed against `spec/` on the same data;
`ClaudeInbox --snapshot out.png [--light] [--open N]` draws the panel to a file,
which is how the screenshots above were made — from `bridge/demo.sh`, on an inbox
of invented sessions. `./app/package.sh --dmg` builds the disk image on the
releases page.

## Status

Works, used daily. Verified against Claude Code 2.1.278; the hook payloads it
depends on are recorded in `spikes/README.md`. Things not done yet:

- A permission's details (which command) live only while the hook waits, so a
  request you missed shows as "needs your permission" without the command.
- Questions (`AskUserQuestion`) and plans (`ExitPlanMode`) are shown but answered
  in the terminal; answering them from the panel is the next slice.
- "Go to Terminal" brings the app forward, not the tab: Warp and most others have
  no way to ask for one.

## License

MIT — see [LICENSE](LICENSE).
