# Spikes

Ground truth for the mechanisms in PLAN.md S0, against **Claude Code 2.1.278**.

Everything below was read out of the shipped binary
(`~/.local/share/claude/versions/2.1.278`) or observed in a live session, and the
binary wins over the docs wherever they differ. The capture hooks in this repo's
`.claude/settings.json` fire **only** for sessions started in this folder.

## How to run

```bash
cd ~/Desktop/work/blckgh/raycast-app
bridge/selftest.sh        # the hook's own logic, against a throwaway inbox
bridge/install-test.sh    # install.sh against throwaway config dirs
bridge/e2e.sh             # a real `claude -p` session, verdict dropped from outside
cd extension && npm test  # the merge rules, and the hook/extension protocol
```

| # | Case | Verdict |
|---|------|---------|
| S0.1 | Payload shapes | **works** — captured below |
| S0.2 | `AskUserQuestion` intercept | **works with a caveat** — a bare allow is dropped |
| S0.3 | `ExitPlanMode` intercept | **works with the same caveat** |
| S0.4 | `Stop` + `asyncRewake` late answer | **exists** — schema confirmed, not yet exercised |

## Findings

### S0.1 — the `PermissionRequest` contract

**Input** (live capture):

```json
{
  "session_id": "…", "transcript_path": "…", "cwd": "…",
  "prompt_id": "…", "permission_mode": "default",
  "hook_event_name": "PermissionRequest",
  "tool_name": "Bash",
  "tool_input": {"command": "touch it-ran.txt", "description": "…"},
  "permission_suggestions": [
    {"type": "addDirectories", "directories": ["…"], "destination": "session"},
    {"type": "setMode", "mode": "acceptEdits", "destination": "session"}
  ]
}
```

There is **no `tool_use_id`** on this event — `PreToolUse` has one, this does not.
A request can only be correlated by `session_id` + `tool_name` + `tool_input`.

`permission_suggestions` is Claude Code offering the broader grant itself. That is
what "allow and stop asking" should be built from, not a rule we invent.

**Output.** This is the one that cost a day:

```json
{"hookSpecificOutput": {"hookEventName": "PermissionRequest",
                        "decision": {"behavior": "allow"}}}
{"hookSpecificOutput": {"hookEventName": "PermissionRequest",
                        "decision": {"behavior": "deny", "message": "…"}}}
```

`decision` is an **object**. A string there fails schema validation, and the
failure is not loud: Claude Code treats the output as plain text, prints
`hook output invalid: …` with a schema dump, and falls through to the normal
permission flow. From the outside that is indistinguishable from a hook that timed
out — which is exactly how it went unnoticed. The binary's own error string:

> `(PermissionRequest decision must be {"behavior": "allow"} or {"behavior": "deny", "message": "..."})`

Allow also takes `updatedInput` (object) and `updatedPermissions` (array). Deny
takes `message` and `interrupt`. There is no `reason` field at any level, and no
`ask` — that value belongs to `PreToolUse.permissionDecision`.

**When it fires.** Only once the permission evaluation has already resolved to
"ask". In an interactive TUI the dialog is rendered **and** the hooks run, racing:
whoever answers first wins, and the hook's answer tears the dialog down. So the
terminal prompt still appears — the bridge is a second, faster way to answer it,
never a replacement. In a session that cannot prompt, no decision means deny.

**Timeout.** Default 600s for a `command` hook, no maximum in the schema. The 20s
in `install.sh` is our choice, not a limit.

### S0.2 / S0.3 — answering a question or a plan

Both tools declare `requiresUserInteraction()`, and the permission path drops a
bare allow for them: `if (!x.updatedInput && e.requiresUserInteraction?.()) return null`.
So an allow must carry `updatedInput` with the answer in it. Deny has no such
guard and always works.

- `AskUserQuestion.tool_input`: `{questions: [{question, header, options: [{label, description}], multiSelect}]}`.
  To answer, echo `questions` back and add `answers` mapping question → chosen label.
- `ExitPlanMode.tool_input`: the model sends almost nothing, but Claude Code
  injects `plan` and `planFilePath` before hooks see it — so the plan text is there.

This is S4's whole design, and it is unblocked.

### S0.4 — waking a finished session

`asyncRewake` is a field on a `command` hook entry, not an event: *"If true, hook
runs in background and wakes the model on exit code 2 (blocking error)."* The wake
carries `rewakeMessage` + the hook's stderr/stdout. Schema confirmed in the binary;
not yet run end to end, because it needs an interactive TTY.

### Session lifecycle, and the event that was missing

`SessionStart` carries `{session_id, transcript_path, cwd, scratchpad_dir, source, model}`
— and **no `permission_mode`**. `UserPromptSubmit` does carry it.

`Stop` fires at the end of **every turn**, not at the end of the session. Without
`UserPromptSubmit` to mark a turn starting, the registry says `idle` from the first
completed answer until the process dies — a grey Idle row over a working session.
Both events are installed now.

### The live registry, `~/.claude/sessions/`

One `<pid>.json` per session (plus `<pid>.<hash>.key` siblings, which are not JSON):

```json
{"pid": 7441, "sessionId": "…", "cwd": "…", "startedAt": 1789892889175,
 "procStart": "Sun Sep 20 08:28:05 2026", "kind": "interactive",
 "name": "raycast-app-cb", "status": "busy", "statusUpdatedAt": 1789892919301}
```

Timestamps are **milliseconds**. `status` is exactly `busy | shell | idle | waiting`
— `shell` is idle with the user at a `!` prompt, and `waiting` is a dialog only the
terminal can answer. `kind` is `interactive | bg | daemon | daemon-worker`; the last
two are machinery, not sessions. `procStart` is there because a pid alone does not
identify a process across a reboot.

This registry lives under the **config directory**, so it moves with
`CLAUDE_CONFIG_DIR`. `install.sh` records every config dir it installs into, in
`inbox/config-dirs`, because the reader cannot guess it.

### The status line payload

`rate_limits.{five_hour,seven_day}.{used_percentage,resets_at}` is real and
first-party (`resets_at` in seconds). `context.used_percentage` is **null** until
the first API response of a session. The session's own directory is
`workspace.current_dir` — a wrapped status line has to be run from there, or every
`git branch` in someone's status line reports the wrong repo.
