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

# Re-merge hooks from install (keeps permanent before* approval observer).
SCRIPT_DIR=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd) || SCRIPT_DIR=
ROOT_DIR=$(dirname "$SCRIPT_DIR")
if [ -x "$ROOT_DIR/install.sh" ]; then
  CURSOR_CONFIG_DIR="$CURSOR_DIR" sh "$ROOT_DIR/install.sh" >/dev/null 2>&1 || true
fi

printf 'cursor-pulse audit mode disabled.\n'
printf 'events.log kept at: %s/events.log\n' "$INSTALL_DIR"
exit 0
