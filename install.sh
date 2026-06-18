#!/bin/sh
#
# cursor-pulse installer.
#
# Installs into ~/.cursor/cursor-pulse/ and merges hook entries into
# ~/.cursor/hooks.json WITHOUT clobbering existing configuration.

set -u

SCRIPT_DIR=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd) || exit 1
CURSOR_DIR=${CURSOR_CONFIG_DIR:-"$HOME/.cursor"}
INSTALL_DIR="$CURSOR_DIR/cursor-pulse"
HOOKS_FILE="$CURSOR_DIR/hooks.json"

STATUSLINE_SRC="$SCRIPT_DIR/statusline.sh"
STATUSLINE_DST="$INSTALL_DIR/statusline.sh"
NOTIFY_SRC="$SCRIPT_DIR/hooks/notify.sh"
NOTIFY_DST="$INSTALL_DIR/notify.sh"
FOCUS_SRC="$SCRIPT_DIR/hooks/focus-session.sh"
FOCUS_DST="$INSTALL_DIR/focus-session.sh"
UNINSTALL_SRC="$SCRIPT_DIR/uninstall.sh"
UNINSTALL_DST="$INSTALL_DIR/uninstall.sh"
CLI_SRC="$SCRIPT_DIR/cursor-pulse"
CLI_DST="$INSTALL_DIR/cursor-pulse"

RAW_URL=${PULSE_RAW_URL:-"https://raw.githubusercontent.com/martinoyovo/cursor-pulse/main"}

mkdir -p "$INSTALL_DIR" "$CURSOR_DIR"

resolve_link() {
  p=$1
  while [ -L "$p" ]; do
    t=$(readlink "$p")
    case "$t" in /*) p=$t ;; *) p=$(dirname "$p")/$t ;; esac
  done
  printf '%s' "$p"
}

fetch_file() {
  url=$1; dst=$2
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$dst"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$dst" "$url"
  else
    return 1
  fi
}

install_file() {
  src=$1; url_path=$2; dst=$3
  if [ -f "$src" ]; then
    cp "$src" "$dst"
    return 0
  fi
  case "$RAW_URL" in
    "")
      printf 'Local source %s was not found.\n' "$src" >&2
      printf 'For piped installs, set PULSE_RAW_URL to the raw repository URL.\n' >&2
      exit 1 ;;
  esac
  if ! fetch_file "$RAW_URL/$url_path" "$dst"; then
    printf 'Could not download %s/%s.\n' "$RAW_URL" "$url_path" >&2
    exit 1
  fi
}

install_file "$STATUSLINE_SRC" "statusline.sh" "$STATUSLINE_DST"
install_file "$NOTIFY_SRC" "hooks/notify.sh" "$NOTIFY_DST"
install_file "$FOCUS_SRC" "hooks/focus-session.sh" "$FOCUS_DST"
install_file "$UNINSTALL_SRC" "uninstall.sh" "$UNINSTALL_DST"
install_file "$CLI_SRC" "cursor-pulse" "$CLI_DST"
chmod +x "$STATUSLINE_DST" "$NOTIFY_DST" "$FOCUS_DST" "$UNINSTALL_DST" "$CLI_DST" || exit 1

CONFIG_DST="$INSTALL_DIR/config.sh"
if [ ! -f "$CONFIG_DST" ]; then
  cat > "$CONFIG_DST" <<'EOF'
# cursor-pulse config — edit to taste. Sourced by the scripts; survives updates.
# Uncomment a line to enable it.

# Icon modes (mutually exclusive — default is plain text, no icons):
# CURSOR_PULSE_NERD=1      # Nerd Font glyphs (needs a Nerd Font installed)
# CURSOR_PULSE_EMOJI=1     # emoji icons (any terminal)
# CURSOR_PULSE_SYMBOLS=1   # plain Unicode symbols (✦ ▸ ⎇ ▦ ⚙ ◷)

# Context bar width, in cells:
# CURSOR_PULSE_BAR_WIDTH=10

# Show token counts after context % (1 = show, 0 = hide):
# CURSOR_PULSE_TOKENS=1

# Hide status-line segments (comma list):
# mode,model,dir,branch,activity,context,duration,tools
# CURSOR_PULSE_HIDE=

# Notifications:
# CURSOR_PULSE_NOTIFY=auto
# CURSOR_PULSE_NOTIFY_ON_STOP=1
# CURSOR_PULSE_NOTIFY_ON_SESSION_END=0
# CURSOR_PULSE_NOTIFY_ON_SHELL=0
# CURSOR_PULSE_NOTIFY_SKIP_FOCUSED=1
# CURSOR_PULSE_NOTIFY_FOCUS_ON_CLICK=1
# CURSOR_PULSE_NOTIFY_ON_APPROVAL=1
# CURSOR_PULSE_NOTIFY_DEBOUNCE=10
# CURSOR_PULSE_NOTIFY_TITLE=
# CURSOR_PULSE_NOTIFY_ICON=
EOF
fi

CLI_LINK=""
CLI_LINK_NOTE=""
link_cli() {
  for d in "$HOME/.local/bin" "/usr/local/bin" "/opt/homebrew/bin"; do
    case ":$PATH:" in
      *":$d:"*)
        if [ -d "$d" ] && [ -w "$d" ] && ln -sf "$CLI_DST" "$d/cursor-pulse" 2>/dev/null; then
          CLI_LINK="$d/cursor-pulse"; return 0
        fi ;;
    esac
  done
  if mkdir -p "$HOME/.local/bin" 2>/dev/null && ln -sf "$CLI_DST" "$HOME/.local/bin/cursor-pulse" 2>/dev/null; then
    CLI_LINK="$HOME/.local/bin/cursor-pulse"
    case ":$PATH:" in
      *":$HOME/.local/bin:"*) : ;;
      *) CLI_LINK_NOTE="Add ~/.local/bin to your PATH to use the 'cursor-pulse' command." ;;
    esac
    return 0
  fi
  return 1
}
link_cli || CLI_LINK_NOTE="Could not link the CLI onto PATH; run it as $CLI_DST"

# macOS: build Cursor-branded notifier app
NOTIFIER_APP="$INSTALL_DIR/CursorPulse.app"
find_cursor_icns() {
  for cand in \
    "/Applications/Cursor.app/Contents/Resources/Cursor.icns" \
    "/Applications/Cursor.app/Contents/Resources/"*.icns \
    "/Applications/Cursor.app/Contents/Resources/app.icns" \
    "/Applications/Cursor.app/Contents/Resources/electron.icns"; do
    [ -f "$cand" ] && printf '%s' "$cand" && return 0
  done
  return 1
}

build_macos_notifier() {
  [ "$(uname -s)" = "Darwin" ] || return 0
  CURSOR_ICNS=$(find_cursor_icns) || return 0
  [ -n "$CURSOR_ICNS" ] || return 0
  command -v codesign >/dev/null 2>&1 || return 0
  tn=$(command -v terminal-notifier 2>/dev/null) || return 0
  [ -n "$tn" ] || return 0
  tn=$(resolve_link "$tn")

  app_src=""
  for cand in \
    "$(dirname "$(dirname "$tn")")/terminal-notifier.app" \
    "${tn%/Contents/MacOS/*}"; do
    if [ -d "$cand" ] && [ -x "$cand/Contents/MacOS/terminal-notifier" ]; then
      app_src=$cand; break
    fi
  done
  [ -n "$app_src" ] || return 0

  rm -rf "$NOTIFIER_APP"
  cp -R "$app_src" "$NOTIFIER_APP" 2>/dev/null || return 0

  plist="$NOTIFIER_APP/Contents/Info.plist"
  icon_file=$(defaults read "$plist" CFBundleIconFile 2>/dev/null || echo "Terminal")
  case "$icon_file" in *.icns) : ;; *) icon_file="$icon_file.icns" ;; esac
  cp "$CURSOR_ICNS" "$NOTIFIER_APP/Contents/Resources/$icon_file" 2>/dev/null \
    || { rm -rf "$NOTIFIER_APP"; return 0; }
  defaults write "$plist" CFBundleIdentifier "com.cursorpulse.notifier" 2>/dev/null \
    || { rm -rf "$NOTIFIER_APP"; return 0; }
  defaults write "$plist" CFBundleName "Cursor" 2>/dev/null \
    || { rm -rf "$NOTIFIER_APP"; return 0; }
  defaults write "$plist" CFBundleDisplayName "Cursor" 2>/dev/null \
    || { rm -rf "$NOTIFIER_APP"; return 0; }
  plutil -convert xml1 "$plist" 2>/dev/null || true

  if ! codesign --force --deep --sign - "$NOTIFIER_APP" >/dev/null 2>&1; then
    rm -rf "$NOTIFIER_APP"; return 0
  fi
  lsr="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  [ -x "$lsr" ] && "$lsr" -f "$NOTIFIER_APP" >/dev/null 2>&1
}
build_macos_notifier

merge_hooks() {
  if command -v python3 >/dev/null 2>&1; then
    HOOKS_FILE=$HOOKS_FILE \
    NOTIFY_DST=$NOTIFY_DST \
    python3 - <<'PY'
from pathlib import Path
import json, os

path = Path(os.environ["HOOKS_FILE"])
notify = os.environ["NOTIFY_DST"]

try:
    data = json.loads(path.read_text()) if path.exists() else {}
except Exception:
    if path.exists():
        path.rename(path.with_suffix(".json.bak"))
    data = {}
if not isinstance(data, dict):
    data = {}

data["version"] = 1
hooks = data.setdefault("hooks", {})
if not isinstance(hooks, dict):
    hooks = {}
    data["hooks"] = hooks

def is_pulse_entry(item):
    if not isinstance(item, dict):
        return False
    cmd = item.get("command", "")
    return isinstance(cmd, str) and ("cursor-pulse" in cmd or cmd == notify)

pulse_entry = {"command": notify, "timeout": 5}

for event in ("stop", "sessionStart", "sessionEnd", "afterShellExecution", "preCompact", "beforeShellExecution", "beforeMCPExecution"):
    entries = hooks.get(event)
    if not isinstance(entries, list):
        entries = []
    entries = [e for e in entries if not is_pulse_entry(e)]
    entries.append(dict(pulse_entry))
    hooks[event] = entries

path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(data, indent=2) + "\n")
print("ok")
PY
  else
    if [ ! -f "$HOOKS_FILE" ]; then
      cat > "$HOOKS_FILE" <<EOF
{
  "version": 1,
  "hooks": {
    "stop": [{ "command": "$NOTIFY_DST", "timeout": 5 }],
    "sessionStart": [{ "command": "$NOTIFY_DST", "timeout": 5 }],
    "sessionEnd": [{ "command": "$NOTIFY_DST", "timeout": 5 }],
    "afterShellExecution": [{ "command": "$NOTIFY_DST", "timeout": 5 }],
    "preCompact": [{ "command": "$NOTIFY_DST", "timeout": 5 }]
  }
}
EOF
    else
      printf 'python3 not found — merge hooks manually (see hooks.example.json).\n' >&2
      printf '  notify.sh -> %s\n' "$NOTIFY_DST" >&2
      return 1
    fi
  fi
}

merge_hooks || true

if command -v cursor-agent >/dev/null 2>&1; then
  agent_version=$(cursor-agent --version 2>/dev/null || printf 'unknown')
else
  agent_version="not found on PATH"
fi

printf '\ncursor-pulse installed.\n\n'
printf 'Installed files:\n'
printf '  %s\n' "$STATUSLINE_DST"
printf '  %s\n' "$NOTIFY_DST"
printf '  %s\n\n' "$CLI_DST"
printf 'Wired into:\n'
printf '  %s (stop, sessionStart, sessionEnd, afterShellExecution, preCompact, beforeShellExecution, beforeMCPExecution)\n\n' "$HOOKS_FILE"
printf 'cursor-agent version: %s\n\n' "$agent_version"
if [ -n "$CLI_LINK" ]; then
  printf 'CLI available as: %s\n' "$CLI_LINK"
else
  printf 'CLI available as: %s\n' "$CLI_DST"
fi
printf '  cursor-pulse status    # render the status line on demand\n'
printf '  cursor-pulse test        # fire a test notification\n'
printf '  cursor-pulse doctor      # check install health\n'
printf '  cursor-pulse update      # update to the latest version\n'
printf '  cursor-pulse uninstall   # remove cursor-pulse\n'
[ -n "$CLI_LINK_NOTE" ] && printf '  (%s)\n' "$CLI_LINK_NOTE"
printf '\nNote: Cursor has no live in-TUI status line. Use cursor-pulse status in\n'
printf 'your shell prompt or tmux status bar. Context %% appears after preCompact.\n'
printf 'Start a cursor-agent session for hooks to capture state.\n'

exit 0
