import SwiftUI

/// A labelled row holding a control.
///
/// Exists because the toggle version of this row would otherwise be written by
/// hand at each call site, and each hand-written version is another place for
/// the Dynamic Type fix to have reached only some of.
///
/// ## Why the parameter is `@ViewBuilder` and explicitly given
///
/// `@ViewBuilder` is what makes the call site work at all. Swift cannot infer a
/// generic parameter from a multi-statement `@ViewBuilder` closure, so the
/// closure has to be *labelled* — `control: { … }` — and inferred from the single
/// expression inside. Passing the value positionally produces
/// `generic parameter 'Control' could not be inferred`, which is the error this
/// shape exists to avoid.
struct SettingsRow<Control: View>: View {

    let title: String

    /// One sentence, under the title. Optional, and when absent the row is
    /// shorter rather than having an empty gap.
    var subtitle: String?

    @ViewBuilder let control: () -> Control

    init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder control: @escaping () -> Control
    ) {
        self.title = title
        self.subtitle = subtitle
        self.control = control
    }

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            // **The same branch, and the same reason, as `MetadataRow`.** A title
            // and a control cannot share a line once either has grown, and a
            // measurement-driven branch is a branch that can be wrong about a
            // width it was never shown.
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    labels
                    control()
                }
            } else {
                HStack {
                    labels
                    Spacer(minLength: Theme.Spacing.m)
                    control()
                }
            }
        }
        .padding(.vertical, Theme.Spacing.s)
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Text(title)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Color.textPrimary)
            if let subtitle {
                Text(subtitle)
                    .font(Theme.Typography.metadata)
                    .foregroundStyle(Theme.Color.textSecondary)
            }
        }
    }
}

/// How to say "this is a toggle row".
///
/// **No generic convenience initialiser, because `Toggle` resists one.** `Toggle`
/// is generic over its label, and `.labelsHidden()` returns yet another type, so
/// neither `Control == Toggle` nor `Control == Toggle<EmptyView>` names the value
/// a caller actually passes. Two attempts to pin it down both produced an
/// initialiser that could not be called.
///
/// So the toggle is written at the call site:
///
/// ```swift
/// SettingsRow(title: …, subtitle: …, control: Toggle("", isOn: binding).labelsHidden())
/// ```
///
/// One extra line per toggle, in exchange for no metaprogramming and no type
/// gymnastics. The row still owns the layout — which is the part that has to be
/// consistent — and the call site owns the control, which is the part that varies.
private enum SettingsRowToggleDocs {}

extension Theme.Spacing {
    /// Between a settings row's title and its subtitle.
    ///
    /// `xs` is too tight at a large text size — the two lines nearly touch — and
    /// `s` is too loose at the default. One value for both, chosen as `xs` for
    /// the default and accepting that it is snug at AX5, because a title and its
    /// own subtitle *should* read as one unit rather than two.
    static let xxs: CGFloat = 2
}
