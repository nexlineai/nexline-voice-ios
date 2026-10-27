import SwiftUI
import UIKit

/// Home Assistant through serve.py on the Jetson (`/ha/*`, same Access token as Nexa). serve.py already fails
/// over between the LAN and ha.nexline.ai, so this works at home and in the car. Names, units and kinds come
/// from Home Assistant itself; nothing here knows a particular device.
struct HAEntity: Identifiable, Equatable {
    let id: String
    var state: String
    let name: String
    let unit: String?
    let currentTemperature: Double?

    var domain: String { String(id.split(separator: ".").first ?? "") }

    var isOn: Bool { ["on", "open", "unlocked", "playing", "heat", "cool", "auto"].contains(state) }

    var controllable: Bool { ["light", "switch", "input_boolean", "fan", "media_player"].contains(domain) }

    var offline: Bool { (state == "unavailable" || state == "unknown") && domain != "sensor" }

    var reading: String {
        if let unit, !unit.isEmpty { return "\(state) \(unit)" }
        if let currentTemperature { return "\(state) · \(currentTemperature.formatted(.number.precision(.fractionLength(0...1))))°" }
        if offline { return "offline" }
        return state.replacingOccurrences(of: "_", with: " ")
    }

    var icon: String {
        switch domain {
        case "light": return isOn ? "lightbulb.fill" : "lightbulb"
        case "switch", "input_boolean": return isOn ? "power.circle.fill" : "power.circle"
        case "fan": return "fan"
        case "climate": return "thermometer.medium"
        case "cover": return "blinds.vertical.closed"
        case "media_player": return "hifispeaker"
        case "sensor": return "gauge.with.dots.needle.33percent"
        case "binary_sensor": return isOn ? "circle.inset.filled" : "circle"
        case "camera": return "video"
        case "lock": return isOn ? "lock.open" : "lock"
        default: return "cube"
        }
    }
}

@MainActor
final class HomeStore: ObservableObject {
    static let shared = HomeStore()

    enum Tab: String, CaseIterable, Identifiable {
        case cameras, lights, switches, climate, sensors

        var id: String { rawValue }
        var label: String { rawValue.capitalized }
        var domains: Set<String> {
            switch self {
            case .cameras: return ["camera"]
            case .lights: return ["light"]
            case .switches: return ["switch", "input_boolean"]
            case .climate: return ["climate", "fan", "cover"]
            case .sensors: return ["sensor", "binary_sensor"]
            }
        }
    }

    @Published private(set) var entities: [HAEntity] = []
    @Published private(set) var problem: String?
    @Published private(set) var loaded = false
    @Published private(set) var busy: Set<String> = []
    private var lastLoad = Date.distantPast

    func entity(_ id: String) -> HAEntity? { entities.first { $0.id == id } }

    /// Live devices first, offline last (the kiosk's order).
    func list(_ tab: Tab) -> [HAEntity] {
        entities.filter { tab.domains.contains($0.domain) }
            .sorted { ($0.offline ? 1 : 0, $0.name) < ($1.offline ? 1 : 0, $1.name) }
    }

    /// Several cards may ask at once; one fetch every few seconds is enough.
    func refresh(force: Bool = false) async {
        guard force || Date().timeIntervalSince(lastLoad) > 4 else { return }
        lastLoad = Date()
        do {
            let (data, code) = try await NexaClient.shared.get("ha/states")
            guard code == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let states = json["states"] as? [[String: Any]]
            else { throw URLError(.cannotParseResponse) }
            entities = states.compactMap(Self.entity)
            problem = nil
        } catch {
            problem = "Couldn't reach Home Assistant. \(error.localizedDescription)"
        }
        loaded = true
    }

    /// Flips at once on screen, then confirms against Home Assistant (it can refuse or lag).
    func toggle(_ id: String) async {
        guard let index = entities.firstIndex(where: { $0.id == id }), !busy.contains(id) else { return }
        let before = entities[index].state
        entities[index].state = entities[index].isOn ? "off" : "on"
        busy.insert(id)
        do {
            try await NexaClient.shared.post("ha/toggle", json: ["entity_id": id])
            try? await Task.sleep(for: .milliseconds(800))
            await refresh(force: true)
        } catch {
            if let again = entities.firstIndex(where: { $0.id == id }) { entities[again].state = before }
        }
        busy.remove(id)
    }

    private static func entity(_ raw: [String: Any]) -> HAEntity? {
        guard let id = raw["entity_id"] as? String else { return nil }
        let attributes = raw["attributes"] as? [String: Any] ?? [:]
        return HAEntity(
            id: id,
            state: raw["state"] as? String ?? "unknown",
            name: (attributes["friendly_name"] as? String) ?? id,
            unit: attributes["unit_of_measurement"] as? String,
            currentTemperature: (attributes["current_temperature"] as? NSNumber)?.doubleValue)
    }
}

// MARK: Cameras

/// A camera, live-ish: Home Assistant's snapshot fetched again every 1.2 s (a sleeping camera can take 6-10 s
/// for its first frame). Only polls while on screen. Tap for full screen.
struct CameraFrame: View {
    let entityID: String
    var compact = false
    @State private var frame: UIImage?
    @State private var trouble = false
    @State private var fullScreen = false
    @ObservedObject private var home = HomeStore.shared

    var body: some View {
        ZStack {
            Color(hex: 0x06080D)
            if let frame {
                Image(uiImage: frame).resizable().scaledToFill()
            } else {
                VStack(spacing: 8) {
                    ProgressView().tint(Theme.teal)
                    Text(trouble ? "reconnecting…" : "connecting to the camera…")
                        .font(.caption).foregroundStyle(Theme.muted)
                }
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .overlay(alignment: .topTrailing) { LiveBadge().padding(8) }
        .overlay(alignment: .bottomLeading) {
            Text(name)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.8), radius: 4)
                .padding(10)
        }
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.caption)
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .glassEffect(Glass.clear, in: Circle())
                .padding(8)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { fullScreen = true }
        .task(id: entityID) { await poll() }
        .fullScreenCover(isPresented: $fullScreen) {
            CameraFullScreen(entityID: entityID, name: name)
        }
    }

    private var name: String {
        home.entity(entityID)?.name
            ?? entityID.replacingOccurrences(of: "camera.", with: "").replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func poll() async {
        await HomeStore.shared.refresh()
        while !Task.isCancelled {
            if let image = await CameraFrame.snapshot(entityID) {
                frame = image
                trouble = false
                try? await Task.sleep(for: .milliseconds(1200))
            } else {
                trouble = true
                try? await Task.sleep(for: .milliseconds(2400))
            }
        }
    }

    static func snapshot(_ entityID: String) async -> UIImage? {
        let bust = URLQueryItem(name: "t", value: String(Int(Date().timeIntervalSince1970 * 1000)))
        guard let result = try? await NexaClient.shared.get("ha/camera/\(entityID)", query: [bust], timeout: 12),
              result.1 == 200 else { return nil }
        return UIImage(data: result.0)
    }
}

private struct LiveBadge: View {
    @State private var on = false

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(Color(hex: 0xFF5470)).frame(width: 7, height: 7)
                .opacity(on ? 1 : 0.35)
                .animation(.easeInOut(duration: 0.8).repeatForever(), value: on)
            Text("LIVE").font(Theme.mono(9, weight: .semibold)).tracking(1.4).foregroundStyle(Color(hex: 0x7EF0C9))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.black.opacity(0.5), in: Capsule())
        .onAppear { on = true }
    }
}

private struct CameraFullScreen: View {
    let entityID: String
    let name: String
    @Environment(\.dismiss) private var dismiss
    @State private var frame: UIImage?
    @State private var zoom: CGFloat = 1

    var body: some View {
        ZStack {
            Color(red: 0.01, green: 0.015, blue: 0.03).ignoresSafeArea()
            if let frame {
                Image(uiImage: frame)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(zoom)
                    .gesture(MagnifyGesture()
                        .onChanged { zoom = max(1, min(4, $0.magnification)) }
                        .onEnded { _ in withAnimation(.spring) { if zoom < 1.1 { zoom = 1 } } })
                    .onTapGesture(count: 2) { withAnimation(.spring) { zoom = zoom > 1 ? 1 : 2 } }
            } else {
                ProgressView().tint(Theme.teal).controlSize(.large)
            }
        }
        .overlay(alignment: .top) {
            HStack(spacing: 10) {
                LiveBadge()
                Text(name).font(.headline).foregroundStyle(.white)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.headline).frame(width: 44, height: 44)
                }
                .buttonStyle(.glass)
            }
            .padding(.horizontal, 16)
        }
        .task {
            while !Task.isCancelled {
                if let image = await CameraFrame.snapshot(entityID) { frame = image }
                try? await Task.sleep(for: .milliseconds(1000))
            }
        }
    }
}

// MARK: Devices

/// A device Nexa mentions (`[ha:device:…]`): live state, and a switch when it can be switched.
struct HADeviceCard: View {
    let entityID: String
    @ObservedObject private var home = HomeStore.shared

    var body: some View {
        Group {
            if let entity = home.entity(entityID) {
                DeviceRow(entity: entity, busy: home.busy.contains(entityID)) {
                    Task { await home.toggle(entityID) }
                }
            } else if !home.loaded {
                HStack(spacing: 10) {
                    ProgressView().tint(Theme.teal)
                    Text("loading the device…").font(.footnote).foregroundStyle(Theme.muted)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard(cornerRadius: 14)
            } else {
                Label("\(entityID) isn't in Home Assistant", systemImage: "questionmark.circle")
                    .font(.footnote).foregroundStyle(Theme.muted)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassCard(cornerRadius: 14)
            }
        }
        .task { await home.refresh() }
    }
}

struct DeviceRow: View {
    let entity: HAEntity
    let busy: Bool
    let toggle: () -> Void

    var body: some View {
        let lit = entity.isOn && entity.controllable
        HStack(spacing: 12) {
            Image(systemName: entity.icon)
                .font(.body)
                .foregroundStyle(lit ? Theme.teal : Theme.muted)
                .symbolEffect(.bounce, value: entity.isOn)
                .frame(width: 38, height: 38)
                .background(lit ? Theme.teal.opacity(0.16) : Theme.bg3, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(entity.name).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text).lineLimit(1)
                Text(entity.reading).font(.caption).foregroundStyle(lit ? Theme.teal : Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 6)
            if busy {
                ProgressView().tint(Theme.teal)
            } else if entity.controllable && !entity.offline {
                Toggle("", isOn: Binding(get: { entity.isOn }, set: { _ in toggle() }))
                    .labelsHidden()
                    .tint(Theme.teal)
            }
        }
        .padding(12)
        .glassCard(tint: lit ? Theme.teal : nil, cornerRadius: 16)
        .opacity(entity.offline ? 0.45 : 1)
        .sensoryFeedback(.impact(weight: .light, intensity: 0.7), trigger: entity.isOn)
    }
}

/// The Home screen: cameras, lights, switches, climate, sensors (the RN app's Devices screen).
struct DevicesView: View {
    @ObservedObject private var home = HomeStore.shared
    @State private var tab = HomeStore.Tab.cameras
    @Namespace private var tabs

    var body: some View {
        ZStack {
            AmbientBackground(accent: Theme.teal, intensity: 0.7)
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    GlassEffectContainer(spacing: 8) {
                        HStack(spacing: 8) {
                            ForEach(HomeStore.Tab.allCases) { item in
                                Button {
                                    withAnimation(.snappy) { tab = item }
                                } label: {
                                    Text(item.label)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(tab == item ? Theme.teal : Theme.muted)
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 9)
                                }
                                .buttonStyle(.plain)
                                .glassEffect(Glass.regular.tint(tab == item ? Theme.teal.opacity(0.25) : nil).interactive(),
                                             in: Capsule())
                                .glassEffectID(item.id, in: tabs)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }
                }
                .sensoryFeedback(.selection, trigger: tab)

                content
            }
        }
        .navigationTitle("Home")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            while !Task.isCancelled {
                await home.refresh(force: true)
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    @ViewBuilder private var content: some View {
        if !home.loaded {
            Spacer()
            ProgressView().tint(Theme.teal)
            Spacer()
        } else if let problem = home.problem, home.entities.isEmpty {
            Spacer()
            VStack(spacing: 14) {
                Image(systemName: "wifi.exclamationmark").font(.largeTitle).foregroundStyle(Theme.muted)
                Text(problem).font(.footnote).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                Button("Try again") { Task { await home.refresh(force: true) } }
                    .buttonStyle(.glass)
            }
            .padding(24)
            Spacer()
        } else {
            let items = home.list(tab)
            ScrollView {
                LazyVStack(spacing: 10) {
                    if items.isEmpty {
                        Text("Nothing here.").foregroundStyle(Theme.faint).padding(.top, 40)
                    } else if tab == .cameras {
                        ForEach(items) { camera in
                            if camera.offline {
                                Label("\(camera.name) · offline", systemImage: "video.slash")
                                    .font(.footnote).foregroundStyle(Theme.muted)
                                    .frame(maxWidth: .infinity)
                                    .aspectRatio(16 / 9, contentMode: .fit)
                                    .glassCard(cornerRadius: 14)
                            } else {
                                CameraFrame(entityID: camera.id)
                            }
                        }
                    } else {
                        ForEach(items) { entity in
                            DeviceRow(entity: entity, busy: home.busy.contains(entity.id)) {
                                Task { await home.toggle(entity.id) }
                            }
                        }
                    }
                }
                .padding(16)
            }
            .refreshable { await home.refresh(force: true) }
        }
    }
}
