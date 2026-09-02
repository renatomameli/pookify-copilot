# Demo and UI testing

The demo harness writes fake Copilot session snapshots to an isolated support directory and starts
the debug app with hook installation disabled. It does not touch `~/.copilot` or real session
state.

```bash
./scripts/demo.sh help
./scripts/demo.sh editing
./scripts/demo.sh multi 6
./scripts/demo.sh story
./scripts/demo.sh stop
```

The first command builds automatically when needed. Always use `stop` after testing to remove the
demo process and its isolated files.

## Activities

| Command | Display |
|---|---|
| `thinking` | Thinking |
| `reading` | Reading with a file name |
| `searching` | Searching source |
| `running` | Running command |
| `editing` | Editing with a file name |
| `writing` | Writing with a file name |
| `websearch` | Searching web |
| `webfetch` | Browsing web |
| `planning` | Planning |
| `delegating` | Delegating |
| `mcp` | Using MCP tool |
| `asking` | Asking a question |
| `compacting` | Compacting |
| `working` | Unknown/custom tool fallback |
| `permission` | Awaiting permission |
| `input` | Input requested |
| `done` | Completed turn |
| `error` | Failed turn |

For example:

```bash
./scripts/demo.sh permission
EXPAND=1 ./scripts/demo.sh editing
SHADE=0.06 ./scripts/demo.sh running
```

`EXPAND=1` keeps the activity label visible. `SHADE` accepts a grayscale value from `0` to `1`
or a `#RRGGBB` color.

## Sequences

```bash
./scripts/demo.sh story   # think -> read -> edit -> permission -> command -> done
./scripts/demo.sh finish  # repeat working -> done -> retract
./scripts/demo.sh cycle   # cycle through every activity
./scripts/demo.sh blink   # repeat emerge -> retract
```

These looping commands can be stopped with <kbd>Ctrl</kbd>+<kbd>C</kbd> or from another terminal:

```bash
./scripts/demo.sh stop
```

## Multiple sessions

```bash
./scripts/demo.sh multi       # four sessions
./scripts/demo.sh multi 10    # ten rows without scrolling
./scripts/demo.sh multi 12    # scrollable stack after the tenth row
```

Up to ten sessions are shown without scrolling. Permission requests sort above active work, then
newer turns sort above older ones. Click a row to
focus its terminal; the closed bar keeps following automatic urgency ordering. Demo sessions use
synthetic processes, so terminal focusing is intended for real Copilot sessions.

## Hook-to-state mapping

| Copilot event | State |
|---|---|
| `sessionStart` | Idle session marker |
| `userPromptSubmitted` | Thinking |
| `preToolUse` | Tool-specific activity |
| `postToolUse` / `postToolUseFailure` | Brief tool linger, then thinking |
| `subagentStart` / `subagentStop` | Delegating, then thinking |
| `preCompact` | Compacting |
| `notification(permission_prompt)` | Awaiting permission |
| `notification(elicitation_dialog)` | Input requested |
| `agentStop` | Done |
| non-recoverable `errorOccurred` | Error |
| `sessionEnd` | Remove session |
