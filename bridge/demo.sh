#!/bin/bash
# Fill the inbox with believable data so the UI can be judged before real
# sessions start reporting. Everything it writes carries "demo": true and is
# removed by --clear, so it can never be mistaken for a live request.
set -uo pipefail
cd "$(dirname "$0")" 2>/dev/null || exit 1
# shellcheck source=lib.sh
. ./lib.sh

inbox_ready || { echo "cannot prepare $INBOX_DIR"; exit 1; }
mkdir -p "$INBOX_DIR/usage"

stop_watcher() {
  # The marker used to be the only handle on the watcher, and `clear_demo` removed
  # it a line before the next run re-created it — so the old loop never noticed and
  # every run left one more behind. Kill by pid, then drop the marker.
  local pid
  pid=$(cat "$INBOX_DIR/.demo-watcher" 2>/dev/null) || pid=""
  case "$pid" in ''|*[!0-9]*) ;; *) kill "$pid" 2>/dev/null ;; esac
  rm -f "$INBOX_DIR/.demo-watcher"
}

clear_demo() {
  local n=0
  for f in "$INBOX_DIR"/pending/*.json "$INBOX_DIR"/sessions/*.json "$INBOX_DIR"/usage/*.json; do
    [ -f "$f" ] || continue
    if [ "$("$JQ" -r '.demo // false' "$f" 2>/dev/null)" = "true" ]; then rm -f "$f"; n=$((n + 1)); fi
  done
  stop_watcher
  echo "removed $n demo files"
}

[ "${1:-}" = "--clear" ] && { clear_demo; exit 0; }
clear_demo >/dev/null

now=$(date +%s)
pend() { # req, tool, input-json, cwd, ago
  "$JQ" -n --arg req "$1" --arg tool "$2" --argjson input "$3" --arg cwd "$4" --argjson ts "$((now - $5))" \
    '{demo:true, req:$req, kind:"permission", state:"blocked.permission", ts:$ts,
      session_id:("demo-" + $req), cwd:$cwd, tool_name:$tool, tool_input:$input,
      permission_mode:"default", transcript_path:null}' > "$INBOX_DIR/pending/$1.json"
}
# A row carries everything the panel would otherwise read from a transcript or
# ask a model for — the name, the step, what was asked, what it said, and the
# reading of that — so the demo looks like a working day without one.
sess() { # id, state, cwd, issue, label, phase, ago, last prompt, last message, needs_you, line, replies (a|b|c)
  "$JQ" -n --arg id "$1" --arg st "$2" --arg cwd "$3" --arg issue "$4" --arg label "$5" --arg ph "$6" \
    --argjson ts "$((now - $7))" --arg prompt "$8" --arg msg "$9" --argjson needs "${10}" --arg line "${11}" --arg replies "${12}" \
    '{demo:true, session_id:$id, state:$st, ts:$ts, cwd:$cwd, permission_mode:"default", transcript_path:null,
      issue:(if $issue == "" then null else $issue end),
      label:(if $label == "" then null else $label end),
      phase:(if $ph == "" then null else $ph end),
      last_prompt:(if $prompt == "" then null else $prompt end),
      last_message:(if $msg == "" then null else $msg end),
      needs_you:$needs,
      line:(if $line == "" then null else $line end),
      replies:(if $replies == "" then [] else ($replies | split("|")) end)}' > "$INBOX_DIR/sessions/$1.json"
}

pend demo01 Bash '{"command":"npm run db:migrate -- --env staging","description":"Apply the pending migrations to staging"}' "$HOME/work/acme-api" 140
# Claude Code sends these on a real request; the panel offers them back as
# "Allow and…", so the demo has to carry them or that button is never seen.
"$JQ" --argjson s '[{"type":"setMode","mode":"acceptEdits","destination":"session"},
                    {"type":"addDirectories","directories":["'"$HOME"'/work/acme-api"],"destination":"userSettings"}]' \
  '.permission_suggestions = $s' "$INBOX_DIR/pending/demo01.json" > "$INBOX_DIR/pending/demo01.tmp" \
  && mv "$INBOX_DIR/pending/demo01.tmp" "$INBOX_DIR/pending/demo01.json"

# A question and a plan: the two asks that are answered on the card itself.
"$JQ" -n --argjson ts "$((now - 90))" '{demo:true, req:"demo02", kind:"question", state:"blocked.question", ts:$ts,
  session_id:"demo-q", cwd:"'"$HOME"'/work/acme-web", tool_name:"AskUserQuestion", permission_mode:"default", transcript_path:null,
  tool_input:{questions:[{question:"The export breaks either way — which do we protect?",header:"Trade-off",multiSelect:false,
    options:[{label:"Keep legacy_rate"},{label:"Drop it and patch the export"},{label:"Ship behind a flag"}]}]}}' \
  > "$INBOX_DIR/pending/demo02.json"

# A plan, read and approved on the card like a question.
"$JQ" -n --argjson ts "$((now - 200))" '{demo:true, req:"demo03", kind:"plan", state:"blocked.plan", ts:$ts,
  session_id:"demo-p", cwd:"'"$HOME"'/work/acme-api", tool_name:"ExitPlanMode", permission_mode:"default", transcript_path:null,
  tool_input:{plan:"## Drop `legacy_rate` safely\n\n1. Add `rate_cents` and backfill it from `legacy_rate` in one migration — no reads change yet.\n2. Point the finance export at the new column, behind `FINANCE_V2`.\n3. Run both for one billing cycle and diff the totals.\n4. Drop `legacy_rate` once the diff is empty two months running.\n\n**Not in this plan:** the marketplace markup, which reads neither column."}}' \
  > "$INBOX_DIR/pending/demo03.json"

sess demo-s1 idle "$HOME/work/acme-api" "ACME-231" "" "track" 660 \
  "/track https://linear.app/acme/issue/ACME-231/legacy-rate-column is this done? finish it if not" \
  "Both PRs are green and merged to staging.

I found that the migration drops the \`legacy_rate\` column, which the finance export still reads.

**I need your call before going further:**

1. Keep the column for one more release, or
2. Drop it now and patch the export in the same PR.

I'd recommend option 1: the export runs on the 1st, and a broken finance run costs more than a column." \
  true "Decide: keep legacy_rate one more release, or drop it now and patch the export" \
  "Keep it one release|Drop it now|Show me the diff"

sess demo-s2 idle "$HOME/work/acme-web" "ACME-198" "" "pull" 180 \
  "/pull https://linear.app/acme/issue/ACME-198/hide-cancelled-legs" \
  "Pushed the fix and opened PR #482. CI is running — the background watcher will wake me when the checks finish, then I'll merge if green." \
  false "PR #482 opened; CI running, will merge on green" ""

sess demo-s3 idle "$HOME/work/acme-web" "" "Onboarding email" "" 2100 \
  "rewrite the onboarding email for step 3, keep it under 120 words" \
  "Draft is in \`emails/onboarding-3.md\` at 108 words. Two versions of the subject line — pick one when you review." \
  false "Step-3 draft written (108 words); two subject lines to choose from" ""

sess demo-s4 working "$HOME/work/acme-api" "ACME-205" "" "pull" 300 \
  "/pull add a shared predicate for empty-leg filtering and use it in both endpoints" "" false "" ""

sess demo-s5 working "$HOME/work/acme-docs" "" "Docs search" "" 90 \
  "the search index is stale after the sidebar change — rebuild it and check the top 20 queries" "" false "" ""

sess demo-s6 done "$HOME/work/acme-web" "ACME-190" "" "clean" 1500 "" \
  "Shipped. Tests pass, PR #479 merged to staging." false "" ""

"$JQ" -n --argjson ts "$((now - 180))" --arg cfg "$HOME/.claude" \
  --argjson five "$((now + 7300))" --argjson week "$((now + 250000))" \
  '{demo:true, ts:$ts, config_dir:$cfg, session_id:"demo-s1", model:"Opus 5",
    rate_limits:{five_hour:{used_percentage:38.4, resets_at:$five},
                 seven_day:{used_percentage:61.2, resets_at:$week}},
    context:{used_percentage:42.7, context_window_size:1000000},
    cost:{total_cost_usd:3.21}}' > "$INBOX_DIR/usage/demo.json"

# Stand in for the waiting hook: a verdict must make the row disappear, or the
# UI reads as broken during a demo.
stop_watcher
if true; then
  ( for _ in $(seq 1 12000); do
      [ -f "$INBOX_DIR/.demo-watcher" ] || break
      for v in "$INBOX_DIR"/verdicts/*.json; do
        [ -f "$v" ] || continue
        req=$(basename "$v" .json)
        p="$INBOX_DIR/pending/$req.json"
        if [ -f "$p" ] && [ "$("$JQ" -r '.demo // false' "$p" 2>/dev/null)" = "true" ]; then rm -f "$p" "$v"; fi
      done
      sleep 0.3
    done ) >/dev/null 2>&1 &
  printf '%s' "$!" > "$INBOX_DIR/.demo-watcher"
  disown 2>/dev/null || true
fi

echo "seeded: 1 permission, 1 decision, 2 answers, 2 running, 1 done, usage 5h 38% / 7d 61%"
echo "clear with: $(pwd)/demo.sh --clear"
