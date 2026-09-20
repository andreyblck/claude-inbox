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

    enum Radius {
        static let card: CGFloat = 10
        static let chip: CGFloat = 7
        static let pill: CGFloat = 5
    }

    /// The scale is narrow on purpose. Hierarchy comes from weight and colour,
    /// because five type sizes in a 460pt panel reads as five different apps.
    enum Font {
        static let title = SwiftUI.Font.system(size: 13, weight: .semibold)
        static let row = SwiftUI.Font.system(size: 12.5, weight: .semibold)
        static let body = SwiftUI.Font.system(size: 12, weight: .regular)
        static let caption = SwiftUI.Font.system(size: 11, weight: .regular)
        static let micro = SwiftUI.Font.system(size: 10, weight: .medium)
        static let section = SwiftUI.Font.system(size: 10, weight: .semibold)
        static let mono = SwiftUI.Font.system(size: 11, design: .monospaced)
        static let monoSmall = SwiftUI.Font.system(size: 10, design: .monospaced)
    }

    static let panelWidth: CGFloat = 470
    static let panelMaxHeight: CGFloat = 640

    /// Expanding a card moves everything below it. Without motion that reads as
    /// the list jumping; with too much it reads as a toy.
    static let expand = Animation.snappy(duration: 0.22, extraBounce: 0)
    static let hover = Animation.easeOut(duration: 0.12)

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
    var size: CGFloat = 20

    private var fraction: Double { min(1, max(0, (percentage ?? 0) / 100)) }
    private var tint: Color { Theme.usageTint(percentage ?? 0) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(tint.opacity(percentage == nil ? 0.25 : 0.9),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(label)
                .font(.system(size: 7.5, weight: .bold))
                .foregroundStyle(.tertiary)
        }
        .frame(width: size, height: size)
        .animation(Theme.expand, value: fraction)
    }
}
