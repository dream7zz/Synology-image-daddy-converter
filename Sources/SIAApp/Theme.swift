import SwiftUI

/// Design tokens for the "darkroom" direction.
///
/// Deliberately not the default SwiftUI look: near-black surfaces, one warm
/// accent (safelight amber), monospaced numerals, and a serif for section
/// titles so the window reads like a lab instrument rather than a dashboard.
enum Theme {

    // MARK: Colour

    static let background = Color(hex: 0x0E0F12)
    static let panel = Color(hex: 0x16181D)
    static let panelRaised = Color(hex: 0x1C1F26)
    static let stroke = Color(hex: 0x252932)
    static let text = Color(hex: 0xE8EAED)
    static let textDim = Color(hex: 0x9BA1A9)
    static let textFaint = Color(hex: 0x6B7280)

    static let accent = Color(hex: 0xF5A524)      // safelight amber
    static let success = Color(hex: 0x3FB950)
    static let warning = Color(hex: 0xD29922)
    static let danger = Color(hex: 0xF85149)

    // MARK: Type

    static func title(_ size: CGFloat = 15) -> Font {
        .system(size: size, weight: .semibold, design: .serif)
    }
    static func body(_ size: CGFloat = 12) -> Font {
        .system(size: size, weight: .regular)
    }
    static func mono(_ size: CGFloat = 12, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    // MARK: Metrics

    static let radiusCard: CGFloat = 10
    static let radiusControl: CGFloat = 8
    static let gutter: CGFloat = 12
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

/// Small caps label used above every group of controls.
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .kerning(0.8)
            .foregroundStyle(Theme.textFaint)
    }
}

/// Rounded pill used for states and counters.
struct Pill: View {
    let text: String
    var color: Color = Theme.textDim
    var filled: Bool = false

    var body: some View {
        Text(text)
            .font(Theme.mono(10, weight: .medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(filled ? color.opacity(0.16) : .clear)
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(color.opacity(filled ? 0.0 : 0.45), lineWidth: 1)
            )
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

/// The card surface used by the grid and inspector.
struct CardBackground: ViewModifier {
    var selected: Bool = false
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusCard)
                    .fill(Theme.panelRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusCard)
                    .stroke(selected ? Theme.accent.opacity(0.9) : Theme.stroke,
                            lineWidth: selected ? 1.5 : 1)
            )
    }
}

extension View {
    func card(selected: Bool = false) -> some View {
        modifier(CardBackground(selected: selected))
    }
}
