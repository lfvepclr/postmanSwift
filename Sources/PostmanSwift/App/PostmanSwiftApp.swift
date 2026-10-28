import SwiftUI
import AppKit

@main
struct PostmanSwiftApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = AppStore.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environmentObject(store.ui)
                .frame(minWidth: 960, minHeight: 620)
                .ignoresSafeArea(.container, edges: .top)
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1100, height: 700)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About PostmanSwift") { AppInfo.showAboutPanel() }
            }
            CommandGroup(replacing: .newItem) {
                Button("New Request") {
                    store.newRequest(collectionID: store.library.collections.first?.id, parentID: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
                Button("New Collection") {
                    store.newCollection()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("New Folder") {
                    if let collectionID = store.activeTab?.collectionID ?? store.library.collections.first?.id {
                        store.newFolder(collectionID: collectionID, parentID: nil)
                    }
                }
                .keyboardShortcut("n", modifiers: [.command, .option])
            }
            CommandGroup(after: .newItem) {
                Button("Import…") { store.ui.showImportPanel = true }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Close Tab") {
                    if let tab = store.activeTab { store.requestClose(tab) }
                }
                .keyboardShortcut("w", modifiers: .command)
            }
            CommandMenu("Request") {
                Button("Send") {
                    if let tab = store.activeTab { store.send(tab) }
                }
                .keyboardShortcut(.return, modifiers: .command)
                Button("Save") {
                    if let tab = store.activeTab { store.save(tab) }
                }
                .keyboardShortcut("s", modifiers: .command)
                Divider()
                Button("Manage Environments") { store.openEnvironments() }
                    .keyboardShortcut("e", modifiers: .command)
                Button("Cookies") { store.ui.showCookies = true }
                Button("WebSocket Client") { store.ui.showWebSocket = true }
                Button("Mock API") { store.setSidebarMode(.mock) }
                Button("Runner") { store.ui.showRunner = true }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Console") { store.ui.showConsole = true }
                    .keyboardShortcut("j", modifiers: [.command, .shift])
                Button("Settings") { store.ui.showSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var signalSource: DispatchSourceSignal?
    private var didNormalizeInitialWindow = false
    private var borderlessWindows = Set<ObjectIdentifier>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppStore.shared.applyTheme()
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
            if let window = note.object as? NSWindow {
                self?.restoreWindowControls(window)
                self?.normalizeInitialWindow(window)
            }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification, object: nil, queue: .main) { [weak self] note in
            guard let window = note.object as? NSWindow else { return }
            self?.borderlessWindows.remove(ObjectIdentifier(window))
            self?.restoreWindowControls(window)
        }
        DispatchQueue.main.async {
            for window in NSApp.windows {
                self.restoreWindowControls(window)
                self.normalizeInitialWindow(window)
            }
        }
        Darwin.signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                AppStore.shared.persistNow()
            }
            exit(0)
        }
        source.resume()
        signalSource = source
    }

    private func normalizeInitialWindow(_ window: NSWindow) {
        guard !didNormalizeInitialWindow else { return }
        didNormalizeInitialWindow = true
        window.isRestorable = false
        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
            return
        }
        if window.isZoomed {
            window.zoom(nil)
        }
        // A restored frame may point at a display the user is not looking at. Launch
        // where the launch click happened instead of opening silently on another screen.
        if let target = screenUnderMouse() ?? NSScreen.main,
           let placed = WindowPlacement.placedFrame(for: window.frame, in: target.visibleFrame) {
            window.setFrame(placed, display: true)
        }
        let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let tooLarge = window.frame.width > 1200 || window.frame.height > 820
        guard tooLarge, visible.width > 200, visible.height > 200 else { return }
        let width = min(1100, visible.width - 80)
        let height = min(700, visible.height - 80)
        let rect = NSRect(
            x: visible.midX - width / 2,
            y: visible.midY - height / 2,
            width: width,
            height: height
        )
        window.setFrame(rect, display: true)
    }

    private func restoreWindowControls(_ window: NSWindow) {
        // Sheets, alerts and panels become key too. Restyling them as borderless windows makes the
        // sheet lose its chrome/buttons and can leave a modal alert stuck with no way to dismiss it.
        guard window.sheetParent == nil, !(window is NSPanel) else {
            if window.sheetParent != nil, !(window is NSPanel) {
                // SwiftUI sheets in this borderless window need their own rounded, transparent shell
                // so the content provides the surface (and nothing falls back to the window gray).
                window.isOpaque = false
                window.backgroundColor = .clear
                window.contentView?.wantsLayer = true
                window.contentView?.layer?.cornerRadius = 14
                window.contentView?.layer?.masksToBounds = true
            }
            return
        }
        let identifier = ObjectIdentifier(window)
        guard !borderlessWindows.contains(identifier) else { return }
        borderlessWindows.insert(identifier)
        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
        // Keep the window titled: a borderless NSWindow cannot become key, so once the app
        // lost focus no text field could ever be focused again. Hiding the title bar and
        // buttons gives the same borderless look while staying a normal key window.
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.hasShadow = true
        window.isMovableByWindowBackground = false
        if #available(macOS 26.0, *) {
            // Liquid Glass samples what is behind the window, so the window itself must not paint an
            // opaque backdrop. Editors keep their own opaque surface.
            window.isOpaque = false
            window.backgroundColor = .clear
        }
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.cornerRadius = 12
        window.contentView?.layer?.masksToBounds = true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Dock/Finder activation must bring the (borderless, hidden-titlebar) window back:
    /// restore it from the Dock, pull it back from a disconnected display and focus it.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated {
            revealMainWindow(in: sender)
        }
        return true
    }

    private func revealMainWindow(in app: NSApplication) {
        let candidates = app.windows.filter { $0.sheetParent == nil && !($0 is NSPanel) }
        guard let window = candidates.first(where: { $0.isVisible }) ?? candidates.first else {
            app.activate(ignoringOtherApps: true)
            return
        }
        if window.isMiniaturized { window.deminiaturize(nil) }
        if !window.styleMask.contains(.fullScreen) {
            place(window, on: screenUnderMouse() ?? NSScreen.main)
        }
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
    }

    private func screenUnderMouse() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
    }

    /// Dock clicks are a "show me the window" gesture: if the window sits on another
    /// display (or was left off-screen by a display change), bring it to the display
    /// the click came from instead of silently activating on a screen nobody is looking at.
    private func place(_ window: NSWindow, on screen: NSScreen?) {
        guard let visible = screen?.visibleFrame,
              let frame = WindowPlacement.placedFrame(for: window.frame, in: visible) else { return }
        window.setFrame(frame, display: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppStore.shared.persistNow()
    }
}
