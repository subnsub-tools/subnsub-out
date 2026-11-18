import AppKit
import CryptoKit
import Security
import QingyanCore

/// Keeps the installed app at the newest build: from the public repository's releases on GitHub,
/// or from our site when GitHub cannot be reached (see `UpdateFeed`).
///
/// A build is taken only when it is signed by the same identity as the app that is running: the
/// downloaded bundle must satisfy this app's own designated requirement. So nothing but our own
/// builds can replace the app, whatever GitHub, the site or the network says — and macOS keeps
/// the permissions it gave, because to it the new build is the same app.
@MainActor
final class Updater: ObservableObject {
    /// One line for the settings: what is installed, what is going on, or what is in the way.
    @Published private(set) var status = ""
    /// How `status` was made, so that a change of language can make it again.
    private var statusWords: (key: String, arguments: [CVarArg]) = ("", [])
    private var languageObserver: NSObjectProtocol?

    private func say(_ key: String, _ arguments: CVarArg...) {
        statusWords = (key, arguments)
        status = arguments.isEmpty ? tr(key) : String(format: tr(key), arguments: arguments)
    }
    @Published private(set) var working = false

    private let settings: SettingsStore
    /// The app must not be replaced under a recording.
    var isBusy: () -> Bool = { false }
    private var timer: Timer?
    private var ready: (build: UpdateFeed.Build, app: URL)?
    private var lastCheck = Date.distantPast
    private let installed = URL(fileURLWithPath: "/Applications/input.app")

    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"
    private let number = Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0

    init(settings: SettingsStore) {
        self.settings = settings
        say("Version %@", version)
        languageObserver = NotificationCenter.default.addObserver(forName: Localization.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let words = self.statusWords
                self.status = words.arguments.isEmpty ? tr(words.key) : String(format: tr(words.key), arguments: words.arguments)
            }
        }
    }

    /// Whether this copy can be replaced at all: only the one in Applications is.
    private var replaceable: Bool {
        !settings.preview && Bundle.main.bundleURL.standardizedFileURL.path == installed.path
    }

    func start() {
        guard !settings.preview else { return }
        guard replaceable else { say("Version %@ · Not in Applications, so automatic updates are off", version); return }
        if let last = UserDefaults.standard.string(forKey: "updatedTo"), last == version {
            say("Updated to %@", version)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Once a minute: install what is waiting as soon as nothing is being recorded, and look for
    /// a new build every six hours (the first time shortly after launch).
    private func tick() {
        guard !working else { return }
        if ready != nil { installIfIdle(); return }
        if settings.preferences.autoUpdate, Date().timeIntervalSince(lastCheck) > 6 * 3600 { check() }
    }

    func check(manual: Bool = false) {
        guard replaceable, !working else { return }
        working = true; lastCheck = Date()
        if manual { say("Checking for updates…") }
        Task { @MainActor in
            defer { working = false }
            do {
                // The time GitHub is out of reach is kept per attempt, not per request: a manifest
                // that loads followed by a package that never does is still no answer.
                do {
                    try await update(from: .github)
                    githubDownSince = UpdateFeed.githubDownSince(afterAway: false, was: githubDownSince)
                } catch let away as Away {
                    // GitHub gave no answer: the site, if it may be asked yet.
                    let since = UpdateFeed.githubDownSince(afterAway: true, was: githubDownSince)
                    githubDownSince = since
                    guard UpdateFeed.asksSite(manual: manual, githubDownSince: since) else { throw away }
                    try await update(from: .site)
                } catch {
                    githubDownSince = UpdateFeed.githubDownSince(afterAway: false, was: githubDownSince)
                    throw error
                }
            } catch {
                let shown = (error as? Away)?.reason ?? error
                let reason = shown is VoiceError ? shown.localizedDescription : tr("Could not check for updates. Check the network connection.")
                say("Version %@ · %@", version, reason)
            }
        }
    }

    /// A failure that says nothing about what is published (see `UpdateFeed.away`).
    private struct Away: Error { let reason: Error }

    /// Since when GitHub has given no answer; cleared by an attempt it answered. Kept, so that a
    /// restart does not start the grace again.
    private var githubDownSince: Date? {
        get { UserDefaults.standard.object(forKey: "updateGitHubDownSince") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "updateGitHubDownSince") }
    }

    private let githubRedirects = GitHubRedirects()

    /// One request to a source: for GitHub, redirects only to its download hosts. No answer, or
    /// the host's own trouble, is `Away`.
    private func ask<Value>(_ source: UpdateFeed.Source, _ send: (URLSessionTaskDelegate?) async throws -> (Value, URLResponse)) async throws -> Value {
        let value: Value, response: URLResponse
        do { (value, response) = try await send(source == .github ? githubRedirects : nil) }
        catch { throw UpdateFeed.away(error) ? Away(reason: error) : error }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if UpdateFeed.away(status: code) { throw Away(reason: UpdateFeed.problem(status: code)) }
        guard code == 200 else { throw UpdateFeed.problem(status: code) }
        return value
    }

    /// Reads one source's manifest and, when it names a newer build, fetches that build from the
    /// same source and keeps it ready.
    private func update(from source: UpdateFeed.Source) async throws {
        let data: Data = try await ask(source) { delegate in
            try await URLSession.shared.data(for: UpdateFeed.request(source.latest), delegate: delegate)
        }
        guard let build = UpdateFeed.build(in: (try? JSONSerialization.jsonObject(with: data)) as Any, from: source) else {
            throw VoiceError(tr("The list of versions could not be read. The update was canceled."))
        }
        guard build.number > number else { say("Up to date (%@)", version); return }
        say("Downloading %@…", build.version)
        let app = try await fetch(build)
        ready = (build, app)
        say("%@ is ready and will install when input is idle", build.version)
        installIfIdle()
    }

    /// Downloads the build, unpacks it beside the history, and proves it is ours before it is kept.
    private func fetch(_ build: UpdateFeed.Build) async throws -> URL {
        let files = FileManager.default
        let folder = try files.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Qingyan/Update", isDirectory: true)
        try? files.removeItem(at: folder)
        try files.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let temporary: URL = try await ask(build.source) { delegate in
            try await session.download(for: UpdateFeed.request(build.asset, file: true), delegate: delegate)
        }
        let zip = folder.appendingPathComponent("input.zip")
        try files.moveItem(at: temporary, to: zip)
        let bytes = try Data(contentsOf: zip, options: .mappedIfSafe)
        let found = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard bytes.count == build.size, found == build.digest else {
            throw VoiceError(tr("The package for %@ did not pass verification. The installation was canceled.", build.version))
        }
        guard await Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, folder.path], seconds: 60) != nil else {
            throw VoiceError(tr("Could not unpack the package for %@.", build.version))
        }
        try? files.removeItem(at: zip)
        let app = folder.appendingPathComponent("input.app", isDirectory: true)
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard info?["CFBundleIdentifier"] as? String == UpdateFeed.bundleIdentifier,
              Int(info?["CFBundleVersion"] as? String ?? "") == build.number else {
            throw VoiceError(tr("The version details in the package for %@ do not match. The installation was canceled.", build.version))
        }
        try Self.requireSameSigner(app)
        return app
    }

    /// The downloaded bundle must be intact and satisfy the designated requirement of the app
    /// that is running, which names the identity our builds are signed with.
    private static func requireSameSigner(_ app: URL) throws {
        let refused = VoiceError(tr("The package is signed by a different identity. The app was not replaced."))
        var running: SecCode?, mine: SecStaticCode?, requirement: SecRequirement?, candidate: SecStaticCode?
        guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
              SecCodeCopyStaticCode(running, [], &mine) == errSecSuccess, let mine,
              SecCodeCopyDesignatedRequirement(mine, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(app as CFURL, [], &candidate) == errSecSuccess, let candidate else { throw refused }
        let strict = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(candidate, strict, requirement) == errSecSuccess else { throw refused }
    }

    /// Swaps the bundle in Applications for the one that is waiting and starts it again.
    private func installIfIdle() {
        guard let ready, replaceable, !isBusy() else { return }
        do {
            // Proven again at the moment of use: the folder has been lying on disk since the download.
            try Self.requireSameSigner(ready.app)
            _ = try FileManager.default.replaceItemAt(installed, withItemAt: ready.app)
        } catch {
            self.ready = nil
            let reason = error is VoiceError ? error.localizedDescription : tr("Could not replace input in Applications.")
            say("Version %@ · %@", version, reason)
            return
        }
        UserDefaults.standard.set(ready.build.version, forKey: "updatedTo")
        // The new copy starts once this one has gone: two cannot run side by side.
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"\(installed.path)\""]
        try? relaunch.run()
        NSApp.terminate(nil)
    }

    /// Runs a tool and returns what it printed, or nil if it failed or took too long.
    private static func run(_ path: String, _ arguments: [String], seconds: Double) async -> String? {
        await withCheckedContinuation { (done: CheckedContinuation<String?, Never>) in
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            DispatchQueue.global(qos: .utility).async {
                do { try process.run() } catch { done.resume(returning: nil); return }
                let limit = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: limit)
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                limit.cancel()
                guard process.terminationStatus == 0 else { done.resume(returning: nil); return }
                done.resume(returning: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }
}

/// Follows GitHub's redirect of a release file to where it is stored, and no other: a redirect
/// that is not followed is the answer (see `UpdateFeed.followsRedirect`).
private final class GitHubRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        UpdateFeed.followsRedirect(to: request.url) ? request : nil
    }
}
