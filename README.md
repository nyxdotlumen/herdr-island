# Herdr Island

A small native terminal at the top of your display. Herdr agents surface when they need input or finish a run. Open the island to interact directly with the agent’s terminal.

## Run

Requires macOS 14+, Apple Command Line Tools with Swift 6+, and a local Herdr installation that supports `herdr terminal attach` (verified with the installed protocol 22 client/server).

```sh
./scripts/build-app.sh
open "dist/Herdr Island.app"
```

The app lives in the menu bar. Its default socket is `~/.config/herdr/herdr.sock`. Open **Settings** with **⌘,** or **Ctrl+B, s** to change the socket or Herdr executable. The app checks `~/.local/bin/herdr`, `/opt/homebrew/bin/herdr`, and `/usr/local/bin/herdr`. Named sessions typically use `~/.config/herdr/sessions/<name>/herdr.sock`.

You can specify the connection at launch:

```sh
"dist/Herdr Island.app/Contents/MacOS/DynamicHerdr" --socket "$HOME/.config/herdr/sessions/work/herdr.sock"
```

`--socket` overrides Settings. Otherwise Settings overrides the inherited `HERDR_SOCKET_PATH`, `HERDR_SESSION`, and default config directory. `--herdr /absolute/path` overrides executable discovery.

For a disconnected demo, run `./scripts/run-demo.sh`. Quit the existing companion first with **⌘Q** or its menu-bar menu; `open` reuses a running app and does not change its mode. Demo mode never connects to Herdr.

## Keyboard

**Ctrl+Option+Space** opens or closes the island from anywhere. With no pending notifications, it opens Home: every live Herdr pane, its project, and current status. Click a pane or use ↑/↓ and Return to open its terminal. Escape closes Home. The terminal receives focus when opened. Its text entry, choices, cursor, selection, copy/paste, and control keys behave like a terminal. There is no separate reply box or send button.

On Home, **+** or **Cmd+N** opens New agent. Choose Claude, Codex, or Terminal (Cmd+1 / Cmd+2 / Cmd+3), use the inline folder browser or type a path, and start with Cmd+Return. Tab cycles agent, folder, and Start focus; ←/→ switches the focused agent toggle, ↑/↓ selects folders, Return opens one, and Cmd+↑ goes to its parent. Herdr creates a separate workspace in that folder and starts the selected installed CLI, or leaves a shell for Terminal; setup/trust prompts stay interactive in its terminal. No permissions are bypassed. Failed launches keep their workspace for inspection and are never automatically retried.

Press **Ctrl+B**, release it, then press the island action:

| Keys | Action |
| --- | --- |
| Ctrl+B, 0 or Cmd+0 | Home / all terminals |
| Ctrl+B, n / p | Next / previous terminal |
| Ctrl+B, 1–9 or Cmd+1–9 | Select a terminal |
| Ctrl+B, q | Close and return to the previous app |
| Ctrl+B, s or Cmd+, | Settings |
| Ctrl+B, ? | Keyboard reference |
| Ctrl+B, o | Open the selected pane in your external terminal |
| Ctrl+B, z / x | Snooze ten minutes / dismiss |
| Ctrl+B, r | Reconnect the selected terminal |
| Ctrl+B, m | Quiet notifications for thirty minutes |
| Ctrl+B, Ctrl+B | Send literal Ctrl+B |
| Cmd+C / Cmd+V | Copy selection / paste |
| Page Up / Page Down, wheel | Scroll through Herdr’s terminal history |

**Inside a terminal, Tab, Escape, Return, Shift+Return, Ctrl+C, and ordinary typing belong to the agent.** Their meaning is determined by the terminal application. Escape closes the keyboard reference or Settings; use Ctrl+B, q to close the island. Prefix shortcuts use physical key positions, including with Hebrew input enabled. Text entry remains native.

The selected terminal stays pinned while you respond, so another notification cannot redirect your typing. When Herdr confirms the selected agent is working again or clears its attention state to idle, the island shrinks and returns focus to your previous app. A waiting question keeps it open. Viewing a completed pane in Herdr marks it seen (done → idle), which also closes its island notification. Other waiting agents remain in the inbox. Switching agents, closing, or opening Settings releases the attached client. An agent leaving its pane disables that attachment. Failed connections show an error; Ctrl+B, r explicitly reconnects. Input is never retried automatically, and the app never takes over another direct terminal controller.

## Displays and notifications

Settings → **Open on** defaults to **Display I’m working on**. The app chooses the display containing most of the foreground app’s front window, then falls back to the pointer’s display and finally the primary display. Choose **Primary display** to keep it fixed. Window bounds are read locally; no screen image capture or recording permission is used. When macOS does not expose window bounds, the pointer fallback applies.

Each opening selects a display. An open terminal stays put while you interact with it. Display changes and wake recalculate the placement. A notched screen uses its measured camera housing; other screens use the top-center edge. Expansion and contraction use a short damped spring; Reduce Motion is respected.

Notifications appear compactly for eight seconds without taking keyboard focus or attaching a terminal client. A short Pop sound accompanies new attention/completion popups; disable Notification sound in Settings to mute it. Quiet mode and suppressed popups remain silent, as does manually opening the island. Only opening an agent terminal attaches; browsing Home does not. Settings retracts the island immediately, opens on the chosen display, and suppresses popups while visible.

To replace Herdr’s existing system notifications, change its existing config section:

```toml
[ui.toast]
delivery = "off"
```

The app never changes Herdr’s config or stops its server. Existing completions enter the inbox quietly; blocked agents surface at launch. Quiet mode, snoozes, and dismissals are in memory.

## How it works

`agent.list` polls the socket every two seconds, every half-second while expanded, and every five seconds when disconnected to maintain the attention inbox. Terminal output is **streamed**, not polled or scraped. Opening an agent starts one official Herdr client:

```text
herdr terminal attach <terminal_id>
```

The interactive client runs in a local PTY and renders in [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), a native AppKit terminal emulator. Herdr handles application mouse modes, click coordinates, and application versus host scrollback. SwiftTerm accumulates precise trackpad deltas by line height; mouse-wheel deltas retain their native line units. Hold Shift to select text locally instead of sending mouse input. Terminal size changes resize the PTY. Closing stops only the local attach client and releases its controller. There are no per-key API calls, prompt reconstruction, shell scripts, or separate composer. The client launches directly with an argument array and an explicit socket. Literal Ctrl+B is escaped through the nested client.

Attaching controls that pane’s terminal dimensions while open; closing releases them. This is Herdr’s direct terminal attachment behavior. It does not start an additional agent or shell. Another direct controller is respected: the app does not pass `--takeover`.

Current scope: one local Herdr server. Remote SSH and aggregation across servers are not implemented. The external-terminal shortcut selects the pane and activates the configured terminal app; a terminal with multiple windows may need manual window selection.

## Development

```sh
./scripts/test.sh
./scripts/build-app.sh
```

SwiftTerm 1.20.0 is pinned in SwiftPM. The build packages its resources and license, then ad-hoc signs the app. The app can be moved to Applications; set launch at login after moving it. It is a local build, not a notarized distribution.

Checks cover queue lifecycle, identity validation, physical shortcut routing, native terminal key passthrough, fragmented terminal frames, raw byte encoding, and monitor selection (including displays above/left, spanning windows, and disconnected displays). See [verification notes](docs/verification.md) for the isolated native terminal checks.

Render the actual native demo views:

```sh
"dist/Herdr Island.app/Contents/MacOS/DynamicHerdr" --snapshot /tmp/attention.png
"dist/Herdr Island.app/Contents/MacOS/DynamicHerdr" --snapshot /tmp/completion.png --completion
"dist/Herdr Island.app/Contents/MacOS/DynamicHerdr" --snapshot /tmp/compact.png --compact
"dist/Herdr Island.app/Contents/MacOS/DynamicHerdr" --snapshot /tmp/keyboard.png --help-view
```

`--snapshot` always forces demo mode. `--layout-report` prints display and notch geometry without connecting to a server.

Herdr references: [terminal session interface](https://herdr.dev/docs/cli-reference/#direct-terminal-attach), [socket API](https://herdr.dev/docs/socket-api/).

Home includes ordinary shells and panes running other commands. Starting or exiting an agent inside an open pane updates its status without replacing its terminal attachment. Only detected agents generate attention notifications.
