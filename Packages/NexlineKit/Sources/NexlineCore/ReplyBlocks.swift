import Foundation

/// How a reply is shown: text lines, code, pictures, media cards, app launches, cameras, Home Assistant
/// devices. Port of the RN app's `parseBlocks` (MessageBubble.tsx), regexes kept as in the original.
public enum ReplyBlock: Equatable, Sendable {
    case line(String)
    case code(lang: String, code: String)
    case image(URL)
    case media(URL, MediaKind)
    case open(AppLink)
    case camera(entityID: String)
    case haDevice(entityID: String)
}

public enum MediaKind: String, Sendable {
    case youtube, soundcloud, mixcloud, spotify, video, audio, radio

    public var label: String {
        switch self {
        case .youtube: return "YouTube"
        case .soundcloud: return "SoundCloud"
        case .mixcloud: return "Mixcloud"
        case .spotify: return "Spotify"
        case .video: return "Video"
        case .audio: return "Audio"
        case .radio: return "Grooveline Radio"
        }
    }

    public static func of(_ url: String) -> MediaKind? {
        let u = url.lowercased()
        // Any radio.grooveline.org / stream.grooveline.org link is the one live stream.
        if u.matches("^https?://(radio|stream)\\.grooveline\\.org(?![\\w.-])") { return .radio }
        if u.matches("youtube\\.com/(watch|shorts)|youtu\\.be/") { return .youtube }
        if u.contains("soundcloud.com/") { return .soundcloud }
        if u.contains("mixcloud.com/") { return .mixcloud }
        if u.contains("open.spotify.com/") { return .spotify }
        if u.matches("\\.(mp4|mov|webm)(\\?|$)") { return .video }
        if u.matches("\\.(mp3|m4a|wav|aac)(\\?|$)") { return .audio }
        return nil
    }

    /// Track-level Mixcloud/SoundCloud links play inline through serve.py's stream proxy; profiles, sets and
    /// service pages keep the plain link card.
    public static func playsInline(_ url: String, _ kind: MediaKind) -> Bool {
        switch kind {
        case .mixcloud:
            return url.matches(#"(?:https?://)?(?:www\.)?mixcloud\.com/(?!(?:widget|live|categories|search|discover|upload|premium|pro|settings|about|developers)\b)[A-Za-z0-9_.%-]+/[A-Za-z0-9_.%()!-]+"#)
        case .soundcloud:
            return url.matches(#"(?:https?://)?(?:www\.|m\.)?soundcloud\.com/(?!(?:discover|search|you|stream|upload|pages|charts|people|tags|popular|settings)\b)[A-Za-z0-9_-]+/(?!sets\b)[A-Za-z0-9_-]+"#)
        default:
            return false
        }
    }
}

public enum ReplyBlocks {
    static let mdImage = #"!\[[^\]]*\]\(([^)\s]+)[^)]*\)"#
    static let imageURL = #"https?://[^\s<>()]+\.(?:png|jpe?g|gif|webp)(?:\?[^\s<>()]*)?"#
    static let cameraMark = #"^\s*CAMERA:(camera\.[a-z0-9_]+)\s*$"#
    static let haDevice = #"\[ha:device:([\w.]+?)(?::\d+)?\]"#
    /// xAI expression tags ([laughs], [soft wonder]) are voice direction, never shown. Markdown links keep
    /// their text (`(?!\()`), [ha:…] markers have a colon, and [Face ID] starts with a capital.
    static let expressionTag = #"\[[a-z][a-z]*(?:[ ,]+[a-z]+){0,3}\](?!\()"#

    public static func parse(_ text: String) -> [ReplyBlock] {
        var blocks: [ReplyBlock] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]

            // OPEN:<app>[:query]: voice mode launches it by itself; in typed chat it is a tap target.
            if let link = AppLink.parse(line) {
                blocks.append(.open(link))
                i += 1
                continue
            }

            if let camera = line.firstGroup(cameraMark, options: .caseInsensitive) {
                blocks.append(.camera(entityID: camera.lowercased()))
                i += 1
                continue
            }

            // She also drops the device tag mid-sentence, so pull it out and keep the rest of the line.
            if let device = line.firstGroup(haDevice, options: .caseInsensitive) {
                let rest = line.replacingFirst(haDevice, with: "", options: .caseInsensitive)
                    .trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty { blocks.append(.line(rest)) }
                blocks.append(.haDevice(entityID: device.lowercased()))
                i += 1
                continue
            }

            if let fence = line.groups(#"^\s*(```|~~~)\s*(\w*)"#) {
                let marker = fence[0]
                var code: [String] = []
                i += 1
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(marker) {
                    code.append(lines[i])
                    i += 1
                }
                i += 1
                if !code.isEmpty { blocks.append(.code(lang: fence[1], code: code.joined(separator: "\n"))) }
                continue
            }

            // Markdown image or bare image URL → inline picture.
            let picture = line.firstGroup(mdImage) ?? line.firstMatch(imageURL, options: .caseInsensitive)
            if let picture {
                let rest = line.replacingFirst(mdImage, with: "")
                    .replacingFirst(imageURL, with: "", options: .caseInsensitive)
                    .trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty { blocks.append(.line(rest)) }
                if let url = URL(string: picture) { blocks.append(.image(url)) }
                i += 1
                continue
            }

            let visible = stripExpressionTags(line)
            // A line that was only an expression tag disappears.
            if visible.isEmpty && !line.trimmingCharacters(in: .whitespaces).isEmpty {
                i += 1
                continue
            }
            blocks.append(.line(visible))
            // Media links get a card under the text line.
            for raw in line.allMatches(#"https?://[^\s<>()]+"#) {
                let cleaned = raw.replacingFirst(#"[.,;:!?'")\]]+$"#, with: "")
                guard let kind = MediaKind.of(cleaned), let url = URL(string: cleaned) else { continue }
                // Page link plus a guessed stream link: one radio card is enough.
                if kind == .radio && blocks.contains(where: { if case .media(_, .radio) = $0 { return true }; return false }) {
                    continue
                }
                blocks.append(.media(url, kind))
            }
            i += 1
        }
        return blocks
    }

    public static func stripExpressionTags(_ line: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: expressionTag) else { return line }
        let ns = line as NSString
        var out = ""
        var last = 0
        for match in regex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let tag = ns.substring(with: match.range)
            if tag.contains(":") { out += tag }
            last = match.range.location + match.range.length
        }
        out += ns.substring(from: last)
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// serve.py writes kiosk media as "](/media/x)"; make those links absolute so the phone can load them.
    /// (Like the RN app, only the markdown form is rewritten.)
    public static func rewriteMediaURLs(_ text: String, base: String) -> String {
        text.replacingOccurrences(of: "](/media/", with: "](\(base)/media/")
    }
}

/// An app to open from a reply ("play X on YouTube"). Port of the RN app's `appLaunch.ts`: the app's own
/// scheme first so the native app opens, then the web address.
public struct AppLink: Equatable, Sendable {
    public let key: String
    public let label: String
    public let query: String?

    static let targets: [(key: String, label: String)] = [
        ("youtube", "YouTube"), ("spotify", "Spotify"), ("maps", "Maps"), ("waze", "Waze"),
        ("soundcloud", "SoundCloud"), ("mixcloud", "Mixcloud"), ("whatsapp", "WhatsApp"), ("chrome", "Chrome"),
        ("safari", "Browser"),
    ]

    public init?(key name: String, query: String? = nil) {
        let n = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard let target = Self.targets.first(where: { $0.key == n }) ?? Self.targets.first(where: { $0.label.lowercased() == n })
        else { return nil }
        key = target.key
        label = target.label
        let q = query?.trimmingCharacters(in: .whitespaces) ?? ""
        self.query = q.isEmpty ? nil : q
    }

    /// `OPEN:<app>[:<query>]` on its own line, e.g. "OPEN:youtube:Solomun boiler room".
    public static func parse(_ line: String) -> AppLink? {
        guard let groups = line.groups(#"^\s*OPEN:([a-z]+)(?::(.*))?\s*$"#, options: .caseInsensitive) else { return nil }
        return AppLink(key: groups[0], query: groups[1])
    }

    /// The app's own link (native app), then the web fallback. Either may be missing.
    public var appURL: URL? {
        let q = query.map(Self.encode)
        switch key {
        case "youtube": return URL(string: q.map { "youtube://results?search_query=\($0)" } ?? "youtube://")
        case "spotify": return URL(string: q.map { "spotify:search:\($0)" } ?? "spotify://")
        case "maps": return URL(string: q.map { "maps://?q=\($0)" } ?? "maps://")
        case "waze": return URL(string: q.map { "waze://?q=\($0)&navigate=yes" } ?? "waze://")
        case "soundcloud": return URL(string: q.map { "soundcloud://search?q=\($0)" } ?? "soundcloud://")
        case "mixcloud": return URL(string: "mixcloud://")
        case "whatsapp": return URL(string: "whatsapp://")
        case "chrome": return URL(string: query.map(Self.chromeLink) ?? "googlechromes://")
        default: return nil
        }
    }

    public var webURL: URL? {
        let q = query.map(Self.encode)
        switch key {
        case "youtube": return URL(string: q.map { "https://www.youtube.com/results?search_query=\($0)" } ?? "https://www.youtube.com")
        case "spotify": return URL(string: q.map { "https://open.spotify.com/search/\($0)" } ?? "https://open.spotify.com")
        case "maps": return q.flatMap { URL(string: "https://maps.apple.com/?q=\($0)") }
        case "waze": return q.flatMap { URL(string: "https://waze.com/ul?q=\($0)") }
        case "soundcloud": return URL(string: q.map { "https://soundcloud.com/search?q=\($0)" } ?? "https://soundcloud.com")
        case "mixcloud": return URL(string: q.map { "https://www.mixcloud.com/search/?q=\($0)" } ?? "https://www.mixcloud.com")
        case "whatsapp": return query == nil ? URL(string: "https://web.whatsapp.com") : nil
        case "chrome", "safari":
            guard let query else { return URL(string: "https://www.google.com") }
            if query.matches("^https?://", options: .caseInsensitive) { return URL(string: query) }
            return URL(string: "https://www.google.com/search?q=\(Self.encode(query))")
        default: return nil
        }
    }

    /// Chrome's own scheme takes the URL minus its scheme; anything else is a Google search.
    static func chromeLink(_ q: String) -> String {
        if let groups = q.groups("^(https?)://(.+)$", options: .caseInsensitive) {
            return "\(groups[0].lowercased() == "https" ? "googlechromes" : "googlechrome")://\(groups[1])"
        }
        return "googlechromes://www.google.com/search?q=\(encode(q))"
    }

    /// Like JS `encodeURIComponent`.
    static func encode(_ s: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.!~*'()")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

// MARK: Regex helpers

extension String {
    func matches(_ pattern: String, options: NSRegularExpression.Options = []) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return false }
        return regex.firstMatch(in: self, range: NSRange(startIndex..., in: self)) != nil
    }

    func firstMatch(_ pattern: String, options: NSRegularExpression.Options = []) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options),
              let match = regex.firstMatch(in: self, range: NSRange(startIndex..., in: self)),
              let range = Range(match.range, in: self)
        else { return nil }
        return String(self[range])
    }

    func firstGroup(_ pattern: String, options: NSRegularExpression.Options = []) -> String? {
        groups(pattern, options: options)?.first
    }

    /// The capture groups of the first match ("" for a group that didn't take part), or nil without a match.
    func groups(_ pattern: String, options: NSRegularExpression.Options = []) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options),
              let match = regex.firstMatch(in: self, range: NSRange(startIndex..., in: self))
        else { return nil }
        return (1..<max(1, match.numberOfRanges)).map { index in
            Range(match.range(at: index), in: self).map { String(self[$0]) } ?? ""
        }
    }

    func allMatches(_ pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: self, range: NSRange(startIndex..., in: self)).compactMap {
            Range($0.range, in: self).map { String(self[$0]) }
        }
    }

    func replacingFirst(_ pattern: String, with template: String, options: NSRegularExpression.Options = []) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options),
              let match = regex.firstMatch(in: self, range: NSRange(startIndex..., in: self))
        else { return self }
        return (self as NSString).replacingCharacters(in: match.range, with: template)
    }
}
