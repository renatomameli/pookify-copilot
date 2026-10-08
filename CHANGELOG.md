# Changelog

All notable changes to Pookify Copilot are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

- Added an optional **F1 Pit Wall** style: a carbon-fibre timing tower with positions, team
  stripes, sector lights, BOX BOX permission calls, chequered flags, and start lights.
- Added an optional **Slot Machine** style (right-click → Style): casino cabinet with gold reels,
  marquee bulbs, a winning line, JACKPOT results, and a pull lever that spins the reels.
- Replaced SwiftUI `@State` with a `@StateObject` box so the app builds with Command Line Tools 27,
  which expand `@State` as a macro without shipping the SwiftUI macro plugin.
- Demo sessions no longer pick up real Copilot processes.
- Hover is now tracked by the AppKit pointer router instead of SwiftUI `onHover`, restoring the
  hover-to-expand animation and adding row hover highlights (slot rows lift and glow).

- Clicking a session row activates the terminal or IDE application that owns the corresponding
  Copilot process without pinning the closed bar to that session.
- The closed multi-session island shows a green ready-session count whenever one or more sessions
  have completed.
- Snapshots are deduplicated by Copilot process and delayed older hook events are ignored, keeping
  stale completed sessions from overriding current work.
- Completed sessions now keep the ready-count bar visible after all active work finishes. The bar
  clears when those Copilot sessions close or begin another turn.
- With one session remaining, clicking anywhere on the island opens its terminal and collapses
  the panel as visual confirmation. Hover stays suppressed until the pointer exits, so this
  feedback remains visible even when the target terminal was already frontmost.
- Open Copilot sessions now remain in the stack as **Idle** between turns instead of disappearing,
  so two open terminals always produce two selectable session entries.
- Transparent panel areas now use window-level mouse pass-through, preventing the enlarged
  ten-session host panel from blocking clicks in fullscreen applications.
- The top bar, multi-session rows, and single-session status now have independent click targets
  rather than competing through an ancestor island gesture.
- Session clicks are dispatched from AppKit using the visible row geometry, avoiding unreliable
  SwiftUI actions in a nonactivating panel.
- Installation now blocks hook-driven relaunches, terminates the previous process, and starts a
  fresh app instance so upgrades cannot leave an old binary running in memory.
- Live Copilot sessions no longer disappear after two hours without a hook event; only stale
  snapshots without a live process identity are age-reaped.
- Missing hook snapshots are reconstructed from live interactive Copilot CLI processes as Idle,
  so every open terminal remains visible and selectable.
- Process fallback accepts official GitHub Copilot npm and Homebrew install paths only.
- The green collapsed badge now shows `ready/open` instead of only the ready count.
- Right-click now opens a native AppKit context menu through the window router, restoring reliable
  Display and Quit actions in the nonactivating overlay.
- The expanded session stack now shows ten complete rows before scrolling instead of three.

## [0.1.0]

- Ported the Pookify notch interface to GitHub Copilot CLI's native hook events.
- Added thinking, tool, subagent, compaction, permission, input-request, completion, and error
  states with multi-session urgency ordering.
- Added an isolated bundle ID, app/support paths, executable, and owned user-level Copilot hook
  file so the app can coexist with upstream Pookify.
- Made `preToolUse` reporting fail open so helper failures cannot deny Copilot tools.
- Replaced Claude artwork and icon selection with a dependency-free SwiftUI robot glyph.
- Preserved local-only operation with no network calls or analytics.
