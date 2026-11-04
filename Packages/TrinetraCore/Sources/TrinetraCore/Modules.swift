import Foundation

/// Optional toolkit modules (architecture/TOOLKIT.md). Every module is off until the user turns it
/// on, so the keep-awake core stays as light as before and a module that is off costs nothing:
/// no timers, no permissions, no observers.
public enum Module: String, Codable, CaseIterable, Sendable {
    // Phase 1: Mac health
    case systemMonitor = "system-monitor"
    case healthAlerts = "health-alerts"
    // Phase 2: files and clipboard
    case finderCut = "finder-cut"
    case quitOnClose = "quit-on-close"
    case quitProtection = "quit-protection"
    case clipboardHistory = "clipboard-history"
    // Phase 3: windows and Dock
    case windowSnapping = "window-snapping"
    case windowSwitcher = "window-switcher"
    case dockPreviews = "dock-previews"
    // Phase 4: sound
    case volumeMixer = "volume-mixer"
    case audioRouting = "audio-routing"
    case micMute = "mic-mute"
    // Phase 5: everyday tools
    case commandBar = "command-bar"
    case snippets = "snippets"
    case quickToggles = "quick-toggles"
    case colorPicker = "color-picker"
    case textRecognition = "text-recognition"
    // Phase 6: capture
    case screenshots = "screenshots"
    case screenRecording = "screen-recording"
    // Phase 7: maintenance
    case cleaner = "cleaner"
    case uninstaller = "uninstaller"
    case appUpdates = "app-updates"
    case homebrew = "homebrew"
    case speedTest = "speed-test"
    // Phase 8: hardware
    case fanControl = "fan-control"
    case displayBrightness = "display-brightness"
    case bluetoothSleep = "bluetooth-sleep"

    public var title: String {
        switch self {
        case .systemMonitor: return "System monitor"
        case .healthAlerts: return "Health alerts"
        case .finderCut: return "Cut and paste files in Finder"
        case .quitOnClose: return "Quit on close"
        case .quitProtection: return "⌘Q and ⌘W protection"
        case .clipboardHistory: return "Clipboard history"
        case .windowSnapping: return "Window snapping"
        case .windowSwitcher: return "Window switcher"
        case .dockPreviews: return "Dock previews"
        case .volumeMixer: return "Volume mixer"
        case .audioRouting: return "Per-app audio output"
        case .micMute: return "Microphone mute"
        case .commandBar: return "Command bar"
        case .snippets: return "Text snippets"
        case .quickToggles: return "Quick toggles"
        case .colorPicker: return "Colour picker"
        case .textRecognition: return "Copy text from screen"
        case .screenshots: return "Screenshots"
        case .screenRecording: return "Screen recording"
        case .cleaner: return "Cleaner"
        case .uninstaller: return "Uninstaller"
        case .appUpdates: return "App updates"
        case .homebrew: return "Homebrew"
        case .speedTest: return "Internet speed test"
        case .fanControl: return "Fan control"
        case .displayBrightness: return "Display brightness"
        case .bluetoothSleep: return "Bluetooth off during sleep"
        }
    }

    public var summary: String {
        switch self {
        case .systemMonitor: return "CPU, GPU, memory, temperature, battery, power and network, with the CPU each agent uses"
        case .healthAlerts: return "A notification when the Mac runs hot, memory or disk run short, or battery gets low"
        case .finderCut: return "⌘X then ⌘V moves files in Finder"
        case .quitOnClose: return "Closing an app's last window quits it, for the apps you choose"
        case .quitProtection: return "Hold ⌘Q or ⌘W to quit or close, so a slip doesn't lose work"
        case .clipboardHistory: return "Search, pin and paste what you copied, or paste as plain text"
        case .windowSnapping: return "Halves, thirds, quarters and centre, from shortcuts or screen edges"
        case .windowSwitcher: return "Switch between windows, not just apps"
        case .dockPreviews: return "Window thumbnails when you hover a Dock icon"
        case .volumeMixer: return "A volume slider for each app"
        case .audioRouting: return "Send each app's sound to a different output"
        case .micMute: return "One shortcut mutes the microphone everywhere"
        case .commandBar: return "Launch apps, calculate, convert and search files from one bar"
        case .snippets: return "Type a short code, get the full text"
        case .quickToggles: return "Dark mode, hidden files, eject, empty Trash and more"
        case .colorPicker: return "Pick any colour on screen as HEX, RGB or HSL"
        case .textRecognition: return "Select part of the screen and copy its text, offline"
        case .screenshots: return "Area, window and full-screen captures with a quick editor"
        case .screenRecording: return "Record the screen with system and microphone sound"
        case .cleaner: return "Find caches, logs and leftovers taking space"
        case .uninstaller: return "Remove an app and the files it left behind"
        case .appUpdates: return "See which apps have updates"
        case .homebrew: return "Update and clean up Homebrew packages"
        case .speedTest: return "Measure download and upload speed"
        case .fanControl: return "Set fan speeds or a temperature curve"
        case .displayBrightness: return "Brightness for each display, including external ones"
        case .bluetoothSleep: return "Turn Bluetooth off while the Mac sleeps, back on when it wakes"
        }
    }

    /// Build phase in architecture/TOOLKIT.md.
    public var phase: Int {
        switch self {
        case .systemMonitor, .healthAlerts: return 1
        case .finderCut, .quitOnClose, .quitProtection, .clipboardHistory: return 2
        case .windowSnapping, .windowSwitcher, .dockPreviews: return 3
        case .volumeMixer, .audioRouting, .micMute: return 4
        case .commandBar, .snippets, .quickToggles, .colorPicker, .textRecognition: return 5
        case .screenshots, .screenRecording: return 6
        case .cleaner, .uninstaller, .appUpdates, .homebrew, .speedTest: return 7
        case .fanControl, .displayBrightness, .bluetoothSleep: return 8
        }
    }

    /// Built and usable in this version. Later phases are listed so the roadmap is visible.
    public var isAvailable: Bool { phase <= Module.builtThroughPhase }

    public static let builtThroughPhase = 1

    public var group: String {
        switch phase {
        case 1: return "Mac health"
        case 2: return "Files and clipboard"
        case 3: return "Windows and Dock"
        case 4: return "Sound"
        case 5: return "Everyday tools"
        case 6: return "Capture"
        case 7: return "Maintenance"
        default: return "Hardware"
        }
    }

    /// Modules that need another module on to do anything.
    public var requires: [Module] {
        switch self {
        case .healthAlerts: return [.systemMonitor]
        default: return []
        }
    }
}

/// The set of modules the user turned on. Unknown names (from a newer version) are kept on save.
public struct ModuleSet: Codable, Equatable, Sendable {
    public private(set) var names: [String]

    public init(_ modules: [Module] = []) { names = modules.map(\.rawValue) }

    public init(from decoder: Decoder) throws {
        names = try decoder.singleValueContainer().decode([String].self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(names)
    }

    /// On and usable: turned on, built, and everything it needs is on too.
    public func isOn(_ module: Module) -> Bool {
        module.isAvailable && names.contains(module.rawValue) && module.requires.allSatisfy { isOn($0) }
    }

    /// Turning a module on also turns on what it needs; turning one off also turns off what needs it.
    public mutating func set(_ module: Module, on: Bool) {
        if on {
            for dep in module.requires { set(dep, on: true) }
            if !names.contains(module.rawValue) { names.append(module.rawValue) }
        } else {
            names.removeAll { $0 == module.rawValue }
            for other in Module.allCases where other.requires.contains(module) { set(other, on: false) }
        }
    }
}
