import AppKit

/// The menu bar icon: what Jarvis is doing, and the few controls he needs.
@MainActor
final class StatusMenu: NSObject {
    private var item: NSStatusItem?
    private let titleItem = NSMenuItem(title: "Jarvis", action: nil, keyEquivalent: "")
    private let detailItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let tasksItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let talkItem = NSMenuItem(title: "Talk to Jarvis", action: #selector(AppController.menuTalk), keyEquivalent: "j")
    private let stopItem = NSMenuItem(title: "Stop Speaking", action: #selector(AppController.menuStop), keyEquivalent: "")
    private let muteItem = NSMenuItem(title: "Mute Microphone", action: #selector(AppController.menuMute), keyEquivalent: "")
    private let permissionItem = NSMenuItem(title: "Open Microphone Settings…", action: #selector(AppController.menuPermissions), keyEquivalent: "")
    private let interfaceItem = NSMenuItem(title: "Open JARVIS Interface", action: #selector(AppController.menuInterface), keyEquivalent: "")
    private let settingsItem = NSMenuItem(title: "Edit Settings…", action: #selector(AppController.menuSettings), keyEquivalent: "")
    private let reloadItem = NSMenuItem(title: "Reload Settings", action: #selector(AppController.menuReload), keyEquivalent: "")
    private let logsItem = NSMenuItem(title: "Show Logs", action: #selector(AppController.menuLogs), keyEquivalent: "")
    private let quitItem = NSMenuItem(title: "Quit Jarvis Voice", action: #selector(AppController.menuQuit), keyEquivalent: "")

    func install(target: AppController) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.autoenablesItems = false
        titleItem.isEnabled = false
        detailItem.isEnabled = false
        tasksItem.isEnabled = false
        tasksItem.isHidden = true
        talkItem.keyEquivalentModifierMask = [.command, .option]
        for entry in [talkItem, stopItem, muteItem, permissionItem, interfaceItem, settingsItem, reloadItem, logsItem, quitItem] {
            entry.target = target
        }
        menu.addItem(titleItem)
        menu.addItem(detailItem)
        menu.addItem(tasksItem)
        menu.addItem(.separator())
        menu.addItem(talkItem)
        menu.addItem(stopItem)
        menu.addItem(muteItem)
        menu.addItem(permissionItem)
        menu.addItem(.separator())
        menu.addItem(interfaceItem)
        menu.addItem(settingsItem)
        menu.addItem(reloadItem)
        menu.addItem(logsItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)
        item.menu = menu
        self.item = item
    }

    func update(state: AppController.State, detail: String, muted: Bool) {
        let (symbol, label): (String, String) = switch state {
        case .starting: ("hourglass", "Starting")
        case .downloading: ("arrow.down.circle", "Downloading speech model")
        case .permission: ("exclamationmark.triangle", "Needs permission")
        case .idle: ("waveform", "Ready")
        case .listening: ("mic.fill", "Listening")
        case .followUp: ("mic", "Listening")
        case .thinking: ("ellipsis.circle", "Thinking")
        case .speaking: ("speaker.wave.2.fill", "Speaking")
        case .confirming: ("questionmark.circle", "Waiting for your answer")
        case .looking: ("eye.circle.fill", "Camera or screen in use")
        case .muted: ("mic.slash", "Muted")
        case .failed: ("exclamationmark.triangle", "Problem")
        }
        if let button = item?.button {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Jarvis: \(label)")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "Jarvis — \(label)"
        }
        titleItem.title = "Jarvis — \(label)"
        detailItem.title = detail
        detailItem.isHidden = detail.isEmpty
        muteItem.title = muted ? "Unmute Microphone" : "Mute Microphone"
        stopItem.isEnabled = state == .speaking || state == .thinking || state == .confirming
        talkItem.isEnabled = !(state == .permission || state == .starting || state == .downloading)
        permissionItem.isHidden = state != .permission
    }

    /// "2 tasks running: opening Chess; what's the weather" — empty hides the line.
    func updateTasks(_ summary: String) {
        tasksItem.title = summary
        tasksItem.isHidden = summary.isEmpty
        if let button = item?.button {
            let base = (button.toolTip ?? "Jarvis").components(separatedBy: " · ").first ?? "Jarvis"
            button.toolTip = summary.isEmpty ? base : "\(base) · \(summary)"
        }
    }
}
