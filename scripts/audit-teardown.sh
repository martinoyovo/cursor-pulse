#!/bin/sh
#
# Disable cursor-pulse audit mode and remove temporary before* hook entries.

set -u

CURSOR_DIR=${CURSOR_CONFIG_DIR:-"$HOME/.cursor"}
INSTALL_DIR="$CURSOR_DIR/cursor-pulse"
HOOKS_FILE="$CURSOR_DIR/hooks.json"
NOTIFY_DST="$INSTALL_DIR/notify.sh"
CONFIG="$INSTALL_DIR/config.sh"

if [ -f "$CONFIG" ]; then
  sed -i.bak '/^CURSOR_PULSE_AUDIT=/d' "$CONFIG" 2>/dev/null \
    || sed -i '' '/^CURSOR_PULSE_AUDIT=/d' "$CONFIG"
  sed -i.bak '/Temporary audit mode/d' "$CONFIG" 2>/dev/null \
    || sed -i '' '/Temporary audit mode/d' "$CONFIG"
  rm -f "$CONFIG.bak"
fi

if [ -f "$HOOKS_FILE" ] && command -v python3 >/dev/null 2>&1; then
  HOOKS_FILE=$HOOKS_FILE NOTIFY_DST=$NOTIFY_DST python3 - <<'PY'
from pathlib import Path
import json, os

path = Path(os.environ["HOOKS_FILE"])
notify = os.environ["NOTIFY_DST"]
try:
    data = json.loads(path.read_text())
except Exception:
    raise SystemExit(0)
hooks = data.get("hooks")
if not isinstance(hooks, dict):
    raise SystemExit(0)
for event in ("beforeShellExecution", "beforeMCPExecution"):
    hooks.pop(event, None)
if not hooks:
    data.pop("hooks", None)
path.write_text(json.dumps(data, indent=2) + "\n")
PY
fi

printf 'cursor-pulse audit mode disabled.\n'
printf 'events.log kept at: %s/events.log\n' "$INSTALL_DIR"
exit 0
