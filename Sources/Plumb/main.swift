import AppKit

let arguments = CommandLine.arguments

// Helper modes run without UI and never open the data files themselves;
// they talk to the running app through the control socket.
if arguments.contains("--mcp") {
    MCPServer.runStdio()
}
if let i = arguments.firstIndex(of: "--cli") {
    CLI.run(Array(arguments[(i + 1)...]))
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    if let i = arguments.firstIndex(of: "--render-snapshots"), i + 1 < arguments.count {
        app.setActivationPolicy(.accessory)
        Snapshots.render(to: URL(fileURLWithPath: arguments[i + 1]))
        exit(0)
    }
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
