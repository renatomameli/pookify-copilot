# Privacy

Pookify Copilot is fully local and makes **no network calls**.

- No telemetry, analytics, accounts, or remote services.
- Per-session status is stored under
  `~/Library/Application Support/Pookify Copilot/state.d/` with owner-only permissions.
- Status files contain the Copilot session ID, lifecycle state, tool name, project/working
  directory, optional file basename, timestamps, and the local Copilot process ID.
- To recover open sessions whose hook snapshot is missing, the app locally inspects process names,
  executable paths, process IDs, and working directories for interactive `copilot` processes.
  Discovered fallback state is kept in memory and is not sent anywhere.
- Copilot hook payloads are handled in memory. Prompt text, code, tool arguments other than a file
  path, tool results, error details, and transcripts are not persisted.
- The installer owns only `~/.copilot/hooks/pookify-copilot.json` (or the equivalent path under
  `COPILOT_HOME`). It does not edit Copilot's settings or other hook files.

The uninstall script removes the owned hook file, helper, state, and app.
