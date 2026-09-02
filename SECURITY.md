# Security policy

Pookify Copilot runs locally, makes no network calls, and collects no data. Its main trust
boundaries are:

- Copilot CLI runs the compiled `island-hook` helper at lifecycle points.
- The installer creates `~/.copilot/hooks/pookify-copilot.json`.
- Session metadata is written below `~/Library/Application Support/Pookify Copilot/`.

The generated `preToolUse` command ends with `|| true`. This is required because Copilot CLI
treats a failed command hook as a denial; a status-only integration must fail open and never
control tool execution.

## Reporting a vulnerability

Report security issues privately through GitHub's private vulnerability reporting rather than a
public issue. Include the macOS version, Copilot CLI version, Pookify Copilot version, and steps to
reproduce.

## Scope notes

- State directories use mode `0700`; state and hook files use mode `0600`.
- The helper persists metadata only, never prompt text, code, tool output, error details, or
  transcripts.
- The installer refuses to overwrite a pre-existing `pookify-copilot.json` that does not carry
  its ownership marker, and saves a one-time `.bak` copy.
- Hook helper paths are single-quoted before being written into shell commands.

## Supported versions

The project is pre-1.0; only the latest release and `main` receive fixes.
