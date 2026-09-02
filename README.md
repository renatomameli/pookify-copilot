<div align="center">

# Pookify Copilot

The GitHub Copilot CLI dynamic island for your MacBook.

</div>

Pookify Copilot is an unofficial macOS notch app that shows what local Copilot CLI sessions
are doing: thinking, reading, editing, running commands, delegating, waiting for permission,
requesting input, finishing, or failing. Multiple sessions are sorted by urgency in an expandable
stack.

## Requirements

- macOS 14 or later
- Apple Silicon by default (`UNIVERSAL=1` also builds for Intel)
- Swift 6 / Xcode Command Line Tools
- GitHub Copilot CLI with hooks support (1.0.82 or newer)

Install the command-line tools first if needed:

```bash
xcode-select --install
```

## Install

Clone, build, and install:

```bash
git clone https://github.com/renatomameli/pookify-copilot.git
cd pookify-copilot
./scripts/install.sh
```

The installer builds `/Applications/Pookify Copilot.app`, installs its helper under
`~/Library/Application Support/Pookify Copilot/bin/`, and creates the owned user hook file
`~/.copilot/hooks/pookify-copilot.json`.

Restart Copilot CLI after installation because hook configurations are loaded when the CLI
starts. The island appears when Copilot begins a turn and the app quits itself after all sessions
become idle.

> If `COPILOT_HOME` is set, the installer writes the hook below `$COPILOT_HOME/hooks/`.

## Multiple sessions

Run as many local Copilot CLI sessions as you want. The closed island shows the session needing
the most attention. Permission and input requests take priority and auto-expand once. Hover or
click the island to open the full session stack. Clicking a row brings that session's existing
terminal or IDE to the foreground while the closed bar continues following the most urgent
session. When one or more sessions finish while others are active, the closed island shows their
count in a green badge. Up to ten sessions are shown at once before the stack starts scrolling.

## Update

Pull the latest source and run the installer again:

```bash
git pull
./scripts/install.sh
```

## Uninstall

```bash
./scripts/uninstall.sh
```

This removes only Pookify Copilot's owned hook file, local state/helper files, and application.
Other Copilot settings and hooks are untouched.

## How it works

Copilot CLI invokes `island-hook` for lifecycle events such as `userPromptSubmitted`,
`preToolUse`, `postToolUse`, `agentStop`, and `sessionEnd`. The helper normalizes those events
into one small JSON file per session under:

```text
~/Library/Application Support/Pookify Copilot/state.d/
```

The app polls that directory, ranks live sessions, and renders the highest-priority state on the
closed bar. The `notification` hook is restricted to `permission_prompt` and
`elicitation_dialog`; `permissionRequest` is deliberately not used because it fires before every
permission evaluation, including requests that never block the user.

`preToolUse` command hooks normally fail closed in Copilot CLI. The generated command explicitly
ends with `|| true`, ensuring a missing or broken status helper can never deny a tool.

To preview every state without installing hooks, see [DEMO.md](DEMO.md).

## Scope and limitations

- Supports local GitHub Copilot CLI sessions. It does not install hooks into the VS Code
  extension or Copilot cloud agent.
- On a notched Mac, the island fuses with the hardware notch. Other Macs get a synthetic notch.
- With several displays, right-click the island and use **Display** to move it immediately.
  **Automatic** returns it to the built-in notched display. The choice is remembered.
- Terminal focusing follows the Copilot process to its owning macOS application. If several
  terminal windows share one application process, the application's most recent window is used.
- A turn that terminates without an `agentStop` or `sessionEnd` event is hidden by a conservative
  stale-state backstop.

## Privacy

Everything runs locally. There are no network calls, accounts, telemetry, or analytics. Prompt
text, code, tool output, and transcripts are not persisted. See [PRIVACY.md](PRIVACY.md).

## Attribution and trademarks

This project is based on [Pookify](https://github.com/eyadhammouda/pookify), used under the MIT
License. It is an independent project and is not affiliated with or endorsed by GitHub or Apple.
See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and [TRADEMARKS.md](TRADEMARKS.md).

## License

MIT. See [LICENSE](LICENSE).
