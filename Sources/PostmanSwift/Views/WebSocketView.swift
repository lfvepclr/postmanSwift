import SwiftUI
import AppKit

struct WebSocketView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @StateObject private var client = WebSocketClient()
    @State private var urlText = "wss://echo.websocket.events"
    @State private var headers: [KeyValue] = []
    @State private var composer = ""
    @State private var showHeaders = false
    @State private var localError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            connectionBar
            if showHeaders {
                Divider()
                headerEditor
            }
            Divider()
            messageLog
            Divider()
            composerBar
        }
        .frame(width: 920, height: 640)
        .onDisappear { client.disconnect() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt.horizontal.circle.fill")
                .foregroundStyle(Theme.accent)
            Text("WebSocket")
                .font(.system(size: 14, weight: .semibold))
            stateBadge
            if let negotiated = client.negotiatedProtocol {
                Text(negotiated)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.tertiaryText)
            }
            Spacer()
            Button("Clear") { client.clearMessages() }
            Button("Close") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var stateBadge: some View {
        Text(client.state.rawValue)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color(for: client.state))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color(for: client.state).opacity(0.12), in: Capsule())
    }

    private func color(for state: WebSocketClient.State) -> Color {
        switch state {
        case .connected: return Theme.success
        case .connecting, .closing: return Theme.warning
        case .disconnected: return Theme.secondaryText
        }
    }

    private var connectionBar: some View {
        HStack(spacing: 8) {
            TextField("wss://example.com/socket", text: $urlText)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .padding(.horizontal, 9)
                .frame(height: 30)
                .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border))
                .onSubmit(connect)

            Button {
                showHeaders.toggle()
            } label: {
                Label("Headers", systemImage: "list.bullet.rectangle")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(showHeaders ? Theme.accent : Theme.secondaryText)

            if client.isConnected {
                Button("Ping") { client.sendPing() }
                    .buttonStyle(.bordered)
                Button("Disconnect") { client.disconnect() }
                    .buttonStyle(.bordered)
            } else {
                Button("Connect", action: connect)
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(client.state == .connecting)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var headerEditor: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Handshake headers (sent when connecting)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 12)
                .padding(.top, 6)
            KeyValueEditor(rows: $headers, keyPlaceholder: "Header", valuePlaceholder: "Value")
        }
    }

    private var messageLog: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if client.messages.isEmpty {
                        EmptyStateView(
                            icon: "bolt.horizontal",
                            title: "No messages",
                            message: "Connect to a WebSocket endpoint, then send a message below."
                        )
                        .frame(minHeight: 220)
                    }
                    ForEach(client.messages) { message in
                        messageRow(message)
                            .id(message.id)
                    }
                }
                .padding(12)
            }
            .onChange(of: client.messages.count) { _, _ in
                if let last = client.messages.last {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .background(Theme.editor)
    }

    private func messageRow(_ message: WebSocketMessage) -> some View {
        HStack {
            if message.direction == .sent { Spacer(minLength: 80) }
            VStack(alignment: message.direction == .sent ? .trailing : .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(label(for: message.direction))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(labelColor(for: message.direction))
                    Text(message.timestamp.formatted(date: .omitted, time: .standard))
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(Theme.tertiaryText)
                }
                Text(message.text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(bubbleColor(for: message.direction), in: RoundedRectangle(cornerRadius: 6))
            }
            if message.direction != .sent { Spacer(minLength: 80) }
        }
    }

    private func label(for direction: WebSocketMessage.Direction) -> String {
        switch direction {
        case .sent: return "SENT"
        case .received: return "RECEIVED"
        case .system: return "SYSTEM"
        }
    }

    private func labelColor(for direction: WebSocketMessage.Direction) -> Color {
        switch direction {
        case .sent: return Theme.accent
        case .received: return Theme.success
        case .system: return Theme.secondaryText
        }
    }

    private func bubbleColor(for direction: WebSocketMessage.Direction) -> Color {
        switch direction {
        case .sent: return Theme.accentSoft
        case .received: return Color.secondary.opacity(0.09)
        case .system: return Color.clear
        }
    }

    private var composerBar: some View {
        VStack(spacing: 6) {
            if let error = client.error ?? localError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.danger)
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.secondaryText)
                    Spacer()
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextEditor(text: $composer)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 62)
                    .padding(4)
                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border))
                Button {
                    sendMessage()
                } label: {
                    Text("Send")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 72, height: 30)
                        .background(Theme.accent.opacity(canSend ? 1 : 0.5), in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var canSend: Bool {
        client.isConnected && !composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func connect() {
        localError = nil
        let resolved = store.resolveText(urlText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: URLUtilities.normalize(resolved)),
              let scheme = url.scheme?.lowercased(),
              scheme == "ws" || scheme == "wss" else {
            localError = "Enter a valid ws:// or wss:// URL."
            return
        }
        let resolvedHeaders = headers.filter(\.isEnabled).map {
            KeyValue(key: store.resolveText($0.key), value: store.resolveText($0.value))
        }
        client.connect(url: url, headers: resolvedHeaders, cookies: store.cookieJar, settings: store.library.settings)
    }

    private func sendMessage() {
        let text = composer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        client.send(text)
        composer = ""
    }
}
