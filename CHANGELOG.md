# Changelog

All notable changes to Pookify Copilot are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

- Clicking a session row activates the terminal or IDE application that owns the corresponding
  Copilot process without pinning the closed bar to that session.
- The closed multi-session island shows a green ready-session count whenever one or more sessions
  have completed.
- Snapshots are deduplicated by Copilot process and delayed older hook events are ignored, keeping
  stale completed sessions from overriding current work.
- Completed sessions now keep the ready-count bar visible after all active work finishes. The bar
  clears when those Copilot sessions close or begin another turn.
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
