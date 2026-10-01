import SwiftUI

/// One moment in the grid.
///
/// **Rear photograph, not the composite.** The composite is BeReal's own
/// geometry and it is right on the Today screen, where there is exactly one
/// thing to look at. Across 500 cells it puts 500 faces in a grid of scenes,
/// which is a gallery of selfies rather than a record of days. The inset belongs
/// in the detail view, where there is room to read it as *your* moment.
///
/// The placeholder is a flat `surface` rectangle rather than a spinner, for the
/// reason `TodayView`'s does: an image usually arrives in a few milliseconds,
/// and a spinner implies work that is not happening. What the placeholder must
/// not be is empty black — that reads as a broken photograph.
struct ArchiveCell: View {

    let moment: MomentFacts
    let image: UIImage?
    let isMissing: Bool

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Theme.Color.surface
                    .overlay {
                        if isMissing {
                            Text("Not in Photos")
                                .font(Theme.Typography.metadata)
                                .foregroundStyle(Theme.Color.textTertiary)
                                .multilineTextAlignment(.center)
                                .padding(Theme.Spacing.xs)
                        }
                    }
            }
        }
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.thumbnail))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.thumbnail)
                .strokeBorder(Theme.Color.divider, lineWidth: 1)
        }
        // One label per cell, composed rather than read image by image. A grid
        // of 500 unlabelled images is 500 VoiceOver stops that all say
        // "image", which is the same dead end as a button that does nothing.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.label(for: moment, isMissing: isMissing))
        .accessibilityAddTraits(.isButton)
    }

    /// "Photograph from 30 September, 4:12 in the afternoon."
    ///
    /// Written out rather than as a date string because VoiceOver reads `30/09/26`
    /// as three numbers and a user has to work out which is which. The time is
    /// included because the grid is chronological and the *time* is what
    /// distinguishes two moments in the same day — which, with one moment per
    /// day, is never.
    private static func label(for moment: MomentFacts, isMissing: Bool) -> String {
        let day = moment.day.date.formatted(.dateTime.day().month(.wide).year())
        let time = moment.capturedAt.formatted(date: .omitted, time: .shortened)
        let base = "Photograph from \(day), \(time)"
        return isMissing ? "\(base). No longer in your photo library." : base
    }
}

/// The grid.
///
/// Three columns, 3:4 cells, newest first.
///
/// `LazyVGrid` rather than a `List`, and that is not a style preference: a
/// `List` on iOS is a table view, and table views size their rows to content
/// rather than laying them out on a grid, so a two-column arrangement means
/// fighting the container. `LazyVGrid` also does the only thing that matters
/// here — it does not build a cell that is not near the screen, which for 500
/// moments is the difference between instant and several hundred milliseconds.
struct ArchiveGrid: View {

    let moments: [MomentFacts]
    let images: [UUID: UIImage]
    let missing: Set<UUID>
    let onOpen: (MomentFacts) -> Void

    /// Reports which day has scrolled into view, so the view model can warm
    /// Photos' cache ahead of the user.
    ///
    /// Driven by each cell's `onAppear` rather than by a scroll-position reader.
    /// `onScrollVisibilityChange` is the right API and it is iOS 18; the
    /// deployment floor here is 17, and a cell appearing *is* the signal that
    /// matters — it is the moment a thumbnail is about to be needed, which is
    /// exactly what prefetching is for.
    ///
    /// Per-cell rather than per-grid because a `LazyVGrid` only ever knows which
    /// cells exist, not which are on screen, and a single callback at the top
    /// would fire once and never again.
    let onDayVisible: (DayIdentifier) -> Void

    var body: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: Theme.Spacing.s),
                          GridItem(.flexible(), spacing: Theme.Spacing.s),
                          GridItem(.flexible(), spacing: Theme.Spacing.s)],
                spacing: Theme.Spacing.s
            ) {
                ForEach(moments) { moment in
                    Button {
                        onOpen(moment)
                    } label: {
                        ArchiveCell(
                            moment: moment,
                            image: images[moment.id],
                            isMissing: missing.contains(moment.id)
                        )
                    }
                    .buttonStyle(.plain)
                    .onAppear { onDayVisible(moment.day) }
                }
            }
            .padding(.horizontal, Theme.Spacing.m)
            .padding(.vertical, Theme.Spacing.m)
        }
    }
}
