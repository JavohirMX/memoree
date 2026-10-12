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
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                ZStack {
                    Theme.Color.surface
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else if isMissing {
                        Text("Not in Photos")
                            .font(Theme.Typography.metadata)
                            .foregroundStyle(Theme.Color.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(Theme.Spacing.xs)
                    }
                    // Neither a spinner nor a black rectangle — see the type documentation.
                }
            }
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.thumbnail))
            .overlay(alignment: .topLeading) { dayBadge }
            .overlay(alignment: .topTrailing) { topTrailingBadges }
            // One label per cell, composed rather than read image by image. A grid
            // of 500 unlabelled images is 500 VoiceOver stops that all say
            // "image", which is the same dead end as a button that does nothing.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.label(for: moment, isMissing: isMissing))
            .accessibilityAddTraits(.isButton)
    }

    /// The day of the month, top-left, over the photograph.
    ///
    /// **Hidden from VoiceOver**, because the cell's own label already says the
    /// full date in words and two VoiceOver stops per cell is worse than one.
    ///
    /// ## Why a badge and not a caption underneath
    ///
    /// The month header above says *which month*. It cannot say which day —
    /// thirty squares in a row all read "October" and the user's actual question
    /// is usually "which one was last Tuesday". So each cell carries its own day
    /// number, and the two together answer "when was this" without the grid ever
    /// leaving the picture.
    ///
    /// ## Why the scrim
    ///
    /// A number over a photograph is unreadable half the time. Photographs are
    /// the one thing in this app whose colours are not under the app's control,
    /// so the badge carries a black pill at 60% — enough to hold white text at
    /// every size, and it borrows the same `textTertiary` grey as the missing-
    /// photograph label for its own edge.
    private var dayBadge: some View {
        Text(moment.capturedAt.formatted(.dateTime.day()))
            .font(Theme.Typography.retakePill)
            .foregroundStyle(Theme.Color.textPrimary)
            .padding(.horizontal, Theme.Spacing.xs)
            .padding(.vertical, 2)
            .background(Theme.Color.canvas.opacity(0.6))
            .clipShape(Capsule())
            .padding(Theme.Spacing.xs)
            .accessibilityHidden(true)
    }

    /// Behind-the-Scenes and micro-journal badges, top-right.
    @ViewBuilder
    private var topTrailingBadges: some View {
        HStack(spacing: Theme.Spacing.xs) {
            if moment.hasBTS {
                Image(systemName: "video.fill")
                    .font(Theme.Typography.retakePill)
                    .foregroundStyle(Theme.Color.textPrimary)
                    .padding(.horizontal, Theme.Spacing.xs)
                    .padding(.vertical, 2)
                    .background(Theme.Color.canvas.opacity(0.6))
                    .clipShape(Capsule())
            }
            if let note = moment.note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Image(systemName: "text.bubble.fill")
                    .font(Theme.Typography.retakePill)
                    .foregroundStyle(Theme.Color.textPrimary)
                    .padding(.horizontal, Theme.Spacing.xs)
                    .padding(.vertical, 2)
                    .background(Theme.Color.canvas.opacity(0.6))
                    .clipShape(Capsule())
            }
        }
        .padding(Theme.Spacing.xs)
        .accessibilityHidden(true)
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
        var text = isMissing ? "\(base). No longer in your photo library." : base
        if moment.hasBTS {
            text += ". Includes Behind the Scenes video."
        }
        if let note = moment.note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text += ". Includes journal note."
        }
        return text
    }
}

/// The grid.
///
/// Three columns, 3:4 cells, newest first, **grouped by month under a pinned
/// header**.
///
/// `LazyVGrid` rather than a `List`, and that is not a style preference: a
/// `List` on iOS is a table view, and table views size their rows to content
/// rather than laying them out on a grid, so a two-column arrangement means
/// fighting the container. `LazyVGrid` also does the only thing that matters
/// here — it does not build a cell that is not near the screen, which for 500
/// moments is the difference between instant and several hundred milliseconds.
///
/// ## Why the months were missing and why this is the shape of the fix
///
/// The grid showed 500 photographs in an unbroken block of squares with no
/// dates anywhere. Scrolling it told you how many moments you had and nothing
/// about *when* — a user could not find last Tuesday, could not tell six weeks
/// ago from yesterday, and had no way to know whether the archive had stopped
/// filling. An archive you cannot locate things in is a contact sheet.
///
/// A `ScrollView` of sections rather than one grid of everything: each section
/// carries its own `LazyVGrid` so that a month is the unit, and `pinnedViews`
/// keeps the header of the month you are looking at under the navigation bar
/// while its photographs scroll beneath it. The alternative — a plain vertical
/// `LazyVStack` of header-then-cells — cannot know how many cells to put after a
/// header without doing the column arithmetic itself, which is the thing a grid
/// already knows how to do.
struct ArchiveGrid: View {

    let moments: [MomentFacts]
    let images: [UUID: UIImage]
    let missing: Set<UUID>
    let onOpen: (MomentFacts) -> Void
    let onDayVisible: (DayIdentifier) -> Void
    @Binding var targetMonth: MonthKey?

    private static let columns = Array(
        repeating: GridItem(.flexible(), spacing: Theme.Size.gridSpacing),
        count: Theme.Size.gridColumns
    )

    /// Grouped once, not per body evaluation.
    ///
    /// `body` re-runs on every state change, and grouping is a sort plus a walk
    /// over the whole archive — 500 moments, on every thumbnail that arrives.
    var sections: [ArchiveSection] { ArchiveSection.grouping(moments) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                    ForEach(sections) { section in
                        Section {
                            LazyVGrid(columns: Self.columns, spacing: Theme.Size.gridSpacing) {
                                ForEach(section.moments) { moment in
                                    cell(moment)
                                }
                            }
                            .padding(.horizontal, Theme.Spacing.s)
                            .padding(.bottom, Theme.Spacing.xl)
                        } header: {
                            header(for: section)
                                .id(section.id)
                        }
                    }
                }
                .padding(.top, Theme.Spacing.s)
            }
            .onChange(of: targetMonth) { _, newMonth in
                if let newMonth {
                    withAppAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(newMonth, anchor: .top)
                    }
                    targetMonth = nil
                }
            }
        }
    }

    private func cell(_ moment: MomentFacts) -> some View {
        Button {
            onOpen(moment)
        } label: {
            ArchiveCell(
                moment: moment,
                image: images[moment.id],
                isMissing: missing.contains(moment.id)
            )
        }
        .buttonStyle(.pressDip)
        .onAppear { onDayVisible(moment.day) }
    }

    /// The pinned month header.
    ///
    /// **Opaque canvas, and it has to be.** A pinned header with a transparent
    /// background shows the photographs scrolling *through* the text, and since
    /// these cells are full-bleed photographs rather than rows, there is always
    /// something behind it to see. `.background(Theme.Color.canvas)` is the fix
    /// and it is the reason the header is not a bare `Text`.
    ///
    /// `metadata` rather than `body`: it is a label for what is below it, not
    /// content, and it must not out-shout the photographs it introduces.
    private func header(for section: ArchiveSection) -> some View {
        HStack {
            Text(section.title)
                .font(Theme.Typography.metadata)
                .foregroundStyle(Theme.Color.textPrimary)
            Spacer()
            Text(section.countDescription)
                .font(Theme.Typography.metadata)
                .foregroundStyle(Theme.Color.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, Theme.Spacing.s)
        .background(Theme.Color.canvas)
        .accessibilityAddTraits(.isHeader)
    }
}
