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
    @Binding var targetMonth: MonthKey?

    private static let columns = Array(
        repeating: GridItem(.flexible(), spacing: Theme.Spacing.xs),
        count: 7
    )

    private var sections: [ArchiveSection] {
        ArchiveSection.grouping(moments)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                    ForEach(sections) { section in
                        Section {
                            monthGrid(for: section)
                                .padding(.horizontal, Theme.Spacing.m)
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
        let isToday = item.date.map { Calendar.current.isDateInToday($0) } ?? false

        return Button {
            onOpen(moment)
        } label: {
            // Day number lives *below* the circle so it cannot sit next to the
            // multi-capture count and read as a second date (e.g. "4 5").
            VStack(spacing: Theme.Spacing.xs) {
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
                .clipShape(Circle())
                .overlay {
                    Circle()
                        .strokeBorder(isToday ? Theme.Color.textPrimary : Theme.Color.divider, lineWidth: 1)
                }
                .contentShape(Circle())
                .overlay(alignment: .topLeading) {
                    // ADR-030: more than one capture. `×N` — not a bare digit —
                    // so it cannot be read as a day-of-month.
                    if item.hasMultipleMoments {
                        Text("×\(item.momentCount)")
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

                if let dayNumber = item.dayNumber {
                    Text("\(dayNumber)")
                        .font(Theme.Typography.retakePill)
                        .foregroundStyle(
                            isToday ? Theme.Color.textPrimary : Theme.Color.textSecondary
                        )
                        .accessibilityHidden(true)
                }
            }
            // Full cell is tappable — circle glyphs stay dense; hit fills the grid slot.
            .contentShape(Rectangle())
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
        let isToday = item.date.map { Calendar.current.isDateInToday($0) } ?? false

        // Same VStack chrome as captured cells so the grid row height stays even
        // when a neighbouring day has its number under the circle.
        return VStack(spacing: Theme.Spacing.xs) {
            ZStack {
                Theme.Color.surface.opacity(item.isFuture ? 0.25 : 0.5)
                if let dayNumber = item.dayNumber {
                    Text("\(dayNumber)")
                        .font(Theme.Typography.retakePill)
                        .foregroundStyle(
                            isToday
                                ? Theme.Color.textPrimary
                                : (item.isFuture
                                    ? Theme.Color.textTertiary.opacity(0.4)
                                    : Theme.Color.textTertiary)
                        )
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(Circle())
            .overlay {
                if isToday {
                    Circle()
                        .strokeBorder(Theme.Color.textPrimary, lineWidth: 1)
                }
            }

            Text(" ")
                .font(Theme.Typography.retakePill)
                .accessibilityHidden(true)
                .hidden()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            item.isFuture
                ? "Future day"
                : (isToday ? "Today, no moment captured yet" : "No moment captured")
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
        if item.hasMultipleMoments {
            label += ". \(item.momentCount) moments this day."
        }
        if moment.hasBTS {
            label += ". Includes Behind the Scenes video."
        }
        if let note = moment.note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            label += ". Includes journal note."
        }
        return label
    }
}
