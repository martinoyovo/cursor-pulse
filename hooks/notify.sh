#!/bin/sh
#
# cursor-pulse — hook dispatcher: desktop notifications + session state capture.
#
# Cursor pipes one JSON object on stdin for each hook event. We capture session
# state to disk and optionally fire a local desktop alert. stdout must stay
# clean — bell/OSC-9 go to /dev/tty; all notifier output is redirected.

set -u

payload=$(cat 2>/dev/null) || payload=
[ -n "$payload" ] || exit 0

# Hooks are not supported on Windows shells.
case "$(uname -s 2>/dev/null)" in
  CYGWIN*|MINGW*|MSYS*|Windows_NT*) exit 0 ;;
esac

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd) || SCRIPT_DIR=
[ -n "${SCRIPT_DIR:-}" ] && [ -f "$SCRIPT_DIR/config.sh" ] && . "$SCRIPT_DIR/config.sh"

CURSOR_DIR=${CURSOR_CONFIG_DIR:-"$HOME/.cursor"}
STATE_DIR="${CURSOR_PULSE_STATE_DIR:-$CURSOR_DIR/cursor-pulse/state}"
mkdir -p "$STATE_DIR" 2>/dev/null || true

# ─── Parse payload (jq → sed fallback for event + cwd) ───────────────────────
event=
cwd=
conversation_id=
model=
root=
status=
command=
context_pct=
context_tokens=
context_window=

if command -v jq >/dev/null 2>&1; then
  event=$(printf '%s' "$payload" | jq -r '.hook_event_name // ""' 2>/dev/null) || event=
  cwd=$(printf '%s' "$payload" | jq -r '.cwd // ""' 2>/dev/null) || cwd=
  conversation_id=$(printf '%s' "$payload" | jq -r '.conversation_id // ""' 2>/dev/null) || conversation_id=
  model=$(printf '%s' "$payload" | jq -r '.model // ""' 2>/dev/null) || model=
  root=$(printf '%s' "$payload" | jq -r '.workspace_roots[0] // .cwd // ""' 2>/dev/null) || root=
  status=$(printf '%s' "$payload" | jq -r '.status // ""' 2>/dev/null) || status=
  command=$(printf '%s' "$payload" | jq -r '.command // ""' 2>/dev/null) || command=
  context_pct=$(printf '%s' "$payload" | jq -r '.context_usage_percent // ""' 2>/dev/null) || context_pct=
  context_tokens=$(printf '%s' "$payload" | jq -r '.context_tokens // ""' 2>/dev/null) || context_tokens=
  context_window=$(printf '%s' "$payload" | jq -r '.context_window_size // ""' 2>/dev/null) || context_window=
fi

if [ -z "$event" ]; then
  event=$(printf '%s' "$payload" |
    sed -n 's/.*"hook_event_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
    sed -n '1p')
fi

if [ -z "$cwd" ]; then
  cwd=$(printf '%s' "$payload" |
    sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | sed -n '1p')
fi

[ -n "$root" ] || root="$cwd"

# ─── State capture (requires jq) ───────────────────────────────────────────────
capture_state() {
  [ -n "$conversation_id" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0

  state_file="$STATE_DIR/${conversation_id}.json"
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")

  if [ -f "$state_file" ]; then
    existing=$(cat "$state_file" 2>/dev/null) || existing='{}'
  else
    existing='{}'
  fi

  merged=$(printf '%s' "$existing" | jq \
    --arg model "$model" \
    --arg root "$root" \
    --arg last_event "$event" \
    --arg updated_at "$now" \
    --arg conversation_id "$conversation_id" \
    '. + {
      model: (if $model != "" then $model else .model // "" end),
      root: (if $root != "" then $root else .root // "" end),
      last_event: $last_event,
      updated_at: $updated_at,
      conversation_id: $conversation_id
    }' 2>/dev/null) || merged=

  [ -n "$merged" ] || return 0

  case "$event" in
    sessionStart)
      merged=$(printf '%s' "$merged" | jq '. + {status: "running", command_count: 0}' 2>/dev/null) || :
      ;;
    afterShellExecution)
      merged=$(printf '%s' "$merged" | jq \
        --arg cmd "$command" \
        '. + {
          status: "running",
          command_count: ((.command_count // 0) + 1),
          last_command: (if $cmd != "" then $cmd else .last_command // "" end)
        }' 2>/dev/null) || :
      ;;
    preCompact)
      merged=$(printf '%s' "$merged" "$payload" | jq -s \
        '.[0] + {
          context_pct: (.[1].context_usage_percent // .[0].context_pct // null),
          context_tokens: (.[1].context_tokens // .[0].context_tokens // null),
          context_window: (.[1].context_window_size // .[0].context_window // null)
        }' 2>/dev/null) || :
      ;;
    stop)
      merged=$(printf '%s' "$merged" | jq \
        --arg st "$status" \
        '. + {status: (if $st != "" then $st else .status // "completed" end)}' 2>/dev/null) || :
      ;;
    sessionEnd)
      merged=$(printf '%s' "$merged" | jq '. + {status: "ended"}' 2>/dev/null) || :
      ;;
  esac

  printf '%s\n' "$merged" > "$state_file" 2>/dev/null || return 0
  printf '%s' "$conversation_id" > "$STATE_DIR/latest" 2>/dev/null || true
}

capture_state

# ─── Title: project folder basename ──────────────────────────────────────────
if [ -n "${CURSOR_PULSE_NOTIFY_TITLE:-}" ]; then
  title="$CURSOR_PULSE_NOTIFY_TITLE"
elif [ -n "$root" ]; then
  title=$(basename -- "$root")
elif [ -n "$cwd" ]; then
  title=$(basename -- "$cwd")
else
  title="Cursor"
fi

# ─── Map event → notification message ────────────────────────────────────────
notify=0
message=

case "$event" in
  stop)
    [ "${CURSOR_PULSE_NOTIFY_ON_STOP:-1}" = "1" ] || exit 0
    notify=1
    case "$status" in
      aborted) message="Cursor stopped" ;;
      error)   message="Cursor hit an error" ;;
      *)       message="Cursor is waiting for your input" ;;
    esac
    ;;
  sessionEnd)
    [ "${CURSOR_PULSE_NOTIFY_ON_SESSION_END:-0}" = "1" ] || exit 0
    notify=1
    message="Cursor session ended"
    ;;
  afterShellExecution)
    [ "${CURSOR_PULSE_NOTIFY_ON_SHELL:-0}" = "1" ] || exit 0
    notify=1
    if [ -n "$command" ]; then
      message="ran: $command"
    else
      message="Cursor ran a shell command"
    fi
    ;;
  *)
    exit 0
    ;;
esac

[ "$notify" = "1" ] || exit 0

# ─── Notifier backends (stdout must stay clean) ──────────────────────────────
TTY_OUT="/dev/tty"
[ -w "$TTY_OUT" ] 2>/dev/null || TTY_OUT="/dev/null"

notify_icon() {
  if [ -n "${CURSOR_PULSE_NOTIFY_ICON:-}" ] && [ -f "$CURSOR_PULSE_NOTIFY_ICON" ]; then
    printf '%s' "$CURSOR_PULSE_NOTIFY_ICON"
    return 0
  fi
  return 1
}

notify_terminal_notifier() {
  tn=""
  if [ -n "${SCRIPT_DIR:-}" ] && [ -x "$SCRIPT_DIR/CursorPulse.app/Contents/MacOS/terminal-notifier" ]; then
    tn="$SCRIPT_DIR/CursorPulse.app/Contents/MacOS/terminal-notifier"
  elif command -v terminal-notifier >/dev/null 2>&1; then
    tn="terminal-notifier"
  else
    return 1
  fi
  set -- -title "$title" -message "$message"
  if [ "$tn" = "terminal-notifier" ]; then
    icon=$(notify_icon || printf '')
    [ -n "$icon" ] && set -- "$@" -appIcon "$icon"
  fi
  "$tn" "$@" >/dev/null 2>&1
  return 0
}

notify_alerter() {
  command -v alerter >/dev/null 2>&1 || return 1
  alerter -title "$title" -message "$message" -group "cursor-pulse" >/dev/null 2>&1
  return 0
}

notify_send() {
  command -v notify-send >/dev/null 2>&1 || return 1
  icon=$(notify_icon || printf '')
  if [ -n "$icon" ]; then
    notify-send -a "Cursor" -i "$icon" "$title" "$message" >/dev/null 2>&1
  else
    notify-send -a "Cursor" "$title" "$message" >/dev/null 2>&1
  fi
  return 0
}

notify_osa() {
  command -v osascript >/dev/null 2>&1 || return 1
  osascript -e "display notification \"$message\" with title \"$title\"" >/dev/null 2>&1
  return 0
}

notify_osc9() { printf '\033]9;%s\007' "$message" >"$TTY_OUT" 2>/dev/null || true; }
notify_bell() { printf '\a' >"$TTY_OUT" 2>/dev/null || true; }

case "${CURSOR_PULSE_NOTIFY:-auto}" in
  off) ;;
  terminal-notifier|notifier) notify_terminal_notifier || notify_osa || notify_osc9 ;;
  alerter) notify_alerter || notify_osa || notify_osc9 ;;
  notify-send) notify_send || notify_osc9 ;;
  osa) notify_osa || notify_osc9 ;;
  osc9) notify_osc9 ;;
  bell) notify_bell ;;
  *)
    notify_terminal_notifier || notify_alerter || notify_send \
      || notify_osa || notify_osc9 || notify_bell
    ;;
esac

exit 0
