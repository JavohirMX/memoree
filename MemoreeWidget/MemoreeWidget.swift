import AppIntents
import SwiftUI
import WidgetKit

/// Home Screen widget — layout-is-state, metadata only (ADR-040).
@main
struct MemoreeWidgetBundle: WidgetBundle {
    var body: some Widget {
        MemoreeStatusWidget()
    }
}

struct MemoreeStatusWidget: Widget {
    let kind = "MemoreeStatusWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MemoreeTimelineProvider()) { entry in
            MemoreeWidgetEntryView(entry: entry)
                .containerBackground(for: .widget) {
                    WidgetTheme.Color.canvas
                }
        }
        .configurationDisplayName("Memoree")
        .description("Your streak. Tap to open the camera.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct MemoreeWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct MemoreeTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> MemoreeWidgetEntry {
        MemoreeWidgetEntry(
            date: Date(),
            snapshot: WidgetSnapshot(
                dayIdentifier: "2026-01-01",
                capturedToday: false,
                currentStreak: 12,
                lastSevenDays: [true, true, true, true, true, false, false],
                updatedAt: Date()
            )
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (MemoreeWidgetEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MemoreeWidgetEntry>) -> Void) {
        let entry = currentEntry()
        // Refresh at next local midnight so a stale day flips to “waiting”.
        let calendar = Calendar.current
        let nextMidnight = calendar.nextDate(
            after: Date(),
            matching: DateComponents(hour: 0, minute: 0, second: 0),
            matchingPolicy: .nextTime
        ) ?? Date().addingTimeInterval(60 * 60)
        completion(Timeline(entries: [entry], policy: .after(nextMidnight)))
    }

    private func currentEntry() -> MemoreeWidgetEntry {
        let today = todayRawValue()
        let snapshot = WidgetSnapshotStore.load().resolved(forToday: today)
        return MemoreeWidgetEntry(date: Date(), snapshot: snapshot)
    }

    private func todayRawValue() -> String {
        let calendar = Calendar.current
        let comps = calendar.dateComponents([.year, .month, .day], from: Date())
        let year = comps.year ?? 0
        let month = comps.month ?? 0
        let day = comps.day ?? 0
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}

struct MemoreeWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    var entry: MemoreeWidgetEntry

    var body: some View {
        Button(intent: CaptureMomentIntent()) {
            Group {
                switch family {
                case .systemMedium:
                    mediumBody
                default:
                    smallBody
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint("Double-tap to open camera.")
        }
        .buttonStyle(.plain)
    }

    private var accessibilityLabel: String {
        let streak = entry.snapshot.currentStreak
        if entry.snapshot.capturedToday {
            return "\(streak) day streak. Moment captured today."
        }
        return "\(streak) day streak. No moment today."
    }

    // MARK: - Small

    @ViewBuilder
    private var smallBody: some View {
        if entry.snapshot.capturedToday {
            VStack(spacing: 4) {
                Text("\(entry.snapshot.currentStreak)")
                    .font(.system(size: 56, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(WidgetTheme.Color.textPrimary)
                Text("day streak")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(WidgetTheme.Color.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ZStack(alignment: .bottomLeading) {
                ShutterRing()
                    .frame(width: 72, height: 72)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(entry.snapshot.currentStreak)")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(WidgetTheme.Color.textPrimary)
                    Text("day streak")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(WidgetTheme.Color.textSecondary)
                }
                .padding(12)
            }
        }
    }

    // MARK: - Medium

    private var mediumBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            if entry.snapshot.capturedToday {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(entry.snapshot.currentStreak)")
                        .font(.system(size: 48, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(WidgetTheme.Color.textPrimary)
                    Text("day streak")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(WidgetTheme.Color.textSecondary)
                    Spacer(minLength: 0)
                }
            } else {
                HStack(alignment: .center, spacing: 16) {
                    ShutterRing()
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(entry.snapshot.currentStreak)")
                            .font(.system(size: 28, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(WidgetTheme.Color.textPrimary)
                        Text("day streak")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(WidgetTheme.Color.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
            }

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 6) {
                WeekStrip(days: entry.snapshot.lastSevenDays)
                Text("week")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(WidgetTheme.Color.textTertiary)
            }
        }
        .padding(16)
    }
}

/// Empty shutter ring — waiting state affordance (stroke only, no fill).
private struct ShutterRing: View {
    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(WidgetTheme.Color.textPrimary, lineWidth: 3)
            Circle()
                .strokeBorder(WidgetTheme.Color.textTertiary, lineWidth: 1.5)
                .padding(8)
        }
        .accessibilityHidden(true)
    }
}

/// Seven dots, oldest → newest (today is the last).
private struct WeekStrip: View {
    let days: [Bool]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(padded.enumerated()), id: \.offset) { _, filled in
                Circle()
                    .fill(filled ? WidgetTheme.Color.textPrimary : WidgetTheme.Color.textTertiary.opacity(0.35))
                    .frame(width: 8, height: 8)
            }
            Spacer(minLength: 0)
        }
        .accessibilityHidden(true)
    }

    private var padded: [Bool] {
        if days.count == 7 { return days }
        var copy = days
        while copy.count < 7 { copy.insert(false, at: 0) }
        return Array(copy.suffix(7))
    }
}
