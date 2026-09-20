#!/bin/bash
# End-to-end: a real Claude Code session blocks on a permission request, and a
# verdict file dropped from outside decides it.
#
#   ./e2e.sh            verdict "allow"  -> the tool must run
#   ./e2e.sh --deny     verdict "deny"   -> the tool must not run
#   ./e2e.sh --silent   no verdict       -> hook times out, session survives
#
# selftest.sh proves the hook's own logic against a synthetic payload. This proves
# the thing selftest cannot: that Claude Code itself fires the hook and honours the
# decision it prints. It runs against a throwaway inbox, never the real one.
#
# The session runs with --permission-prompts none, so "nobody would have approved
# this" is the baseline. Anything that runs, ran because of our verdict.
set -uo pipefail
cd "$(dirname "$0")"

MODE=allow
case "${1:-}" in
  --deny) MODE=deny ;;
  --silent) MODE=silent ;;
  "") ;;
  *) echo "unknown option: $1" >&2; exit 2 ;;
esac

MODEL="${CLAUDE_INBOX_E2E_MODEL:-claude-haiku-4-5-20251001}"
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/claude-inbox-e2e.XXXXXX")
export CLAUDE_INBOX_DIR="$ROOT/inbox"
mkdir -p "$ROOT/project" "$CLAUDE_INBOX_DIR"/{pending,verdicts,sessions}
# mktemp hands back /var/..., Claude Code reports /private/var/... — resolve the
# symlink here or every cwd comparison below is a false failure.
PROJECT=$(cd "$ROOT/project" && pwd -P)
MARKER="$PROJECT/it-ran.txt"

fail=0
check() { if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1: expected [$3] got [$2]"; fail=1; fi; }
cleanup() { [ -n "${watcher:-}" ] && kill "$watcher" 2>/dev/null; rm -rf "$ROOT"; }
trap cleanup EXIT

# The stand-in for Raycast: first pending request wins a verdict.
captured="$ROOT/captured.json"
if [ "$MODE" != silent ]; then
  ( for _ in $(seq 1 600); do
      for f in "$CLAUDE_INBOX_DIR"/pending/*.json; do
        [ -f "$f" ] || continue
        cp "$f" "$captured" 2>/dev/null
        /usr/bin/jq -n --arg d "$MODE" '{decision:$d, reason:"e2e"}' \
          > "$CLAUDE_INBOX_DIR/verdicts/$(basename "$f" .json).json"
        exit 0
      done
      sleep 0.2
    done ) &
  watcher=$!
fi

echo "mode: $MODE   inbox: $CLAUDE_INBOX_DIR"
out=$(cd "$PROJECT" && claude -p \
  --model "$MODEL" \
  --permission-mode manual \
  --permission-prompts none \
  --output-format json \
  --max-turns 4 \
  "Run exactly this shell command and nothing else: touch it-ran.txt" 2>&1)
rc=$?
[ -n "${watcher:-}" ] && wait "$watcher" 2>/dev/null

ran=no; [ -f "$MARKER" ] && ran=yes
echo "  session exit $rc, tool ran: $ran"

case "$MODE" in
  allow)
    check "hook fired (pending captured)" "$([ -f "$captured" ] && echo yes || echo no)" "yes"
    check "tool ran after allow" "$ran" "yes"
    if [ -f "$captured" ]; then
      check "payload: kind"  "$(/usr/bin/jq -r '.kind'  "$captured")" "permission"
      check "payload: state" "$(/usr/bin/jq -r '.state' "$captured")" "blocked.permission"
      check "payload: tool"  "$(/usr/bin/jq -r '.tool_name' "$captured")" "Bash"
      check "payload: cwd"   "$(/usr/bin/jq -r '.cwd' "$captured")" "$PROJECT"
      check "payload: has session_id" \
        "$([ -n "$(/usr/bin/jq -r '.session_id // empty' "$captured")" ] && echo yes || echo no)" "yes"
      check "payload: has command" \
        "$([ -n "$(/usr/bin/jq -r '.tool_input.command // empty' "$captured")" ] && echo yes || echo no)" "yes"
      echo "  ---- captured pending ----"
      /usr/bin/jq -C '.' "$captured" | sed 's/^/  /'
    fi
    ;;
  deny)
    check "hook fired (pending captured)" "$([ -f "$captured" ] && echo yes || echo no)" "yes"
    check "tool blocked after deny" "$ran" "no"
    ;;
  silent)
    check "tool blocked with no verdict" "$ran" "no"
    check "session still exited cleanly" "$rc" "0"
    check "pending cleaned up" \
      "$(ls -1 "$CLAUDE_INBOX_DIR/pending" 2>/dev/null | wc -l | tr -d ' ')" "0"
    ;;
esac

echo
[ "$fail" = 0 ] && echo "e2e $MODE: pass" || { echo "e2e $MODE: FAIL"; echo "--- session output ---"; echo "$out" | head -40; exit 1; }
