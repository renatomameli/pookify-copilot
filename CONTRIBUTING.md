# Contributing to Pookify Copilot

## Prerequisites

- macOS 14 or later
- Swift 6 (Xcode 16+ or matching command-line tools)
- GitHub Copilot CLI 1.0.82 or newer for real hook testing

The project has no third-party runtime dependencies.

## Build and run

```bash
swift build
./scripts/build.sh
./scripts/test.sh
./scripts/demo.sh editing
./scripts/demo.sh stop
```

Use `./scripts/install.sh` only when you want to copy the app to `/Applications` and install the
user-level Copilot hook file.

## Project layout

- `Sources/IslandCore/` — shared state schema and filesystem paths.
- `Sources/island-hook/` — converts Copilot hook payloads into session snapshots.
- `Sources/Pookify/` — polling, aggregation, notch window, and SwiftUI interface.

The data flow is one-way: Copilot CLI -> helper -> local JSON snapshots -> app.

## Style and safety

- Keep the helper fast, local, and best-effort.
- A status hook must not alter prompts, results, or permission decisions.
- Preserve the fail-open wrapper on `preToolUse`.
- Keep UI work on `@MainActor` and filesystem polling off the main thread.
- Update README, DEMO, and CHANGELOG when behavior changes.

Before opening a pull request, run:

```bash
swift build
./scripts/build.sh
./scripts/test.sh
```
