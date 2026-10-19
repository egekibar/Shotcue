import AppKit
import ShotcueCore
import SwiftUI

/// One grid cell (research 05 §C.2): thumbnail, title, status chip, voice badge, relative date.
///
/// Stateless on purpose. The image comes from the shared `ThumbnailCache`, which returns nil on a miss
/// and re-renders this view when the decode finishes — so the card needs no `@State` and no per-cell
/// `.task`, which matters because `@State` does not compile with Command Line Tools (see Global
/// Constraints).
public struct TaskCardView: View {
    public let task: ShotTask
    public let thumbnailURL: URL?
    public let isSelected: Bool
    public let cache: ThumbnailCache?
    public let voiceSeconds: Double?

    static let cornerRadius: CGFloat = 10
    /// Space between the card and its selection ring.
    static let selectionGap: CGFloat = 3
    static let selectionLineWidth: CGFloat = 2
    /// How far the ring reaches outside the card; it must stay under half the grid spacing (12) so two selected
    /// neighbours' rings do not touch.
    static var selectionInset: CGFloat { selectionGap + selectionLineWidth }

    public init(
        task: ShotTask, thumbnailURL: URL?, isSelected: Bool,
        cache: ThumbnailCache? = nil, voiceSeconds: Double? = nil
    ) {
        self.task = task
        self.thumbnailURL = thumbnailURL
        self.isSelected = isSelected
        self.cache = cache
        self.voiceSeconds = voiceSeconds
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            preview
            details
        }
        .background(.background.secondary)
        // The whole card, thumbnail included: unclipped, the thumbnail's square corners stuck out of the rounded card.
        .clipShape(.rect(cornerRadius: Self.cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
        }
        // The selection ring sits outside the card with a small gap, so it never covers the thumbnail.
        .overlay {
            if isSelected {
                // Concentric with the card: the ring's inner edge is `selectionGap` away, at radius + gap.
                RoundedRectangle(cornerRadius: Self.cornerRadius + Self.selectionInset)
                    .strokeBorder(Color.accentColor, lineWidth: Self.selectionLineWidth)
                    .padding(-Self.selectionInset)
            }
        }
        .contentShape(.rect(cornerRadius: Self.cornerRadius))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(task.title), \(StatusPresentation.label(for: task.status))")
    }

    private var preview: some View {
        ZStack {
            if let image = cache?.image(at: thumbnailURL) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: thumbnailURL == nil ? "text.alignleft" : "photo")
                            .imageScale(.large)
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        .frame(height: 118)
        // `minWidth: 0` so a wide `.fill` thumbnail cannot push the card wider than its grid column.
        .frame(minWidth: 0, maxWidth: .infinity)
        .clipped()
        .overlay(alignment: .topTrailing) {
            StatusChip(status: task.status)
                .padding(6)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(task.title)
                .font(.callout.weight(.medium))
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
            HStack(spacing: 6) {
                if let voiceSeconds {
                    Label(Formatting.stopwatch(voiceSeconds), systemImage: "mic.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if task.mode == .analyze {
                    Label(L10n.t("Analyze"), systemImage: "magnifyingglass")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Text(Formatting.relativeDate(task.updatedAt, now: Date()))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
