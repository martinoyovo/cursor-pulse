#!/usr/bin/env bash
#
# cursor-pulse — on-demand status line renderer.
#
# Cursor's CLI has no live status-line slot, so hooks capture session state to
# disk and this script renders a line on demand (shell prompt, tmux, etc.).
#
# Reads state from ~/.cursor/cursor-pulse/state/ (or CURSOR_CONFIG_DIR override).
# Also accepts a JSON object on stdin to override fields (forward-compat).
#
# Dependencies: bash + jq (git optional). Degrades gracefully.

set -uo pipefail

INPUT_JSON=$(cat 2>/dev/null) || INPUT_JSON=""

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)
[ -n "${SELF_DIR:-}" ] && [ -f "$SELF_DIR/config.sh" ] && . "$SELF_DIR/config.sh"

CURSOR_DIR=${CURSOR_CONFIG_DIR:-"$HOME/.cursor"}
STATE_DIR="${CURSOR_PULSE_STATE_DIR:-$CURSOR_DIR/cursor-pulse/state}"

# ─── ANSI helpers ────────────────────────────────────────────────────────────
if [ -n "${NO_COLOR:-}" ]; then
  R="" B="" D=""
  C_MODEL="" C_DIR="" C_BRANCH="" C_DIRTY="" C_ACT="" C_SEP=""
  C_CTX_LOW="" C_CTX_MID="" C_CTX_HIGH="" C_BAR_EMPTY=""
else
  R=$'\033[0m'; B=$'\033[1m'; D=$'\033[2m'
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
fi

if [ "${CURSOR_PULSE_NERD:-0}" = "1" ]; then
  G_MODEL=""
  G_DIR=""
  G_BRANCH=""
  G_CTX="󰓅 "
  G_ACT=""
else
  G_MODEL=""
  G_DIR=""
  G_BRANCH=""
  G_CTX=""
  G_ACT=""
fi

SEP="${C_SEP} │ ${R}"

is_hidden() {
  case ",${CURSOR_PULSE_HIDE:-}," in
    *",$1,"*) return 0 ;;
    *) return 1 ;;
  esac
}

# ─── Load state from disk ────────────────────────────────────────────────────
load_state_file() {
  local f=$1
  [ -f "$f" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  MODEL=$(jq -r '.model // ""' "$f" 2>/dev/null)
  ROOT=$(jq -r '.root // ""' "$f" 2>/dev/null)
  STATUS=$(jq -r '.status // ""' "$f" 2>/dev/null)
  CMD_COUNT=$(jq -r '.command_count // 0' "$f" 2>/dev/null)
  CONTEXT_PCT=$(jq -r '.context_pct // empty' "$f" 2>/dev/null)
  CONTEXT_TOKENS=$(jq -r '.context_tokens // empty' "$f" 2>/dev/null)
  CONTEXT_WINDOW=$(jq -r '.context_window // empty' "$f" 2>/dev/null)
  return 0
}

MODEL="" ROOT="" STATUS="" CMD_COUNT=0
CONTEXT_PCT="" CONTEXT_TOKENS="" CONTEXT_WINDOW=""

# Stdin override (forward-compat)
if [ -n "$INPUT_JSON" ] && command -v jq >/dev/null 2>&1; then
  MODEL=$(printf '%s' "$INPUT_JSON" | jq -r '.model // .model.id // ""' 2>/dev/null)
  ROOT=$(printf '%s' "$INPUT_JSON" | jq -r '.root // .cwd // .workspace.current_dir // ""' 2>/dev/null)
  STATUS=$(printf '%s' "$INPUT_JSON" | jq -r '.status // ""' 2>/dev/null)
  CMD_COUNT=$(printf '%s' "$INPUT_JSON" | jq -r '.command_count // 0' 2>/dev/null)
  CONTEXT_PCT=$(printf '%s' "$INPUT_JSON" | jq -r '.context_pct // .context_usage_percent // empty' 2>/dev/null)
  CONTEXT_TOKENS=$(printf '%s' "$INPUT_JSON" | jq -r '.context_tokens // empty' 2>/dev/null)
  CONTEXT_WINDOW=$(printf '%s' "$INPUT_JSON" | jq -r '.context_window // .context_window_size // empty' 2>/dev/null)
fi

# Fill from disk when stdin didn't provide enough
if [ -z "$MODEL" ] && [ -z "$ROOT" ] && [ -d "$STATE_DIR" ]; then
  state_file=""
  pwd_real=$(CDPATH= cd -- "$PWD" 2>/dev/null && pwd) || pwd_real="$PWD"

  # Prefer session whose root matches $PWD
  if command -v jq >/dev/null 2>&1; then
    for f in "$STATE_DIR"/*.json; do
      [ -f "$f" ] || continue
      r=$(jq -r '.root // ""' "$f" 2>/dev/null)
      [ -n "$r" ] || continue
      r_real=$(CDPATH= cd -- "$r" 2>/dev/null && pwd) || r_real="$r"
      if [ "$r_real" = "$pwd_real" ]; then
        state_file=$f
        break
      fi
    done
  fi

  # Else most recently modified state file
  if [ -z "$state_file" ]; then
    state_file=$(ls -t "$STATE_DIR"/*.json 2>/dev/null | head -n 1)
  fi

  # Else latest pointer
  if [ -z "$state_file" ] && [ -f "$STATE_DIR/latest" ]; then
    cid=$(cat "$STATE_DIR/latest" 2>/dev/null)
    [ -n "$cid" ] && [ -f "$STATE_DIR/${cid}.json" ] && state_file="$STATE_DIR/${cid}.json"
  fi

  if [ -n "$state_file" ]; then
    load_state_file "$state_file" || true
  fi
fi

# Friendly hint when no state exists
if [ -z "$MODEL" ] && [ -z "$ROOT" ] && [ -z "$STATUS" ]; then
  printf '%bNo cursor-pulse session state yet.%b Run cursor-agent in a hooked session, or: cursor-pulse test stop\n' "${D:-}" "${R:-}"
  exit 0
fi

[ -n "$ROOT" ] || ROOT="$PWD"
CWD="$ROOT"

# ─── Segment: model ──────────────────────────────────────────────────────────
SEG_MODEL=""
if [ -n "$MODEL" ] && ! is_hidden model; then
  SEG_MODEL="${C_MODEL}${B}${G_MODEL}${MODEL}${R}"
fi

# ─── Segment: directory (basename) ───────────────────────────────────────────
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

# ─── Segment: context usage (from preCompact capture) ────────────────────────
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

  SEG_CTX="${ctx_color}${G_CTX}${R}${bar} ${ctx_color}${pct}%${R}"
fi

# ─── Segment: activity (status + command count) ──────────────────────────────
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
  count_str=""
  [ "${CMD_COUNT:-0}" -gt 0 ] 2>/dev/null && count_str=" (${CMD_COUNT} cmds)"
  SEG_ACT="${C_ACT}${G_ACT}${act_label}${count_str}${R}"
fi

# ─── Assemble ────────────────────────────────────────────────────────────────
out=""
for seg in "$SEG_MODEL" "$SEG_DIR" "$SEG_BRANCH" "$SEG_CTX" "$SEG_ACT"; do
  [ -n "$seg" ] || continue
  if [ -z "$out" ]; then out="$seg"; else out="${out}${SEP}${seg}"; fi
done

[ -n "$out" ] && printf '%b\n' "$out"
