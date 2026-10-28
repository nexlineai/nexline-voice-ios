import SwiftUI

/// Each agent's voice and model, how voice behaves, and the keys (they go to this iPhone's Keychain only).
struct SettingsView: View {
    @EnvironmentObject private var talk: TalkModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Prefs.bargeIn) private var bargeIn = true
    @AppStorage(Prefs.autoplayMedia) private var autoplayMedia = true
    @AppStorage(AppLauncher.settingKey) private var appLaunch = true
    @AppStorage(Prefs.standby) private var standby = false
    @AppStorage(Prefs.conversationWindow) private var window = 3
    @AppStorage(Prefs.speechLanguage) private var language = SpeechLanguage.en.rawValue
    @AppStorage(EarsChoice.storageKey) private var ears = EarsChoice.deepgram
    @State private var expanded: Bot?
    @State private var keys: [Keychain.Key: String] = [:]
    @State private var confirmClearAll = false
    @State private var haAddress = UserDefaults.standard.string(forKey: HAClient.urlKey) ?? ""
    @State private var haStatus: String?
    @State private var haTesting = false
    @State private var refresh = 0

    var body: some View {
        NavigationStack {
            Form {
                Section("Agents") {
                    ForEach(Bot.allCases) { bot in
                        BotSettings(bot: bot, expanded: $expanded, key: optionalBinding(bot.key))
                    }
                }

                Section {
                    Toggle("Talk over her to interrupt", isOn: $bargeIn)
                    Toggle("Play mixes as soon as they arrive", isOn: $autoplayMedia)
                    Toggle("Let her open apps", isOn: $appLaunch)
                    Toggle("Start voice mode in standby", isOn: $standby)
                    Picker("Conversation window", selection: $window) {
                        Text("Off").tag(0)
                        Text("1 min").tag(1)
                        Text("3 min").tag(3)
                        Text("5 min").tag(5)
                        Text("10 min").tag(10)
                    }
                } header: {
                    Text("Voice")
                } footer: {
                    Text("Standby: she only answers sentences that start with her name; after that the conversation window "
                         + "keeps her listening without it. You can still tap the orb to stop her. "
                         + "\"Play X on YouTube\" opens YouTube by itself in voice mode; in chat it's a card to tap.")
                }

                Section {
                    Picker("Language", selection: $language) {
                        ForEach(SpeechLanguage.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    Picker("Listening", selection: $ears) {
                        ForEach(EarsChoice.allCases) { Text($0.label).tag($0) }
                    }
                } header: {
                    Text("Your voice")
                } footer: {
                    Text("One language at a time; English knows the agents' names best. " + earsNote)
                }

                Section {
                    KeyField(title: "Client ID", text: binding(.nexaClientID), secure: false)
                    KeyField(title: "Client Secret", text: binding(.nexaClientSecret))
                } header: {
                    Text("Nexa: Cloudflare Access token")
                } footer: {
                    Text("\(status(.nexaClientID)) · \(status(.nexaClientSecret))")
                }

                Section {
                    TextField("Address, like https://home.example.com", text: $haAddress)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    KeyField(title: "Long-lived access token", text: binding(.haToken))
                    Button {
                        haTesting = true
                        Task {
                            haStatus = await HAClient.test(address: haAddress, token: keys[.haToken])
                            haTesting = false
                        }
                    } label: {
                        HStack {
                            Text("Test connection")
                            Spacer()
                            if haTesting { ProgressView() }
                        }
                    }
                    .disabled(haTesting)
                    if let haStatus {
                        Text(haStatus)
                            .font(.footnote)
                            .foregroundStyle(haStatus.hasPrefix("Connected") ? Theme.teal : Theme.coral)
                    }
                } header: {
                    Text("Home Assistant")
                } footer: {
                    Text("Token \(status(.haToken)). Create one on your Home Assistant profile page, under "
                         + "Long-lived access tokens. Without an address and token, the app reaches Home Assistant "
                         + "through the kiosk.")
                }

                Section {
                    KeyField(title: "xAI API key", text: binding(.xaiKey))
                    KeyField(title: "Deepgram API key", text: binding(.deepgramKey))
                } header: {
                    Text("Voices and listening")
                } footer: {
                    Text("xAI \(status(.xaiKey)) · Deepgram \(status(.deepgramKey)). "
                         + "An empty field keeps what's saved. Keys stay on this iPhone, never in backups.")
                }

                Section {
                    Button("Clear all chats", role: .destructive) { confirmClearAll = true }
                } footer: {
                    Text("Carapava's and Mamadona's chats, and the copy of Nexa's on this phone. The kiosk keeps hers.")
                }

                Section {
                    NavigationLink("Diagnostics") { LogView() }
                    LabeledContent("Build", value: build)
                }
            }
            .id(refresh)
            .scrollContentBackground(.hidden)
            .background(AmbientBackground(accent: Theme.teal, intensity: 0.5))
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        for (key, value) in keys where !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Keychain.set(key, value)
                        }
                        let address = haAddress.trimmingCharacters(in: .whitespacesAndNewlines)
                        if address.isEmpty {
                            UserDefaults.standard.removeObject(forKey: HAClient.urlKey)
                        } else {
                            UserDefaults.standard.set(HAClient.normalized(address)?.absoluteString ?? address,
                                                      forKey: HAClient.urlKey)
                        }
                        Task { await HomeStore.shared.refresh(force: true) }
                        talk.keysChanged()
                        dismiss()
                    }
                }
            }
            .confirmationDialog("Clear all chats?", isPresented: $confirmClearAll, titleVisibility: .visible) {
                Button("Clear all", role: .destructive) {
                    for bot in Bot.allCases { ChatStore.shared.clear(bot) }
                    talk.reloadLines()
                }
            }
        }
    }

    private var earsNote: String {
        switch ears {
        case .deepgram: return "If Deepgram fails, the iPhone listens."
        case .iphone: return "On the iPhone, works offline."
        case .whisper:
            return "Whisper on Nexa's Jetson, only while it runs there: the iPhone hears when you finish, Whisper writes "
                + "the words (the iPhone's if Whisper is off). Carapava, Mamadona, music and Dutch use Deepgram."
        }
    }

    private var build: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    private func optionalBinding(_ key: Keychain.Key?) -> Binding<String> {
        Binding(get: { key.flatMap { keys[$0] } ?? "" },
                set: { if let key { keys[key] = $0 } })
    }

    private func binding(_ key: Keychain.Key) -> Binding<String> {
        Binding(get: { keys[key] ?? "" }, set: { keys[key] = $0 })
    }

    private func status(_ key: Keychain.Key) -> String {
        Keychain.get(key) == nil ? "not set" : "saved"
    }
}

private struct KeyField: View {
    let title: String
    @Binding var text: String
    var secure = true

    var body: some View {
        Group {
            if secure {
                SecureField(title, text: $text)
            } else {
                TextField(title, text: $text)
            }
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
    }
}

/// One agent: tap to open its voice engine, voice (tap a voice to hear it), model, and key.
private struct BotSettings: View {
    let bot: Bot
    @Binding var expanded: Bot?
    @Binding var key: String
    @EnvironmentObject private var talk: TalkModel
    @State private var voice: BotVoice
    @State private var model: String

    init(bot: Bot, expanded: Binding<Bot?>, key: Binding<String>) {
        self.bot = bot
        _expanded = expanded
        _key = key
        _voice = State(initialValue: BotVoice.current(bot))
        _model = State(initialValue: UserDefaults.standard.string(forKey: Prefs.modelKey(bot)) ?? "")
    }

    private var open: Bool { expanded == bot }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.snappy) { expanded = open ? nil : bot }
            } label: {
                HStack(spacing: 12) {
                    Avatar(bot: bot, size: 38, ring: 1.5)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(bot.name).font(.headline).foregroundStyle(bot.accent)
                        Text(summary).font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(open ? 180 : 0))
                        .foregroundStyle(Theme.muted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if open {
                Picker("Speaks with", selection: $voice.engine) {
                    // Kokoro runs on Nexa's Jetson, so only Nexa has it.
                    ForEach(VoiceChoice.allCases.filter { $0 != .kokoro || bot == .nexa }) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)

                if voice.engine == .kokoro {
                    Button("Hear it") {
                        Task { await talk.previewVoice(.kokoro, xai: voice.xai, deepgram: voice.deepgram) }
                    }
                    .font(.footnote.weight(.semibold))
                    .disabled(talk.checking || talk.phase != .off)
                    Text("Kokoro on the Jetson, in the kiosk's Kokoro voice. It only speaks while Kokoro is running "
                         + "there; the app never starts it.")
                        .font(.caption2).foregroundStyle(Theme.faint)
                }
                if voice.engine == .xai || voice.engine == .deepgram {
                    Text("Voice · tap to hear it").metaStyle(10, color: Theme.muted)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 8)], spacing: 8) {
                        ForEach(voice.engine == .xai ? BotVoice.xaiVoices : BotVoice.deepgramVoices, id: \.self) { id in
                            let selected = voice.engine == .xai ? voice.xai == id : voice.deepgram == id
                            Button {
                                if voice.engine == .xai { voice.xai = id } else { voice.deepgram = id }
                                Task { await talk.previewVoice(voice.engine, xai: voice.xai, deepgram: voice.deepgram) }
                            } label: {
                                Text(voice.engine == .xai ? id.capitalized : BotVoice.deepgramLabel(id))
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(selected ? Theme.bg0 : Theme.text)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .background(selected ? bot.accent : Theme.bg3, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(talk.checking || talk.phase != .off)
                        }
                    }
                    if voice.engine == .deepgram {
                        Text("Deepgram speaks English only and leaves out voice tags like [laughs].")
                            .font(.caption2).foregroundStyle(Theme.faint)
                    }
                }
                Text("If it fails: " + voice.engine.chain.dropFirst().map(\.name).joined(separator: ", then ") + ".")
                    .font(.caption2).foregroundStyle(Theme.faint)

                TextField("Model (default: \(bot.defaultModel))", text: $model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.footnote)
                    .padding(10)
                    .background(Theme.bg3, in: RoundedRectangle(cornerRadius: 10))

                if let keyName = bot.key {
                    SecureField("\(bot.name) API key (\(Keychain.get(keyName) == nil ? "not set" : "saved"))", text: $key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.footnote)
                        .padding(10)
                        .background(Theme.bg3, in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .padding(.vertical, 4)
        .onChange(of: voice) { _, new in
            let defaults = UserDefaults.standard
            defaults.set(new.engine.rawValue, forKey: BotVoice.engineKey(bot))
            defaults.set(new.xai, forKey: BotVoice.xaiKey(bot))
            defaults.set(new.deepgram, forKey: BotVoice.deepgramKey(bot))
        }
        .onChange(of: model) { _, new in
            UserDefaults.standard.set(new.trimmingCharacters(in: .whitespaces), forKey: Prefs.modelKey(bot))
        }
    }

    private var summary: String {
        let name: String
        switch voice.engine {
        case .xai: name = "xAI \(voice.xai.capitalized)"
        case .deepgram: name = "Deepgram \(BotVoice.deepgramLabel(voice.deepgram))"
        case .iphone: name = "iPhone voice"
        case .kokoro: name = "Kokoro on the Jetson"
        }
        let trimmed = model.trimmingCharacters(in: .whitespaces)
        return "\(bot.tagline) · \(name)" + (trimmed.isEmpty ? "" : " · \(trimmed)")
    }
}

/// Check connection, Copy log and the log itself.
struct LogView: View {
    @EnvironmentObject private var talk: TalkModel

    var body: some View {
        List {
            Section {
                Button("Check connection") { Task { await talk.checkConnection() } }
                    .disabled(talk.phase != .off || talk.checking || !talk.keysSet)
                if talk.checking { ProgressView("Checking…") }
                Button("Copy log") { talk.copyLog() }
                    .disabled(talk.log.isEmpty)
            } footer: {
                Text("Checks Nexa's token, the Deepgram key and the Jetson's Whisper, then each voice says one sentence. "
                     + "It doesn't talk to Nexa, so nothing shows up on the kiosk.")
            }
            Section("Log") {
                ForEach(talk.log.reversed()) { line in
                    Text(line.text).font(.caption.monospaced())
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg0)
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
    }
}
