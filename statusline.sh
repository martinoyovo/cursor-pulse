#!/usr/bin/env bash
#
# cursor-pulse — on-demand status line renderer (v2).
#
# Cursor's CLI has no live status-line slot; hooks capture session state to disk
# and this script renders a line on demand. Also reads cli-config.json and agent
# transcripts for richer segments.
#
# Dependencies: bash + jq (git optional). Degrades gracefully.

set -uo pipefail

INPUT_JSON=""
[ -t 0 ] || INPUT_JSON=$(cat 2>/dev/null) || INPUT_JSON=""

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)
[ -n "${SELF_DIR:-}" ] && [ -f "$SELF_DIR/config.sh" ] && . "$SELF_DIR/config.sh"

CURSOR_DIR=${CURSOR_CONFIG_DIR:-"$HOME/.cursor"}
STATE_DIR="${CURSOR_PULSE_STATE_DIR:-$CURSOR_DIR/cursor-pulse/state}"
CLI_CONFIG="$CURSOR_DIR/cli-config.json"
PROJECTS_DIR="$CURSOR_DIR/projects"

# ─── ANSI helpers ────────────────────────────────────────────────────────────
if [ -n "${NO_COLOR:-}" ]; then
  R="" B="" D="" I=""
  C_MODEL="" C_DIR="" C_BRANCH="" C_DIRTY="" C_ACT="" C_SEP="" C_MODE=""
  C_CTX_LOW="" C_CTX_MID="" C_CTX_HIGH="" C_BAR_EMPTY="" C_DUR=""
else
  R=$'\033[0m'; B=$'\033[1m'; D=$'\033[2m'; I=$'\033[3m'
  C_MODE=$'\033[38;5;141m'
  C_MODEL=$'\033[95m'
  C_DIR=$'\033[96m'
  C_BRANCH=$'\033[94m'
  C_DIRTY=$'\033[93m'
  C_ACT=$'\033[92m'
  C_SEP=$'\033[90m'
  C_CTX_LOW=$'\033[32m'
  C_CTX_MID=$'\033[93m'
  C_CTX_HIGH=$'\033[91m'
  C_BAR_EMPTY=$'\033[90m'
  C_DUR=$'\033[90m'
fi

# ─── Glyphs (plain by default; opt-in icon modes are mutually exclusive) ─────
if [ "${CURSOR_PULSE_NERD:-0}" = "1" ]; then
  G_MODEL=" "
  G_DIR=" "
  G_BRANCH=" "
  G_CTX="󰓅 "
  G_ACT=" "
  G_DUR=" "
elif [ "${CURSOR_PULSE_EMOJI:-0}" = "1" ]; then
  G_MODEL="🤖 "
  G_DIR="📁 "
  G_BRANCH="🌿 "
  G_CTX="📊 "
  G_ACT="⚡ "
  G_DUR="⏱️ "
elif [ "${CURSOR_PULSE_SYMBOLS:-0}" = "1" ]; then
  G_MODEL="✦ "
  G_DIR="▸ "
  G_BRANCH="⎇ "
  G_CTX="▦ "
  G_ACT="⚙ "
  G_DUR="◷ "
else
  G_MODEL=""
  G_DIR=""
  G_BRANCH=""
  G_CTX=""
  G_ACT=""
  G_DUR=""
fi

SEP="${C_SEP} │ ${R}"

is_hidden() {
  case ",${CURSOR_PULSE_HIDE:-}," in
    *",$1,"*) return 0 ;;
    *) return 1 ;;
  esac
}

human_tokens() {
  local n=$1
  if [ "$n" -ge 1000000 ] 2>/dev/null; then
    printf '%d.%dM' "$((n/1000000))" "$(((n%1000000)/100000))"
  elif [ "$n" -ge 1000 ] 2>/dev/null; then
    printf '%dK' "$((n/1000))"
  else
    printf '%d' "${n:-0}"
  fi
}

# Path → Cursor projects slug (e.g. /Users/me/proj → Users-me-proj)
project_slug() {
  local p=$1
  p="${p#/}"
  printf '%s' "$p" | tr '/' '-'
}

find_transcript() {
  local cid=$1 root=$2 stored_path=$3
  if [ -n "$stored_path" ] && [ -f "$stored_path" ]; then
    printf '%s' "$stored_path"
    return 0
  fi
  [ -n "$cid" ] || return 1
  local slug cand
  slug=$(project_slug "$root")
  cand="$PROJECTS_DIR/$slug/agent-transcripts/$cid/$cid.jsonl"
  if [ -f "$cand" ]; then
    printf '%s' "$cand"
    return 0
  fi
  # Fallback: search any project slug for this conversation id
  cand=$(find "$PROJECTS_DIR" -path "*/agent-transcripts/$cid/$cid.jsonl" 2>/dev/null | head -n 1)
  [ -n "$cand" ] && [ -f "$cand" ] && printf '%s' "$cand"
}

# ─── Load state from disk ────────────────────────────────────────────────────
MODEL="" ROOT="" STATUS="" CMD_COUNT=0 CONVERSATION_ID=""
CONTEXT_PCT="" CONTEXT_TOKENS="" CONTEXT_WINDOW=""
TRANSCRIPT_PATH="" STARTED_AT="" DURATION_MS="" SESSION_END_MS=""
STATE_FILE=""

load_state_file() {
  local f=$1
  [ -f "$f" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  MODEL=$(jq -r '.model // ""' "$f" 2>/dev/null)
  ROOT=$(jq -r '.root // ""' "$f" 2>/dev/null)
  STATUS=$(jq -r '.status // ""' "$f" 2>/dev/null)
  CMD_COUNT=$(jq -r '.command_count // 0' "$f" 2>/dev/null)
  CONVERSATION_ID=$(jq -r '.conversation_id // ""' "$f" 2>/dev/null)
  CONTEXT_PCT=$(jq -r '.context_pct // empty' "$f" 2>/dev/null)
  CONTEXT_TOKENS=$(jq -r '.context_tokens // empty' "$f" 2>/dev/null)
  CONTEXT_WINDOW=$(jq -r '.context_window // empty' "$f" 2>/dev/null)
  TRANSCRIPT_PATH=$(jq -r '.transcript_path // ""' "$f" 2>/dev/null)
  STARTED_AT=$(jq -r '.started_at // ""' "$f" 2>/dev/null)
  DURATION_MS=$(jq -r '.duration_ms // empty' "$f" 2>/dev/null)
  return 0
}

# Stdin override (forward-compat)
if [ -n "$INPUT_JSON" ] && command -v jq >/dev/null 2>&1; then
  MODEL=$(printf '%s' "$INPUT_JSON" | jq -r '.model // .model.id // ""' 2>/dev/null)
  ROOT=$(printf '%s' "$INPUT_JSON" | jq -r '.root // .cwd // .workspace.current_dir // ""' 2>/dev/null)
  STATUS=$(printf '%s' "$INPUT_JSON" | jq -r '.status // ""' 2>/dev/null)
  CMD_COUNT=$(printf '%s' "$INPUT_JSON" | jq -r '.command_count // 0' 2>/dev/null)
  CONVERSATION_ID=$(printf '%s' "$INPUT_JSON" | jq -r '.conversation_id // ""' 2>/dev/null)
  CONTEXT_PCT=$(printf '%s' "$INPUT_JSON" | jq -r '.context_pct // .context_usage_percent // empty' 2>/dev/null)
  CONTEXT_TOKENS=$(printf '%s' "$INPUT_JSON" | jq -r '.context_tokens // empty' 2>/dev/null)
  CONTEXT_WINDOW=$(printf '%s' "$INPUT_JSON" | jq -r '.context_window // .context_window_size // empty' 2>/dev/null)
  TRANSCRIPT_PATH=$(printf '%s' "$INPUT_JSON" | jq -r '.transcript_path // ""' 2>/dev/null)
  DURATION_MS=$(printf '%s' "$INPUT_JSON" | jq -r '.duration_ms // empty' 2>/dev/null)
fi

# Fill from disk when stdin didn't provide enough
if [ -z "$ROOT" ] && [ -d "$STATE_DIR" ]; then
  pwd_real=$(CDPATH= cd -- "$PWD" 2>/dev/null && pwd) || pwd_real="$PWD"

  if command -v jq >/dev/null 2>&1; then
    best_epoch=0
    for f in "$STATE_DIR"/*.json; do
      [ -f "$f" ] || continue
      r=$(jq -r '.root // ""' "$f" 2>/dev/null)
      [ -n "$r" ] || continue
      r_real=$(CDPATH= cd -- "$r" 2>/dev/null && pwd) || r_real="$r"
      [ "$r_real" = "$pwd_real" ] || continue

      epoch=0
      updated_at=$(jq -r '.updated_at // ""' "$f" 2>/dev/null)
      if [ -n "$updated_at" ] && [ "$updated_at" != "null" ]; then
        epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$updated_at" +%s 2>/dev/null) \
          || epoch=$(date -u -d "$updated_at" +%s 2>/dev/null) \
          || epoch=0
      fi
      if [ "$epoch" -le 0 ] 2>/dev/null; then
        epoch=$(stat -f %m "$f" 2>/dev/null) || epoch=$(stat -c %Y "$f" 2>/dev/null) || epoch=0
      fi
      if [ "$epoch" -ge "$best_epoch" ] 2>/dev/null; then
        best_epoch=$epoch
        STATE_FILE=$f
      fi
    done
  fi

  if [ -z "$STATE_FILE" ]; then
    STATE_FILE=$(ls -t "$STATE_DIR"/*.json 2>/dev/null | head -n 1)
  fi

  if [ -z "$STATE_FILE" ] && [ -f "$STATE_DIR/latest" ]; then
    cid=$(cat "$STATE_DIR/latest" 2>/dev/null)
    [ -n "$cid" ] && [ -f "$STATE_DIR/${cid}.json" ] && STATE_FILE="$STATE_DIR/${cid}.json"
  fi

  [ -n "$STATE_FILE" ] && load_state_file "$STATE_FILE" || true
fi

# Friendly hint when no state exists
if [ -z "$MODEL" ] && [ -z "$ROOT" ] && [ -z "$STATUS" ]; then
  printf '%bNo cursor-pulse session state yet.%b Run cursor-agent in a hooked session, or: cursor-pulse test stop\n' "${D:-}" "${R:-}"
  exit 0
fi

[ -n "$ROOT" ] || ROOT="$PWD"
CWD="$ROOT"

# ─── cli-config.json (model display name + mode badge) ───────────────────────
CLI_MODEL=""
MAX_MODE="false"
APPROVAL_MODE=""

if [ -f "$CLI_CONFIG" ] && command -v jq >/dev/null 2>&1; then
  CLI_MODEL=$(jq -r '.model.displayName // .model.displayNameShort // ""' "$CLI_CONFIG" 2>/dev/null)
  MAX_MODE=$(jq -r '.maxMode // .model.maxMode // false' "$CLI_CONFIG" 2>/dev/null)
  APPROVAL_MODE=$(jq -r '.approvalMode // ""' "$CLI_CONFIG" 2>/dev/null)
fi

# Prefer cli-config display name over hook-captured model id
DISPLAY_MODEL="$MODEL"
[ -n "$CLI_MODEL" ] && DISPLAY_MODEL="$CLI_MODEL"

# ─── Transcript mining ───────────────────────────────────────────────────────
TRANSCRIPT=""
TOP_TOOL="" TOP_TOOL_COUNT=0 TURN_COUNT=0

TRANSCRIPT=$(find_transcript "$CONVERSATION_ID" "$ROOT" "$TRANSCRIPT_PATH") || TRANSCRIPT=""

if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] && command -v jq >/dev/null 2>&1; then
  TURN_COUNT=$(jq -rc 'select(.role=="user")' "$TRANSCRIPT" 2>/dev/null | wc -l | tr -d ' ')
  top_line=$(jq -rc 'select(.role=="assistant") | .message.content[]? | select(.type=="tool_use") | .name' \
    "$TRANSCRIPT" 2>/dev/null | sort | uniq -c | sort -rn | head -n 1)
  if [ -n "$top_line" ]; then
    TOP_TOOL_COUNT=$(printf '%s' "$top_line" | awk '{print $1}')
    TOP_TOOL=$(printf '%s' "$top_line" | awk '{print $2}')
  fi

  # Optional: usage from transcript if a future cursor-agent adds it (not default)
  if [ -z "$CONTEXT_TOKENS" ] || [ "$CONTEXT_TOKENS" = "null" ]; then
    usage_line=$(grep -E '"usage"|"context_tokens"|"context_usage"' "$TRANSCRIPT" 2>/dev/null | tail -n 1)
    if [ -n "$usage_line" ]; then
      tok=$(printf '%s' "$usage_line" | jq -r '
        .message.usage.input_tokens // .usage.input_tokens //
        .context_tokens // empty' 2>/dev/null)
      [ -n "$tok" ] && [ "$tok" != "null" ] && CONTEXT_TOKENS=$tok
    fi
  fi
fi

# ─── Segment: MODE badge ─────────────────────────────────────────────────────
SEG_MODE=""
if ! is_hidden mode; then
  mode_parts=""
  case "$MAX_MODE" in
    true|True|1) mode_parts="MAX" ;;
  esac
  # Show approvalMode when noteworthy (not automatic/default/empty)
  case "$APPROVAL_MODE" in
    ""|automatic|default) ;;
    *)
      am=$(printf '%s' "$APPROVAL_MODE" | tr '[:lower:]' '[:upper:]')
      if [ -n "$mode_parts" ]; then mode_parts="${mode_parts} ${am}"
      else mode_parts="$am"
      fi
      ;;
  esac
  [ -n "$mode_parts" ] && SEG_MODE="${C_MODE}${B}◆ ${mode_parts}${R}"
fi

# ─── Segment: model ──────────────────────────────────────────────────────────
SEG_MODEL=""
if [ -n "$DISPLAY_MODEL" ] && ! is_hidden model; then
  SEG_MODEL="${C_MODEL}${B}${G_MODEL}${DISPLAY_MODEL}${R}"
fi

# ─── Segment: directory (basename) ─────────────────────────────────────────
SEG_DIR=""
if [ -n "$CWD" ] && ! is_hidden dir; then
  base=$(basename -- "$CWD")
  [ "$CWD" = "$HOME" ] && base="~"
  SEG_DIR="${C_DIR}${G_DIR}${base}${R}"
fi

# ─── Segment: git branch (+ dirty) ───────────────────────────────────────────
SEG_BRANCH=""
if ! is_hidden branch && command -v git >/dev/null 2>&1; then
  branch=$(git -C "$CWD" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  if [ -n "$branch" ]; then
    if [ "$branch" = "HEAD" ]; then
      branch=$(git -C "$CWD" rev-parse --short HEAD 2>/dev/null || echo "HEAD")
    fi
    if [ -n "$(git -C "$CWD" status --porcelain 2>/dev/null)" ]; then
      SEG_BRANCH="${C_BRANCH}${G_BRANCH}${branch}${C_DIRTY}*${R}"
    else
      SEG_BRANCH="${C_BRANCH}${G_BRANCH}${branch}${R}"
    fi
  fi
fi

# ─── Segment: activity (status + counts + optional tool) ─────────────────────
SEG_ACT=""
if ! is_hidden activity; then
  act_label=""
  case "$STATUS" in
    running)   act_label="running" ;;
    completed) act_label="idle" ;;
    aborted)   act_label="stopped" ;;
    error)     act_label="error" ;;
    ended)     act_label="ended" ;;
    *)         [ -n "$STATUS" ] && act_label="$STATUS" || act_label="unknown" ;;
  esac
  extras=""
  [ "${CMD_COUNT:-0}" -gt 0 ] 2>/dev/null && extras="${extras}, ${CMD_COUNT} cmds"
  [ "${TURN_COUNT:-0}" -gt 0 ] 2>/dev/null && extras="${extras}, ${TURN_COUNT} turns"
  if ! is_hidden tools && [ -n "$TOP_TOOL" ]; then
    tool_str="$TOP_TOOL"
    [ "${TOP_TOOL_COUNT:-0}" -gt 1 ] 2>/dev/null && tool_str="${TOP_TOOL}×${TOP_TOOL_COUNT}"
    extras="${extras}, ${tool_str}"
  fi
  extras="${extras#, }"
  if [ -n "$extras" ]; then
    SEG_ACT="${C_ACT}${G_ACT}${act_label}${D} (${extras})${R}"
  else
    SEG_ACT="${C_ACT}${G_ACT}${act_label}${R}"
  fi
fi

# ─── Segment: context usage (preCompact capture only) ────────────────────────
SEG_CTX=""
if ! is_hidden context && [ -n "$CONTEXT_PCT" ] && [ "$CONTEXT_PCT" != "null" ]; then
  pct=${CONTEXT_PCT%.*}
  [ -n "$pct" ] && [ "$pct" -ge 0 ] 2>/dev/null || pct=0
  [ "$pct" -gt 100 ] && pct=100

  if [ "$pct" -ge 80 ]; then ctx_color="$C_CTX_HIGH"
  elif [ "$pct" -ge 50 ]; then ctx_color="$C_CTX_MID"
  else ctx_color="$C_CTX_LOW"
  fi

  len=${CURSOR_PULSE_BAR_WIDTH:-10}
  eighths=$(( pct * len * 8 / 100 ))
  full=$(( eighths / 8 ))
  rem=$(( eighths % 8 ))
  bar=""
  i=0
  while [ "$i" -lt "$len" ]; do
    if [ "$i" -lt "$full" ]; then
      bar="${bar}${ctx_color}█${R}"
    elif [ "$i" -eq "$full" ] && [ "$rem" -gt 0 ]; then
      case "$rem" in
        1) ch="▏" ;; 2) ch="▎" ;; 3) ch="▍" ;; 4) ch="▌" ;;
        5) ch="▋" ;; 6) ch="▊" ;; 7) ch="▉" ;;
      esac
      bar="${bar}${ctx_color}${ch}${R}"
    else
      bar="${bar}${C_BAR_EMPTY}░${R}"
    fi
    i=$(( i + 1 ))
  done

  counts=""
  if [ "${CURSOR_PULSE_TOKENS:-1}" != "0" ]; then
    used=${CONTEXT_TOKENS:-0}
    limit=${CONTEXT_WINDOW:-0}
    if [ -n "$used" ] && [ "$used" != "null" ] && [ "$used" -gt 0 ] 2>/dev/null; then
      if [ -n "$limit" ] && [ "$limit" != "null" ] && [ "$limit" -gt 0 ] 2>/dev/null; then
        counts=" ${D}($(human_tokens "$used")/$(human_tokens "$limit"))${R}"
      else
        counts=" ${D}($(human_tokens "$used"))${R}"
      fi
    fi
  fi
  SEG_CTX="${ctx_color}${G_CTX}${R}${bar} ${ctx_color}${pct}%${R}${counts}"
fi

# ─── Segment: session duration ───────────────────────────────────────────────
SEG_DUR=""
if ! is_hidden duration; then
  dur_ms=""
  if [ -n "$DURATION_MS" ] && [ "$DURATION_MS" != "null" ] && [ "$DURATION_MS" -gt 0 ] 2>/dev/null; then
    dur_ms=$DURATION_MS
  elif [ -n "$STARTED_AT" ] && [ "$STATUS" = "running" ]; then
    # Elapsed since sessionStart while still running
    now_epoch=$(date -u +%s 2>/dev/null)
    start_epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$STARTED_AT" +%s 2>/dev/null) \
      || start_epoch=$(date -u -d "$STARTED_AT" +%s 2>/dev/null) \
      || start_epoch=0
    if [ "$start_epoch" -gt 0 ] 2>/dev/null && [ "$now_epoch" -gt "$start_epoch" ] 2>/dev/null; then
      dur_ms=$(( (now_epoch - start_epoch) * 1000 ))
    fi
  fi

  if [ -n "$dur_ms" ] && [ "$dur_ms" -gt 0 ] 2>/dev/null; then
    secs=$(( dur_ms / 1000 ))
    if [ "$secs" -ge 3600 ]; then
      dur_str="$(( secs / 3600 ))h$(( (secs % 3600) / 60 ))m"
    elif [ "$secs" -ge 60 ]; then
      dur_str="$(( secs / 60 ))m"
    else
      dur_str="${secs}s"
    fi
    SEG_DUR="${C_DUR}${G_DUR}${dur_str}${R}"
  fi
fi

# ─── Assemble: mode │ model │ dir │ branch │ activity │ context │ duration ─
out=""
for seg in "$SEG_MODE" "$SEG_MODEL" "$SEG_DIR" "$SEG_BRANCH" "$SEG_ACT" "$SEG_CTX" "$SEG_DUR"; do
  [ -n "$seg" ] || continue
  if [ -z "$out" ]; then out="$seg"; else out="${out}${SEP}${seg}"; fi
done

[ -n "$out" ] && printf '%b\n' "$out"
