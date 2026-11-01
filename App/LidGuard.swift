import Foundation
import ServiceManagement
import TrinetraCore

/// Lid-closed mode through the privileged helper (`TrinetraHelper`, a LaunchDaemon registered with SMAppService).
///
/// The helper:
///   • runs only fixed `/usr/bin/pmset -a disablesleep 0|1` commands (no shell, no paths, no caller strings)
///   • accepts XPC calls only from Trinetra.app signed by this team
///   • restores normal sleep the moment the app disconnects (quit, crash, rebuild)
///   • restores it after 120 s without a heartbeat (dead-man switch), and on every launch/boot
/// No password per hold and no sudoers rule: the user approves the helper once in Login Items.
final class LidGuard {
    enum HelperStatus: Equatable {
        case ready
        case needsApproval
        case notRegistered
        case unavailable(String)
    }

    private let service = SMAppService.daemon(plistName: HelperConstants.daemonPlistName)
    private var connection: NSXPCConnection?
    /// Called on the main queue when the XPC connection drops (the helper has already reverted).
    var onDisconnect: (() -> Void)?

    var status: HelperStatus {
        switch service.status {
        case .enabled: return .ready
        case .requiresApproval: return .needsApproval
        case .notRegistered: return .notRegistered
        case .notFound: return .unavailable("The helper is missing from the app bundle.")
        @unknown default: return .unavailable("Unknown helper status.")
        }
    }

    /// Registers the helper. macOS then asks the user to allow it once in Login Items.
    @discardableResult
    func register() -> HelperStatus {
        do {
            try service.register()
        } catch {
            // Throws when already registered or awaiting approval; the status below says which.
            NSLog("Trinetra: helper register: %@", error.localizedDescription)
        }
        return status
    }

    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func setLidSleepDisabled(_ disabled: Bool, completion: @escaping (Bool, String?) -> Void) {
        var finished = false
        let finish: (Bool, String?) -> Void = { ok, message in
            DispatchQueue.main.async {
                guard !finished else { return }
                finished = true
                completion(ok, message)
            }
        }
        guard let helper = proxy(onError: { finish(false, $0.localizedDescription) }) else {
            finish(false, "Couldn't reach the helper.")
            return
        }
        helper.setLidSleepDisabled(disabled) { ok, message in finish(ok, message) }
    }

    func heartbeat() {
        proxy(onError: { _ in })?.heartbeat {}
    }

    /// Drops the connection; the helper reverts as soon as it sees the disconnect.
    func disconnect() {
        connection?.invalidate()
        connection = nil
    }

    private func proxy(onError: @escaping (Error) -> Void) -> TrinetraHelperProtocol? {
        if connection == nil {
            let c = NSXPCConnection(machServiceName: HelperConstants.machServiceName, options: .privileged)
            c.remoteObjectInterface = NSXPCInterface(with: TrinetraHelperProtocol.self)
            let dropped: () -> Void = { [weak self] in
                DispatchQueue.main.async {
                    self?.connection = nil
                    self?.onDisconnect?()
                }
            }
            c.invalidationHandler = dropped
            c.interruptionHandler = dropped
            c.resume()
            connection = c
        }
        return connection?.remoteObjectProxyWithErrorHandler(onError) as? TrinetraHelperProtocol
    }

    /// Live system flag, read without privileges. Call off the main thread.
    static func sleepDisabled() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").contains { line in
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            return parts.first == "SleepDisabled" && parts.last == "1"
        }
    }
}
