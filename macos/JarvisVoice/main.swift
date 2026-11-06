import AppKit

// Jarvis Voice: a menu bar app (no Dock icon, no windows) that listens for
// "Hey Jarvis" and talks to the existing JARVIS bridge. Started at login by
// ~/Library/LaunchAgents/local.jarvis.voice.plist.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let controller = AppController()
    app.delegate = controller
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(controller) {
        app.run()
    }
}
