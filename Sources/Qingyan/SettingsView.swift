import AppKit
import SwiftUI
import UniformTypeIdentifiers
import QingyanCore

/// Everything that is set once and then left alone. Lives inside the panel's side drawer so
/// opening and closing Settings glides sideways with the same 120fps smoothness as History.
struct SettingsPage: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var controller: DictationController

    var body: some View {
        let prefs = settings.preferences
        let speech = Platform.named(prefs.speechPlatform)
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
            if speech.wire == .onDevice { OnDeviceGroup(model: prefs.speechModel, models: OnDeviceModels.shared) }
            KeysGroup(settings: settings)
            InputGroup(settings: settings, controller: controller, microphones: controller.microphones)
            DictionaryGroup(settings: settings, controller: controller)
            ClipboardGroup(settings: settings, history: controller.clipboard)
            // Only where the Monitor helper is installed: the Dashboard reaches this Mac through it.
            if [.ready, .stopped, .noTunnel].contains(controller.helperState) { DashboardGroup(settings: settings) }
            GeneralGroup(settings: settings, controller: controller, updater: controller.updater)
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
    words(text, color: warning ? Color.orange : Palette.muted)
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
                .glassField().autocorrectionDisabled()
        }
        if !onMac { KeyChoice(settings: settings, speech: speech, platform: platform) }
    }
}

/// Which saved key a job uses first, when its service has several, and the keys it tries in turn
/// when the one before fails.
private struct KeyChoice: View {
    @ObservedObject var settings: SettingsStore
    let speech: Bool
    let platform: Platform
    /// At most this many keys are tried after the first.
    private static let most = 3

    var body: some View {
        let own = settings.keys(on: platform.id)
        let first = settings.firstKey(speech: speech, on: platform.id)
        let chain = settings.fallbackKeys(speech: speech, after: first)
        let able = settings.preferences.keys.filter { speech || Platform.named($0.platform).writes }
        if own.isEmpty {
            hint(platform == .custom ? tr("No endpoint is saved yet. Add one under API keys.")
                                     : tr("No %@ key is saved yet. Add one under API keys.", platform.name), warning: true)
        } else if own.count > 1 {
            Row(tr("API key")) {
                GlassMenu(label: tr("API key"), selection: Binding(get: { first?.id ?? "" }, set: { choose($0) }),
                          options: own.map { ($0.id, settings.label($0, service: false)) })
            }
        }
        ForEach(0..<min(chain.count + 1, Self.most), id: \.self) { index in
            let others = able.filter { $0.id != first?.id && !chain.prefix(index).contains($0) }
            if !others.isEmpty {
                let label = index == 0 ? tr("If it fails") : tr("If that fails too")
                Row(label, info: index == 0 ? tr("When the key before it fails (the key is invalid, its quota is used up or it is limited, or its service reports an error), the same request goes to this key. A key of another service uses the model last chosen for that service here, or its first one.") : nil) {
                    GlassMenu(label: label, selection: Binding(get: { index < chain.count ? chain[index].id : "" },
                                                               set: { place($0, at: index, in: chain) }),
                              options: [("", tr("None"))] + others.map { ($0.id, settings.label($0)) })
                }
            }
        }
    }

    private func choose(_ id: String) {
        if speech { settings.preferences.speechKey = id } else { settings.preferences.textKey = id }
    }

    /// Puts `id` at `index` of the fallbacks; none there ends the list at that place. A key named
    /// twice keeps its first place.
    private func place(_ id: String, at index: Int, in chain: [APIKey]) {
        var ids = chain.map(\.id)
        if id.isEmpty { ids = Array(ids.prefix(index)) }
        else if index < ids.count { ids[index] = id }
        else { ids.append(id) }
        var seen = Set<String>()
        ids = ids.filter { seen.insert($0).inserted }
        if speech { settings.preferences.speechFallbacks = ids } else { settings.preferences.textFallbacks = ids }
    }
}

/// Every saved API key, each with its check and its removal, and the form that adds one for any
/// service; for Model Studio and the user's own endpoint, the address it works with as well.
private struct KeysGroup: View {
    @ObservedObject var settings: SettingsStore
    @State private var platform = Platform.openAI.id
    @State private var name = ""
    @State private var address = ""
    @State private var secret = ""
    @State private var checking: Set<String> = []
    @State private var removing: APIKey?

    var body: some View {
        let chosen = Platform.named(platform)
        let saving = settings.savingKeys.contains(SettingsStore.newKeyNote)
        SettingsGroup(tr("API keys")) {
            ForEach($settings.preferences.keys) { $key in
                row($key)
                Divider()
            }
            GlassMenu(label: tr("Service"), selection: $platform,
                      options: Platform.all.filter { $0.wire != .onDevice }.map { ($0.id, $0.name) })
            if chosen == .alibaba || chosen == .custom { addressField($address, platform: chosen) }
            TextField(tr("Name, to tell keys apart (optional)"), text: $name)
                .glassField().autocorrectionDisabled()
            SecureField(tr("API key (%@)", tr(chosen.keyHint)), text: $secret)
                .glassField().onSubmit { save() }
            Button(saving ? tr("Saving…") : tr("Save")) { save() }
                .buttonStyle(SolidButton()).disabled(!ready || saving)
            if let message = settings.keyMessages[SettingsStore.newKeyNote], !message.isEmpty {
                words(message, color: Palette.ink)
            }
        }
        // What was typed for one service never goes to another.
        .onChange(of: platform) { address = ""; secret = "" }
        .alert(tr("Remove the %@ API key from the system keychain?", removing.map { settings.label($0) } ?? ""),
               isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button(tr("Cancel"), role: .cancel) { removing = nil }
            Button(tr("Remove"), role: .destructive) {
                if let key = removing { settings.removeKey(key.id) }
                removing = nil
            }
        }
    }

    /// Whether the form holds what a save takes: a secret, or for the user's own endpoint an address.
    private var ready: Bool {
        let chosen = Platform.named(platform)
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if chosen == .custom { return Platform.normalized(base: address) != nil }
        if chosen == .alibaba, Platform.alibabaBase(address) == nil { return false }
        return !trimmed.isEmpty
    }

    private func row(_ key: Binding<APIKey>) -> some View {
        let value = key.wrappedValue
        let service = Platform.named(value.platform)
        let busy = settings.savingKeys.contains(value.id)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(settings.label(value)).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button(checking.contains(value.id) ? tr("Verifying…") : tr("Verify")) { check(value) }
                    .buttonStyle(QuietButton()).disabled(!settings.usable(value) || checking.contains(value.id) || busy)
                Button(tr("Remove")) { removing = value }.buttonStyle(QuietButton()).disabled(busy)
            }
            if service == .alibaba || service == .custom { addressField(key.address, platform: service) }
            if let message = settings.keyMessages[value.id], !message.isEmpty {
                words(message, color: Palette.ink)
            }
        }
    }

    /// Model Studio's host, or the user's own endpoint's address, with what is wrong with it.
    @ViewBuilder
    private func addressField(_ text: Binding<String>, platform: Platform) -> some View {
        let value = text.wrappedValue.trimmingCharacters(in: .whitespaces)
        if platform == .alibaba {
            TextField(tr("Address, such as dashscope-intl.aliyuncs.com"), text: text)
                .glassField().autocorrectionDisabled()
            hint(tr("Leave empty for the Singapore region. A key works only with the address of the region it was created in; for another region or a workspace's own domain, enter that address."))
            if !value.isEmpty, Platform.alibabaBase(value) == nil {
                hint(tr("Enter a host name, such as dashscope-intl.aliyuncs.com, or an https:// address."), warning: true)
            }
        } else {
            TextField(tr("Endpoint URL, such as https://example.com/v1"), text: text)
                .glassField().autocorrectionDisabled()
            if !value.isEmpty, Platform.normalized(base: value) == nil {
                hint(tr("Use an https:// address. http:// is accepted only for this Mac, a local network host name or an IP address."), warning: true)
            }
            if let base = Platform.normalized(base: value), Platform.isPlain(base) {
                hint(tr("This connection is not encrypted: the key, audio and text cross the network in plain text."), warning: true)
            }
        }
    }

    private func save() {
        guard ready else { return }
        settings.addKey(platform: platform, name: name, address: address, secret: secret)
        secret = ""; name = ""; address = ""
    }

    /// Tries the key with the models it would be asked for now: where it is a job's first key or one
    /// of its fallbacks, that job's model there; a key no job uses, its service's model list alone.
    private func check(_ key: APIKey) {
        checking.insert(key.id)
        let id = key.id
        let platform = Platform.named(key.platform)
        Task { @MainActor in
            defer { checking.remove(id) }
            do {
                let service = try await settings.serviceAsync(platform, key: key)
                let prefs = settings.preferences
                let polishing = prefs.dictationStyle != .raw
                let routedSpeech = settings.routes(speech: true, platform: prefs.speechPlatform, model: prefs.speechModel)
                    .first { $0.key?.id == id }?.model
                let textModel = polishing ? settings.routes(speech: false, platform: prefs.textPlatform, model: prefs.textModel)
                    .first { $0.key?.id == id }?.model : nil
                // A key no job uses yet, of a service spoken to in its own way, is checked as for its
                // first speech model: its secret never goes out as a bearer token to a model list.
                let unused = routedSpeech == nil && textModel == nil && (platform.wire == .own || platform.wire == .alibaba)
                let speechModel = unused ? platform.speechModels.first : routedSpeech
                // A service spoken to in its own way proves the key over its live socket; one that
                // takes the finished recording is proven by a recording. Neither lists its speech models.
                let own = speechModel.flatMap { platform.own(model: $0) }
                if own == .live, let model = speechModel, let wire = platform.liveWire(model: model, base: service.base) {
                    try await LiveSocketTranscriber.probe(wire: wire, key: service.key, model: model, name: platform.name)
                }
                if own != nil && textModel == nil {
                    let proven: Bool = own == .live && (speechModel.flatMap { platform.liveWire(model: $0, base: service.base)?.provesKey(model: $0) } ?? false)
                    let valid: String = tr("The API key is valid, and the chosen models are available.")
                    let untested: String = tr("This service does not list its models. Make a recording to test the connection.")
                    settings.keyMessages[id] = proven ? valid : untested
                    return
                }
                // Model Studio proves the key and the speech model over its realtime socket;
                // the speech model's name is not looked up in the model list.
                if platform.wire == .alibaba, let model = speechModel, own == nil {
                    try await QwenRealtimeTranscriber.probe(key: service.key,
                        endpoint: Platform.realtimeURL(base: service.base, model: model))
                }
                // Proven by the socket and nothing else wanted; a key kept only for polishing is
                // still checked against the model list below.
                if platform.wire == .alibaba && speechModel != nil && textModel == nil {
                    settings.keyMessages[id] = tr("The API key is valid, and the chosen models are available."); return
                }
                guard let models = try await service.models() else {
                    settings.keyMessages[id] = tr("This service does not list its models. Make a recording to test the connection."); return
                }
                var wanted: [String] = []
                if let model = speechModel, platform.wire != .alibaba, own == nil { wanted.append(model) }
                if let model = textModel { wanted.append(model) }
                let missing = wanted.filter { !models.contains($0) }
                let custom = platform == .custom
                // The list is joined the way each language writes one: ", ", or an ideographic comma in Chinese and Japanese.
                let separator = Localization.current.listSeparator
                let absent = missing.map { $0.isEmpty ? tr("(blank)") : $0 }.joined(separator: separator)
                settings.keyMessages[id] = wanted.isEmpty
                    ? (custom ? tr("The endpoint answers.") : tr("The API key is valid."))
                    : missing.isEmpty
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
        SettingsGroup(tr("Audio and shortcut")) {
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
                words(controller.shortcutStatus,
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
            Divider()
            OutMicRow(link: controller.microphone)
        }
    }
}

/// out Mic on this Mac: installed once, with the Mac's password (user 2026-11-27: a virtual
/// microphone on the Mac worked from another one, for meetings).
private struct OutMicRow: View {
    @ObservedObject var link: MicrophoneLink

    var body: some View {
        Row(tr("out Mic"), info: tr("Lets apps on this Mac use the microphone of another of your Macs. On that Mac, the microphone button beside this Mac in Multiple Macs lends it here: out Mic becomes this Mac's input, and whenever an app here records, that Mac's microphone turns on. When it is taken back, the input goes back to what it was. Installing asks for this Mac's password, also when that button is first clicked; the sound of every app stops for a moment.")) {
            HStack(spacing: 6) {
                if link.installing {
                    ProgressView().controlSize(.mini)
                } else {
                    switch link.driver {
                    case .absent:
                        Button(tr("Install")) { link.install() }.buttonStyle(QuietButton())
                    case .older:
                        Button(tr("Update")) { link.install() }.buttonStyle(QuietButton())
                    case .current:
                        Text(tr("Installed")).font(.system(size: 11)).foregroundStyle(Palette.muted)
                        Button(tr("Remove")) { link.install(remove: true) }.buttonStyle(QuietButton())
                    }
                }
            }
        }
        .onAppear { link.refreshDriver() }
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
        .background(Color.primary.opacity(isCopied ? 0.13 : 0.07), in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).stroke(isCopied ? Palette.accent.opacity(0.5) : Palette.line, lineWidth: 0.75))
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

extension ClipboardHistory {
    /// One of `dayChoices` by name: here and in History's Keep and Clear.
    static func keptFor(_ days: Int) -> String {
        switch days {
        case 0: return tr("No time limit")
        case 1: return tr("1 day")
        default: return tr("%ld days", days)
        }
    }
}

/// What is copied on this Mac, kept for Control + Option + C (ClipboardHistory).
private struct ClipboardGroup: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var history: ClipboardHistory
    @State private var confirming = false

    var body: some View {
        let on = settings.preferences.clipHistory
        SettingsGroup(tr("Clipboard history"), detail: history.entries.isEmpty ? "" : history.entries.count == 1 ? tr("1 item") : tr("%ld items", history.entries.count)) {
            Row(tr("Keep what is copied"), info: tr("Text, images and files copied on this Mac are kept on this Mac, unencrypted. While Work across Macs is on, your other Macs in Multiple Macs keep them too (files by name alone), and this Mac keeps what is copied on them. Control + Option + C shows them over the app in front, and Return pastes the one chosen. Copied files also go on the Shelf, which the Macs in Multiple Macs share.")) {
                Toggle(tr("Keep what is copied"), isOn: $settings.preferences.clipHistory).toggleStyle(.switch).labelsHidden().controlSize(.mini)
            }
            if on {
                Row(tr("Keep up to")) {
                    GlassMenu(label: tr("Keep up to"), selection: $settings.preferences.clipLimit,
                              options: ClipboardHistory.limits.map { ($0, tr("%ld items", $0)) })
                }
                Row(tr("Keep for")) {
                    GlassMenu(label: tr("Keep for"), selection: $settings.preferences.clipDays,
                              options: ClipboardHistory.dayChoices.map { ($0, Self.days($0)) })
                }
                Divider()
                HStack(spacing: 6) {
                    Text(tr("Apps left out")).font(.system(size: 12))
                    Spacer(minLength: 2)
                    Button(tr("Add App…")) { addApp() }.buttonStyle(QuietButton())
                }
                ForEach(settings.preferences.clipIgnored, id: \.bundle) { app in
                    HStack(spacing: 6) {
                        Text(app.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 2)
                        Button { settings.preferences.clipIgnored.removeAll { $0.bundle == app.bundle } } label: {
                            Image(systemName: "xmark").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Palette.muted)
                                .frame(width: 18, height: 18).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(tr("Keep copies made in %@", app.name))
                        .accessibilityLabel(tr("Keep copies made in %@", app.name))
                    }
                }
                hint(tr("Never kept: copies made in Passwords, Keychain Access, 1Password, Bitwarden, KeePassXC, LastPass, Dashlane or Proton Pass, and anything an app marks as a password or as temporary."))
            }
            Divider()
            HStack(spacing: 6) {
                if confirming {
                    hint(settings.sendsRemotely ? tr("Remove every item but the pinned ones, here and on your other Macs?") : tr("Remove every item but the pinned ones?"))
                    Spacer(minLength: 2)
                    Button(tr("Cancel")) { confirming = false }.buttonStyle(QuietButton())
                    Button(tr("Remove")) { history.clear(); confirming = false }.buttonStyle(SolidButton())
                } else {
                    hint(tr("Pinned items stay until they are removed."))
                    Spacer(minLength: 2)
                    Button(tr("Clear")) { confirming = true }.buttonStyle(QuietButton())
                        .disabled(history.entries.allSatisfy(\.pinned))
                }
            }
        }
    }

    static func days(_ days: Int) -> String { ClipboardHistory.keptFor(days) }

    /// An app chosen in the Applications folder, by its bundle identifier.
    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = tr("Add")
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK else { return }
            MainActor.assumeIsolated {
                for url in panel.urls {
                    guard let bundle = Bundle(url: url)?.bundleIdentifier,
                          !settings.preferences.clipIgnored.contains(where: { $0.bundle == bundle }) else { continue }
                    let name = FileManager.default.displayName(atPath: url.path)
                    settings.preferences.clipIgnored.append(IgnoredApp(bundle: bundle, name: name.hasSuffix(".app") ? String(name.dropLast(4)) : name))
                }
            }
        }
    }
}

/// Whether the Dashboard may list this Mac's History and clipboard history (HistoryFeed).
private struct DashboardGroup: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        SettingsGroup(tr("Dashboard")) {
            Row(tr("Show on the Dashboard"), info: tr("When on, the Dashboard's Clipboard tab can list this Mac's History and clipboard history, read through the Monitor helper on this Mac while the tab is open. It gets text, file names and image sizes, not the files or images. When off, it is told only that this is off.")) {
                Toggle(tr("Show on the Dashboard"), isOn: $settings.preferences.showOnDashboard).toggleStyle(.switch).labelsHidden().controlSize(.mini)
            }
        }
    }
}

struct GeneralGroup: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var controller: DictationController
    @ObservedObject var updater: Updater

    /// Whether the Monitor helper is on this Mac, and its version (user 2026-11-27).
    private var helper: String {
        switch controller.helperState {
        case .checking: return tr("Checking…")
        case .missing: return tr("Not installed on this Mac")
        case .stopped: return tr("Installed on this Mac, not running")
        case .noTunnel, .ready:
            return controller.helperVersion.isEmpty ? tr("Installed on this Mac") : tr("Installed on this Mac · %@", controller.helperVersion)
        }
    }

    var body: some View {
        SettingsGroup(tr("General")) {
            Row(tr("Monitor helper")) {
                Text(helper).font(.system(size: 12)).foregroundStyle(Palette.muted).lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
            }
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
            if settings.hasCameraHousing {
                Toggle(isOn: $settings.preferences.shelfAtCamera) {
                    Text(tr("Show the Shelf at the camera cutout")).font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                }.toggleStyle(.switch).controlSize(.mini)
            }
            Row(tr("Install updates automatically"), info: tr("Checks for new versions in the background. Once an update's hash and digital signature are verified, out replaces itself and restarts while idle.")) {
                Toggle(tr("Install updates automatically"), isOn: $settings.preferences.autoUpdate).toggleStyle(.switch).labelsHidden().controlSize(.mini)
            }
            HStack(alignment: .center, spacing: 6) {
                words(updater.status)
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
