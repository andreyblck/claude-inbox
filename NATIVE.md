# Moving off Raycast

Raycast was the fastest way to find out whether the idea works. It did its job:
the bridge is proven, the state model survived contact with real data, and the
product's shape is clear. What it cannot do is be the product.

This document is what we know before choosing a stack, so the choice is made on
evidence rather than on taste.

## Why Raycast stops here

`MenuBarExtra` renders native `NSMenu` rows and nothing else: icon, title,
subtitle, shortcut. No custom views, no colour (icons are template-rendered), no
layout, no controls inside a row. That is a platform ceiling, not an effort
problem — it was written into DESIGN.md before we hit it.

Everything the product wants next is on the other side of that ceiling:

- a panel you can read an answer in, not a menu row that truncates it
- a reply box
- notifications with buttons
- an account and its credentials, held properly
- anything generated, rendered as more than a string

## What carries over untouched

**`bridge/` in full.** The hooks, the protocol, the install safety, the tests.
This is the part that took the longest and broke the most: the decision shape,
the missing `UserPromptSubmit`, the freshest-observation merge, the liveness
check, the reaping. None of it knows what a UI is.

**The derivation logic**, about 800 lines under `extension/src/lib/` with 61
tests: state model, merge, subject selection, sentence cutting, markdown
stripping, transcript reading, usage. This is knowledge, not plumbing — whatever
the next stack is, these rules stay true.

**DESIGN.md.** The rules about saying a thing once, about a row's one line,
about not inventing urgency, all hold.

What is thrown away is the two `.tsx` views, about 500 lines.

## What a native app can and cannot do

Established by experiment on 2026-09-20 against Claude Code 2.1.278, not by
reading documentation.

Claude Code gives every session a Unix socket at `/tmp/cc-socks/<pid>.sock` and
publishes a token beside it in `~/.claude/sessions/<pid>.<hash>.key`, readable by
the owning user. The binary documents the protocol itself:

```
{ echo '{"type":"auth","token":"'"$TOKEN"'"}';
  echo '{"type":"user","message":{"role":"user","content":"hello"}}'; } \
  | socat - UNIX-CONNECT:/tmp/cc-socks/<pid>.sock
```

**Tested end to end and it delivers.** But the receiving session renders it as:

> Another Claude session sent a message: …
> This came from another Claude session — not typed by your user…

That framing is hardcoded, with no mode that says otherwise, and it is right that
it is: an external process must not be able to impersonate the user to a session.

So there are two classes of session, and the product has to be honest about them:

| | Started in a terminal | Started by the app |
|---|---|---|
| See state, phase, what it said | yes, via the bridge | yes |
| Read the full answer | yes, from the transcript | yes |
| Approve or deny a permission | **yes** — proven, `e2e.sh` | yes |
| Send a message | as a *peer*, with a safety preamble | **as the user** |
| Steer the conversation | no | yes |

**The design conclusion: the app should be able to own sessions.** Dispatch stops
being a convenience feature and becomes the thing that makes the loop close. A
session started from the app is one you can read and answer without a terminal.
A session started in a terminal is one you can watch and unblock. Both are worth
having; only the first removes the round trip.

Sessions the app owns are driven by a supported interface — the Agent SDK, or
`claude -p --input-format stream-json` — not by the peer socket.

## The choice that has to be made first

| | Swift + SwiftUI | Tauri (Rust + web UI) |
|---|---|---|
| Looks like CleanMyMac | yes, natively | yes, it is a web view |
| Menu bar + popover | `NSStatusItem`, first class | tray API, workable |
| Notifications with buttons | `UNNotificationAction`, built in | needs native glue |
| Idle memory | ~30 MB | ~60 MB |
| Keychain, login item, signing | native | via plugins |
| The 800 tested lines | **rewritten in Swift** | **kept as they are** |
| Ceiling later | none on macOS | thin one at the native edge |

Electron is out: 150 MB and a few hundred MB resident for something that is
always running in a menu bar is the wrong trade for this product.

The honest summary: Swift costs a port and buys no ceiling; Tauri keeps the
tested logic and buys speed. The port is not the scary part — those rules are
small and fully specified by their tests, which is exactly what makes a port
safe.

## Slices, once the stack is chosen

Each one leaves a working app.

**N0 — the shell.** Menu bar item, popover, reads the same inbox directory. Same
three sections. Nothing new, everything ported. This is the slice that proves the
stack, and it is where the 61 tests earn their keep as the port's specification.

**N1 — reading.** The panel that makes the terminal unnecessary: the full answer
as rendered markdown, the exchange above it, what it is doing now. This is the
one the current product keeps failing at, and the one with no platform obstacle.

**N2 — answering.** Approve and deny from the panel, which the bridge already
does. Then questions and plans, which the spike unblocked.

**N3 — dispatch.** Start a session from the app, and own it. This is where the
loop closes: read it, reply to it, never open a terminal.

**N4 — notifications.** A banner with Approve and Deny on it, fired by the hook
process that is already waiting. Needs the Alerts style and a notification
category, both native.

**N5 — the app's own intelligence.** Now that there is somewhere to render it:
summaries across sessions, "what changed while I was away", grouping by project
rather than by process.

## What not to repeat

Three mistakes from the Raycast build, all of which cost hours:

1. **A test that asserts what the code does proves nothing.** `selftest.sh` was
   green for a day while the product could not approve anything, because it
   checked the same wrong shape the hook emitted. Only `e2e.sh`, which drives
   real Claude Code, could catch it.
2. **Check the source before designing on it.** The step/phase board was going to
   be built on Claude Code's todo lists. Not one of 225 transcripts had one.
3. **Every uncertainty resolves toward showing something.** A liveness check that
   compared a UTC string to a local one reported every session dead and emptied
   both views — a bug that looked exactly like "nothing is happening".
