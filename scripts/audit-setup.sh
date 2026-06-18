#!/bin/sh
#
# Enable temporary hook-event audit mode for cursor-pulse.
# Logs all hook payloads to ~/.cursor/cursor-pulse/events.log and registers
# notify.sh on beforeShellExecution / beforeMCPExecution (observe-only).

set -u

SCRIPT_DIR=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd) || exit 1
ROOT_DIR=$(dirname "$SCRIPT_DIR")
CURSOR_DIR=${CURSOR_CONFIG_DIR:-"$HOME/.cursor"}
INSTALL_DIR="$CURSOR_DIR/cursor-pulse"
HOOKS_FILE="$CURSOR_DIR/hooks.json"
NOTIFY_DST="$INSTALL_DIR/notify.sh"
CONFIG="$INSTALL_DIR/config.sh"

# Install latest notify.sh from repo (includes audit block).
if [ -f "$ROOT_DIR/hooks/notify.sh" ]; then
  cp "$ROOT_DIR/hooks/notify.sh" "$NOTIFY_DST"
  chmod +x "$NOTIFY_DST"
fi

# Enable audit flag in config.sh (append or replace).
touch "$CONFIG"
if grep -q '^CURSOR_PULSE_AUDIT=' "$CONFIG" 2>/dev/null; then
  sed -i.bak 's/^CURSOR_PULSE_AUDIT=.*/CURSOR_PULSE_AUDIT=1/' "$CONFIG" 2>/dev/null \
    || sed -i '' 's/^CURSOR_PULSE_AUDIT=.*/CURSOR_PULSE_AUDIT=1/' "$CONFIG"
  rm -f "$CONFIG.bak"
else
  printf '\n# Temporary audit mode — run scripts/audit-teardown.sh when done\nCURSOR_PULSE_AUDIT=1\n' >> "$CONFIG"
fi

: > "$INSTALL_DIR/events.log"

# Merge before* hooks (temporary).
if command -v python3 >/dev/null 2>&1; then
  HOOKS_FILE=$HOOKS_FILE NOTIFY_DST=$NOTIFY_DST python3 - <<'PY'
from pathlib import Path
import json, os

path = Path(os.environ["HOOKS_FILE"])
notify = os.environ["NOTIFY_DST"]
data = json.loads(path.read_text()) if path.exists() else {}
data.setdefault("version", 1)
hooks = data.setdefault("hooks", {})
entry = {"command": notify, "timeout": 5}
for event in ("beforeShellExecution", "beforeMCPExecution"):
    hooks[event] = [entry]
path.write_text(json.dumps(data, indent=2) + "\n")
print("ok")
PY
else
  printf 'python3 required to merge hooks.json\n' >&2
  exit 1
fi

printf '\ncursor-pulse AUDIT mode enabled.\n\n'
printf '  Log file: %s/events.log\n' "$INSTALL_DIR"
printf '  beforeShellExecution + beforeMCPExecution registered (observe-only, fail-open).\n\n'
printf 'Next: run a cursor-agent session that triggers approval + stop, then:\n'
printf '  scripts/audit-report.sh\n'
printf '  scripts/audit-teardown.sh\n\n'

exit 0
