@AGENTS.md

## Claude Code notes

- Run builds and tests through `scripts/swift.sh`, not plain `swift`.
- Light work (research, reading, testing) goes to subagents on Sonnet; set the
  model explicitly.
- To drive the editor itself from a session, connect it as an MCP server
  (`dme info` prints the command) and follow
  [docs/agent-guide.md](docs/agent-guide.md).
