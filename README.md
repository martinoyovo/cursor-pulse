# cursor-pulse

A tiny [Cursor CLI](https://cursor.com) (`cursor-agent`) companion that bundles two
things in one repo:

1. **An on-demand status line** — rendered by `cursor-pulse status` from session
   state captured by hooks (see limitation below).
2. **Desktop notifications** — fired via hooks when Cursor finishes a turn or
   needs your attention.

It's the Cursor CLI counterpart to
[`claude-pulse`](https://github.com/martinoyovo/claude-pulse) and
[`codex-pulse`](https://github.com/martinoyovo/codex-pulse).
Dependency-light: portable `bash`/`sh` + `jq` (and `git` for the branch
segment). No frameworks.

## Important: no live in-TUI status line

Unlike Claude Code, **Cursor's CLI has no customizable status-line slot** as of
2026 — there is no composer-bar hook that pipes session JSON to a script on
every render. cursor-pulse works around this by:

- **Hooks capture session state to disk** as they fire (`stop`, `sessionStart`,
  `afterShellExecution`, `preCompact`, etc.).
- **`cursor-pulse status` renders the line on demand** from that captured state.

Use it in your shell prompt, tmux status bar, or run it manually. Context usage
(`context_pct`) only appears **after Cursor fires a `preCompact` hook** — there
is no other source for context-window percentage in the Cursor CLI payload.

## Preview

The status line is a single, color-coded line:

```
composer-2 │ cursor-pulse │ main* │ ███░░ 64% │ idle (3 cmds)
```

| Segment | Shows | Color |
| --- | --- | --- |
| `composer-2` | Model name | magenta |
| `cursor-pulse` | Project directory (basename) | cyan |
| `main*` | Git branch — `*` means dirty working tree | blue / yellow `*` |
| `███░░ 64%` | Context-window usage (green → yellow → red) | by threshold |
| `idle (3 cmds)` | Activity status + shell command count | green |

Notifications look like:

- **cursor-pulse** (title = project folder) — **Cursor is waiting for your input**
  when a turn ends (`stop`, status `completed`).
- **Cursor stopped** / **Cursor hit an error** for aborted/error stops.
- Optional: **Cursor session ended** (`sessionEnd`) or **ran: `<cmd>`**
  (`afterShellExecution`).

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

The installer:

- copies scripts to `~/.cursor/cursor-pulse/`, and
- **merges** hook entries into `~/.cursor/hooks.json` without clobbering your
  existing hooks. Re-running is idempotent.

Hooks are registered only on **observe-only events** (`stop`, `sessionStart`,
`sessionEnd`, `afterShellExecution`, `preCompact`) — never on permission-gating
events like `beforeShellExecution`.

Then start a **`cursor-agent` session** so hooks can capture state. The first
time a hook runs, Cursor may ask you to trust it.

The installer also adds a `cursor-pulse` command (symlinked onto your `PATH`):

```sh
cursor-pulse status     # render the status line on demand
cursor-pulse test       # fire a test notification
cursor-pulse doctor     # check install health
cursor-pulse update     # re-install the latest version from GitHub
cursor-pulse uninstall  # remove cursor-pulse
cursor-pulse version
```

### Updating

```sh
cursor-pulse update
```

cursor-pulse doesn't auto-update — your installed copy is frozen at install
time. `cursor-pulse update` re-fetches the latest from GitHub and reinstalls in
place (idempotent; your config survives). If the command isn't on your
`PATH`, re-run the `curl … | sh` one-liner.

### Manual install

Copy the scripts wherever you like and merge the block from
[`hooks.example.json`](hooks.example.json) into `~/.cursor/hooks.json` (use
**absolute paths** for the `command` field):

```sh
mkdir -p ~/.cursor/cursor-pulse
cp statusline.sh hooks/notify.sh uninstall.sh cursor-pulse ~/.cursor/cursor-pulse/
chmod +x ~/.cursor/cursor-pulse/*.sh ~/.cursor/cursor-pulse/cursor-pulse
```

## Configuration

Set these as environment variables, or — easier — edit
`~/.cursor/cursor-pulse/config.sh`, which the scripts source on every run and
which **survives `cursor-pulse update`**. The installer drops a commented
template there. Example:

```sh
# ~/.cursor/cursor-pulse/config.sh
CURSOR_PULSE_NERD=1        # use Nerd Font icons
CURSOR_PULSE_BAR_WIDTH=12  # a slightly longer bar
```

### Status line (`statusline.sh` / `cursor-pulse status`)

| Variable | Default | Effect |
| --- | --- | --- |
| `CURSOR_PULSE_NERD` | `0` | Set to `1` to use [Nerd Font](https://www.nerdfonts.com/) glyphs. Off uses plain text. |
| `CURSOR_PULSE_BAR_WIDTH` | `10` | Width of the context bar, in cells. |
| `CURSOR_PULSE_HIDE` | _(none)_ | Comma list of segments to hide: `model`, `dir`, `branch`, `context`, `activity`. |
| `NO_COLOR` | _(unset)_ | Standard [`NO_COLOR`](https://no-color.org/) — disables all ANSI color. |
| `CURSOR_CONFIG_DIR` | `~/.cursor` | Override Cursor's config directory. |

Context percentage comes from the `preCompact` hook payload (`context_usage_percent`).
If no compaction has occurred yet, the context segment is omitted.

**Shell prompt example** (bash/zsh):

```sh
# Add to your .bashrc or .zshrc after installing cursor-pulse:
PS1='$(cursor-pulse status 2>/dev/null)\n'"$PS1"
```

### Notifications (`notify.sh`)

| Variable | Default | Effect |
| --- | --- | --- |
| `CURSOR_PULSE_NOTIFY` | `auto` | Backend: `auto`, `terminal-notifier`, `alerter`, `notify-send`, `osa`, `osc9`, `bell`, `off`. |
| `CURSOR_PULSE_NOTIFY_ON_STOP` | `1` | Notify when a turn ends (`stop`). |
| `CURSOR_PULSE_NOTIFY_ON_SESSION_END` | `0` | Notify on `sessionEnd`. |
| `CURSOR_PULSE_NOTIFY_ON_SHELL` | `0` | Notify after each shell command (`afterShellExecution`). |
| `CURSOR_PULSE_NOTIFY_TITLE` | folder name | Override the notification title. |
| `CURSOR_PULSE_NOTIFY_ICON` | _(none)_ | PNG path for `notify-send` / plain `terminal-notifier`. |

`auto` tries, in order: `terminal-notifier` → `alerter` → `notify-send`
(Linux) → `osascript` (macOS) → terminal bell / OSC-9 escape.

**About the icon (the Cursor logo).** On macOS the installer builds a small
Cursor-branded notifier — `CursorPulse.app`, a rebranded copy of
`terminal-notifier` carrying the icon from your local Cursor.app — so alerts
show the Cursor logo. This needs `terminal-notifier` and `codesign` (Xcode
Command Line Tools). If it can't be built, it falls back to the plain notifier.

On macOS install `terminal-notifier` for the best experience:

```sh
brew install terminal-notifier
```

## Test

Status line — after a hook has captured state:

```sh
echo '{"hook_event_name":"stop","status":"completed","workspace_roots":["'"$PWD"'"],"conversation_id":"test","model":"composer-2","cwd":"'"$PWD"'"}' \
  | ./hooks/notify.sh
./statusline.sh </dev/null
```

Notification hook:

```sh
echo '{"hook_event_name":"stop","status":"completed","workspace_roots":["'"$PWD"'"],"conversation_id":"test","model":"test","cwd":"'"$PWD"'"}' \
  | ./hooks/notify.sh   # title=folder, "Cursor is waiting for your input"

CURSOR_PULSE_NOTIFY_ON_SHELL=1 \
  echo '{"hook_event_name":"afterShellExecution","command":"echo hello","workspace_roots":["'"$PWD"'"],"conversation_id":"test","model":"test","cwd":"'"$PWD"'"}' \
  | ./hooks/notify.sh   # title=folder, "ran: echo hello"
```

Or use the CLI:

```sh
cursor-pulse test stop
cursor-pulse test shell
cursor-pulse status
cursor-pulse doctor
```

Real cursor-agent test — paste into a session:

```text
Run `sleep 8; echo cursor-pulse notification test complete` and then stop.
```

Switch away while it sleeps. The notification's title is the project folder and
the message is **Cursor is waiting for your input**.

## Uninstall

```sh
cursor-pulse uninstall
# or
~/.cursor/cursor-pulse/uninstall.sh
```

Removes `~/.cursor/cursor-pulse/`, strips cursor-pulse hook entries from
`~/.cursor/hooks.json`, and removes the CLI symlink. Your other hooks are left
intact.

## Notes

- Hooks are not supported on Windows shells; the notifier exits quietly there.
- Hook scripts must keep **stdout clean** — Cursor parses JSON on stdout. Bell
  and OSC-9 escapes go to `/dev/tty`.
- Everything degrades gracefully: missing fields, no state file, no `jq`, or no
  `git` just drop the affected segment rather than erroring.
- `sessionStart` / `sessionEnd` / `stop` require a recent `cursor-agent`
  version; older CLIs may only deliver shell events.
- Status-line design modeled on
  [agy-statusline](https://codeberg.org/jochenkirstaetter/agy-statusline) and
  [claude-pulse](https://github.com/martinoyovo/claude-pulse), adapted for
  Cursor's hook payload and on-demand rendering.

## License

MIT, copyright 2026 Martino Yovo. See [LICENSE](LICENSE).
