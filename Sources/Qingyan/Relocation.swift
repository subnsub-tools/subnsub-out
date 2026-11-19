import AppKit
import ServiceManagement
import QingyanCore

/// The app was called input until it was renamed put. The builds from before the rename install and
/// update it as /Applications/input.app, so the first build named put arrives there; started from
/// there, it moves its own bundle to /Applications/put.app and starts again from the new place
/// (see `AppLocation`). macOS keeps the permissions it gave: they belong to the bundle ID and the
/// signature, which do not change.
@MainActor
enum Relocation {
    /// Set before the move when the app opens at login: that item names the bundle where it was
    /// registered, so the copy at the new place registers it again. It stays until that worked.
    private static let loginItemKey = "relocatedLoginItem"
    /// What a start was asked to do, passed on to the copy that starts at the new place.
    private static let startupArguments = ["--setup-permissions", "--take-over-fn"]

    /// Moves this copy from input.app to put.app. True when it did and is quitting for the copy
    /// there; false when it stays where it is (the updater then keeps it current in place).
    static func moveIfNeeded() -> Bool {
        let running = Bundle.main.bundleURL.standardizedFileURL.path
        let files = FileManager.default
        guard AppLocation.step(running: running, currentTaken: files.fileExists(atPath: AppLocation.current)) == .move else { return false }
        let opensAtLogin = SMAppService.mainApp.status == .enabled
        do { try files.moveItem(atPath: AppLocation.legacy, toPath: AppLocation.current) } catch { return false }
        if opensAtLogin { UserDefaults.standard.set(true, forKey: loginItemKey) }
        relaunch(AppLocation.current, arguments: CommandLine.arguments.filter(startupArguments.contains))
        NSApp.terminate(nil)
        return true
    }

    /// After a move: the login item, if it was on, is registered from here. False when that failed;
    /// it is tried again at the next start, and Settings says so meanwhile.
    static func renewLoginItem() -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: loginItemKey) else { return true }
        try? SMAppService.mainApp.unregister()
        do { try SMAppService.mainApp.register() } catch { return false }
        defaults.removeObject(forKey: loginItemKey)
        return true
    }

    /// Starts the app at `path` once this process has gone: two cannot run side by side.
    static func relaunch(_ path: String, arguments: [String] = []) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        let wait = "while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done"
        let open = "if [ $# -gt 0 ]; then /usr/bin/open \"$0\" --args \"$@\"; else /usr/bin/open \"$0\"; fi"
        task.arguments = ["-c", wait + "; " + open, path] + arguments
        try? task.run()
    }
}
