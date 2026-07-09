<div align="center">

<img src="docs/demo.gif" alt="Pookify — the Claude Code dynamic island, live on the MacBook notch" width="760">

<img src="docs/multi-sessions.gif" alt="Multiple Claude Code sessions — the closed bar shows a session count, and hovering opens the session stack" width="760">

# Pookify 🐼

The Claude Code dynamic Island for your MacBook.

</div>


## Install

**1. Clone the repo**

```bash
git clone https://github.com/eyadhammouda/pookify
cd pookify
```

**2. Build and install**

```bash
./scripts/install.sh
```

This adds Pookify to your Applications and sets up Claude Code. Start a session and the island shows up on your notch.

> On MacBooks without a notch, Pookify draws its own. The island looks and works the same.

> **Build trouble?** Make sure Xcode's Command Line Tools are installed first: `xcode-select --install`

## Claude icons

Right-click the island to switch between **Clawd** (the crab, default) and the **Spark**.

<a href="docs/change-icon.gif"><img src="docs/change-icon-poster.png" alt="Switching the Claude icon from the island's right-click menu — click to play" width="640"></a>


## Multiple sessions

Run as many Claude Code sessions as you want. The closed island always shows what needs your attention most. If multiple sessions are running, you'll see a small count badge. If any session is waiting for your permission, the island shows an amber dot instead, with blocked sessions always taking priority.

## Where it works

- ✅ Claude Code in the terminal
- ✅ Claude Code in the VS Code extension
- ✅ Several sessions at once, across both

## Update

```bash
cd pookify
git pull
./scripts/install.sh
```

Same command as installing — it rebuilds, replaces the app, and refreshes the hooks. If the island is on screen at that moment, right-click it → Quit once; the new version takes over from the next session.

## Uninstall

```bash
./scripts/uninstall.sh
```

Removes the app and its hooks. Your config backup (`settings.json.bak-pookify`) stays in place.

## How it works

Claude Code runs a hook each time something happens (a tool starts, a tool finishes, a turn ends, a prompt needs approval). A small compiled helper, `island-hook`, writes that session's status to a JSON file under `~/Library/Application Support/Pookify/state.d/` — one file per session. The app checks that folder a few times a second, sorts the live sessions by urgency, and draws the notch: the most urgent session on the closed bar, all of them in the expanded stack.

The installer adds its hooks to `~/.claude/settings.json`, backs the file up first, and leaves your other hooks and settings alone.

To preview every state without running an agent, see [DEMO.md](DEMO.md).


## Limitations

- On a notched Mac (14-inch or 16-inch MacBook Pro, or a notched MacBook Air) the island fuses with the hardware notch. On Macs without one, Pookify draws a notch of the same proportions at the top of the screen, so the experience is the same.
- With more than one display connected, Pookify shows on the notched screen (or the main one). To move it elsewhere, right-click the island → **Display** and pick a screen; **Automatic** restores the default. The choice is remembered.
- Building from source needs Xcode's Command Line Tools (`xcode-select --install`).

## Privacy

Pookify runs entirely on your Mac. It makes no network calls and collects no analytics. See [PRIVACY.md](PRIVACY.md).

## Trademark and affiliation

Pookify is an independent, unofficial, open-source project. It is not affiliated with, endorsed by, or sponsored by Anthropic or Apple.

Product names and logos belong to their owners and are used here only to say what Pookify works with:

- "Claude", "Claude Code", and the Claude spark logo are trademarks of Anthropic, PBC.
- "Dynamic Island", "MacBook", and "macOS" are trademarks of Apple Inc. Pookify is a notch status display in the style of the Dynamic Island; it is not Apple's product.

The MIT license covers Pookify's source code only and grants no rights to any third-party trademark, logo, or brand. See [TRADEMARKS.md](TRADEMARKS.md). Bundled third-party material (the claude-status-bar artwork under MIT) is credited in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), which also ships inside the app. If you are a rights holder and want a mark removed, open an issue and it will be handled promptly. This is a free, non-commercial project.

## License

MIT. See [LICENSE](LICENSE).
