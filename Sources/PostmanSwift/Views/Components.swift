import SwiftUI

struct MethodBadge: View {
    let method: String
    var fontSize: CGFloat = 10

    var body: some View {
        Text(method.uppercased())
            .font(.system(size: fontSize, weight: .bold, design: .monospaced))
            .foregroundStyle(Theme.methodColor(method))
            .frame(minWidth: 38, alignment: .leading)
    }
}

struct StatusBadge: View {
    let code: Int
    let text: String

    var body: some View {
        Text("\(code) \(text)")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.statusColor(code))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Theme.statusColor(code).opacity(0.12), in: Capsule())
    }
}

struct CountBadge: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text("\(count)")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.secondary.opacity(0.12), in: Capsule())
        }
    }
}

struct SectionTabButton: View {
    let title: String
    let isSelected: Bool
    var badge: Int = 0
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                HStack(spacing: 5) {
                    Text(title)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.primary : Theme.secondaryText)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    CountBadge(count: badge)
                }
                Rectangle()
                    .fill(isSelected ? Theme.accent : Color.clear)
                    .frame(height: 2)
            }
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct IconButton: View {
    let systemName: String
    var help: String = ""
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                Theme.accent.opacity(configuration.isPressed ? 0.82 : 1),
                in: Capsule()
            )
            .overlay(
                Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
            )
    }
}

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Theme.tertiaryText)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

struct EnvironmentMenu: View {
    @Environment(AppStore.self) private var store
    @State private var hovering = false

    var body: some View {
        Menu {
            Button {
                store.setActiveEnvironment(id: nil)
            } label: {
                Label("No Environment", systemImage: store.library.activeEnvironmentID == nil ? "checkmark" : "circle")
            }
            if !store.library.environments.isEmpty {
                Divider()
                ForEach(store.library.environments) { environment in
                    Button {
                        store.setActiveEnvironment(id: environment.id)
                    } label: {
                        Label(environment.name, systemImage: store.library.activeEnvironmentID == environment.id ? "checkmark" : "circle")
                    }
                }
            }
            Divider()
            Button("Manage Environments…") { store.openEnvironments() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "globe")
                    .font(.system(size: 10))
                Text(store.activeEnvironmentName)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 130, alignment: .leading)
            }
            .foregroundStyle(Theme.secondaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(hovering ? Color.secondary.opacity(0.1) : Color.clear, in: Capsule())
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help("Active environment")
    }
}

struct SearchField: View {
    @Binding var text: String
    var placeholder: String = "Search"

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiaryText)
            InlineTextField(text: $text, placeholder: placeholder, fontSize: 12)
                .frame(maxWidth: .infinity)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
    }
}

struct ReadOnlyRow: View {
    let key: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(key)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 180, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}

enum RelativeTime {
    /// Reused across row renders; a fresh RelativeDateTimeFormatter per call showed up in traces.
    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    static func string(_ date: Date) -> String {
        formatter.localizedString(for: date, relativeTo: Date())
    }
}

struct WindowDragView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        DragView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.zoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }
    }
}

struct WindowControlsOverlay: View {
    private let closeColor = Color(red: 1.00, green: 0.37, blue: 0.34)
    private let minimizeColor = Color(red: 0.99, green: 0.74, blue: 0.18)
    private let zoomColor = Color(red: 0.16, green: 0.78, blue: 0.25)

    var body: some View {
        HStack(spacing: 8) {
            TrafficLightDot(color: closeColor, symbol: "xmark") {
                (NSApp.keyWindow ?? NSApp.mainWindow)?.performClose(nil)
            }
            TrafficLightDot(color: minimizeColor, symbol: "minus") {
                guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
                if window.styleMask.contains(.fullScreen) {
                    window.toggleFullScreen(nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        window.miniaturize(nil)
                    }
                } else {
                    window.miniaturize(nil)
                }
            }
            TrafficLightDot(color: zoomColor, symbol: "arrow.up.left.and.arrow.down.right") {
                (NSApp.keyWindow ?? NSApp.mainWindow)?.zoom(nil)
            }
        }
    }
}

private struct TrafficLightDot: View {
    let color: Color
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(color)
                    .frame(width: 12, height: 12)
                if hovering {
                    Image(systemName: symbol)
                        .font(.system(size: 6, weight: .black))
                        .foregroundStyle(Color.black.opacity(0.55))
                }
            }
            .frame(width: 14, height: 14)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
