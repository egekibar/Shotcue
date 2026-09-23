import ShotcueCore
import SwiftUI

/// The run log (research 05 §C.3): one monospaced row per `RunEvent`, auto-scrolled to the bottom while
/// a run is live. Row rendering is a pure static function so it can be asserted without SwiftUI.
public struct RunLogView: View {
    public let events: [RunEvent]
    public let isLive: Bool

    public init(events: [RunEvent], isLive: Bool = false) {
        self.events = events
        self.isLive = isLive
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            log
            // Outside the scrolled content: a single, always-visible indicator. Inside the LazyVStack its
            // id kept shifting to collide with the newest row, which left ghost copies behind.
            if isLive && !events.isEmpty {
                Divider()
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("akıyor…").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            }
        }
        .background(.background.secondary, in: .rect(cornerRadius: 8))
    }

    private var log: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    if events.isEmpty {
                        Text(isLive ? "Bağlanıyor…" : "Bu çalışmanın logu yok.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(events.enumerated()), id: \.offset) { pair in
                        row(pair.element)
                            .id(pair.offset)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .onChange(of: events.count) { _, newCount in
                guard isLive, newCount > 0 else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(newCount - 1, anchor: .bottom)
                }
            }
        }
    }

    private func row(_ event: RunEvent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: Self.symbol(for: event))
                .imageScale(.small)
                .foregroundStyle(Self.tint(for: event))
                .frame(width: 14)
            Text(Self.line(for: event))
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Turkish one-liner for an event. Pure and tested.
    nonisolated public static func line(for event: RunEvent) -> String {
        switch event {
        case .initialized(_, let model):
            return "başladı · \(model ?? "model bilinmiyor")"
        case .assistantText(let text):
            return text
        case .toolUse(_, let summary):
            return summary
        case .apiRetry(let attempt):
            return attempt.map { "API yeniden deneme (\($0))" } ?? "API yeniden deneme"
        case .other(let type):
            return type
        case .result(let result):
            if result.isSuccess {
                var parts = ["bitti"]
                parts.append(Formatting.cost(result.totalCostUSD))
                parts.append(Formatting.turns(result.numTurns))
                parts.append(Formatting.duration(result.durationMs.map { Double($0) / 1000 }))
                return parts.joined(separator: " · ")
            }
            if result.hitLimit {
                return "limit aşıldı (\(result.subtype)) · \(Formatting.turns(result.numTurns))"
            }
            return "hata (\(result.subtype))"
        }
    }

    nonisolated public static func symbol(for event: RunEvent) -> String {
        switch event {
        case .initialized: "play.circle"
        case .assistantText: "text.bubble"
        case .toolUse: "wrench.and.screwdriver"
        case .apiRetry: "arrow.clockwise"
        case .other: "circle"
        case .result(let result): result.isSuccess ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
        }
    }

    /// `Color.tertiary` does not exist (only the `ShapeStyle` does), so `.gray` stands in here.
    nonisolated public static func tint(for event: RunEvent) -> Color {
        switch event {
        case .initialized: .secondary
        case .assistantText: .primary
        case .toolUse: .blue
        case .apiRetry: .orange
        case .other: .gray
        case .result(let result): result.isSuccess ? .green : .red
        }
    }
}
