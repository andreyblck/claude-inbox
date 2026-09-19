#!/bin/bash
# Install (or remove) the bridge in a Claude Code config directory.
#
#   ./install.sh                 install into ${CLAUDE_CONFIG_DIR:-~/.claude}
#   ./install.sh --dry-run       print the resulting settings.json, write nothing
#   ./install.sh --uninstall     remove the hooks and give the status line back
#   ./install.sh --wait 300      seconds the permission hook waits for Raycast
#
# Every run backs the file up first and is idempotent: our entries are recognised
# by their path, so installing twice leaves one copy.
set -euo pipefail
cd "$(dirname "$0")"
BRIDGE=$(pwd)
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
INBOX_DIR="${CLAUDE_INBOX_DIR:-$HOME/.claude/inbox}"
WAIT=20
MODE=install
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) MODE=dry ;;
    --uninstall) MODE=uninstall ;;
    --wait) WAIT="$2"; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

BRIDGE="$BRIDGE" CONFIG_DIR="$CONFIG_DIR" INBOX_DIR="$INBOX_DIR" WAIT="$WAIT" MODE="$MODE" \
/usr/bin/python3 - <<'PY'
import json, os, pathlib, shutil, time

bridge = pathlib.Path(os.environ["BRIDGE"])
config = pathlib.Path(os.environ["CONFIG_DIR"])
inbox = pathlib.Path(os.environ["INBOX_DIR"])
wait = os.environ["WAIT"]
mode = os.environ["MODE"]

settings_path = config / "settings.json"
settings = {}
if settings_path.exists():
    settings = json.loads(settings_path.read_text() or "{}")

def ours(entry):
    return str(bridge) in str(entry.get("command", ""))

def strip(hooks):
    """Drop our previous entries, keep everyone else's untouched."""
    out = {}
    for event, matchers in (hooks or {}).items():
        kept = []
        for matcher in matchers:
            inner = [h for h in matcher.get("hooks", []) if not ours(h)]
            if inner:
                kept.append({**matcher, "hooks": inner})
        if kept:
            out[event] = kept
    return out

hooks = strip(settings.get("hooks"))

if mode != "uninstall":
    hooks.setdefault("PermissionRequest", []).append({
        "hooks": [{
            "type": "command",
            # env inline: hooks run in a shell and do not inherit ours
            "command": f"CLAUDE_INBOX_PERMISSION_TIMEOUT={wait} {bridge}/hook-permission.sh",
            "timeout": int(wait) + 40,
        }]
    })
    for event in ("SessionStart", "Stop", "SessionEnd"):
        hooks.setdefault(event, []).append({
            "hooks": [{"type": "command", "command": f"{bridge}/hook-session.sh", "timeout": 5}]
        })

if hooks:
    settings["hooks"] = hooks
else:
    settings.pop("hooks", None)

# Status line: wrap, never replace. The delegate file holds whatever was there.
delegate_file = inbox / "statusline-delegate"
current = (settings.get("statusLine") or {}).get("command", "")
ours_statusline = str(bridge) in current

if mode == "uninstall":
    if ours_statusline:
        previous = delegate_file.read_text().strip() if delegate_file.exists() else ""
        if previous:
            settings["statusLine"] = {**settings.get("statusLine", {}), "command": previous}
        else:
            settings.pop("statusLine", None)
else:
    if current and not ours_statusline:
        inbox.mkdir(parents=True, exist_ok=True)
        delegate_file.write_text(current + "\n")
    settings["statusLine"] = {**(settings.get("statusLine") or {}), "type": "command",
                              "command": f"{bridge}/statusline.sh"}

payload = json.dumps(settings, indent=2) + "\n"
if mode == "dry":
    print(payload)
    raise SystemExit(0)

config.mkdir(parents=True, exist_ok=True)
if settings_path.exists():
    backup = settings_path.with_suffix(f".json.bak-{int(time.time())}")
    shutil.copy2(settings_path, backup)
    print(f"backup      {backup}")
settings_path.write_text(payload)
print(f"settings    {settings_path}")

if mode == "uninstall":
    print("removed     bridge hooks; status line restored")
else:
    inbox.mkdir(parents=True, exist_ok=True)
    os.chmod(inbox, 0o700)
    (inbox / "nudge-url").write_text(
        "raycast://extensions/andreyblack/claude-inbox/menubar?launchType=background\n")
    print(f"inbox       {inbox}")
    print(f"permission  waits {wait}s for Raycast, then the terminal prompts as usual")
    print("new sessions pick this up; sessions already running keep the hooks they started with")
PY
