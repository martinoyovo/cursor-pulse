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
transcript_path=
duration_ms=

if command -v jq >/dev/null 2>&1; then
  event=$(printf '%s' "$payload" | jq -r '.hook_event_name // ""' 2>/dev/null) || event=
  cwd=$(printf '%s' "$payload" | jq -r '.cwd // ""' 2>/dev/null) || cwd=
  conversation_id=$(printf '%s' "$payload" | jq -r '.conversation_id // ""' 2>/dev/null) || conversation_id=
  model=$(printf '%s' "$payload" | jq -r '.model // ""' 2>/dev/null) || model=
  root=$(printf '%s' "$payload" | jq -r '.workspace_roots[0] // .cwd // ""' 2>/dev/null) || root=
  status=$(printf '%s' "$payload" | jq -r '.status // ""' 2>/dev/null) || status=
  command=$(printf '%s' "$payload" | jq -r '.command // ""' 2>/dev/null) || command=
  transcript_path=$(printf '%s' "$payload" | jq -r '.transcript_path // ""' 2>/dev/null) || transcript_path=
  duration_ms=$(printf '%s' "$payload" | jq -r '.duration_ms // empty' 2>/dev/null) || duration_ms=
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

# ─── State capture (requires jq) ─────────────────────────────────────────────
capture_state() {
  [ -n "$conversation_id" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0

  state_file="$STATE_DIR/${conversation_id}.json"
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)

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
    --arg transcript_path "$transcript_path" \
    '. + {
      model: (if $model != "" then $model else .model // "" end),
      root: (if $root != "" then $root else .root // "" end),
      last_event: $last_event,
      updated_at: $updated_at,
      conversation_id: $conversation_id,
      transcript_path: (if $transcript_path != "" then $transcript_path else .transcript_path // "" end)
    }' 2>/dev/null) || merged=

  [ -n "$merged" ] || return 0

  case "$event" in
    sessionStart)
      merged=$(printf '%s' "$merged" | jq \
        --arg started_at "$now" \
        '. + {status: "running", command_count: 0, started_at: $started_at}' 2>/dev/null) || :
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
          context_window: (.[1].context_window_size // .[0].context_window // null),
          message_count: (.[1].message_count // .[0].message_count // null)
        }' 2>/dev/null) || :
      ;;
    stop)
      merged=$(printf '%s' "$merged" | jq \
        --arg st "$status" \
        '. + {status: (if $st != "" then $st else .status // "completed" end)}' 2>/dev/null) || :
      ;;
    sessionEnd)
      merged=$(printf '%s' "$merged" "$payload" | jq -s \
        '.[0] + {
          status: "ended",
          duration_ms: (.[1].duration_ms // .[0].duration_ms // null)
        }' 2>/dev/null) || :
      ;;
  esac

  printf '%s\n' "$merged" > "$state_file" 2>/dev/null || return 0
  printf '%s' "$conversation_id" > "$STATE_DIR/latest" 2>/dev/null || true
}

capture_state

# ─── Notification debounce (per conversation_id) ─────────────────────────────
notify_debounce_skip() {
  [ -n "$conversation_id" ] || return 1
  win=${CURSOR_PULSE_NOTIFY_DEBOUNCE:-10}
  [ "$win" -gt 0 ] 2>/dev/null || return 1
  sf="$STATE_DIR/${conversation_id}.json"
  [ -f "$sf" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  last=$(jq -r '.last_notify_epoch // 0' "$sf" 2>/dev/null) || last=0
  now=$(date +%s 2>/dev/null) || now=0
  [ "$last" -gt 0 ] 2>/dev/null && [ $((now - last)) -lt "$win" ] 2>/dev/null
}

notify_debounce_record() {
  [ -n "$conversation_id" ] || return 0
  sf="$STATE_DIR/${conversation_id}.json"
  command -v jq >/dev/null 2>&1 || return 0
  [ -f "$sf" ] || return 0
  now=$(date +%s 2>/dev/null) || return 0
  merged=$(jq --argjson t "$now" '. + {last_notify_epoch: $t}' "$sf" 2>/dev/null) || return 0
  printf '%s\n' "$merged" > "$sf" 2>/dev/null || true
}

truncate_cmd() {
  _c=$1
  _max=${CURSOR_PULSE_APPROVAL_CMD_MAX:-80}
  if [ "${#_c}" -gt "$_max" ] 2>/dev/null; then
    printf '%s...' "$(printf '%.77s' "$_c")"
  else
    printf '%s' "$_c"
  fi
}

# ─── Title: session title → project folder basename ──────────────────────────
session_title=
if [ -n "$transcript_path" ] && [ -f "$transcript_path" ] && command -v jq >/dev/null 2>&1; then
  title_line=$(grep -E '"title"|"customTitle"|"session_name"' "$transcript_path" 2>/dev/null | head -n 1)
  if [ -n "$title_line" ]; then
    session_title=$(printf '%s' "$title_line" | jq -r '
      .title // .customTitle // .session_name // ""' 2>/dev/null)
  fi
fi

if [ -n "${CURSOR_PULSE_NOTIFY_TITLE:-}" ]; then
  title="$CURSOR_PULSE_NOTIFY_TITLE"
elif [ -n "$session_title" ]; then
  title="$session_title"
elif [ -n "$root" ]; then
  title=$(basename -- "$root")
elif [ -n "$cwd" ]; then
  title=$(basename -- "$cwd")
else
  title="Cursor"
fi

# ─── Detect the host terminal + this session's TTY (macOS) ───────────────────
host_bid=""; my_tty=""
if [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
  host_app=""; pid=$$; n=0
  while [ "$n" -lt 20 ]; do
    exe=$(ps -o comm= -p "$pid" 2>/dev/null)
    case "$exe" in */*.app/Contents/MacOS/*) host_app="${exe%/Contents/MacOS/*}" ;; esac
    tt=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')
    case "$tt" in ttys*) [ -z "$my_tty" ] && my_tty="$tt" ;; esac
    ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    { [ -z "$ppid" ] || [ "$ppid" -le 1 ]; } && break
    pid=$ppid; n=$(( n + 1 ))
  done
  [ -n "$host_app" ] && [ -f "$host_app/Contents/Info.plist" ] \
    && host_bid=$(defaults read "$host_app/Contents/Info.plist" CFBundleIdentifier 2>/dev/null)
fi

# ─── Map event → notification message ────────────────────────────────────────
notify=0
message=

case "$event" in
  beforeShellExecution|beforeMCPExecution)
    [ "${CURSOR_PULSE_NOTIFY_ON_APPROVAL:-1}" = "1" ] || exit 1
    approval_cmd="$command"
    if [ -z "$approval_cmd" ] && command -v jq >/dev/null 2>&1; then
      approval_cmd=$(printf '%s' "$payload" | jq -r '.tool_name // ""' 2>/dev/null)
    fi
    [ -n "$approval_cmd" ] || exit 1
    message="Cursor needs approval: $(truncate_cmd "$approval_cmd")"
    notify=1
    ;;
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

# Debounce duplicate stop (and approval) notifications per conversation.
if notify_debounce_skip; then
  case "$event" in
    beforeShellExecution|beforeMCPExecution) exit 1 ;;
    *) exit 0 ;;
  esac
fi

# ─── Skip when this exact terminal tab is focused (macOS) ────────────────────
if [ "${CURSOR_PULSE_NOTIFY_SKIP_FOCUSED:-1}" != "0" ] \
  && [ -n "$host_bid" ] \
  && command -v lsappinfo >/dev/null 2>&1; then
  front_bid=$(lsappinfo info -only bundleID "$(lsappinfo front 2>/dev/null)" 2>/dev/null \
    | sed 's/.*"\(.*\)".*/\1/' | grep -v '^$' | tail -1)

  if [ "$host_bid" = "$front_bid" ]; then
    front_tty=""
    case "$host_bid" in
      com.apple.Terminal)
        front_tty=$(osascript -e 'tell application "Terminal" to get tty of selected tab of front window' 2>/dev/null) ;;
      com.googlecode.iterm2)
        front_tty=$(osascript -e 'tell application "iTerm2" to tell current session of current window to get tty' 2>/dev/null) ;;
    esac
    if [ -n "$front_tty" ] && [ -n "$my_tty" ]; then
      case "$event" in
        beforeShellExecution|beforeMCPExecution) exit 1 ;;
        *) [ "$front_tty" = "/dev/$my_tty" ] && exit 0 ;;
      esac
    else
      case "$event" in
        beforeShellExecution|beforeMCPExecution) exit 1 ;;
        *) exit 0 ;;
      esac
    fi
  fi
fi

# ─── Notifier backends (stdout must stay clean; run synchronously, no &) ───────
TTY_OUT="/dev/tty"
[ -w "$TTY_OUT" ] 2>/dev/null || TTY_OUT="/dev/null"

notify_icon() {
  # PNG only for notify-send — never pass .icns to terminal-notifier (-appIcon).
  if [ -n "${CURSOR_PULSE_NOTIFY_ICON:-}" ] && [ -f "$CURSOR_PULSE_NOTIFY_ICON" ]; then
    case "$CURSOR_PULSE_NOTIFY_ICON" in
      *.png|*.PNG) printf '%s' "$CURSOR_PULSE_NOTIFY_ICON"; return 0 ;;
    esac
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
  # Bare title + message — no -group, no -appIcon, no -sender.
  set -- -title "$title" -message "$message"
  # Click-to-focus: -execute runs on click only (after the hook exits); stdout stays clean.
  if [ "${CURSOR_PULSE_NOTIFY_FOCUS_ON_CLICK:-1}" != "0" ] \
    && [ -n "${my_tty:-}" ] && [ -n "${SCRIPT_DIR:-}" ] \
    && [ -x "$SCRIPT_DIR/focus-session.sh" ]; then
    case "${host_bid:-}" in
      com.apple.Terminal|com.googlecode.iterm2)
        set -- "$@" -execute "$SCRIPT_DIR/focus-session.sh $my_tty"
        ;;
    esac
  fi
  "$tn" "$@" >/dev/null 2>&1
  return 0
}

notify_alerter() {
  command -v alerter >/dev/null 2>&1 || return 1
  # alerter blocks; background is the one acceptable exception.
  alerter -title "$title" -message "$message" >/dev/null 2>&1 &
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

notify_debounce_record

case "$event" in
  beforeShellExecution|beforeMCPExecution) exit 1 ;;
esac

exit 0
