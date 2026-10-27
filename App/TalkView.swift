import NexlineCore
import SwiftUI

struct TalkView: View {
    @StateObject private var model = TalkModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false
    @State private var showLog = false
    @State private var draft = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ConversationList(lines: model.lines)
                Divider()
                VStack(spacing: 10) {
                    if model.phase != .off {
                        HStack(spacing: 10) {
                            Text(model.phase.rawValue).font(.headline)
                            MeterRow(meter: model.meter)
                        }
                        if !model.hearing.isEmpty {
                            Text(model.hearing)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .lineLimit(3)
                        }
                    }
                    HStack(alignment: .bottom, spacing: 10) {
                        TextField(model.keysSet ? "Message Nexa" : "Add Nexa's token in Settings", text: $draft)
                            .textFieldStyle(.roundedBorder)
                            .submitLabel(.send)
                            .onSubmit(sendDraft)
                            .disabled(!model.keysSet)
                        Button(action: sendDraft) {
                            Image(systemName: model.typing ? "ellipsis.circle" : "arrow.up.circle.fill").font(.title)
                        }
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.keysSet)
                        Button {
                            Task { await model.toggle() }
                        } label: {
                            Image(systemName: model.phase == .off ? "mic.circle.fill" : "stop.circle.fill")
                                .font(.largeTitle)
                                .foregroundStyle(model.phase == .off ? Color.accentColor : Color.red)
                        }
                        .disabled(model.phase == .starting || model.checking || (model.phase == .off && !model.keysSet))
                    }
                }
                .padding(12)
            }
            .navigationTitle("Nexa")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Log") { showLog = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings") { showSettings = true }
                        .disabled(model.phase != .off)
                }
            }
            .sheet(isPresented: $showSettings, onDismiss: { model.keysChanged() }) {
                SettingsView()
            }
            .sheet(isPresented: $showLog) {
                LogView(model: model)
            }
        }
        .onAppear { model.startSync() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.startSync() } else { model.stopSync() }
        }
    }

    private func sendDraft() {
        let text = draft
        draft = ""
        model.sendTyped(text)
    }
}

/// The shared conversation, newest at the bottom, following new text as it streams in.
private struct ConversationList: View {
    let lines: [TalkModel.Line]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if lines.isEmpty {
                        Text("Talk or type. Nexa's conversation with the kiosk shows up here.")
                            .foregroundStyle(.secondary)
                            .padding(.top, 40)
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(lines) { line in
                        MessageRow(line: line).id(line.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(12)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: lines.last?.text) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }
}

/// Check connection, Copy log and the log itself (what Zé pastes back).
private struct LogView: View {
    @ObservedObject var model: TalkModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("Check connection") { Task { await model.checkConnection() } }
                        .disabled(model.phase != .off || model.checking || !model.keysSet)
                    if model.checking { ProgressView("Checking…") }
                    Button("Copy log") { model.copyLog() }
                        .disabled(model.log.isEmpty)
                } footer: {
                    Text("Checks Nexa's token and the Deepgram key, then each voice says one sentence. "
                         + "It doesn't talk to Nexa, so nothing shows up on the kiosk.")
                }
                Section("Log") {
                    ForEach(model.log.reversed()) { line in
                        Text(line.text).font(.caption.monospaced())
                    }
                }
            }
            .navigationTitle("Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// Who speaks and who listens, plus the keys (pasted from a password manager; they go to this iPhone's
/// Keychain only).
private struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(VoiceChoice.storageKey) private var voice = VoiceChoice.xai
    @AppStorage(EarsChoice.storageKey) private var ears = EarsChoice.deepgram
    @AppStorage(AppLauncher.settingKey) private var appLaunch = true
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var xaiKey = ""
    @State private var deepgramKey = ""
    @State private var refresh = 0

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Voice", selection: $voice) {
                        ForEach(VoiceChoice.allCases) { Text($0.label).tag($0) }
                    }
                } header: {
                    Text("Nexa speaks with")
                } footer: {
                    Text("If it fails: " + voice.chain.dropFirst().map(\.name).joined(separator: ", then ") + ".")
                }

                Section {
                    Picker("Listening", selection: $ears) {
                        ForEach(EarsChoice.allCases) { Text($0.label).tag($0) }
                    }
                } header: {
                    Text("Nexa listens with")
                } footer: {
                    Text(ears == .deepgram ? "If it fails: the iPhone." : "On the iPhone, works offline.")
                }

                Section {
                    Toggle("Open apps from Nexa's replies", isOn: $appLaunch)
                } footer: {
                    Text("In voice mode, \"play X on YouTube\" opens YouTube by itself. In typed chat it's a card you tap.")
                }

                Section {
                    TextField("Client ID", text: $clientID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Client Secret", text: $clientSecret)
                } header: {
                    Text("Nexa: Cloudflare Access token")
                } footer: {
                    Text("\(status(.nexaClientID)) · \(status(.nexaClientSecret))")
                }

                Section {
                    SecureField("xAI API key", text: $xaiKey)
                } header: {
                    Text("xAI: Nexa's voice")
                } footer: {
                    Text(status(.xaiKey))
                }

                Section {
                    SecureField("Deepgram API key", text: $deepgramKey)
                } header: {
                    Text("Deepgram: listening and backup voice")
                } footer: {
                    Text(status(.deepgramKey))
                }

                Section {
                    Button("Delete all keys", role: .destructive) {
                        for key in Keychain.Key.allCases { Keychain.set(key, "") }
                        refresh += 1
                    }
                } footer: {
                    Text("An empty field keeps what's saved. Keys stay on this iPhone, never in backups. "
                         + "Only Nexa's token is required; without the others the fallbacks take over.")
                }
            }
            .id(refresh)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save(.nexaClientID, clientID)
                        save(.nexaClientSecret, clientSecret)
                        save(.xaiKey, xaiKey)
                        save(.deepgramKey, deepgramKey)
                        dismiss()
                    }
                }
            }
        }
    }

    private func status(_ key: Keychain.Key) -> String {
        let name: String
        switch key {
        case .nexaClientID: name = "ID"
        case .nexaClientSecret: name = "secret"
        case .xaiKey, .deepgramKey: name = "key"
        }
        return "\(name): \(Keychain.get(key) == nil ? "not set" : "saved")"
    }

    private func save(_ key: Keychain.Key, _ value: String) {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Keychain.set(key, value)
    }
}

private struct MeterRow: View {
    @ObservedObject var meter: Meter

    var body: some View {
        LevelBar(db: meter.db, threshold: meter.threshold)
    }
}

private struct LevelBar: View {
    let db: Float
    let threshold: Float

    /// -80…0 dBFS across the width.
    private func x(_ value: Float, _ width: CGFloat) -> CGFloat {
        CGFloat((min(max(value, -80), 0) + 80) / 80) * width
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(db > threshold ? Color.orange : Color.green)
                    .frame(width: x(db, geo.size.width))
                Rectangle()
                    .fill(.white)
                    .frame(width: 2)
                    .offset(x: x(threshold, geo.size.width) - 1)
            }
        }
        .frame(height: 14)
        .animation(.linear(duration: 0.05), value: db)
    }
}
