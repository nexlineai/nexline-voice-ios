import NexlineCore
import SwiftUI

struct SpikeView: View {
    @StateObject private var model = SpikeModel()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Route", value: model.route)
                    Toggle("Echo cancellation", isOn: Binding(
                        get: { model.voiceProcessing },
                        set: { model.setVoiceProcessing($0) }
                    ))
                    .disabled(model.running != nil)
                    MeterRow(meter: model.meter)
                } header: {
                    Text("Microphone")
                } footer: {
                    Text("The bar is what the mic hears. Above the line counts as you talking.")
                }

                Section("Tests") {
                    Button("Silent test: stay quiet while it talks") { model.start(.silent) }
                        .disabled(!model.ready || model.running != nil)
                    Button("Talk-over test: interrupt it") { model.start(.talkOver) }
                        .disabled(!model.ready || model.running != nil)
                    if model.running != nil {
                        Button("Stop", role: .destructive) { model.stop() }
                    }
                }

                Section("Results") {
                    if model.runs.isEmpty {
                        Text("No runs yet").foregroundStyle(.secondary)
                    }
                    ForEach(model.runs) { run in
                        Text(run.line).font(.callout)
                    }
                    Button("Copy results") { model.copyResults() }
                        .disabled(model.runs.isEmpty)
                }

                Section("On-device speech recognition") {
                    Text(model.localeReport).font(.callout.monospaced())
                }

                Section("Log") {
                    ForEach(model.log.reversed()) { line in
                        Text(line.text).font(.caption.monospaced())
                    }
                }
            }
            .navigationTitle("Audio spike")
        }
        .task { await model.boot() }
    }
}

private struct MeterRow: View {
    @ObservedObject var meter: Meter

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LevelBar(db: meter.db, threshold: meter.threshold)
            Text(String(format: "mic %.0f dBFS · floor %.0f · line %.0f", meter.db, meter.floor, meter.threshold))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
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
