import SwiftUI
import QingyanCore

/// Everything that is set once and then left alone. Lives inside the panel's side drawer so
/// opening and closing Settings glides sideways with the same 120fps smoothness as History.
struct SettingsPage: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var controller: DictationController

    var body: some View {
        let prefs = settings.preferences
        let speech = Platform.named(prefs.speechPlatform), text = Platform.named(prefs.textPlatform)
        // Everything about polishing shows only once Text polishing is turned on (user 2026-11-20).
        let polishing = prefs.style != StyleChoice.standard
        VStack(alignment: .leading, spacing: 11) {
            SettingsGroup(tr("Recognition and polishing")) {
                ModelRows(settings: settings, speech: true)
                Divider()
                PolishSwitch(settings: settings)
                if polishing {
                    PolishChoice(settings: settings)
                    Row(tr("Text before the cursor"), info: tr("When on, each dictation sends up to 1,000 characters written before the cursor in the current field to the polishing service with the transcript, so names, terms and misheard words can be put right. Nothing is read in password fields, terminals or fields over 6,000 characters, or in a remote desktop window while Work across Macs has other Macs to send to.")) {
                        GlassSegments(label: tr("Text before the cursor"), selection: $settings.preferences.fieldContext,
                                      options: [(false, tr("Off")), (true, tr("On"))], compact: true)
                    }
                    ModelRows(settings: settings, speech: false)
                }
            }
            if polishing { CustomStylesGroup(settings: settings) }
            ForEach(Platform.all.filter { $0 == speech || (polishing && $0 == text) }) { platform in
                if platform.wire == .onDevice {
                    OnDeviceGroup(model: prefs.speechModel, models: OnDeviceModels.shared)
                } else {
                    KeyGroup(settings: settings, platform: platform)
                }
            }
            InputGroup(settings: settings, controller: controller, microphones: controller.microphones)
            DictionaryGroup(settings: settings, controller: controller)
            GeneralGroup(settings: settings, updater: controller.updater)
        }
        .disabled(controller.busy)
    }
}

/// A titled group: a small heading, and under it one card of rows.
private struct SettingsGroup<Content: View>: View {
    let title: String
    var detail = ""
    var content: Content
    init(_ title: String, detail: String = "", @ViewBuilder content: () -> Content) {
        self.title = title; self.detail = detail; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.muted)
                Spacer()
                if !detail.isEmpty {
                    Text(detail).font(.system(size: 10.5)).foregroundStyle(Palette.muted)
                }
            }
            .padding(.horizontal, 4)
            Card { VStack(alignment: .leading, spacing: 9) { content } }
        }
    }
}

private func hint(_ text: String, warning: Bool = false) -> some View {
    CopyableText(text, font: .system(size: 11), color: warning ? Color.orange : Palette.muted)
}

/// Styles the user writes themselves: a name for the Style menu and the instructions sent with
/// each dictation that is written in it.
private struct CustomStylesGroup: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        SettingsGroup(tr("Custom styles")) {
            ForEach($settings.preferences.customStyles) { $style in
                VStack(alignment: .leading, spacing: 7) {
                    TextField(tr("Style name"), text: Binding(
                        get: { $style.wrappedValue.name },
                        set: { $style.wrappedValue.name = String($0.prefix(CustomStyle.maxName)) }))
                        .glassField()
                    TextField(tr("Instructions, such as “Write it as a short, friendly chat message.”"), text: Binding(
                        get: { $style.wrappedValue.prompt },
                        set: { $style.wrappedValue.prompt = String($0.prefix(CustomStyle.maxPrompt)) }), axis: .vertical)
                        .lineLimit(3...8)
                        .glassField()
                    HStack {
                        Spacer()
                        Button(tr("Remove")) { remove($style.wrappedValue.id) }.buttonStyle(QuietButton())
                    }
                }
            }
            hint(tr("A custom style rewrites each dictation by the instructions written here, and can be chosen under Style once it has a name and instructions. At most 12 styles."))
            Button(tr("Add a style")) { settings.preferences.customStyles.append(CustomStyle()) }
                .buttonStyle(SolidButton())
                .disabled(settings.preferences.customStyles.count >= CustomStyle.maxCount)
        }
    }

    /// Removing the style that is chosen goes back to Polish: Text polishing stays on, as it was
    /// turned on here, and this group stays where it is.
    private func remove(_ id: UUID) {
        settings.preferences.customStyles.removeAll { $0.id == id }
        if settings.preferences.style == id.uuidString { settings.preferences.style = "polish" }
    }
}

/// The system speech model's state for the chosen language, and its one download.
private struct OnDeviceGroup: View {
    let model: String
    @ObservedObject var models: OnDeviceModels

    var body: some View {
        SettingsGroup(tr("Speech model on this Mac"), detail: detail) {
            hint(tr("The model for the chosen language is downloaded from Apple and kept by macOS, which shares it with other apps. Until it is installed, a recording waits for it."))
            if models.state == .notInstalled || models.state == .failed {
                Button(tr("Download")) { models.download(model) }.buttonStyle(SolidButton())
            }
        }
        .task(id: model) { await models.refresh(model) }
    }

    private var detail: String {
        switch models.state {
        case .checking: return "…"
        case .unsupported: return tr("Not available on this Mac")
        case .notInstalled: return tr("Not installed")
        case .downloading(let part): return tr("Downloading %ld%%", Int(part * 100))
        case .installed: return tr("Installed")
        case .failed: return tr("Download failed")
        }
    }
}

/// The platform and the model for one of the two jobs.
private struct ModelRows: View {
    @ObservedObject var settings: SettingsStore
    let speech: Bool
    @State private var typing = false
    private static let other = "\u{0}other"

    private var model: Binding<String> {
        Binding(get: { speech ? settings.preferences.speechModel : settings.preferences.textModel },
                set: { value in
                    let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if speech {
                        if settings.preferences.speechModel != name { settings.preferences.speechModel = name }
                    } else {
                        if settings.preferences.textModel != name { settings.preferences.textModel = name }
                    }
                })
    }

    var body: some View {
        let platform = Platform.named(speech ? settings.preferences.speechPlatform : settings.preferences.textPlatform)
        let suggestions = speech ? platform.speechModels : platform.textModels
        let fixed = speech && platform.live
        let onMac = platform.wire == .onDevice
        let listed = suggestions.contains(model.wrappedValue)
        let info: String? = speech
            ? (platform.wire == .openAI ? tr("gpt-live-transcribe shows the words as you speak. gpt-transcribe recognizes the whole recording once it ends, more accurately.")
               : platform.wire == .alibaba ? tr("qwen3-asr-flash-realtime shows the words as you speak.")
               : onMac ? tr("Recognized on this Mac by the system's speech model: the audio does not leave this Mac, and the words show as you speak. Each recording is recognized in the one language chosen here.") : nil)
            : nil
        let modelLabel = speech ? (onMac ? tr("Spoken language") : tr("Recognition model")) : tr("Polishing model")
        Row(speech ? tr("Speech recognition") : tr("Text polishing service")) {
            GlassMenu(label: speech ? tr("Speech recognition service") : tr("Text polishing service"),
                      selection: Binding(get: { platform.id }, set: { typing = false; settings.choose($0, speech: speech) }),
                      options: (speech ? Platform.speechChoices(onDevice: OnDeviceModels.available) : Platform.textChoices).map { ($0.id, $0.name) })
        }
        if !suggestions.isEmpty {
            Row(modelLabel, info: info) {
                GlassMenu(label: modelLabel,
                          selection: Binding(get: { listed && !typing ? model.wrappedValue : Self.other },
                                             set: { value in
                                                 if value == Self.other { typing = true } else { typing = false; model.wrappedValue = value }
                                             }),
                          options: suggestions.map { ($0, onMac ? Platform.languageName($0) : $0) }
                              + (fixed && listed ? [] : [(Self.other, tr("Custom model…"))]))
            }
        }
        if suggestions.isEmpty || (!fixed && (typing || !listed)) {
            TextField(speech ? tr("Recognition model name") : tr("Polishing model name"), text: model)
                .glassField(mono: true).autocorrectionDisabled()
        }
    }
}

/// The API key of one platform in use; for the user's own platform, its address as well.
private struct KeyGroup: View {
    @ObservedObject var settings: SettingsStore
    let platform: Platform
    @State private var key = ""
    @State private var checking = false
    @State private var deleteConfirmation = false

    var body: some View {
        let saved = settings.savedKeys.contains(platform.id)
        let saving = settings.savingPlatforms.contains(platform.id)
        let custom = platform.id == Platform.custom.id
        SettingsGroup(custom ? tr("Custom endpoint · OpenAI-compatible") : tr("%@ API key", platform.name),
                      detail: saved ? tr("Saved") : tr("Not set up")) {
            if platform.wire == .alibaba {
                TextField(tr("Address, such as dashscope-intl.aliyuncs.com"), text: $settings.preferences.alibabaHost)
                    .glassField(mono: true).autocorrectionDisabled()
                hint(tr("Leave empty for the Singapore region. A key works only with the address of the region it was created in; for another region or a workspace's own domain, enter that address."))
                if !settings.preferences.alibabaHost.trimmingCharacters(in: .whitespaces).isEmpty,
                   Platform.alibabaBase(settings.preferences.alibabaHost) == nil {
                    hint(tr("Enter a host name, such as dashscope-intl.aliyuncs.com, or an https:// address."), warning: true)
                }
            }
            if custom {
                TextField(tr("Endpoint URL, such as https://example.com/v1"), text: $settings.preferences.customBase)
                    .glassField(mono: true).autocorrectionDisabled()
                if !settings.preferences.customBase.trimmingCharacters(in: .whitespaces).isEmpty,
                   Platform.normalized(base: settings.preferences.customBase) == nil {
                    hint(tr("Use an https:// address. http:// is accepted only for this Mac, a local network host name or an IP address."), warning: true)
                }
                if let base = Platform.normalized(base: settings.preferences.customBase), Platform.isPlain(base) {
                    hint(tr("This connection is not encrypted: the key, audio and text cross the network in plain text."), warning: true)
                }
            }
            SecureField(saved ? tr("Enter a new key to replace it") : tr("API key (%@)", tr(platform.keyHint)), text: $key)
                .glassField(mono: true).onSubmit { save() }
            HStack(spacing: 6) {
                Button(saving ? tr("Saving…") : tr("Save")) { save() }
                    .buttonStyle(SolidButton()).disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
                Button(checking ? tr("Verifying…") : tr("Verify")) { check() }
                    .buttonStyle(QuietButton()).disabled(!settings.usable(platform.id) || checking || saving)
                Spacer()
                if saved {
                    Button(tr("Remove")) { deleteConfirmation = true }.buttonStyle(QuietButton()).disabled(saving)
                }
            }
            if let message = settings.keyMessages[platform.id], !message.isEmpty {
                CopyableText(message, font: .system(size: 11), color: Palette.ink)
            }
        }
        .alert(tr("Remove the %@ API key from the system keychain?", platform.name), isPresented: $deleteConfirmation) {
            Button(tr("Cancel"), role: .cancel) {}
            Button(tr("Remove"), role: .destructive) { settings.deleteKey(platform: platform.id) }
        }
    }

    private func save() {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        settings.saveKey(trimmed, platform: platform.id)
        if !trimmed.contains(where: { $0.isWhitespace }) { key = "" }
    }

    private func check() {
        checking = true
        let id = platform.id
        Task { @MainActor in
            defer { checking = false }
            do {
                let service = try await settings.serviceAsync(id)
                let prefs = settings.preferences
                // With Raw nothing is polished, so the polishing model is not looked for in the list.
                let speechHere = prefs.speechPlatform == id
                let textHere = prefs.textPlatform == id && prefs.dictationStyle != .raw
                // A service spoken to in its own way proves the key over its live socket; one that
                // takes the finished recording is proven by a recording. Neither lists its speech models.
                let own = speechHere ? platform.own(model: prefs.speechModel) : nil
                if own == .live, let wire = platform.liveWire(model: prefs.speechModel, base: service.base) {
                    try await LiveSocketTranscriber.probe(wire: wire, key: service.key, model: prefs.speechModel, name: platform.name)
                }
                if own != nil && !textHere {
                    let proven: Bool = own == .live && (platform.liveWire(model: prefs.speechModel, base: service.base)?.provesKey(model: prefs.speechModel) ?? false)
                    let valid: String = tr("The API key is valid, and the chosen models are available.")
                    let untested: String = tr("This service does not list its models. Make a recording to test the connection.")
                    settings.keyMessages[id] = proven ? valid : untested
                    return
                }
                // Model Studio proves the key and the speech model over its realtime socket;
                // the speech model's name is not looked up in the model list.
                if platform.wire == .alibaba && speechHere && own == nil {
                    try await QwenRealtimeTranscriber.probe(key: service.key,
                        endpoint: Platform.realtimeURL(base: service.base, model: prefs.speechModel))
                }
                // Proven by the socket and nothing else wanted; a key kept only for polishing is
                // still checked against the model list below.
                if platform.wire == .alibaba && speechHere && !textHere {
                    settings.keyMessages[id] = tr("The API key is valid, and the chosen models are available."); return
                }
                guard let models = try await service.models() else {
                    settings.keyMessages[id] = tr("This service does not list its models. Make a recording to test the connection."); return
                }
                var wanted: [String] = []
                if speechHere && platform.wire != .alibaba && own == nil { wanted.append(prefs.speechModel) }
                if textHere { wanted.append(prefs.textModel) }
                let missing = wanted.filter { !models.contains($0) }
                let custom = id == Platform.custom.id
                // The list is joined the way each language writes one: ", ", or an ideographic comma in Chinese and Japanese.
                let separator = Localization.current.listSeparator
                let absent = missing.map { $0.isEmpty ? tr("(blank)") : $0 }.joined(separator: separator)
                settings.keyMessages[id] = missing.isEmpty
                    ? (custom ? tr("The endpoint answers, and the chosen models are available.")
                              : tr("The API key is valid, and the chosen models are available."))
                    : (custom ? tr("The endpoint answers, but its model list does not include %@.", absent)
                              : tr("The API key is valid, but its model list does not include %@.", absent))
            } catch {
                settings.keyMessages[id] = error is VoiceError ? error.localizedDescription : tr("Could not connect. Check the network and the endpoint URL.")
            }
        }
    }
}

/// Where the sound comes from and which key starts it. Uses the controller's pre-warmed
/// `Microphones` monitor so opening Settings never blocks on CoreAudio HAL queries.
private struct InputGroup: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var controller: DictationController
    @ObservedObject var microphones: Microphones

    var body: some View {
        let chosen = settings.preferences.microphone
        let boundLabel = MicrophoneBinding.displayLabel(boundName: settings.preferences.microphoneName, uid: chosen)
        let away = !settings.preview && microphones.loaded && !chosen.isEmpty && !microphones.all.contains { $0.uid == chosen }
        let inUse = microphones.systemDefault?.name ?? tr("No input device found")
        SettingsGroup(tr("Audio and shortcut"),
                      detail: chosen.isEmpty ? tr("Follows macOS") : (away ? tr("Locked device offline") : tr("Microphone locked"))) {
            VStack(alignment: .leading, spacing: 5) {
                Text(tr("Input microphone (a click locks it permanently)"))
                    .font(.system(size: 11.5, weight: .medium))
                if away {
                    MicrophoneOptionRow(
                        title: boundLabel,
                        badge: tr("Locked · Not connected"),
                        symbol: "exclamationmark.triangle.fill",
                        active: true,
                        warning: true
                    ) {}
                    hint(tr("The locked microphone “%@” is not in the device list. Nothing is recorded, and no other microphone is used in its place. Reconnect it, or click another device below to lock that one instead.", boundLabel), warning: true)
                }
                ForEach(microphones.all) { mic in
                    let selected = chosen == mic.uid
                    MicrophoneOptionRow(
                        title: mic.name,
                        badge: selected ? tr("Locked") : tr("Lock"),
                        symbol: selected ? "lock.fill" : "mic",
                        active: selected
                    ) {
                        settings.bindMicrophone(uid: mic.uid, name: mic.name)
                    }
                }
                MicrophoneOptionRow(
                    title: chosen.isEmpty ? tr("System default (%@)", inUse) : tr("System default"),
                    badge: chosen.isEmpty ? tr("Current") : tr("Unlock"),
                    symbol: chosen.isEmpty ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath",
                    active: chosen.isEmpty
                ) {
                    settings.bindMicrophone(uid: "", name: "")
                }
                if !away && !chosen.isEmpty {
                    hint(tr("Locked to “%@” permanently. If it goes offline, a notice appears and nothing is recorded.", boundLabel))
                }
            }
            if !settings.microphoneAllowed {
                HStack {
                    Label(tr("Microphone permission not granted"), systemImage: "mic.slash").font(.system(size: 11)).foregroundStyle(.orange)
                    Spacer()
                    Button(tr("Grant access")) { settings.requestMicrophone() }.buttonStyle(QuietButton())
                }
            }
            Divider()
            HStack(alignment: .top, spacing: 5) {
                Image(systemName: controller.hotkeyInstalled ? "checkmark.shield" : "exclamationmark.shield")
                    .font(.system(size: 11)).foregroundStyle(controller.hotkeyInstalled ? Palette.muted : .orange)
                    .padding(.top, 2)
                CopyableText(controller.shortcutStatus, font: .system(size: 11),
                             color: controller.hotkeyInstalled ? Palette.muted : .orange)
            }
            HStack(spacing: 6) {
                Button(settings.accessibilityAllowed ? tr("Take over Fn") : tr("Allow and take over Fn")) { controller.takeOverFn() }.buttonStyle(QuietButton())
                Button(tr("Keyboard settings…")) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                }.buttonStyle(QuietButton())
            }
            Divider()
            Row(tr("Type the Clipboard"), info: tr("Control + Option + V types the clipboard's text into the field in front, key by key, where pasting is refused: password fields, forms that block paste, remote desktops and consoles. Line breaks are typed as Return. Esc or the capsule's Cancel button stops it. Nothing typed is kept.")) {
                Text("⌃ ⌥ V").font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.muted)
            }
        }
    }
}

private struct DictionaryGroup: View {
    @ObservedObject var settings: SettingsStore
    let controller: DictationController
    @State private var word = ""
    @State private var validation = ""
    @State private var showAll = false
    @State private var copiedWord: String?

    var body: some View {
        let allWords = settings.preferences.dictionary
        let count = allWords.count
        let visibleWords = showAll || count <= 24 ? allWords : Array(allWords.prefix(24))
        SettingsGroup(tr("Personal dictionary"), detail: count == 0 ? "" : "\(count) / 80") {
            Row(tr("Learn from corrections"), info: tr("When on, out reads the text field again when the next dictation starts, or 30 seconds after the text was written, if that window is still in front. When a word it wrote was replaced there, the panel asks whether to add the new word to the personal dictionary. Nothing is added without asking, and nothing read is sent anywhere.")) {
                GlassSegments(label: tr("Learn from corrections"),
                              selection: Binding(
                                get: { settings.preferences.learnCorrections },
                                set: { settings.preferences.learnCorrections = $0; if !$0 { controller.clearLearned() } }),
                              options: [(false, tr("Off")), (true, tr("On"))], compact: true)
            }
            HStack(spacing: 6) {
                TextField(tr("Add a name, product or term"), text: $word).glassField().onSubmit(add)
                Button(tr("Add"), action: add).buttonStyle(SolidButton()).disabled(word.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !validation.isEmpty { hint(validation, warning: true) }
            if count > 0 {
                FlowLayout(spacing: 5) {
                    ForEach(visibleWords, id: \.self) { item in
                        chip(item)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if count > 24 {
                    Button(showAll ? tr("Show fewer") : tr("Show all (%ld)", count)) { showAll.toggle() }
                        .buttonStyle(QuietButton())
                }
            } else {
                hint(tr("The words here are sent with each recognition request, so names and terms are recognized more accurately."))
            }
        }
    }

    private func chip(_ item: String) -> some View {
        let isCopied = copiedWord == item
        return HStack(spacing: 3) {
            Button {
                ClipboardCopy.copy(item)
                copiedWord = item
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    if copiedWord == item { copiedWord = nil }
                }
            } label: {
                HStack(spacing: 4) {
                    if isCopied {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.accent)
                    }
                    Text(isCopied ? tr("Copied") : item).font(.system(size: 11.5)).lineLimit(1)
                }
                .padding(.leading, 9).padding(.trailing, 4).padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tr("Click to copy “%@”", item))
            Button { settings.preferences.dictionary.removeAll { $0 == item } } label: {
                Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(Palette.muted)
                    .frame(width: 20, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tr("Remove “%@”", item))
            .accessibilityLabel(tr("Remove %@", item))
        }
        .padding(.trailing, 3)
        .background(Color.primary.opacity(isCopied ? 0.13 : 0.07), in: Capsule())
        .overlay(Capsule().stroke(isCopied ? Palette.accent.opacity(0.5) : Palette.line, lineWidth: 0.75))
    }

    private func add() {
        let cleaned = OpenAIWire.cleanDictionary([word])
        guard let value = cleaned.first, settings.preferences.dictionary.count < 80 else {
            validation = tr("An entry cannot contain line breaks or angle brackets and is at most 80 characters long. The dictionary holds up to 80 entries."); return
        }
        guard !settings.preferences.dictionary.contains(value) else { validation = tr("This entry is already in the dictionary."); return }
        settings.preferences.dictionary.append(value)
        word = ""; validation = ""
    }
}

private struct GeneralGroup: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var updater: Updater

    var body: some View {
        SettingsGroup(tr("General")) {
            Row(tr("Language")) {
                GlassMenu(label: tr("Language"), selection: $settings.preferences.language,
                          // Each language by its own name, the same in every language.
                          options: [(Localization.followSystem, tr("Follow macOS"))]
                            + Localization.Language.allCases.map { ($0.rawValue, $0.nativeName) })
            }
            Row(tr("Launch at login")) {
                Toggle(tr("Launch at login"), isOn: Binding(
                    get: { settings.loginItemEnabled },
                    set: { settings.setLoginItem($0) }
                )).toggleStyle(.switch).labelsHidden().controlSize(.mini)
            }
            if !settings.loginMessage.isEmpty { hint(settings.loginMessage, warning: true) }
            Row(tr("Install updates automatically"), info: tr("Checks for new versions in the background. Once an update's hash and digital signature are verified, out replaces itself and restarts while idle.")) {
                Toggle(tr("Install updates automatically"), isOn: $settings.preferences.autoUpdate).toggleStyle(.switch).labelsHidden().controlSize(.mini)
            }
            HStack(alignment: .center, spacing: 6) {
                CopyableText(updater.status, font: .system(size: 11), color: Palette.muted)
                Spacer(minLength: 0)
                Button(updater.working ? tr("Checking…") : tr("Check for updates")) { updater.check(manual: true) }
                    .buttonStyle(QuietButton()).disabled(updater.working)
            }
            Divider()
            HStack {
                hint(tr("The last 100 finished records are kept on this Mac."))
                Spacer(minLength: 0)
                Button(tr("Quit out")) { NSApp.terminate(nil) }.buttonStyle(QuietButton())
            }
        }
    }
}
