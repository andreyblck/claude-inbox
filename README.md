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
  sessions/<session_id>.json   registry: cwd, title, state, phase
  pending/<req_id>.json        what a session is waiting for
  verdicts/<req_id>.json       the answer, written by Raycast
  events.jsonl                 append-only log
```

There is no background process. Raycast cannot host one (its commands are
short-lived), and none is needed: a blocking hook is its own waiter. A
`PermissionRequest` hook may run for up to 600s by default, so the hook process
itself holds the request open, shows the notification, and waits for the verdict file.

## Where the state comes from

Three sources, because each knows something the others don't:

| Source | Knows | Needs the bridge installed |
|---|---|---|
| `~/.claude/sessions/*.json` | who is alive right now: session name, cwd, status, pid | no |
| `bridge/` hooks | what a session is waiting for, its phase, its last message | yes |
| `bridge/statusline.sh` | rate limits, context, cost | yes |

The live registry matters more than it looks: **hooks are read when a session
starts**, so a session that was already running when the bridge was installed
never reports in. Reading Claude Code's own registry makes those sessions appear
anyway, which is the normal case on the first run.

## Safety rule for every hook in `bridge/`

Never break a session. On any error, any missing tool, any malformed payload:
exit 0 with no output. A timed-out or silent hook means "no decision", and Claude
Code continues through its normal permission flow. The bridge can only ever add a
faster path, never remove the existing one.

## Status

Pre-alpha. See PLAN.md for the slices and spikes/README.md for what is being verified.

## Try it

```bash
cd extension && npm install && npm run dev     # installs into Raycast, hot reloads
../bridge/install.sh                           # hooks + status line, backs up settings.json
../bridge/demo.sh                              # fill the inbox with believable data
../bridge/demo.sh --clear                      # remove every demo row
../bridge/install.sh --uninstall               # hooks out, your status line back
```

`install.sh` wraps an existing `statusLine` rather than replacing it, and the
permission hook waits 20s by default (`--wait N`) before letting the terminal
prompt as usual — so the worst case of a bug is a 20 second delay, never a
blocked session.
