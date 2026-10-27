import NexlineCore
import SwiftUI

struct TalkView: View {
    @StateObject private var model = TalkModel()
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 14) {
                        Text(model.phase.rawValue)
                            .font(.largeTitle.bold())
                        if !model.hearing.isEmpty {
                            Text(model.hearing)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        MeterRow(meter: model.meter)
                        Button(model.phase == .off ? "Start talking" : "Stop") {
                            Task { await model.toggle() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.phase == .starting || model.checking || (model.phase == .off && !model.keysSet))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                } footer: {
                    Text(model.keysSet
                         ? "Talk, pause, and Nexa answers. Talk over her to cut in."
                         : "Add Nexa's token first (Settings, top right).")
                }

                if !model.lines.isEmpty {
                    Section("Conversation") {
                        ForEach(model.lines) { line in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(line.fromUser ? "You" : "Nexa")
                                    .font(.caption.bold())
                                    .foregroundStyle(line.fromUser ? Color.secondary : Color.accentColor)
                                Text(line.text.isEmpty ? "…" : line.text)
                            }
                        }
                    }
                }

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
            .navigationTitle("Nexa")
            .toolbar {
                Button("Settings") { showSettings = true }
                    .disabled(model.phase != .off)
            }
            .sheet(isPresented: $showSettings, onDismiss: { model.keysChanged() }) {
                SettingsView()
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
                    Text("Deepgram: listening")
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
