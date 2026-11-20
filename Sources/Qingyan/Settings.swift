import AppKit
import AVFoundation
import Combine
import Security
import ServiceManagement
import QingyanCore

/// A Mac this one sent to before device keys: an address and the pairing code it showed.
struct LegacyPeer: Codable, Equatable {
    var host = ""
    var port = RemoteWire.defaultPort
    var code = ""

    init(host: String, port: Int, code: String) { self.host = host; self.port = port; self.code = code }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        host = try values.decodeIfPresent(String.self, forKey: .host) ?? host
        port = try values.decodeIfPresent(Int.self, forKey: .port) ?? port
        code = try values.decodeIfPresent(String.self, forKey: .code) ?? code
    }
}

struct Preferences: Codable, Equatable {
    var mode: WritingMode = .dictate
    /// How the dictated text is written: "raw" (the default), "polish", "structured", "formal", or a
    /// custom style's id. Chosen only in Settings (see `StyleChoice.standard`).
    var style = StyleChoice.standard
    /// Styles the user wrote in Settings, offered under Style once they have a name and instructions.
    var customStyles: [CustomStyle] = []
    var targetLanguage = "English"
    var speechModel = "gpt-live-transcribe"
    var textModel = "gpt-4.1-mini"
    /// Which platform recognises speech and which one tidies text (see `Platform`).
    var speechPlatform = Platform.openAI.id
    var textPlatform = Platform.openAI.id
    /// The address of the platform the user describes themselves.
    var customBase = ""
    /// Model Studio's address when it is not the Singapore region: another region's host or a
    /// workspace's own domain.
    var alibabaHost = ""
    /// The model last used on each platform, so that switching back restores it: "speech.groq" → model.
    var modelChoices: [String: String] = [:]
    var shortcut = "fn"
    /// The microphone to record from, by the system's lasting name for it; empty follows the system.
    var microphone = ""
    var microphoneName = ""
    var dictionary: [String] = []
    /// Send up to 1,000 characters already written before the cursor along with the transcript to
    /// the polishing service, so names and terms come out right: off by default.
    var fieldContext = false
    /// After a dictation is written, watch the field for a word the user corrected and offer it for
    /// the personal dictionary: off by default.
    var learnCorrections = false
    /// Words the user declined to add, so they are not offered again; at most 200, oldest dropped.
    var declinedWords: [String] = []
    /// Work with other Macs at all: answer their calls, send text to the one being operated, share the shelf.
    var linkEnabled = false
    /// The Macs this one trusts, each by its key, with what it may do here.
    var devices: [TrustedDevice] = []
    /// Only take calls that arrive through Tailscale.
    var tailscaleOnly = true
    /// The port this Mac listens on.
    var remotePort = RemoteWire.defaultPort
    /// From the version before device keys, kept until each old pairing has been turned into trust.
    var remoteRole = "off"
    var remoteHost = ""
    var remoteCode = ""
    var remotePeers: [LegacyPeer] = []
    /// Blocks of the panel the user folded down to their title: "history", "remote".
    var foldedBlocks: [String] = []
    /// Install new builds from the repository by itself.
    var autoUpdate = true
    /// The language of the app's own words: "system" follows macOS, or "en", "zh-Hans".
    var language = Localization.followSystem

    init() {}

    // Settings saved by an earlier version lack the newer keys; a missing key must not reset the rest.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mode = try values.decodeIfPresent(WritingMode.self, forKey: .mode) ?? mode
        // Saved before styles, by a version whose panel had the old on/off switch: Raw, whatever it said.
        style = try values.decodeIfPresent(String.self, forKey: .style) ?? StyleChoice.standard
        customStyles = try values.decodeIfPresent([CustomStyle].self, forKey: .customStyles) ?? customStyles
        targetLanguage = Preferences.englishTarget(try values.decodeIfPresent(String.self, forKey: .targetLanguage) ?? targetLanguage)
        speechModel = try values.decodeIfPresent(String.self, forKey: .speechModel) ?? speechModel
        textModel = try values.decodeIfPresent(String.self, forKey: .textModel) ?? textModel
        speechPlatform = try values.decodeIfPresent(String.self, forKey: .speechPlatform) ?? speechPlatform
        textPlatform = try values.decodeIfPresent(String.self, forKey: .textPlatform) ?? textPlatform
        customBase = try values.decodeIfPresent(String.self, forKey: .customBase) ?? customBase
        alibabaHost = try values.decodeIfPresent(String.self, forKey: .alibabaHost) ?? alibabaHost
        modelChoices = try values.decodeIfPresent([String: String].self, forKey: .modelChoices) ?? modelChoices
        shortcut = try values.decodeIfPresent(String.self, forKey: .shortcut) ?? shortcut
        microphone = try values.decodeIfPresent(String.self, forKey: .microphone) ?? microphone
        microphoneName = try values.decodeIfPresent(String.self, forKey: .microphoneName) ?? microphoneName
        dictionary = try values.decodeIfPresent([String].self, forKey: .dictionary) ?? dictionary
        fieldContext = try values.decodeIfPresent(Bool.self, forKey: .fieldContext) ?? fieldContext
        learnCorrections = try values.decodeIfPresent(Bool.self, forKey: .learnCorrections) ?? learnCorrections
        declinedWords = try values.decodeIfPresent([String].self, forKey: .declinedWords) ?? declinedWords
        remoteRole = try values.decodeIfPresent(String.self, forKey: .remoteRole) ?? remoteRole
        remoteHost = try values.decodeIfPresent(String.self, forKey: .remoteHost) ?? remoteHost
        remotePort = try values.decodeIfPresent(Int.self, forKey: .remotePort) ?? remotePort
        remoteCode = try values.decodeIfPresent(String.self, forKey: .remoteCode) ?? remoteCode
        remotePeers = try values.decodeIfPresent([LegacyPeer].self, forKey: .remotePeers) ?? remotePeers
        foldedBlocks = try values.decodeIfPresent([String].self, forKey: .foldedBlocks) ?? foldedBlocks
        autoUpdate = try values.decodeIfPresent(Bool.self, forKey: .autoUpdate) ?? autoUpdate
        // Settings saved before the app had English were made in Chinese: they keep it.
        language = try values.decodeIfPresent(String.self, forKey: .language) ?? Localization.Language.simplifiedChinese.rawValue
        if remotePeers.isEmpty && remoteRole == "send" && !remoteHost.isEmpty {
            remotePeers = [LegacyPeer(host: remoteHost, port: remotePort, code: remoteCode)]
        }
        devices = try values.decodeIfPresent([TrustedDevice].self, forKey: .devices) ?? devices
        tailscaleOnly = try values.decodeIfPresent(Bool.self, forKey: .tailscaleOnly) ?? tailscaleOnly
        // A Mac that sent or received before keeps working with the others.
        linkEnabled = try values.decodeIfPresent(Bool.self, forKey: .linkEnabled) ?? (remoteRole != "off")
    }

    /// The style the stored id names, unfinished and deleted custom ids included (see `StyleChoice`).
    var dictationStyle: DictationStyle { StyleChoice.resolve(style, customs: customStyles) }

    /// Before the app had English, the target of a translation was kept, and sent to the model,
    /// by its Chinese name. It is the English name now.
    static func englishTarget(_ stored: String) -> String {
        let earlier: [String: String] = [
            "\u{82F1}\u{8BED}": "English",
            "\u{7B80}\u{4F53}\u{4E2D}\u{6587}": "Simplified Chinese",
            "\u{7E41}\u{4F53}\u{4E2D}\u{6587}": "Traditional Chinese",
            "\u{65E5}\u{8BED}": "Japanese",
            "\u{97E9}\u{8BED}": "Korean",
            "\u{6CD5}\u{8BED}": "French",
            "\u{5FB7}\u{8BED}": "German",
            "\u{897F}\u{73ED}\u{7259}\u{8BED}": "Spanish",
        ]
        return earlier[stored] ?? stored
    }
}

/// The parts of the app that can be asked for by name. The history and the other Macs are on
/// the panel's everyday page; the rest is on its settings page. The raw value is the English
/// name; `title` is the name in the chosen language, the one to show.
enum PanelSection: String, CaseIterable {
    case history = "History", dictionary = "Personal dictionary", keyboard = "Audio and shortcut"
    case remote = "Multiple Macs", connection = "Models and keys", general = "General"

    var title: String {
        switch self {
        case .history: return tr("History")
        case .dictionary: return tr("Personal dictionary")
        case .keyboard: return tr("Audio and shortcut")
        case .remote: return tr("Multiple Macs")
        case .connection: return tr("Models and keys")
        case .general: return tr("General")
        }
    }

    var symbol: String {
        switch self {
        case .history: return "clock.arrow.circlepath"
        case .dictionary: return "character.book.closed"
        case .keyboard: return "keyboard"
        case .remote: return "macbook.and.iphone"
        case .connection: return "key.horizontal"
        case .general: return "gearshape"
        }
    }
}

/// Where the app's secrets are kept: the login keychain, written and read through Apple's own
/// `security` tool instead of by the app itself.
enum Vault {
    private static let service = "local.hopo.qingyan.vault"
    private static let tool = "/usr/bin/security"
    /// What has been read or written since launch, so that a dictation does not start a process.
    /// `nil` inside means "looked, and there is none".
    private static let lock = NSLock()
    nonisolated(unsafe) private static var known: [String: Data?] = [:]

    static func read(_ account: String) throws -> Data? {
        lock.lock()
        if let seen = known[account] {
            lock.unlock()
            return seen
        }
        lock.unlock()
        let validAccount = try plain(account)
        let found = try run(["find-generic-password", "-s", service, "-a", validAccount, "-w"])
        lock.lock(); defer { lock.unlock() }
        guard found.status != 44 else { known[account] = .some(nil); return nil }
        guard found.status == 0, let value = Data(base64Encoded: found.output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw VoiceError(tr("Could not read the system keychain. Unlock the keychain and try again."))
        }
        known[account] = value
        return value
    }

    static func save(_ value: Data, account: String) throws {
        let validAccount = try plain(account)
        // Given on the tool's input, not as an argument: arguments can be seen by other programs.
        let line = "add-generic-password -U -s \(service) -a \(validAccount) -D \"out secret\" -w \(value.base64EncodedString())\n"
        _ = try run(["-i"], input: line)
        let back = try run(["find-generic-password", "-s", service, "-a", validAccount, "-w"])
        lock.lock(); defer { lock.unlock() }
        guard back.status == 0, Data(base64Encoded: back.output.trimmingCharacters(in: .whitespacesAndNewlines)) == value else {
            known[account] = nil
            throw VoiceError(tr("Could not write to the system keychain."))
        }
        known[account] = value
    }

    static func delete(_ account: String) throws {
        let validAccount = try plain(account)
        let status = try run(["delete-generic-password", "-s", service, "-a", validAccount]).status
        lock.lock(); defer { lock.unlock() }
        known[account] = nil
        guard status == 0 || status == 44 else { throw VoiceError(tr("Could not delete the keychain item.")) }
    }

    /// Account names are ours and plain; anything else would be a mistake, and must not reach the tool's command line.
    private static func plain(_ account: String) throws -> String {
        guard !account.isEmpty, account.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }) else {
            throw VoiceError(tr("The keychain account name is not valid."))
        }
        return account
    }

    private static func run(_ arguments: [String], input: String? = nil) throws -> (status: Int32, output: String) {
        let process = Process(), output = Pipe(), entry = Pipe()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = input == nil ? FileHandle.nullDevice : entry
        do { try process.run() } catch { throw VoiceError(tr("Could not run the system keychain tool.")) }
        if let input {
            entry.fileHandleForWriting.write(Data(input.utf8))
            try? entry.fileHandleForWriting.close()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

/// This Mac's identity key. Losing it would make every other Mac stop recognising this one, so
/// a keychain that cannot be read is an error, never a reason to make a new key.
enum DeviceKeychain {
    private static let earlier: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "local.hopo.qingyan.device", kSecAttrAccount as String: "identity"]

    static func load() throws -> DeviceIdentity {
        if let saved = try Vault.read("identity") {
            guard let identity = DeviceIdentity(saved: saved) else { throw VoiceError(tr("This Mac's identity key in the keychain is not recognized.")) }
            return identity
        }
        var request = earlier
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        let identity: DeviceIdentity
        if status == errSecSuccess, let data = item as? Data, let kept = DeviceIdentity(saved: data) { identity = kept }
        else if status == errSecItemNotFound { identity = DeviceIdentity() }
        else { throw VoiceError(tr("Could not read this Mac's identity key. Unlock the keychain and open out again.")) }
        do { try Vault.save(identity.saved, account: "identity") }
        catch { throw VoiceError(tr("Could not save this Mac's identity key to the keychain.")) }
        return identity
    }
}

/// One API key per platform.
enum Keychain {
    private static func account(_ platform: String) -> String { platform == Platform.openAI.id ? "api-key" : "api-key.\(platform)" }
    private static func earlier(_ platform: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.hopo.qingyan.openai",
         kSecAttrAccount as String: account(platform)]
    }

    static func read(_ platform: String) throws -> String {
        if let saved = try Vault.read(account(platform)) { return String(decoding: saved, as: UTF8.self) }
        var request = earlier(platform)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw VoiceError(tr("Could not read the keychain. Unlock it, or update the API key in Settings."))
        }
        if !value.isEmpty { try? Vault.save(data, account: account(platform)) }
        return value
    }

    static func save(_ key: String, platform: String) throws {
        try Vault.save(Data(key.utf8), account: account(platform))
        SecItemDelete(earlier(platform) as CFDictionary)
    }

    static func delete(_ platform: String) throws {
        try Vault.delete(account(platform))
        let status = SecItemDelete(earlier(platform) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw VoiceError(tr("Could not delete the keychain item.")) }
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    @Published var preferences: Preferences {
        didSet {
            if preferences != oldValue { schedulePersist() }
            if preferences.language != oldValue.language {
                Localization.use(Localization.resolve(preferences.language))
            }
        }
    }
    @Published var history: [HistoryEntry]
    @Published var section: PanelSection?
    /// A detail opened by hand on the panel (a paired Mac's, the microphone list): like a block
    /// unfolded, it lets a panel that was dragged shorter grow to fit again.
    let detailOpened = PassthroughSubject<Void, Never>()
    /// Which of the panel's two pages is showing: the everyday one, or the settings.
    enum Page { case main, settings }
    @Published var page = Page.main
    /// Brings the panel up; set by the app.
    var openPanel: (() -> Void)?
    /// Turns the compact floating bar on (the full panel goes) or off (it comes back); set by the app.
    var setCompact: ((Bool) -> Void)?

    /// The side drawer beside the panel (hosting either History or Settings), and which side it opens on.
    @Published var historyOpen = false
    @Published var drawerLeft = false
    /// Asked just before the drawer opens from closed: is there no room for it on the right?
    var drawerGoesLeft: (() -> Bool)?

    var drawerOpen: Bool { historyOpen || page == .settings }

    /// Shows a part of the app: Settings and History slide out in the side drawer; Remote unfolds on the main column.
    func reveal(_ target: PanelSection?) {
        if let target, [.connection, .keyboard, .dictionary, .general].contains(target) {
            if !drawerOpen { drawerLeft = drawerGoesLeft?() ?? false }
            if page != .settings { page = .settings }
            if historyOpen { historyOpen = false }
            openPanel?()
            return
        }
        if target == .history {
            if !drawerOpen { drawerLeft = drawerGoesLeft?() ?? false }
            if !historyOpen { historyOpen = true }
            if page != .main { page = .main }
            openPanel?()
            return
        }
        if target != nil {
            closeDrawer()
        }
        if section != target { section = target }
    }

    func toggleHistory() {
        if historyOpen {
            historyOpen = false
        } else {
            if !drawerOpen { drawerLeft = drawerGoesLeft?() ?? false }
            historyOpen = true
            if page != .main { page = .main }
        }
    }

    func toggleSettings() {
        if page == .settings {
            page = .main
        } else {
            if !drawerOpen { drawerLeft = drawerGoesLeft?() ?? false }
            page = .settings
            if historyOpen { historyOpen = false }
        }
    }

    func closeDrawer() {
        if historyOpen { historyOpen = false }
        if page != .main { page = .main }
    }

    /// The platforms whose API key is in the keychain.
    @Published var savedKeys: Set<String> = []
    @Published var microphoneAllowed = false
    @Published var accessibilityAllowed = false
    /// Cached login-item state so opening or rendering Settings never blocks on XPC.
    @Published private(set) var loginItemEnabled = false
    @Published var loginMessage = ""
    /// What the last save, removal or check of each platform's key said.
    @Published var keyMessages: [String: String] = [:]
    @Published var savingPlatforms: Set<String> = []

    func usable(_ platform: String) -> Bool {
        switch platform {
        case Platform.custom.id: return Platform.normalized(base: preferences.customBase) != nil
        case Platform.alibaba.id: return savedKeys.contains(platform) && Platform.alibabaBase(preferences.alibabaHost) != nil
        case Platform.thisMac.id: return OnDeviceModels.available
        default: return savedKeys.contains(platform)
        }
    }

    /// Both platforms in use can be called. Setting it is for previews only.
    var hasKey: Bool {
        get { usable(preferences.speechPlatform) && (preferences.dictationStyle == .raw || usable(preferences.textPlatform)) }
        set { savedKeys = newValue ? Set(Platform.all.map(\.id)) : [] }
    }

    /// Synchronous service lookup (uses Vault's pre-warmed memory cache).
    func service(_ id: String?) throws -> Service {
        let platform = Platform.named(id)
        guard let base = platform.baseURL(custom: preferences.customBase, alibaba: preferences.alibabaHost) else {
            throw platform.wire == .alibaba
                ? VoiceError(tr("Enter a host name, such as dashscope-intl.aliyuncs.com, or an https:// address."))
                : VoiceError(tr("No custom endpoint URL is set. Enter one in Settings."))
        }
        if platform.id == Platform.custom.id {
            return Service(platform: platform, base: base, key: try Keychain.read(platform.id))
        }
        guard savedKeys.contains(platform.id) else {
            throw VoiceError(tr("No %@ API key is set up. Save one in Settings and try again.", platform.name))
        }
        let key = try Keychain.read(platform.id)
        guard !key.isEmpty else { throw VoiceError(tr("The %@ API key is not in the keychain. Save it again.", platform.name)) }
        return Service(platform: platform, base: base, key: key)
    }

    /// Off-main-actor service lookup so Settings validation never blocks UI frames on keychain subprocesses.
    func serviceAsync(_ id: String?) async throws -> Service {
        let platform = Platform.named(id)
        let customBase = preferences.customBase
        let alibabaHost = preferences.alibabaHost
        let isSaved = savedKeys.contains(platform.id)
        guard let base = platform.baseURL(custom: customBase, alibaba: alibabaHost) else {
            throw platform.wire == .alibaba
                ? VoiceError(tr("Enter a host name, such as dashscope-intl.aliyuncs.com, or an https:// address."))
                : VoiceError(tr("No custom endpoint URL is set. Enter one in Settings."))
        }
        if platform.id == Platform.custom.id {
            let key = try await Task.detached(priority: .userInitiated) { try Keychain.read(platform.id) }.value
            return Service(platform: platform, base: base, key: key)
        }
        guard isSaved else {
            throw VoiceError(tr("No %@ API key is set up. Save one in Settings and try again.", platform.name))
        }
        let key = try await Task.detached(priority: .userInitiated) { try Keychain.read(platform.id) }.value
        guard !key.isEmpty else { throw VoiceError(tr("The %@ API key is not in the keychain. Save it again.", platform.name)) }
        return Service(platform: platform, base: base, key: key)
    }

    /// Permanently locks input to a specific microphone UID (or clears binding when `uid` is empty).
    func bindMicrophone(uid: String, name: String = "") {
        var next = preferences
        next.microphone = uid
        next.microphoneName = uid.isEmpty ? "" : name
        preferences = next
    }

    /// Moves recognition or tidying to another platform, with the model last used there or its default.
    func choose(_ platform: String, speech: Bool) {
        var next = preferences
        let slot = speech ? "speech." : "text."
        let old = speech ? next.speechPlatform : next.textPlatform
        guard old != platform else { return }
        next.modelChoices[slot + old] = speech ? next.speechModel : next.textModel
        let preset = Platform.named(platform)
        let model = next.modelChoices[slot + platform] ?? (speech ? preset.speechModels.first : preset.textModels.first) ?? ""
        if speech { next.speechPlatform = platform; next.speechModel = model }
        else { next.textPlatform = platform; next.textModel = model }
        preferences = next
    }

    @Published var historyMessage = ""
    private(set) var archive: DictationArchive?
    let preview: Bool
    private let defaults: UserDefaults
    private var persistWork: DispatchWorkItem?

    init(preview: Bool = false) {
        self.preview = preview
        defaults = preview ? UserDefaults(suiteName: "local.hopo.qingyan.preview")! : .standard
        var loaded = preview ? Preferences() : defaults.data(forKey: "preferences").flatMap {
            try? JSONDecoder().decode(Preferences.self, from: $0)
        } ?? Preferences()
        // Translate and Rewrite are hidden for now (user 2026-11-19): put always dictates.
        loaded.mode = .dictate
        preferences = loaded
        // From the decoded value: self cannot be read before every stored property is set.
        Localization.use(Localization.resolve(loaded.language))
        history = preview ? [] : defaults.data(forKey: "history").flatMap {
            try? JSONDecoder().decode([HistoryEntry].self, from: $0)
        } ?? []
        if !preview {
            savedKeys = Set(defaults.stringArray(forKey: "savedKeys") ?? [])
            if defaults.bool(forKey: "hasKey") { savedKeys.insert(Platform.openAI.id) }
            do {
                let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                    appropriateFor: nil, create: true).appendingPathComponent("Qingyan/History", isDirectory: true)
                archive = try DictationArchive(directory: directory, legacy: history)
                history = archive!.entries
                defaults.removeObject(forKey: "history")
            } catch { historyMessage = tr("Could not read the local history folder. Check disk space and file access permissions.") }

            // Pre-warm login item status and saved API keys in the background so Settings opens in 0 ms.
            let warmPlatforms = Array(savedKeys)
            Task.detached(priority: .utility) {
                let enabled = SMAppService.mainApp.status == .enabled
                for id in warmPlatforms { _ = try? Keychain.read(id) }
                await MainActor.run { [weak self] in
                    if self?.loginItemEnabled != enabled { self?.loginItemEnabled = enabled }
                }
            }
        }
        refreshPermissions()
    }

    var shortcutLabel: String { (Shortcut(stored: preferences.shortcut) ?? .fn).label(keyName: KeyboardLayoutMap.name(of:)) }
    var ready: Bool { hasKey && microphoneAllowed && accessibilityAllowed }
    /// Text may go to another Mac: working with others is on and there is someone to work with.
    var sendsRemotely: Bool { preferences.linkEnabled && !preferences.devices.isEmpty }
    /// A Mac set up only to take text from others: it needs neither a key nor a microphone.
    var receiverOnly: Bool { preferences.linkEnabled && !hasKey }

    private func schedulePersist() {
        guard !preview else { return }
        persistWork?.cancel()
        let snapshot = preferences
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if let data = try? JSONEncoder().encode(snapshot) {
                self.defaults.set(data, forKey: "preferences")
            }
        }
        persistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    func flushPersistence() {
        guard !preview, persistWork != nil else { return }
        persistWork?.cancel()
        persistWork = nil
        if let data = try? JSONEncoder().encode(preferences) {
            defaults.set(data, forKey: "preferences")
        }
    }

    func refreshPermissions() {
        guard !preview else { return }
        let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        if microphoneAllowed != mic { microphoneAllowed = mic }
        let ax = AXIsProcessTrusted()
        if accessibilityAllowed != ax { accessibilityAllowed = ax }
    }

    nonisolated private static func applyLoginItem(_ value: Bool) throws {
        if value { try SMAppService.mainApp.register() }
        else { try SMAppService.mainApp.unregister() }
    }

    func setLoginItem(_ value: Bool) {
        guard loginItemEnabled != value else { return }
        loginItemEnabled = value
        guard !preview else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try Self.applyLoginItem(value)
                DispatchQueue.main.async { self?.loginMessage = "" }
            } catch {
                let actual = SMAppService.mainApp.status == .enabled
                DispatchQueue.main.async {
                    self?.loginItemEnabled = actual
                    self?.loginMessage = tr("Could not update the login item. Move the app to the Applications folder and try again.")
                }
            }
        }
    }

    func saveKey(_ value: String, platform: String) {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains(where: { $0.isWhitespace }) else {
            keyMessages[platform] = tr("Enter the complete API key, without spaces."); return
        }
        if preview {
            savedKeys.insert(platform)
            keyMessages[platform] = tr("Saved to the system keychain, encrypted.")
            return
        }
        savingPlatforms.insert(platform)
        Task.detached(priority: .userInitiated) {
            let outcome: Result<Void, Error>
            do { try Keychain.save(key, platform: platform); outcome = .success(()) }
            catch { outcome = .failure(error) }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.savingPlatforms.remove(platform)
                switch outcome {
                case .success:
                    self.savedKeys.insert(platform)
                    self.rememberKeys()
                    self.keyMessages[platform] = tr("Saved to the system keychain, encrypted.")
                case .failure(let error):
                    self.keyMessages[platform] = error.localizedDescription
                }
            }
        }
    }

    func deleteKey(platform: String) {
        if preview {
            savedKeys.remove(platform)
            keyMessages[platform] = tr("Removed from the system keychain.")
            return
        }
        savingPlatforms.insert(platform)
        Task.detached(priority: .userInitiated) {
            let outcome: Result<Void, Error>
            do { try Keychain.delete(platform); outcome = .success(()) }
            catch { outcome = .failure(error) }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.savingPlatforms.remove(platform)
                switch outcome {
                case .success:
                    self.savedKeys.remove(platform)
                    self.rememberKeys()
                    self.keyMessages[platform] = tr("Removed from the system keychain.")
                case .failure(let error):
                    self.keyMessages[platform] = error.localizedDescription
                }
            }
        }
    }

    private func rememberKeys() {
        guard !preview else { return }
        defaults.set(savedKeys.sorted(), forKey: "savedKeys")
        defaults.set(savedKeys.contains(Platform.openAI.id), forKey: "hasKey")
    }

    func beginHistory(_ request: SavedDictation) throws -> (HistoryEntry, RecordedAudio) {
        guard let archive else { throw VoiceError(tr("The local history folder is not available. Check the disk and access permissions.")) }
        let recording = try archive.begin(request)
        history = archive.entries
        return recording
    }

    func addHistory(_ entry: HistoryEntry) throws {
        guard let archive else { throw VoiceError(tr("The local history folder is not available.")) }
        defer { history = archive.entries }
        try archive.add(entry)
    }

    func updateHistory(_ entry: HistoryEntry) throws {
        guard let archive else { throw VoiceError(tr("The local history folder is not available.")) }
        defer { history = archive.entries }
        try archive.update(entry)
    }

    func clearHistory() {
        guard let archive else { return }
        do { try archive.clear(); historyMessage = "" }
        catch { historyMessage = tr("Some records or audio could not be removed. Check file permissions and try again.") }
        history = archive.entries
    }

    func removeHistory(id: UUID) {
        guard let archive else { return }
        do { try archive.remove(id); historyMessage = "" }
        catch { historyMessage = tr("This record could not be deleted. Check file permissions and try again.") }
        history = archive.entries
    }

    func requestMicrophone() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in Task { @MainActor in self.refreshPermissions() } }
        } else { openPrivacy("Privacy_Microphone") }
    }

    func requestSetupPermissions() async {
        guard !preview else { return }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        refreshPermissions()
        if !accessibilityAllowed { requestAccessibility() }
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openPrivacy("Privacy_Accessibility")
    }

    func openPrivacy(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
