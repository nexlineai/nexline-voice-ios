import NexlineCore
import PhotosUI
import SwiftUI
import UIKit

/// Chat with one agent (the RN chat screen): the conversation, her tool activity, and a dock to type, attach a
/// photo, or go live (the full voice pipeline right here: talk, and talk over her to interrupt).
struct ChatView: View {
    let bot: Bot
    @EnvironmentObject private var talk: TalkModel
    @EnvironmentObject private var router: Router
    @State private var draft = ""
    @State private var photo: Data?
    @State private var pickerItem: PhotosPickerItem?
    @State private var showPicker = false
    @State private var showCamera = false
    @State private var confirmClear = false
    @State private var notice: String?
    @FocusState private var typing: Bool

    private var lines: [TalkModel.Line] { talk.bot == bot ? talk.lines : ChatStore.shared.lines(bot) }
    private var live: Bool { talk.bot == bot && talk.phase != .off }
    private var working: Bool {
        talk.bot == bot && (talk.typing || talk.phase == .thinking || talk.phase == .speaking)
    }

    var body: some View {
        ZStack {
            AmbientBackground(accent: bot.accent, intensity: 0.8)
            VStack(spacing: 0) {
                NowPlayingBar().padding(.top, 4)
                conversation
                activity
                dock
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    Avatar(bot: bot, size: 30, ring: 1.5)
                    Text(bot.name).font(.headline).foregroundStyle(bot.accent)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { router.voice = bot } label: {
                    Image(systemName: "waveform.circle.fill").foregroundStyle(bot.accent)
                }
                .accessibilityLabel("Voice mode")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Home Assistant", systemImage: "house") { router.path.append(.devices) }
                    Button("Clear chat", systemImage: "trash", role: .destructive) { confirmClear = true }
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
        }
        .task { await talk.select(bot) }
        .onDisappear {
            // Leaving the chat ends live mode, unless voice mode took over on top of it.
            if talk.bot == bot && talk.phase != .off && router.voice == nil {
                Task { await talk.endVoice() }
            }
        }
        .photosPicker(isPresented: $showPicker, selection: $pickerItem, matching: .images)
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                photo = try? await item.loadTransferable(type: Data.self)
                pickerItem = nil
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraCapture { data in photo = data }.ignoresSafeArea()
        }
        .confirmationDialog("Clear the chat with \(bot.name)?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { Task { await talk.clearChat() } }
        } message: {
            Text(bot == .nexa ? "Nexa's conversation is shared, so the kiosk starts fresh too." : "She forgets it too.")
        }
        .sensoryFeedback(.impact(weight: .light, intensity: 0.6), trigger: lines.count)
    }

    // MARK: Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    if lines.isEmpty {
                        VStack(spacing: 12) {
                            Avatar(bot: bot, size: 96, ring: 2.5)
                            Text(bot.name).font(.title2.bold()).foregroundStyle(bot.accent)
                            Text(bot == .nexa ? "Type, or go live. Her conversation with the kiosk shows up here."
                                              : "Type, or go live.")
                                .font(.subheadline)
                                .foregroundStyle(Theme.muted)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.top, 80)
                        .padding(.horizontal, 32)
                    }
                    ForEach(lines) { line in
                        MessageBubble(line: line, bot: bot,
                                      pending: working && line.id == lines.last?.id,
                                      onRetry: retry(line))
                            .id(line.id)
                            .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                                    removal: .opacity))
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: lines.count)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: lines.last?.text) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: lines.count) { _, _ in
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    /// Retry a failed turn with the message before it.
    private func retry(_ line: TalkModel.Line) -> (() -> Void)? {
        guard line.failed, let index = lines.firstIndex(of: line),
              let question = lines[..<index].last(where: { $0.fromUser }) else { return nil }
        return { talk.sendTyped(question.text) }
    }

    // MARK: What is happening now

    @ViewBuilder private var activity: some View {
        VStack(alignment: .leading, spacing: 4) {
            if talk.bot == bot {
                ForEach(talk.tools) { tool in
                    Text("▸ \(tool.id) · \(tool.done ? "done" : "running…")")
                        .font(Theme.mono(10))
                        .tracking(0.8)
                        .foregroundStyle(Theme.teal)
                        .opacity(tool.done ? 0.55 : 1)
                        .lineLimit(1)
                }
                if live && !talk.hearing.isEmpty {
                    Text(talk.hearing)
                        .font(.subheadline.italic())
                        .foregroundStyle(bot.accent)
                        .lineLimit(3)
                }
            }
            if let notice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
                    .transition(.opacity)
            }
            if draft.hasPrefix("/") {
                CommandList(query: String(draft.dropFirst())) { command in
                    draft = ""
                    run(command)
                }
            }
            if let photo, let image = UIImage(data: photo) {
                HStack(spacing: 10) {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: 46, height: 46)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    Text("Photo ready. Add a question or just send.")
                        .font(.footnote).foregroundStyle(Theme.muted)
                    Spacer()
                    Button { self.photo = nil } label: {
                        Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(Theme.muted)
                    }
                    .buttonStyle(.plain)
                }
                .padding(8)
                .glassCard(cornerRadius: 14)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.snappy, value: talk.tools)
    }

    // MARK: Dock

    private var dock: some View {
        VStack(spacing: 8) {
            if live { LiveBar(bot: bot) }
            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    Button("Photo Library", systemImage: "photo.on.rectangle") { showPicker = true }
                    Button("Camera", systemImage: "camera") { showCamera = true }
                } label: {
                    Image(systemName: "plus")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(Theme.muted)
                        .frame(width: 44, height: 44)
                }
                TextField(live ? "type to cut in" : "message or /command", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($typing)
                    .foregroundStyle(Theme.text)
                    .padding(.vertical, 11)
                if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || photo != nil {
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(Theme.bg0)
                            .frame(width: 44, height: 44)
                            .background(bot.accent, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .transition(.scale.combined(with: .opacity))
                } else if !live {
                    Button {
                        typing = false
                        Task { await talk.startVoice(standby: false) }
                    } label: {
                        Image(systemName: "mic.fill")
                            .font(.title3)
                            .foregroundStyle(bot.accent)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Talk (live)")
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .glassEffect(Glass.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .animation(.snappy, value: draft.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("/") && photo == nil {
            draft = ""
            run(text)
            return
        }
        talk.sendTyped(text, photo: photo)
        draft = ""
        photo = nil
    }

    // MARK: Commands

    private func run(_ raw: String) {
        let parts = raw.split(separator: " ").map(String.init)
        switch parts.first ?? "" {
        case "/clear": confirmClear = true
        case "/stop": talk.hush()
        case "/voice": router.voice = bot
        case "/live": Task { if live { await talk.endVoice() } else { await talk.startVoice(standby: false) } }
        case "/home": router.path.append(.devices)
        case "/lang":
            if let code = parts.dropFirst().first?.prefix(2).lowercased(), let language = SpeechLanguage(rawValue: code) {
                UserDefaults.standard.set(language.rawValue, forKey: Prefs.speechLanguage)
                show("Speech language: \(language.label). Applies the next time voice starts.")
            } else {
                show("Use /lang en, /lang pt or /lang nl")
            }
        default:
            show(CommandList.commands.map { "\($0.name)  \($0.help)" }.joined(separator: "\n"))
        }
    }

    private func show(_ text: String) {
        withAnimation { notice = text }
        Task {
            try? await Task.sleep(for: .seconds(5))
            withAnimation { if notice == text { notice = nil } }
        }
    }
}

/// The live (hands-free) bar: what she is doing, a level line, and stop.
private struct LiveBar: View {
    let bot: Bot
    @EnvironmentObject private var talk: TalkModel

    var body: some View {
        HStack(spacing: 12) {
            TimelineView(.animation) { _ in
                let level = talk.phase == .speaking
                    ? talk.levels.speech(at: ProcessInfo.processInfo.systemUptime)
                    : (talk.phase == .listening ? talk.levels.mic : 0)
                Circle()
                    .fill(talk.phase == .listening ? bot.accent : Theme.muted)
                    .frame(width: 12, height: 12)
                    .scaleEffect(1 + CGFloat(level) * 0.8)
                    .shadow(color: bot.accent.opacity(0.8), radius: CGFloat(level) * 8)
            }
            .frame(width: 24, height: 24)
            Text(label)
                .font(Theme.mono(11, weight: .bold))
                .tracking(1)
                .foregroundStyle(bot.accent)
                .lineLimit(1)
            Spacer()
            Button {
                Task { await talk.endVoice() }
            } label: {
                Image(systemName: "stop.fill").font(.headline).foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Theme.danger, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .glassEffect(Glass.regular.tint(bot.accent.opacity(0.15)), in: Capsule())
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var label: String {
        if talk.muted { return "MUTED" }
        switch talk.phase {
        case .off, .starting: return "STARTING…"
        case .listening: return "LISTENING · JUST TALK"
        case .thinking: return "THINKING…"
        case .speaking: return "SPEAKING · TALK TO CUT IN"
        }
    }
}

/// Slash commands, filtered as you type.
private struct CommandList: View {
    struct Command {
        let name: String
        let help: String
    }

    static let commands = [
        Command(name: "/clear", help: "clear this chat"),
        Command(name: "/stop", help: "stop her talking"),
        Command(name: "/live", help: "talk hands-free here"),
        Command(name: "/voice", help: "full-screen voice mode"),
        Command(name: "/home", help: "Home Assistant"),
        Command(name: "/lang", help: "speech language (en, pt, nl)"),
        Command(name: "/help", help: "all commands"),
    ]

    let query: String
    let onPick: (String) -> Void

    var body: some View {
        let lower = query.lowercased()
        let matches = Self.commands.filter { $0.name.dropFirst().hasPrefix(lower) || $0.help.contains(lower) }
        if !matches.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(matches, id: \.name) { command in
                    Button { onPick(command.name) } label: {
                        HStack(spacing: 12) {
                            Text(command.name).font(Theme.mono(14, weight: .semibold)).foregroundStyle(Theme.teal)
                                .frame(width: 70, alignment: .leading)
                            Text(command.help).font(.subheadline).foregroundStyle(Theme.muted)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .glassCard(cornerRadius: 16)
        }
    }
}

/// Take a photo with the camera.
struct CameraCapture: UIViewControllerRepresentable {
    let onPhoto: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraCapture

        init(_ parent: CameraCapture) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.9) {
                parent.onPhoto(data)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
