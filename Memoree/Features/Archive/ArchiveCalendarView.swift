import SwiftUI

/// The calendar view: every month mapped out day by day.
///
/// **BeReal's signature Memories mechanic**, showing which days had captures and
/// which days were missed. A 7-column calendar grid where every day you captured
/// carries its thumbnail, and uncaptured days show a subtle placeholder.
///
/// Shares the same image streaming cache as `ArchiveGrid`, so scrolling between
/// views or scrolling through months uses the exact same thumbnail pipeline.
struct ArchiveCalendarView: View {

    let moments: [MomentFacts]
    let images: [UUID: UIImage]
    let missing: Set<UUID>
    let onOpen: (MomentFacts) -> Void
    let onDayVisible: (DayIdentifier) -> Void

    private static let columns = Array(
        repeating: GridItem(.flexible(), spacing: Theme.Spacing.xs),
        count: 7
    )

    private var sections: [ArchiveSection] {
        ArchiveSection.grouping(moments)
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                ForEach(sections) { section in
                    Section {
                        monthGrid(for: section)
                            .padding(.horizontal, Theme.Spacing.m)
                            .padding(.bottom, Theme.Spacing.xl)
                    } header: {
                        header(for: section)
                    }
                }
            }
            .padding(.top, Theme.Spacing.s)
        }
    }

    // MARK: - Month Grid

    private func monthGrid(for section: ArchiveSection) -> some View {
        VStack(spacing: Theme.Spacing.s) {
            weekdayHeader
            LazyVGrid(columns: Self.columns, spacing: Theme.Spacing.xs) {
                ForEach(section.calendarDays()) { item in
                    dayCell(item)
                }
            }
        }
    }

    /// Weekday symbols across 7 columns (e.g. S, M, T, W, T, F, S or locale-specific).
    private var weekdayHeader: some View {
        let symbols = weekdaySymbols()
        return LazyVGrid(columns: Self.columns, spacing: Theme.Spacing.xs) {
            ForEach(0..<symbols.count, id: \.self) { index in
                Text(symbols[index])
                    .font(Theme.Typography.retakePill)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
    }

    private func weekdaySymbols() -> [String] {
        let calendar = Calendar.current
        let symbols = calendar.veryShortWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first..<symbols.count] + symbols[0..<first])
    }

    // MARK: - Day Cell

    @ViewBuilder
    private func dayCell(_ item: CalendarDayItem) -> some View {
        if item.isBlank {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .accessibilityHidden(true)
        } else if let moment = item.moment {
            capturedCell(item: item, moment: moment)
        } else {
            emptyCell(item: item)
        }
    }

    private func capturedCell(item: CalendarDayItem, moment: MomentFacts) -> some View {
        Button {
            onOpen(moment)
        } label: {
            ZStack {
                Theme.Color.surface
                if let image = images[moment.id] {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else if missing.contains(moment.id) {
                    Image(systemName: "photo")
                        .font(Theme.Typography.retakePill)
                        .foregroundStyle(Theme.Color.textTertiary)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.thumbnail))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.thumbnail)
                    .strokeBorder(Theme.Color.divider, lineWidth: 1)
            }
            .overlay(alignment: .topLeading) {
                if let dayNumber = item.dayNumber {
                    Text("\(dayNumber)")
                        .font(Theme.Typography.retakePill)
                        .foregroundStyle(Theme.Color.textPrimary)
                        .padding(.horizontal, Theme.Spacing.xs)
                        .padding(.vertical, 2)
                        .background(Theme.Color.canvas.opacity(0.6))
                        .clipShape(Capsule())
                        .padding(Theme.Spacing.xs)
                        .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .topTrailing) {
                if moment.hasBTS {
                    Image(systemName: "video.fill")
                        .font(Theme.Typography.retakePill)
                        .foregroundStyle(Theme.Color.textPrimary)
                        .padding(.horizontal, Theme.Spacing.xs)
                        .padding(.vertical, 2)
                        .background(Theme.Color.canvas.opacity(0.6))
                        .clipShape(Capsule())
                        .padding(Theme.Spacing.xs)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.pressDip)
        .onAppear {
            if let dayId = item.dayIdentifier {
                onDayVisible(dayId)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(for: item, moment: moment))
        .accessibilityAddTraits(.isButton)
    }

    private func emptyCell(item: CalendarDayItem) -> some View {
        ZStack {
            Theme.Color.surface.opacity(item.isFuture ? 0.25 : 0.5)
            if let dayNumber = item.dayNumber {
                Text("\(dayNumber)")
                    .font(Theme.Typography.retakePill)
                    .foregroundStyle(item.isFuture ? Theme.Color.textTertiary.opacity(0.4) : Theme.Color.textTertiary)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.thumbnail))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            item.isFuture
                ? "Future day"
                : "No moment captured"
        )
    }

    // MARK: - Header

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

    private func accessibilityLabel(for item: CalendarDayItem, moment: MomentFacts) -> String {
        let dayString = item.date?.formatted(.dateTime.day().month(.wide).year()) ?? moment.day.rawValue
        let timeString = moment.capturedAt.formatted(date: .omitted, time: .shortened)
        let isMissing = missing.contains(moment.id)
        let base = "Photograph from \(dayString), \(timeString)"
        var label = isMissing ? "\(base). No longer in your photo library." : base
        if moment.hasBTS {
            label += ". Includes Behind the Scenes video."
        }
        return label
    }
}
