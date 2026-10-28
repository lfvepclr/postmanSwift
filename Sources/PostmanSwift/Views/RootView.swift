import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct RootView: View {
    @Environment(AppStore.self) private var store
    @EnvironmentObject private var ui: UIState
    @AppStorage("sidebarWidth") private var sidebarWidth: Double = 290
    @State private var dragStartWidth: Double?

    var body: some View {
        HStack(spacing: 0) {
            SidebarView()
                .frame(width: clampedSidebarWidth)
                .clipped()
            sidebarDivider
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        }
        .background(Theme.editor)
        .onAppear {
            PerformanceProbe.event("firstFrame")
            store.startDeferredWork()
        }
        .overlay(alignment: .topLeading) {
            ZStack(alignment: .leading) {
                WindowDragView()
                    .frame(width: 74, height: 28)
                WindowControlsOverlay()
                    .padding(.leading, 12)
            }
            .frame(width: 74, height: 28)
            .padding(.top, 6)
        }
        .frame(minWidth: 960, minHeight: 620)
        .overlay {
            codeSnippetOverlay
                .animation(.easeOut(duration: 0.12), value: ui.codeSnippetTabID)
        }
        .sheet(isPresented: $ui.showSettings) {
            SettingsView().environment(store).environmentObject(ui).background(Theme.editor)
        }
        .sheet(isPresented: $ui.showConsole) {
            ConsoleView().environment(store).environmentObject(ui).background(Theme.editor)
        }
        .sheet(isPresented: $ui.showRunner) {
            RunnerView().environment(store).environmentObject(ui).background(Theme.editor)
        }
        .sheet(isPresented: $ui.showCookies) {
            CookiesView().environment(store).environmentObject(ui).background(Theme.editor)
        }
        .sheet(isPresented: $ui.showWebSocket) {
            WebSocketView().environment(store).environmentObject(ui).background(Theme.editor)
        }
        .fileImporter(
            isPresented: $ui.showImportPanel,
            allowedContentTypes: [.json, .text, .plainText],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: url)
                    store.importFile(data: data, filename: url.lastPathComponent)
                } catch {
                    store.showAlert(error.localizedDescription)
                }
            case .failure(let error):
                store.showAlert(error.localizedDescription)
            }
        }
        .alert("PostmanSwift", isPresented: alertPresented) {
            Button("OK") { ui.alertMessage = nil }
        } message: {
            Text(ui.alertMessage ?? "")
        }
        .alert("Unsaved Changes", isPresented: pendingClosePresented) {
            Button(ui.pendingTabClose?.dirtyCount == 1 ? "Save" : "Save All") {
                store.confirmPendingClose(save: true)
            }
            Button(ui.pendingTabClose?.dirtyCount == 1 ? "Don't Save" : "Discard All", role: .destructive) {
                store.confirmPendingClose(save: false)
            }
            Button("Cancel", role: .cancel) {
                ui.pendingTabClose = nil
            }
        } message: {
            Text(pendingCloseMessage)
        }
    }

    private var clampedSidebarWidth: CGFloat {
        CGFloat(min(380, max(240, sidebarWidth)))
    }

    private var sidebarDivider: some View {
        ZStack {
            Theme.panel
            Rectangle()
                .fill(Theme.border.opacity(0.9))
                .frame(width: 1)
        }
        .frame(width: 7)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if dragStartWidth == nil { dragStartWidth = sidebarWidth }
                    sidebarWidth = min(380, max(240, (dragStartWidth ?? sidebarWidth) + value.translation.width))
                }
                .onEnded { _ in
                    dragStartWidth = nil
                }
        )
    }

    @ViewBuilder
    private var detail: some View {
        switch store.workspace {
        case .mock:
            MockWorkspaceView(server: store.mockServer)
        case .environments:
            EnvironmentWorkspaceView()
        case .requests:
            VStack(spacing: 0) {
                TabBarView()
                if store.tabs.isEmpty {
                    WelcomeView()
                } else {
                    RequestWorkspaceView()
                }
            }
            .background(Theme.editor)
        }
    }

    @ViewBuilder
    private var codeSnippetOverlay: some View {
        if let id = ui.codeSnippetTabID,
           let tab = store.tabs.first(where: { $0.id == id }) {
            ZStack {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .onTapGesture { store.closeCodeSnippet() }
                CodeSnippetView(tab: tab)
                    .environment(store)
                    .background(Theme.editor, in: RoundedRectangle(cornerRadius: 14))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(Theme.border, lineWidth: 0.8)
                    )
                    .shadow(color: .black.opacity(0.28), radius: 24, y: 12)
                    .onExitCommand { store.closeCodeSnippet() }
            }
            .transition(.opacity)
        }
    }

    private var pendingClosePresented: Binding<Bool> {
        Binding(
            get: { ui.pendingTabClose != nil },
            set: { if !$0 { ui.pendingTabClose = nil } }
        )
    }

    private var pendingCloseMessage: String {
        guard let pending = ui.pendingTabClose else { return "" }
        if let title = pending.singleTitle {
            var message = "「\(title)」has unsaved changes."
            if pending.unsavableCount > 0 {
                message += " This request does not belong to a collection yet; save it from the request header before closing."
            }
            return message
        }
        var message = "\(pending.dirtyCount) tabs have unsaved changes."
        if pending.unsavableCount > 0 {
            message += " \(pending.unsavableCount) request(s) are not in a collection and will stay open so you can pick one."
        }
        return message
    }

    private var alertPresented: Binding<Bool> {
        Binding(
            get: { ui.alertMessage != nil },
            set: { if !$0 { ui.alertMessage = nil } }
        )
    }
}
