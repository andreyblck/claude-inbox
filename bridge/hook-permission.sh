#!/bin/bash
# PermissionRequest — hand the decision to the app, and wait for it here.
#
# This process IS the daemon: it holds the request open, and the app only has to
# drop a verdict file. On timeout we print nothing, and the usual terminal prompt
# happens as if the bridge did not exist.
set -uo pipefail
cd "$(dirname "$0")" 2>/dev/null || exit 0
# shellcheck source=lib.sh
. ./lib.sh 2>/dev/null || exit 0

TIMEOUT="${CLAUDE_INBOX_PERMISSION_TIMEOUT:-300}"

payload=$(cat) || exit 0
inbox_ready || exit 0

# Nothing to show and nothing to answer: a request with no session is not one we
# can render, and writing it anyway is how ghost rows are born.
[ -n "$(printf '%s' "$payload" | "$JQ" -r '.session_id // empty' 2>/dev/null)" ] || exit 0

# Three kinds of ask reach this hook, and only one of them is "may I run this".
# A question and a plan are answered on the card itself — Claude Code says so:
# both declare requiresUserInteraction(), and a bare allow for them is dropped.
tool=$(printf '%s' "$payload" | "$JQ" -r '.tool_name // empty' 2>/dev/null)
case "$tool" in
  AskUserQuestion) kind=question; state=blocked.question ;;
  ExitPlanMode)    kind=plan;     state=blocked.plan ;;
  *)               kind=permission; state=blocked.permission ;;
esac

req=$(inbox_req_id) || exit 0
pending="$INBOX_DIR/pending/$req.json"
# Armed before the file exists, so there is no window where a failure between the
# two leaves a row behind.
trap 'rm -f "$pending" 2>/dev/null' EXIT

printf '%s' "$payload" | "$JQ" --arg req "$req" --arg kind "$kind" --arg state "$state" \
  --argjson ts "$(date +%s)" --argjson pid "$$" '{
  req: $req,
  kind: $kind,
  state: $state,
  ts: $ts,
  # Whoever reads this row can check whether the process holding the request is
  # still alive. A SIGKILLed hook runs no trap, and without this the row is
  # permanent and approving it does nothing.
  pid: $pid,
  session_id: .session_id,
  cwd: .cwd,
  tool_name: .tool_name,
  tool_input: .tool_input,
  permission_mode: .permission_mode,
  transcript_path: .transcript_path,
  prompt_id: .prompt_id,
  # Claude Code offers these itself — trust this directory, switch to acceptEdits.
  # "Allow and stop asking" is built from them rather than from a rule we invent.
  permission_suggestions: (.permission_suggestions // null)
}' 2>/dev/null | inbox_write "$pending" || exit 0


# Blocking for the full timeout when nothing is listening is a freeze before
# every prompt, in exchange for an answer that was never coming.
inbox_listening || exit 0

verdict=$(inbox_wait "$req" "$TIMEOUT") || exit 0

decision=$(printf '%s' "$verdict" | "$JQ" -r '.decision // empty' 2>/dev/null)
case "$decision" in
  allow|deny) ;;
  *) exit 0 ;;
esac
reason=$(printf '%s' "$verdict" | "$JQ" -r '.reason // "Answered in Claude Inbox"' 2>/dev/null)

# A broader grant the person pressed: "trust this directory", "accept edits".
# These are Claude Code's own `permission_suggestions`, handed straight back — we
# never build one. A malformed entry makes Claude Code drop the whole array and
# log "malformed updatedPermissions ignored" at warn level, which nobody sees, so
# anything that is not a JSON array is left out entirely rather than guessed at.
grants=$(printf '%s' "$verdict" | "$JQ" -c 'select(.updated_permissions | type == "array") | .updated_permissions' 2>/dev/null)
case "$grants" in '['*) ;; *) grants="" ;; esac

# The answer to a question or a plan. Claude Code drops a bare allow for a tool
# that declares requiresUserInteraction(), so for those the answer IS the
# decision: it rides in updatedInput, which must echo the tool's own input
# untouched and add `answers` — anything else is refused.
answer=$(printf '%s' "$verdict" | "$JQ" -c 'select(.updated_input | type == "object") | .updated_input' 2>/dev/null)
case "$answer" in '{'*) ;; *) answer="" ;; esac

# The contract, verbatim from the binary's own validator:
#   {behavior: "allow", updatedInput?: object} | {behavior: "deny", message: string}
# `decision` is an OBJECT. A string here fails schema validation, the decision is
# dropped, the schema error is surfaced into the session, and the terminal prompts
# anyway — which looks exactly like the hook timing out. Get this shape wrong and
# nothing tells you.
"$JQ" -n --arg d "$decision" --arg r "$reason" --argjson g "${grants:-null}" --argjson i "${answer:-null}" '{
  hookSpecificOutput: {
    hookEventName: "PermissionRequest",
    decision: (if $d == "allow"
               then ({behavior: "allow"}
                     + (if $g == null then {} else {updatedPermissions: $g} end)
                     + (if $i == null then {} else {updatedInput: $i} end))
               else {behavior: "deny", message: $r} end)
  }
}' 2>/dev/null
exit 0
