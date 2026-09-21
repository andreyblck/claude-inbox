import AppKit
import SwiftUI

/// One place for every number a view is allowed to use.
///
/// Spacing that drifts by a point or two per view is the difference between a
/// panel that feels made and one that feels assembled, and it drifts the moment
/// each view is allowed its own opinion.
enum Theme {
    /// A 4pt rhythm. Everything is a multiple, so nothing lands half a step off.
    enum Space {
        static let hair: CGFloat = 2
        static let tight: CGFloat = 4
        static let snug: CGFloat = 6
        static let step: CGFloat = 8
        static let gap: CGFloat = 12
        static let wide: CGFloat = 16
        static let room: CGFloat = 24
    }

    /// Concentric, the way the system draws them: a platter, the highlight that
    /// sits inside it, and the controls that sit inside that.
    enum Radius {
        static let platter: CGFloat = 12
        static let row: CGFloat = 8
        static let field: CGFloat = 8
        static let chip: CGFloat = 6
    }

    /// The system's own text styles, not point sizes. They are the sizes every
    /// other panel on the machine is set in — 13 for what you read, 11 for what
    /// goes with it, 10 for what you glance at — and they are what makes a panel
    /// read as part of the Mac rather than as a page drawn on top of it.
    /// Hierarchy comes from weight and from `primary` / `secondary` / `tertiary`,
    /// never from a colour of our own.
    enum Font {
        static let title = SwiftUI.Font.headline
        /// Which session this is: the sender line of a mail row.
        static let label = SwiftUI.Font.body.weight(.semibold)
        /// What it says: the subject line under it.
        static let subject = SwiftUI.Font.callout
        static let body = SwiftUI.Font.body
        /// Long text, read rather than scanned: an answer, in a column some 400
        /// points wide. A size down from the body with a third of a line of air
        /// between lines is about sixty characters a line, which is where a column
        /// stops being work. At the body size it was forty-five and looked bold.
        static let reading = SwiftUI.Font.callout
        static let caption = SwiftUI.Font.subheadline
        static let micro = SwiftUI.Font.caption
        static let section = SwiftUI.Font.subheadline.weight(.semibold)
        static let mono = SwiftUI.Font.system(.callout, design: .monospaced)
    }

    /// Extra space between the lines of anything in `Font.reading`.
    static let leading: CGFloat = 4

    static let panelWidth: CGFloat = 440
    static let panelMaxHeight: CGFloat = 640

    /// Someone has told the system that motion makes them unwell, and a panel
    /// that ignores that is not a Mac app. Everything below goes through here, so
    /// there is one switch rather than a dozen places that forgot.
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Expanding a card moves everything below it. Without motion that reads as
    /// the list jumping; with too much it reads as a toy.
    static var expand: Animation? { reduceMotion ? nil : .snappy(duration: 0.22, extraBounce: 0) }
    static var hover: Animation? { reduceMotion ? nil : .easeOut(duration: 0.12) }
    /// A row arriving or leaving. Slower than a hover and gentler than an expand:
    /// it is the list changing under you, and it should be followable.
    static var shuffle: Animation? { reduceMotion ? nil : .smooth(duration: 0.3) }

    /// Arriving and leaving the way a Mac list does it — a fade with a little
    /// travel, never a pop. Asymmetric on purpose: what leaves gets out of the
    /// way faster than what arrives settles in.
    static var rowTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(y: -6)),
            removal: .opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
    }

    /// One scale for every usage number in the product.
    static func usageTint(_ percentage: Double) -> Color {
        if percentage >= 90 { return .red }
        if percentage >= 70 { return .yellow }
        return .secondary
    }
}

/// The blurred backdrop an NSPopover draws behind its content. SwiftUI's own
/// materials sit *inside* the window and lose the vibrancy that makes a panel
/// look like part of the system rather than a rectangle on top of it.
struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}

/// Reports how tall a view actually is.
///
/// A `ScrollView` has no height of its own, so a panel built from header +
/// scroller + footer has no definite height either, and every layout below it is
/// a guess. Measuring the content and clamping it is what makes the panel as
/// short as one row and no taller than the screen allows.
struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension View {
    func measureHeight(into binding: Binding<CGFloat>) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(key: HeightKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(HeightKey.self) { height in
            if height > 0, abs(binding.wrappedValue - height) > 0.5 {
                binding.wrappedValue = height
            }
        }
    }
}

/// A ring, for a number that is a fraction of something.
///
/// Rings over bars because a bar in a row competes with the text beside it for
/// the same horizontal space, and this number is weather — it must never win.
struct UsageRing: View {
    let label: String
    let percentage: Double?
    var help: String = ""
    var size: CGFloat = 22
    @State private var hovering = false

    private var fraction: Double { min(1, max(0, (percentage ?? 0) / 100)) }
    private var tint: Color { Theme.usageTint(percentage ?? 0) }
    /// What the question actually is. "5h" says which window; hovering asks how
    /// much of it is left, so that is the number that appears.
    private var remaining: String? {
        guard let percentage else { return nil }
        return "\(Int((100 - min(100, max(0, percentage))).rounded()))%"
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(tint.opacity(percentage == nil ? 0.25 : 0.9),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(hovering ? (remaining ?? label) : label)
                .font(.system(size: hovering && remaining != nil ? 7.5 : 8, weight: .semibold))
                .foregroundStyle(hovering ? AnyShapeStyle(tint) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .frame(width: size, height: size)
        .help(help)
        .onHover { value in withAnimation(Theme.hover) { hovering = value } }
        .animation(Theme.expand, value: fraction)
    }
}

/// A row you can choose.
///
/// A plain button gives no sign it was pressed, which on a control that commits
/// an answer is the one place silence is unaffordable — the person is left
/// wondering whether the tap landed. This is what a Mac list row does: a quiet
/// fill under the pointer, a firmer one while held, and it settles rather than
/// snapping back.
struct OptionButton: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, Theme.Space.snug)
            .padding(.vertical, Theme.Space.tight + 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    .fill(.primary.opacity(configuration.isPressed ? 0.12 : hovering ? 0.06 : 0)))
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed && !Theme.reduceMotion ? 0.985 : 1, anchor: .leading)
            .animation(Theme.hover, value: configuration.isPressed)
            .onHover { value in withAnimation(Theme.hover) { hovering = value } }
    }
}
