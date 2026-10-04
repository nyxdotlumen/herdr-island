# Verification

Verified on macOS 26.6.2 using Apple Command Line Tools; no user Herdr server was modified during testing.

## Automated checks

`./scripts/test.sh` runs the core Swift check executable and the four native mouse/scroll checks. It covers attention lifecycle and deduplication, stale identity checks, socket fragmentation/errors, native terminal key passthrough, clipboard routing, prefix/help isolation, streamed ANSI frame decoding, raw byte preservation, and monitor geometry/selection.

Monitor cases include a screen to the left, a screen above, a window spanning displays, missing window metadata, primary-display preference, and removal of a secondary screen. The native placement report also selected the connected external display at (-2560, 0), size 2560 × 1440, using its top-center edge. Physical hot-plug, multiple Spaces, and full-screen apps have not been exhaustively exercised.

## Home page

Home uses the full `agent.list` result independently of the attention inbox, including working, idle, dismissed, and snoozed agents. Rows show name, project, and status; selecting a row opens its terminal. Returning Home dismantles the active terminal. Keyboard checks cover Home navigation, Return, Escape, the home shortcut, and preserving terminal key passthrough. The native `--snapshot … --home-view` preview was inspected with blocked, done, working, and idle demo agents.

## Mouse and scrolling regression checks

The live view now uses `herdr terminal attach` in a PTY. The prior JSON stream omitted application mouse modes and accepted raw mouse bytes even when reporting was disabled.

- `swift run --disable-sandbox --cache-path .build/cache NativeInputChecks`: four AppKit checks pass for fractional trackpad accumulation, line-height scaling, immediate mouse-wheel reporting, and click press/release.
- `python3 scripts/test-herdr-attach.py`: an isolated server verifies click and wheel coordinates reach a mouse-enabled alternate-screen application, clicks are discarded when mouse reporting is disabled, double Ctrl+B delivers one literal prefix, and a fresh controller can attach after the client exits.
- `./scripts/test.sh`: 48 checks pass, including explicit socket/environment isolation and prefix escaping.

These are fixture checks, not tests against the user's live Codex or Claude Code sessions.

## Earlier native end-to-end checks (JSON stream)

A disposable Herdr server was started with its own temporary config and socket. It ran one shell and a small terminal fixture, reported as a test agent. No existing panes, agents, configuration, or server processes were changed.

The installed official `herdr terminal session control` command was verified to emit `terminal.frame` records with base64 ANSI data and accept `terminal.input`, `terminal.resize`, `terminal.scroll`, and `terminal.release`. A live fixture rendered inside SwiftTerm at 83 columns × 25 rows.

Using native UI automation:

- Opened the terminal with the global shortcut and received streaming output.
- Used Down then Return to select the fixture's second option.
- Typed “keyboard input works” and submitted it; the live terminal displayed the exact received text.
- Pasted test text; the fixture's input log confirmed the exact bytes. The automation's clipboard-read acknowledgement timed out even though delivery succeeded, so paste was checked at the receiving fixture as well.
- Sent Tab, Escape, and Ctrl+C directly to the fixture.
- Resume dismissal regression checks cover blocked/done/idle → working, done/blocked → seen/idle with an unchanged sequence, preservation of waiting prompts, identity replacement, and retaining other waiting agents. The island closes on confirmed work or cleared attention.
- Opened Settings using Ctrl+B, s and Cmd+comma. The island retracted, Settings was the foreground window, and Tab selected the socket field.
- Closed Settings with Escape, reopened, and closed the island with Ctrl+B, q.
- Attached a fresh official controller after closing to confirm ownership was released and the pane continued running.
- Verified Ctrl+B shortcuts with Hebrew input active. Physical shortcut keys are resolved independently of terminal text input.

The compact, expanded, completion, and keyboard-reference snapshots are rendered from the actual AppKit/SwiftUI views. `--snapshot` forces demo mode. The demo shares the native terminal renderer but simulates an agent locally.

## Packaging

`./scripts/build-app.sh` builds the release executable, includes SwiftTerm's resource bundle and license under Contents/Resources, and ad-hoc signs the app. The terminal library is pinned to 1.20.0 in Package.resolved.

## Remaining scope

One local server is supported. This build does not aggregate servers or attach over SSH. Native terminal behavior was tested with an isolated fixture rather than sending input to the user's real agents. An attachment controls the terminal size while open and respects existing direct controllers; it never silently takes over.

## New agent form

The native form preview was inspected. Mock Unix-socket checks verify structured directory passing, focus preservation, starting in the returned pane, and no startup retries. Startup requests allow the server’s 30-second readiness window. No paid Claude/Codex agent was launched during verification.

The new-agent form now uses a custom in-panel agent toggle and asynchronous folder browser, with Tab focus zones, arrow navigation, Return to descend, and Cmd+Up to ascend. The native preview was inspected. Folder tests cover partial paths, natural ordering, spaces, file/hidden-folder exclusion, empty folders, and unreadable paths.

## All panes

Home merges pane.list with matching agent.list entries to retain agent names and include shells. The inventory test covers a named shell, a working agent, and pane.get decoding. Attach validation and view identity use the terminal ID so agent detection changes do not detach the terminal. Terminal creation skips agent.start.
