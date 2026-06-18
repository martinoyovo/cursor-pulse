# cursor-pulse

A tiny [Cursor CLI](https://cursor.com) (`cursor-agent`) companion that bundles two
things in one repo:

1. **An on-demand status line** — rendered by `cursor-pulse status` from session
   state captured by hooks, plus live reads of `cli-config.json` and agent
   transcripts.
2. **Desktop notifications** — fired via hooks when Cursor finishes a turn or
   needs your attention (with focus-aware skip on macOS).

It's the Cursor CLI counterpart to
[`claude-pulse`](https://github.com/martinoyovo/claude-pulse) and
[`codex-pulse`](https://github.com/martinoyovo/codex-pulse).
Dependency-light: portable `bash`/`sh` + `jq` (and `git` for the branch
segment). No frameworks.

## Important: no live in-TUI status line

Unlike Claude Code, **Cursor's CLI has no customizable status-line slot** as of
2026 — there is nothing to "turn on" inside cursor-agent itself. cursor-pulse
captures session state via hooks and **`cursor-pulse status` renders a line on
demand**. If you install it and never wire that command anywhere, it will look
like nothing is working.

**You must embed `cursor-pulse status` somewhere that re-runs often** — your
shell prompt, starship, or tmux status bar. Run `cursor-pulse doctor` anytime
for copy-paste snippets.

### Make it feel live

**bash** — add to `~/.bashrc`:

```sh
PROMPT_COMMAND='PS1="$(cursor-pulse status 2>/dev/null)
$PS1"'
```

**zsh** — add to `~/.zshrc`:

```sh
precmd() { CURSOR_PULSE_LINE=$(cursor-pulse status 2>/dev/null); }
PROMPT='${CURSOR_PULSE_LINE:+$CURSOR_PULSE_LINE$'\n'}% '
```

**starship** — add to `~/.config/starship.toml`:

```toml
[custom.cursor-pulse]
command = "cursor-pulse status"
format = "[$output]($style) "
shell = ["bash", "zsh"]
```

**tmux** — add to `~/.tmux.conf`:

```sh
set -g status-right "#(cursor-pulse status 2>/dev/null)"
```

Context usage only appears **after Cursor fires a `preCompact` hook** —
transcripts on current cursor-agent builds do not carry token counts.

## Preview

The status line is a single, color-coded line:

```
◆ ALLOWLIST │ Composer 2.5 Fast │ cursor-pulse │ main* │ idle (3 cmds, 2 turns, Shell×4) │ ▦███░░ 12% (120K/1.0M) │ ◷ 4m
```

| Segment | Source | Shows |
| --- | --- | --- |
| `◆ ALLOWLIST` | `cli-config.json` | MODE badge when noteworthy (`MAX`, non-automatic `approvalMode`) |
| `Composer 2.5 Fast` | `cli-config.json` | Model display name |
| `cursor-pulse` | captured state | Project directory (basename) |
| `main*` | git | Branch — `*` means dirty working tree |
| `idle (…)` | state + transcript | Activity status, command/turn counts, top tool |
| `███░░ 12% (120K/1.0M)` | `preCompact` hook | Smooth context bar + token counts |
| `◷ 4m` | `sessionEnd` / elapsed | Session duration |

Notifications look like:

- **cursor-pulse** (title = project folder, or session title if found) —
  **Cursor is waiting for your input** when a turn ends.
- Skipped automatically when **this terminal tab** is focused (macOS;
  Terminal.app / iTerm2).
- **Click the notification** to jump back to the exact terminal tab (Terminal.app / iTerm2). macOS may prompt once for Automation permission the first time you click.
- **Cursor needs approval: `<cmd>`** — when a shell command or MCP tool awaits your approval (`beforeShellExecution` / `beforeMCPExecution` observer; fail-open, never auto-allows).

## Install

```sh
git clone https://github.com/martinoyovo/cursor-pulse.git
cd cursor-pulse
./install.sh
```

Or one-shot:

```sh
curl -fsSL https://raw.githubusercontent.com/martinoyovo/cursor-pulse/main/install.sh | sh
```

The installer copies scripts to `~/.cursor/cursor-pulse/`, merges hook entries
into `~/.cursor/hooks.json` (observe-only events only), symlinks the CLI, and
on macOS builds a Cursor-branded `CursorPulse.app` notifier.

```sh
cursor-pulse status     # render the status line on demand
cursor-pulse test       # fire a test notification
cursor-pulse doctor     # check install health
cursor-pulse update     # re-install the latest version from GitHub
cursor-pulse uninstall  # remove cursor-pulse
```

Run `cursor-pulse doctor` for install checks **and** the prompt/tmux snippets above.

## Configuration

Edit `~/.cursor/cursor-pulse/config.sh` (created by the installer, never
clobbered on update):

```sh
# Icon modes (mutually exclusive — default is plain text):
# CURSOR_PULSE_NERD=1      # Nerd Font (needs a Nerd Font in your terminal)
# CURSOR_PULSE_EMOJI=1     # emoji (any terminal)
# CURSOR_PULSE_SYMBOLS=1   # Unicode symbols: ✦ ▸ ⎇ ▦ ⚙ ◷

CURSOR_PULSE_BAR_WIDTH=12
CURSOR_PULSE_NOTIFY_SKIP_FOCUSED=1
```

### Status line

| Variable | Default | Effect |
| --- | --- | --- |
| `CURSOR_PULSE_NERD` | `0` | Nerd Font glyphs (needs a Nerd Font or shows boxes). |
| `CURSOR_PULSE_EMOJI` | `0` | Emoji icons — works on any terminal. |
| `CURSOR_PULSE_SYMBOLS` | `0` | Plain Unicode symbols (no special font). |
| `CURSOR_PULSE_BAR_WIDTH` | `10` | Context bar width in cells. |
| `CURSOR_PULSE_TOKENS` | `1` | Show `(120K/1.0M)` token counts after context %. |
| `CURSOR_PULSE_HIDE` | _(none)_ | Comma list: `mode`, `model`, `dir`, `branch`, `activity`, `context`, `duration`, `tools`. |
| `NO_COLOR` | _(unset)_ | Disable ANSI colors. |
| `CURSOR_CONFIG_DIR` | `~/.cursor` | Override Cursor config directory. |

### Notifications

| Variable | Default | Effect |
| --- | --- | --- |
| `CURSOR_PULSE_NOTIFY` | `auto` | Backend: `auto`, `terminal-notifier`, `alerter`, `notify-send`, `osa`, `osc9`, `bell`, `off`. |
| `CURSOR_PULSE_NOTIFY_ON_STOP` | `1` | Notify when a turn ends. |
| `CURSOR_PULSE_NOTIFY_ON_SESSION_END` | `0` | Notify on session end. |
| `CURSOR_PULSE_NOTIFY_ON_SHELL` | `0` | Notify after each shell command. |
| `CURSOR_PULSE_NOTIFY_SKIP_FOCUSED` | `1` | Skip notification when this terminal tab is focused (macOS). |
| `CURSOR_PULSE_NOTIFY_FOCUS_ON_CLICK` | `1` | Click notification → focus the terminal tab that fired it (macOS). |
| `CURSOR_PULSE_NOTIFY_ON_APPROVAL` | `1` | Notify when a command/tool needs approval (`beforeShellExecution` / `beforeMCPExecution`). |
| `CURSOR_PULSE_NOTIFY_DEBOUNCE` | `10` | Suppress duplicate notifications within N seconds per conversation. |
| `CURSOR_PULSE_NOTIFY_TITLE` | folder name | Override notification title. |
| `CURSOR_PULSE_NOTIFY_ICON` | _(none)_ | PNG path for `notify-send` only. |

On macOS, install `terminal-notifier` for the best experience (`brew install terminal-notifier`). The installer builds `CursorPulse.app` with Cursor's icon so alerts show the Cursor logo — no `-sender` or `-appIcon` hacks that suppress banners.

## Test

```sh
# Notification + state (stdout must stay empty)
echo '{"hook_event_name":"stop","status":"completed","workspace_roots":["'"$PWD"'"],"conversation_id":"t","model":"composer-2.5","cwd":"'"$PWD"'"}' \
  | ./hooks/notify.sh

# Stdin override (forward-compat test):
echo '{"root":"/tmp/zzz","status":"error","context_pct":77,"context_tokens":1000,"context_window":2000}' \
  | NO_COLOR=1 ./statusline.sh

# Status line (reads state + cli-config.json)
./statusline.sh </dev/null

# With context segment (simulate preCompact capture)
echo '{"hook_event_name":"preCompact","context_usage_percent":12,"context_tokens":120000,"context_window_size":1000000,"workspace_roots":["'"$PWD"'"],"conversation_id":"t","model":"composer-2.5","cwd":"'"$PWD"'"}' \
  | ./hooks/notify.sh
./statusline.sh
```

## Uninstall

```sh
cursor-pulse uninstall
```

## Notes

- **`beforeShellExecution` / `beforeMCPExecution`** — registered as a **fail-open observer** (exit 1, empty stdout) so Cursor keeps its normal approval UI; cursor-pulse only sends a notification, never auto-allows or denies.
- Other hooks are **observe-only** — no permission changes.
- Hook scripts must keep **stdout clean** — Cursor parses JSON on stdout.
- Context % comes only from `preCompact`; transcripts are mined for turns/tools only.
- `sessionStart` / `sessionEnd` / `stop` require a recent `cursor-agent` version.
- Status-line design modeled on [claude-pulse 0.5.1](https://github.com/martinoyovo/claude-pulse) and [agy-statusline](https://codeberg.org/jochenkirstaetter/agy-statusline).

## License

MIT, copyright 2026 Martino Yovo. See [LICENSE](LICENSE).
