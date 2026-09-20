# claude-inbox

A native macOS control surface for Claude Code, built as a Raycast extension.

One hotkey shows every Claude Code session on the machine that is waiting for you,
what it is waiting for, and answers it — without finding the terminal window.

## Why

With a dozen parallel sessions the bottleneck stops being the model and becomes the
human round trip: a session blocks on a permission prompt or a question, and you find
out twenty minutes later by accident. The terminal gives no aggregate view, and
notifications (bell, banner) say "something happened" without saying what, and cannot
be answered.

## Shape

Two halves, one product:

```
bridge/    Claude Code hooks (bash + jq, no dependencies)
           installed once at user scope -> every session on the machine reports in,
           whatever terminal it runs in
extension/ Raycast extension: inbox, menu bar board, dispatch
```

They talk through a directory, not a daemon:

```
~/.claude/inbox/            mode 0700
  sessions/<session_id>.json   registry: cwd, state, phase, last message
  pending/<req_id>.json        what a session is waiting for, and the pid holding it open
  verdicts/<req_id>.json       the answer, written by Raycast
  usage/<config_dir>.json      rate limits, context, cost — one file per account
  config-dirs                  every config directory the bridge was installed into
  heartbeat, heartbeat-menubar Raycast saying it is here
```

There is no background process. Raycast cannot host one (its commands are
short-lived), and none is needed: a blocking hook is its own waiter. A
`PermissionRequest` hook may run for up to 600s by default, so the hook process
itself holds the request open and waits for the verdict file.

## Where the state comes from

Three sources, because each knows something the others don't:

| Source | Knows | Needs the bridge installed |
|---|---|---|
| `<config>/sessions/*.json` | who is alive right now: session name, cwd, status, pid | no |
| `bridge/` hooks | what a session is waiting for, its phase, its last message | yes |
| `bridge/statusline.sh` | rate limits, context, cost | yes |

The live registry matters more than it looks: **hooks are read when a session
starts**, so a session that was already running when the bridge was installed
never reports in. Reading Claude Code's own registry makes those sessions appear
anyway, which is the normal case on the first run.

It lives under the **config directory**, not under `$HOME` — so it moves with
`CLAUDE_CONFIG_DIR`. That is why `install.sh` records every config directory it
installs into: the reader cannot guess where an account keeps its sessions, and
guessing wrong shows an empty inbox with a dozen sessions running.

Neither source is authoritative on its own, so the merge takes **the freshest
observation**. The registry does not know a session ended cleanly; the hooks do not
know a new turn started until the next event fires. Pick a fixed winner and rows
get pinned to a state that stopped being true minutes ago.

## The one contract that matters

A `PermissionRequest` hook answers with an **object**:

```json
{"hookSpecificOutput": {"hookEventName": "PermissionRequest",
                        "decision": {"behavior": "allow"}}}
{"hookSpecificOutput": {"hookEventName": "PermissionRequest",
                        "decision": {"behavior": "deny", "message": "not on staging"}}}
```

A string where that object goes fails validation, and the failure is quiet: Claude
Code falls through to the normal prompt, which from the outside looks exactly like
the hook timing out. See `spikes/README.md` for the full contract, read out of the
2.1.278 binary.

## Safety rule for every hook in `bridge/`

Never break a session. On any error, any missing tool, any malformed payload:
exit 0 with no output. A timed-out or silent hook means "no decision", and Claude
Code continues through its normal permission flow. The bridge can only ever add a
faster path, never remove the existing one.

The corollary, learned the hard way: **printing the wrong thing is worse than
printing nothing.** Output that fails the schema is surfaced into the session as an
error. Silence is the safe failure; a malformed decision is not.

## Try it

```bash
cd extension && npm install && npm run dev     # installs into Raycast, hot reloads
../bridge/install.sh                           # hooks + status line, backs up settings.json
../bridge/demo.sh                              # fill the inbox with believable data
../bridge/demo.sh --clear                      # remove every demo row
../bridge/install.sh --uninstall               # hooks out, your status line back
```

**One manual step Raycast requires:** open Raycast, run **Claude Sessions** once and
allow it to run in the background, or enable it under Settings → Extensions → Claude
Inbox. Until it has run, the bridge deliberately stays quiet rather than waking a
command that is not there — otherwise Raycast answers every nudge with an error
toast, once per turn, per session.

`install.sh` wraps an existing `statusLine` rather than replacing it, and the
permission hook waits 20s by default (`--wait N`) before letting the terminal
prompt as usual — so the worst case of a bug is a 20 second delay, never a
blocked session. With Raycast not running it does not wait at all.

## Tests

```bash
bridge/selftest.sh        # the hook's own logic, against a throwaway inbox
bridge/install-test.sh    # install.sh against throwaway config dirs — 12 cases
bridge/e2e.sh             # a real `claude -p` session; --deny and --silent too
cd extension && npm test  # the merge rules, and the hook run against writeVerdict
```

`e2e.sh` is the one that earns its keep. `selftest.sh` was green for a day while
the product did not work at all, because it asserted the same wrong shape the hook
emitted — a test written from the same head as the code proves self-consistency,
not a contract. `e2e.sh` drives real Claude Code and checks whether the tool
actually ran.

## Status

Alpha. The permission round trip works end to end and is covered by tests.
See PLAN.md for what is next and spikes/README.md for the verified ground truth.
