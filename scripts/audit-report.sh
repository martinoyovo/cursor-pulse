#!/bin/sh
#
# Summarize ~/.cursor/cursor-pulse/events.log for the hook audit.

set -u

CURSOR_DIR=${CURSOR_CONFIG_DIR:-"$HOME/.cursor"}
LOG="$CURSOR_DIR/cursor-pulse/events.log"

if [ ! -f "$LOG" ]; then
  printf 'No events.log at %s\n' "$LOG"
  printf 'Run scripts/audit-setup.sh and a cursor-agent session first.\n'
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  printf 'jq required\n' >&2
  exit 1
fi

printf '=== cursor-pulse hook audit report ===\n\n'
printf 'Event sequence (%s lines):\n' "$(wc -l < "$LOG" | tr -d ' ')"
n=0
while IFS= read -r line; do
  n=$(( n + 1 ))
  ev=$(printf '%s' "$line" | jq -r '.hook_event_name // "?"' 2>/dev/null)
  status=$(printf '%s' "$line" | jq -r '.status // ""' 2>/dev/null)
  loop=$(printf '%s' "$line" | jq -r '.loop_count // ""' 2>/dev/null)
  cmd=$(printf '%s' "$line" | jq -r '.command // .tool_name // ""' 2>/dev/null)
  extra=""
  [ -n "$status" ] && extra="${extra} status=$status"
  [ -n "$loop" ] && [ "$loop" != "null" ] && extra="${extra} loop_count=$loop"
  [ -n "$cmd" ] && extra="${extra} cmd=${cmd%% *}"
  printf '  %3d. %s%s\n' "$n" "$ev" "$extra"
done < "$LOG"

printf '\nstop events: '
grep -c '"hook_event_name":"stop"' "$LOG" 2>/dev/null || grep -c '"hook_event_name": "stop"' "$LOG" 2>/dev/null || printf '0'
printf '\n'

printf '\nApproval-event payloads (beforeShellExecution / beforeMCPExecution):\n'
while IFS= read -r line; do
  ev=$(printf '%s' "$line" | jq -r '.hook_event_name // ""' 2>/dev/null)
  case "$ev" in
    beforeShellExecution|beforeMCPExecution)
      printf '%s\n' "$line" | jq -c '{event:.hook_event_name, command:.command, tool_name:.tool_name, cwd:.cwd}' 2>/dev/null
      ;;
  esac
done < "$LOG"

printf '\nstop event details:\n'
while IFS= read -r line; do
  ev=$(printf '%s' "$line" | jq -r '.hook_event_name // ""' 2>/dev/null)
  [ "$ev" = "stop" ] || continue
  printf '%s\n' "$line" | jq -c '{status:.status, loop_count:.loop_count, conversation_id:.conversation_id}' 2>/dev/null
done < "$LOG"

printf '\nProceed contract (from Cursor docs + audit observe-only):\n'
printf '  beforeShellExecution / beforeMCPExecution observe-only:\n'
printf '    exit 1, empty stdout → fail-open → default Cursor approval UI unchanged\n'
printf '  DO NOT return {"permission":"allow"} (auto-allows) or exit 2 (denies)\n'

exit 0
