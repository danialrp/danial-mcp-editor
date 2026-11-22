import AppKit

// Danial MCP Editor, the app: one window with the player and the timeline,
// and the MCP server running inside, so agents and the owner edit the same
// open project at the same time.

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
