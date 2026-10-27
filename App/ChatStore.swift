import Foundation
import UIKit

/// The conversations kept on the phone. Carapava's and Mamadona's live only here (last 100 messages); Nexa's is
/// serve.py's and is cached here so the app opens with it already on screen. Photos sent with a message are
/// stored next to it as JPEG files.
@MainActor
final class ChatStore: ObservableObject {
    static let shared = ChatStore()

    @Published private(set) var chats: [Bot: [TalkModel.Line]] = [:]

    private let folder: URL
    private var saveTask: Task<Void, Never>?

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        folder = base.appendingPathComponent("Chats", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent("photos"),
                                                 withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([String: [TalkModel.Line]].self, from: data) {
            for (key, lines) in saved {
                if let bot = Bot(rawValue: key) { chats[bot] = lines }
            }
        }
    }

    private var file: URL { folder.appendingPathComponent("chats.json") }

    func lines(_ bot: Bot) -> [TalkModel.Line] { chats[bot] ?? [] }

    func save(_ bot: Bot, _ lines: [TalkModel.Line]) {
        let kept = lines.count > 100 ? Array(lines.suffix(100)) : lines
        guard chats[bot] != kept else { return }
        chats[bot] = kept
        scheduleWrite()
    }

    /// Empties a chat. For Carapava and Mamadona a new gateway session starts too, so they forget it as well.
    func clear(_ bot: Bot) {
        chats[bot] = []
        if bot != .nexa { UserDefaults.standard.removeObject(forKey: sessionKey(bot)) }
        scheduleWrite()
    }

    /// One Hermes session per chat (`X-Hermes-Session-Id`): the gateway keeps the whole transcript, tool calls
    /// included, instead of rebuilding it from the app's text. Rotates only when the chat is cleared.
    func sessionID(_ bot: Bot) -> String {
        if let id = UserDefaults.standard.string(forKey: sessionKey(bot)) { return id }
        let id = "phone-\(bot.rawValue)-\(UUID().uuidString.prefix(12).lowercased())"
        UserDefaults.standard.set(id, forKey: sessionKey(bot))
        return id
    }

    private func sessionKey(_ bot: Bot) -> String { "session.\(bot.rawValue)" }

    // MARK: Photos

    /// Saves a photo sent with a message; returns its file name.
    func storePhoto(_ jpeg: Data) -> String? {
        let name = UUID().uuidString + ".jpg"
        do {
            try jpeg.write(to: photoURL(name), options: .atomic)
            return name
        } catch {
            return nil
        }
    }

    func photoURL(_ name: String) -> URL {
        folder.appendingPathComponent("photos").appendingPathComponent(name)
    }

    // MARK: Writing

    private func scheduleWrite() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            var out: [String: [TalkModel.Line]] = [:]
            for (bot, lines) in self.chats { out[bot.rawValue] = lines }
            if let data = try? JSONEncoder().encode(out) {
                try? data.write(to: self.file, options: .atomic)
            }
        }
    }
}

/// Shrinks a photo for sending: full camera frames are megabytes of base64, which chokes the upload on mobile
/// data and bloats the prompt. 1280 px JPEG at 0.7 is about 100-300 KB, plenty for vision models.
enum PhotoPrep {
    static func jpeg(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let longest = max(image.size.width, image.size.height)
        let scale = min(1, 1280 / max(longest, 1))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return resized.jpegData(compressionQuality: 0.7)
    }

    static func dataURI(_ jpeg: Data) -> String {
        "data:image/jpeg;base64," + jpeg.base64EncodedString()
    }
}
