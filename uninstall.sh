#!/bin/sh
#
# cursor-pulse uninstaller.

set -u

CURSOR_DIR=${CURSOR_CONFIG_DIR:-"$HOME/.cursor"}
INSTALL_DIR="$CURSOR_DIR/cursor-pulse"
HOOKS_FILE="$CURSOR_DIR/hooks.json"
NOTIFY_DST="$INSTALL_DIR/notify.sh"
NOTIFIER_APP="$INSTALL_DIR/CursorPulse.app"

case "${1:-}" in
  -h|--help)
    printf 'Usage: uninstall.sh\n'
    printf '  Remove cursor-pulse: strip hook entries from hooks.json and delete %s\n' "$INSTALL_DIR"
    exit 0 ;;
esac

if [ -f "$HOOKS_FILE" ] && command -v python3 >/dev/null 2>&1; then
  HOOKS_FILE=$HOOKS_FILE \
  NOTIFY_DST=$NOTIFY_DST \
  python3 - <<'PY'
from pathlib import Path
import json, os

path = Path(os.environ["HOOKS_FILE"])
notify = os.environ["NOTIFY_DST"]

try:
    data = json.loads(path.read_text())
except Exception:
    raise SystemExit(0)
if not isinstance(data, dict):
    raise SystemExit(0)

hooks = data.get("hooks")
if not isinstance(hooks, dict):
    raise SystemExit(0)

def is_pulse_entry(item):
    if not isinstance(item, dict):
        return False
    cmd = item.get("command", "")
    return isinstance(cmd, str) and ("cursor-pulse" in cmd or cmd == notify)

for event in ("stop", "sessionStart", "sessionEnd", "afterShellExecution", "preCompact"):
    entries = hooks.get(event)
    if not isinstance(entries, list):
        continue
    entries = [e for e in entries if not is_pulse_entry(e)]
    if entries:
        hooks[event] = entries
    else:
        hooks.pop(event, None)

if not hooks:
    data.pop("hooks", None)

path.write_text(json.dumps(data, indent=2) + "\n")
print("ok")
PY
else
  printf 'Could not auto-edit %s.\n' "$HOOKS_FILE" >&2
  printf 'Remove cursor-pulse hook entries manually.\n' >&2
fi

if [ "$(uname -s 2>/dev/null)" = "Darwin" ] && [ -d "$NOTIFIER_APP" ]; then
  lsr="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  [ -x "$lsr" ] && "$lsr" -u "$NOTIFIER_APP" >/dev/null 2>&1
fi

CLI_DST="$INSTALL_DIR/cursor-pulse"
for d in "$HOME/.local/bin" "/usr/local/bin" "/opt/homebrew/bin"; do
  link="$d/cursor-pulse"
  if [ -L "$link" ] && [ "$(readlink "$link" 2>/dev/null)" = "$CLI_DST" ]; then
    rm -f "$link"
  fi
done

rm -rf "$INSTALL_DIR"

printf '\ncursor-pulse uninstalled.\n'
printf 'Removed: %s\n' "$INSTALL_DIR"
printf 'Cleaned cursor-pulse entries from: %s\n' "$HOOKS_FILE"
if [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
  printf 'Note: macOS may keep a "Cursor" entry under System Settings >\n'
  printf 'Notifications for a while; it is harmless and clears on its own.\n'
fi

exit 0
