import SwiftUI

struct TabBarView: View {
    @Environment(AppStore.self) private var store
    var leadingInset: CGFloat = 0
    @State private var hoveredTabID: RequestTab.ID?

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 0) {
                        ForEach(store.tabs) { tab in
                            tabChip(tab)
                                .id(tab.id)
                        }
                    }
                }
                .onAppear {
                    if let id = store.activeTabID {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
                .onChange(of: store.activeTabID) { _, id in
                    guard let id else { return }
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            Button {
                store.newRequest(collectionID: store.activeTab?.collectionID ?? store.library.collections.first?.id, parentID: nil)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 30, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New request")

            Rectangle()
                .fill(Theme.border)
                .frame(width: 1, height: 16)
                .padding(.horizontal, 4)

            EnvironmentMenu()
                .padding(.trailing, 10)
        }
        .padding(.leading, leadingInset)
        .frame(height: 35)
        .chromeSurface()
        .overlay(alignment: .bottom) { Divider().opacity(0.6) }
    }

    private func tabChip(_ tab: RequestTab) -> some View {
        let isActive = store.activeTabID == tab.id
        let index = store.tabs.firstIndex { $0.id == tab.id } ?? 0
        let isHovered = hoveredTabID == tab.id
        return HStack(spacing: 7) {
            if tab.isHistory {
                Image(systemName: "clock")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.tertiaryText)
                    .help("Opened from history")
            }
            MethodBadge(method: tab.draft.method, fontSize: 9)
            Text(tab.title)
                .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                .lineLimit(1)
                .frame(maxWidth: 180, alignment: .leading)
            if tab.isDirty {
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 5, height: 5)
            }
            Button {
                store.requestClose(tab)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.tertiaryText)
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .opacity(isActive ? 1 : 0.55)
        }
        .padding(.horizontal, 11)
        .frame(height: 29)
        .background {
            if isActive {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.editor)
                    .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
            } else if isHovered {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 3)
        .overlay(alignment: .bottom) {
            if isActive {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Theme.accent)
                    .frame(height: 2)
                    .padding(.horizontal, 7)
            }
        }
        .overlay(alignment: .leading) {
            if index > 0 {
                Rectangle()
                    .fill(Color.primary.opacity(0.16))
                    .frame(width: 1, height: 18)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                hoveredTabID = tab.id
            } else if hoveredTabID == tab.id {
                hoveredTabID = nil
            }
        }
        .onTapGesture { store.activeTabID = tab.id }
        .contextMenu {
            Button("Close") { store.requestClose(tab) }
            Button("Close Others") { store.requestCloseOthers(tab) }
                .disabled(store.tabs.count <= 1)
            Divider()
            Button("Close Tabs to the Left") { store.requestCloseTabsLeft(of: tab) }
                .disabled(index == 0)
            Button("Close Tabs to the Right") { store.requestCloseTabsRight(of: tab) }
                .disabled(index >= store.tabs.count - 1)
            Divider()
            Button("Close All") { store.requestCloseAll() }
        }
    }
}

/// Reports the workspace container height for the divider drag without wrapping
/// panel content in a GeometryReader.
private struct WorkspaceHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct WorkspaceWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct RequestWorkspaceView: View {
    @Environment(AppStore.self) private var store
    @AppStorage("requestSplitFraction") private var splitFraction: Double = 0.55
    @AppStorage("workspaceSplitOrientation") private var orientation: String = "stacked"
    @AppStorage("workspaceSideSplitFraction") private var sideFraction: Double = 0.55
    @State private var dragStartFraction: Double?
    @State private var hoveringDivider = false
    @State private var containerHeight: CGFloat = 0
    @State private var containerWidth: CGFloat = 0

    private let handleSize: CGFloat = 8
    private let minPaneHeight: CGFloat = 200
    private let minResponseHeight: CGFloat = 170
    private let minPaneWidth: CGFloat = 360

    private var isSideBySide: Bool { orientation == "sideBySide" }

    var body: some View {
        Group {
            if isSideBySide {
                sideBySideLayout
            } else {
                stackedLayout
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            // Size probe only: a background never participates in the panels' layout.
            GeometryReader { proxy in
                Color.clear
                    .preference(key: WorkspaceHeightKey.self, value: proxy.size.height)
                    .preference(key: WorkspaceWidthKey.self, value: proxy.size.width)
            }
        }
        .onPreferenceChange(WorkspaceHeightKey.self) { height in
            guard height > 0, abs(height - containerHeight) > 0.5 else { return }
            containerHeight = height
        }
        .onPreferenceChange(WorkspaceWidthKey.self) { width in
            guard width > 0, abs(width - containerWidth) > 0.5 else { return }
            containerWidth = width
        }
        .background(Theme.editor)
    }

    private var stackedLayout: some View {
        VStack(spacing: 0) {
            editorPane
                .frame(maxWidth: .infinity)
                .frame(
                    height: containerHeight > 1 ? resolvedTopHeight(total: containerHeight) : nil,
                    alignment: .top
                )
                .clipped()

            divider(vertical: false)

            responsePane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        }
    }

    private var sideBySideLayout: some View {
        HStack(spacing: 0) {
            editorPane
                .frame(width: containerWidth > 1 ? resolvedLeftWidth(total: containerWidth) : nil)
                .frame(maxHeight: .infinity)
                .clipped()

            divider(vertical: true)

            responsePane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        }
    }

    @ViewBuilder
    private var editorPane: some View {
        if let tab = store.activeTab {
            RequestEditorView(tab: tab)
                .id(tab.id)
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private var responsePane: some View {
        if let tab = store.activeTab {
            ResponseView(tab: tab)
                .id(tab.id)
        } else {
            Color.clear
        }
    }

    private func resolvedTopHeight(total: CGFloat) -> CGFloat {
        let minimum = min(minPaneHeight, max(120, total * 0.3))
        let maximum = max(minimum, total - minResponseHeight - handleSize)
        let proposed = total * splitFraction - handleSize / 2
        return min(maximum, max(minimum, proposed))
    }

    private func resolvedLeftWidth(total: CGFloat) -> CGFloat {
        let minimum = min(minPaneWidth, max(280, total * 0.32))
        let maximum = max(minimum, total - minPaneWidth - handleSize)
        let proposed = total * sideFraction - handleSize / 2
        return min(maximum, max(minimum, proposed))
    }

    private func divider(vertical: Bool) -> some View {
        ZStack {
            Theme.panel
            Rectangle()
                .fill(hoveringDivider || dragStartFraction != nil ? Theme.accent : Theme.border)
                .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
        }
        .frame(width: vertical ? handleSize : nil, height: vertical ? nil : handleSize)
        .frame(maxWidth: vertical ? nil : .infinity, maxHeight: vertical ? .infinity : nil)
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveringDivider = hovering
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if vertical {
                        guard containerWidth > 1 else { return }
                        if dragStartFraction == nil { dragStartFraction = sideFraction }
                        let minimum = min(minPaneWidth, max(280, containerWidth * 0.32)) / containerWidth
                        let maximum = max(minimum, 1 - (minPaneWidth + handleSize) / containerWidth)
                        let delta = value.translation.width / containerWidth
                        sideFraction = min(maximum, max(minimum, (dragStartFraction ?? sideFraction) + delta))
                    } else {
                        let totalHeight = containerHeight
                        guard totalHeight > 1 else { return }
                        if dragStartFraction == nil { dragStartFraction = splitFraction }
                        let minimum = min(minPaneHeight, max(120, totalHeight * 0.3)) / totalHeight
                        let maximum = max(minimum, 1 - (minResponseHeight + handleSize) / totalHeight)
                        let delta = value.translation.height / totalHeight
                        splitFraction = min(maximum, max(minimum, (dragStartFraction ?? splitFraction) + delta))
                    }
                }
                .onEnded { _ in
                    dragStartFraction = nil
                }
        )
    }
}

struct WelcomeView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "paperplane.fill")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(Theme.accent)
            VStack(spacing: 6) {
                Text("PostmanSwift")
                    .font(.system(size: 24, weight: .semibold))
                Text("A local-first, native Swift API client")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
            }
            HStack(spacing: 10) {
                Button("New Request") {
                    store.newRequest(collectionID: store.library.collections.first?.id, parentID: nil)
                }
                .buttonStyle(PrimaryButtonStyle())
                Button("Import…") { store.ui.showImportPanel = true }
                    .buttonStyle(.bordered)
            }
            VStack(alignment: .leading, spacing: 6) {
                shortcut("⌘N", "New request")
                shortcut("⌘↩", "Send request")
                shortcut("⌘S", "Save request")
                shortcut("⌘E", "Manage environments")
                shortcut("⌘⇧R", "Open runner")
            }
            .padding(14)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.editor)
    }

    private func shortcut(_ key: String, _ title: String) -> some View {
        HStack(spacing: 10) {
            Text(key)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 38, alignment: .trailing)
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
        }
    }
}
