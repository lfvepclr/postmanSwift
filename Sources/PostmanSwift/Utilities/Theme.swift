import SwiftUI

enum Theme {
    static let accent = Color(red: 1.0, green: 0.424, blue: 0.216)
    static let accentSoft = Color(red: 1.0, green: 0.424, blue: 0.216).opacity(0.12)
    static let sidebar = Color(nsColor: .controlBackgroundColor)
    static let panel = Color(nsColor: .windowBackgroundColor)
    static let editor = Color(nsColor: .textBackgroundColor)
    static let border = Color(nsColor: .separatorColor)
    static let secondaryText = Color(nsColor: .secondaryLabelColor)
    static let tertiaryText = Color(nsColor: .tertiaryLabelColor)
    static let success = Color(red: 0.2, green: 0.65, blue: 0.35)
    static let danger = Color(red: 0.85, green: 0.25, blue: 0.25)
    static let warning = Color(red: 0.95, green: 0.65, blue: 0.15)

    static func methodColor(_ method: String) -> Color {
        switch method.uppercased() {
        case "GET": return Color(red: 0.15, green: 0.62, blue: 0.38)
        case "POST": return Color(red: 0.95, green: 0.55, blue: 0.12)
        case "PUT": return Color(red: 0.18, green: 0.48, blue: 0.9)
        case "PATCH": return Color(red: 0.55, green: 0.35, blue: 0.85)
        case "DELETE": return Color(red: 0.85, green: 0.25, blue: 0.25)
        case "HEAD": return Color(red: 0.1, green: 0.6, blue: 0.65)
        case "OPTIONS": return Color(red: 0.5, green: 0.4, blue: 0.2)
        default: return .secondary
        }
    }

    static func statusColor(_ code: Int) -> Color {
        switch code {
        case 200..<300: return success
        case 300..<400: return warning
        case 400...: return danger
        default: return .secondary
        }
    }
}

/// Stable per-environment colors so the same environment keeps its color across launches.
enum EnvironmentPalette {
    static let globalsColor = Color(red: 0.52, green: 0.36, blue: 0.86)

    static let colors: [Color] = [
        Color(red: 1.00, green: 0.45, blue: 0.24),
        Color(red: 0.16, green: 0.50, blue: 0.90),
        Color(red: 0.18, green: 0.64, blue: 0.42),
        Color(red: 0.86, green: 0.36, blue: 0.62),
        Color(red: 0.10, green: 0.62, blue: 0.66),
        Color(red: 0.62, green: 0.45, blue: 0.18),
        Color(red: 0.40, green: 0.42, blue: 0.88),
        Color(red: 0.78, green: 0.30, blue: 0.30)
    ]

    static func color(for id: String) -> Color {
        guard id != "globals" else { return globalsColor }
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in id.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return colors[Int(hash % UInt64(colors.count))]
    }
}

extension View {
    func panelBackground() -> some View {
        background(Theme.editor)
    }
    func thinBorder(_ edges: Edge.Set = .all) -> some View {
        overlay(
            Rectangle()
                .strokeBorder(Theme.border, lineWidth: 0.5)
                .padding(.init(top: edges.contains(.top) ? 0 : 0, leading: 0, bottom: 0, trailing: 0))
        )
    }
}

/// Liquid Glass on macOS 26, with the closest system material for older releases.
enum GlassChrome {
    static var isAvailable: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }
}

extension View {
    /// Translucent chrome surface: sidebar, tab bar, toolbars.
    @ViewBuilder
    func chromeSurface(cornerRadius: CGFloat = 0) -> some View {
        if #available(macOS 26.0, *) {
            background {
                Color.clear.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
            }
        } else {
            background(.ultraThinMaterial)
        }
    }

    /// A glass pill for grouped controls (footer buttons, badges, floating chips).
    @ViewBuilder
    func glassCapsule(tint: Color? = nil) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(tint.map { Glass.regular.tint($0) } ?? .regular, in: .capsule)
        } else {
            background(.ultraThinMaterial, in: Capsule())
        }
    }

    /// A glass rounded card, used for sheets and floating panels.
    @ViewBuilder
    func glassCard(cornerRadius: CGFloat = 14) -> some View {
        if #available(macOS 26.0, *) {
            background {
                Color.clear.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
            }
        } else {
            background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}
