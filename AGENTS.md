# Working on Danial MCP Editor

Guide for AI agents and people who change this repository. For using the
editor through MCP, read [docs/agent-guide.md](docs/agent-guide.md).

## Read first

- [docs/requirements.md](docs/requirements.md): what the editor must do. The
  single source of truth; IDs such as `N-2` point into it.
- [docs/architecture.md](docs/architecture.md): how it is built.
- [docs/mcp-tools.md](docs/mcp-tools.md): every tool, built and planned.
- [docs/roadmap.md](docs/roadmap.md): phases and their exit checks.

When a decision changes, change these documents in the same commit as the
code. They state the current design, not its history.

## Build and test

```bash
scripts/swift.sh build
```

```bash
scripts/swift.sh test
```

```bash
scripts/swift.sh build -c release --product dme && python3 scripts/e2e_recovery.py .build/release/dme <any video file>
```

- `scripts/swift.sh test` runs in two steps: every other test, then the tests
  named `timed...` alone, one at a time. A test with a wall-clock limit gets
  that name; beside the other suites it would measure the queue, not the code.
  With `--filter` or `--skip` the script runs just what was asked. Plain
  `swift test` runs all of them together and is no verdict on speed.
- `FullPropertyTests` sends every command, the read tools and the
  EditorKit write tools (not the MediaEngine ones, project and settings
  tools, or the UI), in random order with random arguments, and checks the
  project's rules, undo, the journal and a reopen after each step. `FP_STEPS=300` makes each run longer and `FP_SALT`
  (any number) tries other random sequences; run it that way after changing
  a command. On a crash, `FP_TRACE=<file prefix>` writes each seed's last
  step to `<prefix>-<seed>`. Every bug it finds also gets a plain case in
  `FoundByPropertyTests`.
- The HyperFrames render test runs only when `DME_HF_COMMAND` holds the
  HyperFrames command as a JSON array, for example
  `DME_HF_COMMAND='["npx","--yes","hyperframes"]' scripts/swift.sh test`.
- Only the Command Line Tools are needed; Xcode is optional.
  `scripts/swift.sh` adds the Swift Testing paths they need.
- Apple Silicon, macOS 26 or later.

## Layout

| Path | What lives there |
|---|---|
| `Sources/EditorCore` | Data model, time maths, commands. Pure Swift, no media frameworks |
| `Sources/EditorKit` | Command bus, journal, undo, user settings, tool catalog |
| `Sources/MediaEngine` | AVFoundation and Metal |
| `Sources/MCPServer` | MCP protocol and transports |
| `Sources/dme` | The editor without a window: runs the MCP server |
| `Sources/dme-probe` | Phase 0 measurement tool (see docs/phase0.md) |
| `Tests/` | Swift Testing suites per module |
| `Effects/` | Built-in effect plug-ins: `manifest.json` and `effect.metal` per folder |
| `Assets/` | App icon: `AppIcon.svg` is the source, `scripts/make-icon.sh` makes `AppIcon.icns` |
| `scripts/` | Build wrapper, test media generator, end-to-end test |
| `local/` | Git-ignored: test media, results, anything machine-specific |

## Rules

1. **MCP first.** A capability is a command or a catalog tool before it is a
   button. Nothing may exist only in the UI.
2. **New write capability = new command.** Add a struct conforming to
   `EditorCommand` in `Sources/EditorCore/Commands`, register it in
   `CommandRegistry.all`, and it becomes an MCP tool automatically. Its stored
   properties must be exactly its declared parameters (a test checks this).
3. **Determinism.** Anything random or time-dependent (new ids, snapped
   times) is decided in `prepare`, never in `apply`. Replaying the journal must
   give the identical project.
4. **Errors are for agents.** Throw `EditorError` with a message that says
   what to change.
5. **Values live in settings or data**, not in code: presets, cut rules,
   keymaps, effects. A new effect is a folder in `Effects/`, never Swift code.
6. **Performance targets** in architecture section 16 are tests, not hopes.
   Name such a test `timed...`; never loosen a limit to get a green run.
   Do not make a command scan the whole project when a binary search will do.
7. **Swift 6 strict concurrency** for all modules except `dme-probe`.
8. **No third-party dependencies** without a reason written into the
   architecture.
9. **Public repository.** No personal paths, account names, tokens, network
   details or footage. Machine-specific material goes in `local/` or in user
   settings outside the repository.
10. **Deleting files**: move them to the Trash (`trash`), never `rm`.

## Commits

Small, one topic each, with a message that says what changed and why. AI
co-author lines are welcome in this repository.
