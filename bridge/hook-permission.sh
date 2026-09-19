#!/bin/bash
# PermissionRequest — hand the decision to Raycast, and wait for it here.
#
# This process IS the daemon: it holds the request open, and Raycast only has to
# drop a verdict file. On timeout we print nothing, and the usual terminal prompt
# happens as if the bridge did not exist.
set -uo pipefail
cd "$(dirname "$0")" 2>/dev/null || exit 0
# shellcheck source=lib.sh
. ./lib.sh 2>/dev/null || exit 0

TIMEOUT="${CLAUDE_INBOX_PERMISSION_TIMEOUT:-300}"

payload=$(cat) || exit 0
inbox_ready || exit 0

req=$(inbox_req_id) || exit 0
pending="$INBOX_DIR/pending/$req.json"

printf '%s' "$payload" | "$JQ" --arg req "$req" --argjson ts "$(date +%s)" '{
  req: $req,
  kind: "permission",
  state: "blocked.permission",
  ts: $ts,
  session_id: .session_id,
  cwd: .cwd,
  tool_name: .tool_name,
  tool_input: .tool_input,
  permission_mode: .permission_mode,
  transcript_path: .transcript_path
}' 2>/dev/null | inbox_write "$pending" || exit 0

trap 'rm -f "$pending" 2>/dev/null' EXIT
inbox_nudge

verdict=$(inbox_wait "$req" "$TIMEOUT") || exit 0

decision=$(printf '%s' "$verdict" | "$JQ" -r '.decision // empty' 2>/dev/null)
case "$decision" in
  allow|deny) ;;
  *) exit 0 ;;
esac
reason=$(printf '%s' "$verdict" | "$JQ" -r '.reason // "Answered in Raycast"' 2>/dev/null)

"$JQ" -n --arg d "$decision" --arg r "$reason" \
  '{hookSpecificOutput: {hookEventName: "PermissionRequest", decision: $d, reason: $r}}'
exit 0
