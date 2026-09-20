# claude-inbox

A Raycast extension plus a set of Claude Code hooks: every session on the machine
that is waiting for you, in one place, answerable without finding the terminal.

## Commands

```bash
# Extension (from extension/)
npm install
npm run dev          # builds into Raycast and watches — the extension only runs while this does
npm test             # merge rules + the real hook against the real writeVerdict
npx tsc --noEmit
npx ray build -e dist

# Bridge (from bridge/)
./install.sh                 # hooks + status line into ${CLAUDE_CONFIG_DIR:-~/.claude}
./install.sh --dry-run       # prints the settings.json it would write, touches nothing
./install.sh --uninstall     # hooks out, status line back, stale pending cleared
./selftest.sh                # the hook's own logic, throwaway inbox
./install-test.sh            # 12 cases against throwaway config dirs
./e2e.sh [--deny|--silent]   # a REAL `claude -p` session; the test that matters
./demo.sh [--clear]          # believable rows for judging the UI
```

## Structure

- `bridge/` — bash hooks, no dependencies beyond `/usr/bin/jq`. `lib.sh` holds the
  shared rules; `hook-permission.sh` is the one that blocks and decides.
- `extension/src/lib/` — `state.ts` is DESIGN.md in code, `inbox.ts` is the whole
  filesystem surface, `format.ts` the shared formatters. Views compose, never invent.
- `extension/test/` — bundled with esbuild against a `@raycast/api` stub, since the
  real package does not load outside Raycast.
- `DESIGN.md` — the contract for anything a person sees. `PLAN.md` — the slices.
- `spikes/README.md` — verified ground truth for Claude Code 2.1.278. Read this
  before changing any hook payload or output.

## Status

- The permission round trip works end to end against real Claude Code, verified
  live: hook blocks → `pending/` → verdict → tool runs. S0–S3 done.
- S4 (questions and plans as a Raycast form) is unblocked and is the next slice.
- Not built: notifications (S5), dispatch (S6), phase board (S7), doctor (S8).
- `phase` is in the types and in `demo.sh`, but nothing writes it yet.
- `failed` is unreachable: no hook ever writes it. `SessionEnd` carries a `reason`
  (`clear`, `logout`, …), none of which mean failure.

## Next

S4. The design is settled by the spike: `AskUserQuestion` and `ExitPlanMode` both
declare `requiresUserInteraction()`, so a bare allow is dropped — the answer has to
ride in `decision.updatedInput`. Echo `questions` back with an `answers` map;
`ExitPlanMode` already has the plan text injected before hooks see it.

## Context

- **The output shape is the whole ballgame.** A `PermissionRequest` decision is an
  object — `{"behavior": "allow"}` or `{"behavior": "deny", "message": …}`. A string
  there fails validation *quietly*: Claude Code falls through to the normal prompt,
  which is indistinguishable from a timeout. That bug shipped and survived a green
  test suite for a day. Check `spikes/README.md` before touching hook output.
- **Test against Claude Code, not against yourself.** `selftest.sh` asserted the
  same wrong shape the hook emitted. `e2e.sh` exists because it is the only test
  that can catch that class of bug — run it after any bridge change.
- **Raycast needs two manual steps, and the second is easy to miss.** The menu bar
  command must be activated (run "Claude Sessions" once and allow background), *and*
  Raycast must be allowed in macOS's own menu bar settings — System Settings →
  Control Center. With Raycast switched off there, the command runs on its interval,
  logs nothing, reports "Last refresh" happily, and puts no icon in the bar. Nothing
  in Raycast or in the code says so. The tell is in `defaults read com.raycast.macos`:
  a working item has `NSStatusItem Visible …` and `NSStatusItem Preferred Position …`
  keys; ours had only `VisibleCC`, because macOS never gave it a slot.
  The hook only nudges after `inbox/heartbeat-menubar` exists.
- **The extension only runs while `npm run dev` does.** It is a development
  extension; stop the watcher and the menu bar item goes away.
- **Two sources, neither authoritative.** The live registry (under the *config*
  directory, hence `inbox/config-dirs`) knows liveness; the hooks know intent. The
  merge takes the freshest observation — do not reintroduce a fixed winner.
- **A liveness check resolves every doubt to "alive".** `procStart` in the registry
  is UTC with no zone marker while `ps -o lstart=` prints local time, so comparing
  the strings can only ever fail — which reported every session dead and emptied
  both views. Compare `startedAt` (epoch ms) instead. `test/live.test.ts` pins it.
- `.camp/track-claude-inbox-basics.md` has the full root-cause trace and the
  theories that were ruled out.
