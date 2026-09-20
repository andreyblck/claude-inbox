#!/bin/bash
# Install (or remove) the bridge in a Claude Code config directory.
#
#   ./install.sh                 install into ${CLAUDE_CONFIG_DIR:-~/.claude}
#   ./install.sh --dry-run       print the resulting settings.json, write nothing
#   ./install.sh --uninstall     remove the hooks and give the status line back
#   ./install.sh --wait 300      seconds the permission hook waits for the app
#
# Every run backs the file up first and is idempotent: our entries are recognised
# by script name, so installing twice — or installing after moving the repo —
# leaves one copy rather than one per path the bridge has ever lived at.
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
    --wait)
      [ $# -ge 2 ] || { echo "--wait needs a number of seconds" >&2; exit 2; }
      case "$2" in
        ''|*[!0-9]*) echo "--wait takes whole seconds, got: $2" >&2; exit 2 ;;
      esac
      WAIT="$2"; shift ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

BRIDGE="$BRIDGE" CONFIG_DIR="$CONFIG_DIR" INBOX_DIR="$INBOX_DIR" WAIT="$WAIT" MODE="$MODE" \
/usr/bin/python3 - <<'PY'
import json, os, pathlib, shutil, sys, time

bridge = pathlib.Path(os.environ["BRIDGE"])
config = pathlib.Path(os.environ["CONFIG_DIR"])
inbox = pathlib.Path(os.environ["INBOX_DIR"])
wait = os.environ["WAIT"]
mode = os.environ["MODE"]

# Recognise our own entries by script name, not by the path they were installed
# from. Matching the path means moving or re-cloning the repo leaves the old
# entries behind: a hook that fails on every request, and — if both copies still
# exist — two hooks racing for the same permission with two 20-second waits.
OUR_SCRIPTS = ("hook-permission.sh", "hook-session.sh", "statusline.sh")

settings_path = config / "settings.json"
settings = {}
if settings_path.exists():
    raw = settings_path.read_text() or "{}"
    try:
        settings = json.loads(raw)
    except json.JSONDecodeError as err:
        sys.exit(f"{settings_path} is not valid JSON ({err}).\n"
                 f"Fix or move it first — refusing to overwrite a file we cannot read.")

def ours(command):
    text = str(command)
    return any(f"/{name}" in text for name in OUR_SCRIPTS)

def strip(hooks):
    """Drop our previous entries, keep everyone else's untouched."""
    out = {}
    for event, matchers in (hooks or {}).items():
        kept = []
        for matcher in matchers:
            if not isinstance(matcher, dict) or "hooks" not in matcher:
                kept.append(matcher)  # not a shape we understand; not ours to delete
                continue
            inner = [h for h in matcher.get("hooks", []) if not ours(h.get("command", ""))]
            if inner:
                kept.append({**matcher, "hooks": inner})
            elif not matcher.get("hooks"):
                kept.append(matcher)  # was already empty before we got here
        if kept:
            out[event] = kept
    return out

hooks = strip(settings.get("hooks"))

# Quoted: a space in the path — ~/Desktop/My Projects, an iCloud folder — otherwise
# breaks every hook AND the status line in the same install.
def cmd(script):
    return f'"{bridge}/{script}"'

if mode != "uninstall":
    hooks.setdefault("PermissionRequest", []).append({
        "hooks": [{
            "type": "command",
            # env inline: hooks run in a shell and do not inherit ours
            "command": f"CLAUDE_INBOX_PERMISSION_TIMEOUT={wait} {cmd('hook-permission.sh')}",
            "timeout": int(wait) + 40,
        }]
    })
    # UserPromptSubmit is what puts a session back to "working" after a Stop.
    # Without it the registry reports idle for the rest of the process's life.
    for event in ("SessionStart", "UserPromptSubmit", "Stop", "SessionEnd"):
        hooks.setdefault(event, []).append({
            "hooks": [{"type": "command", "command": cmd("hook-session.sh"), "timeout": 5}]
        })

if hooks:
    settings["hooks"] = hooks
else:
    settings.pop("hooks", None)

# Status line: wrap, never replace.
#
# The delegate lives beside the settings file it belongs to, not in the shared
# inbox. A status line is per account, exactly like the settings that name it, and
# a single shared file hands account A's status line to account B and restores the
# wrong one on uninstall. Keeping it here also means cleaning out ~/.claude/inbox
# can no longer lose the only record of what the user had.
delegate_file = config / "claude-inbox-statusline-delegate"
legacy_delegate = inbox / "statusline-delegate"
current = (settings.get("statusLine") or {}).get("command", "")
ours_statusline = ours(current)

previous = ""
if delegate_file.exists():
    previous = delegate_file.read_text().strip()
elif legacy_delegate.exists():
    previous = legacy_delegate.read_text().strip()

if mode == "uninstall":
    if ours_statusline:
        if previous:
            settings["statusLine"] = {**settings.get("statusLine", {}), "command": previous}
        else:
            settings.pop("statusLine", None)
elif current and not ours_statusline:
    previous = current
if mode != "uninstall":
    settings["statusLine"] = {**(settings.get("statusLine") or {}), "type": "command",
                              "command": cmd("statusline.sh")}

payload = json.dumps(settings, indent=2) + "\n"
if mode == "dry":
    # "write nothing" has to mean it: the previous version created the inbox here,
    # at the default 0755, and that is the directory verdict files live in.
    print(payload)
    if previous:
        print(f"# would keep your status line as the delegate: {previous}", file=sys.stderr)
    raise SystemExit(0)

config.mkdir(parents=True, exist_ok=True)
if settings_path.exists():
    # One per second was enough to overwrite the pristine copy with an already
    # modified one — `install.sh && install.sh --uninstall` did exactly that.
    stamp = time.strftime("%Y%m%d-%H%M%S")
    backup = settings_path.with_suffix(f".json.bak-{stamp}")
    n = 1
    while backup.exists():
        backup = settings_path.with_suffix(f".json.bak-{stamp}.{n}")
        n += 1
    shutil.copy2(settings_path, backup)
    print(f"backup      {backup}")

if mode != "uninstall" and previous:
    delegate_file.write_text(previous + "\n")

settings_path.write_text(payload)
print(f"settings    {settings_path}")

registered = inbox / "config-dirs"

if mode == "uninstall":
    if registered.exists():
        kept = [line.strip() for line in registered.read_text().splitlines()
                if line.strip() and line.strip() != str(config)]
        # The inbox is shared across accounts, so removing the last account is
        # what says "nobody reports in any more" — not deleting the directory.
        registered.write_text("".join(f"{d}\n" for d in kept))
    # A pending row is a request some hook was holding open. Those hooks are gone
    # now, so every one of them is a row nothing can ever resolve.
    removed = 0
    for stale in (inbox / "pending").glob("*.json"):
        stale.unlink(missing_ok=True)
        removed += 1
    print(f"removed     bridge hooks{f', {removed} pending requests' if removed else ''}")
    if ours_statusline:
        print(f"statusline  {'restored: ' + previous if previous else 'removed (no delegate on record)'}")
else:
    inbox.mkdir(parents=True, exist_ok=True)
    os.chmod(inbox, 0o700)
    # A verdict file approves a tool call. Leaving these to the first hook run
    # meant they existed at whatever umask was in force, with a window in between.
    for sub in ("sessions", "pending", "verdicts", "usage"):
        (inbox / sub).mkdir(exist_ok=True)
        os.chmod(inbox / sub, 0o700)

    # Record where we went. A config directory is an account, it owns its own
    # session registry, and the reader cannot guess it: assuming ~/.claude leaves
    # anyone running CLAUDE_CONFIG_DIR with an inbox that reads empty while a
    # dozen sessions are live.
    known = []
    if registered.exists():
        known = [line.strip() for line in registered.read_text().splitlines() if line.strip()]
    if str(config) not in known:
        known.append(str(config))
    registered.write_text("".join(f"{d}\n" for d in known))

    print(f"inbox       {inbox}")
    print(f"accounts    {', '.join(known)}")
    if previous:
        print(f"statusline  wrapping yours: {previous}")
    print(f"permission  waits {wait}s for the app, then the terminal prompts as usual")
    print("new sessions pick this up; sessions already running keep the hooks they started with")

PY
