import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SidebarView: View {
    @Environment(AppStore.self) private var store
    @EnvironmentObject private var ui: UIState
    @State private var collapsedCollections: Set<String> = []
    @State private var expandedFolders: Set<String> = []
    @State private var collectionSearch = ""
    @State private var historySearch = ""
    @State private var historySearchTask: Task<Void, Never>?
    @State private var renameTarget: RenameTarget?
    @State private var deleteTarget: DeleteTarget?
    @State private var activeSheet: SidebarSheet?
    @State private var draggingItemID: String?
    @State private var draggingSubtreeIDs: Set<String> = []
    @State private var itemDropHint: SidebarItemDropHint?
    @State private var rootDropCollectionID: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            modeTabs
            if store.sidebarMode != .mock {
                searchBar
            }
            Divider()
            content
            Divider()
            footer
        }
        .chromeSurface()
        .alert("Rename", isPresented: renamePresented) {
            TextField("Name", text: Binding(
                get: { renameTarget?.name ?? "" },
                set: { renameTarget?.name = $0 }
            ))
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Rename") { performRename() }
        } message: {
            Text("Enter a new name.")
        }
        .confirmationDialog(
            "Delete \(deleteTarget?.label ?? "")?",
            isPresented: deletePresented,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { performDelete() }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("This action cannot be undone.")
        }
        .sheet(item: $activeSheet) { sheet in
            SidebarSheetView(sheet: sheet)
                .background(Theme.editor)
        }
    }

    // MARK: - Header

    /// Empty title strip: the traffic lights are drawn by the window overlay, the rest is drag space.
    private var header: some View {
        Color.clear
            .frame(height: 30)
            .frame(maxWidth: .infinity)
            .background(WindowDragView())
    }

    /// Underline tabs read as navigation; a segmented control here looked like a row of buttons.
    private var modeTabs: some View {
        HStack(spacing: 2) {
            ForEach(SidebarMode.allCases) { mode in
                modeTab(mode)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .overlay(alignment: .bottom) { Divider().opacity(0.7) }
    }

    private func modeTab(_ mode: SidebarMode) -> some View {
        let isActive = store.sidebarMode == mode
        return Button {
            store.setSidebarMode(mode)
        } label: {
            VStack(spacing: 4) {
                Text(mode.rawValue)
                    .font(.system(size: 11.5, weight: isActive ? .semibold : .medium))
                    .foregroundStyle(isActive ? Color.primary : Theme.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
                Capsule()
                    .fill(isActive ? Theme.accent : Color.clear)
                    .frame(height: 2)
            }
            .padding(.horizontal, 9)
            .padding(.top, 7)
            .padding(.bottom, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            if store.sidebarMode == .collections {
                addMenu
            }
            SearchField(text: searchBinding, placeholder: store.sidebarMode == .collections ? "Search collections" : "Search history")
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 9)
    }

    private var addMenu: some View {
        PopUpMenuButton(
            systemImage: "plus",
            help: "New request, collection or folder",
            items: [
                .init("New Request") {
                    store.newRequest(collectionID: defaultCollectionID, parentID: nil)
                },
                .init("New Collection") { store.newCollection() },
                .init("New Folder") {
                    if let collectionID = defaultCollectionID {
                        store.newFolder(collectionID: collectionID, parentID: nil)
                    }
                },
                .separator,
                .init("Import…") { ui.showImportPanel = true },
                .init("Export Backup…") {
                    if let data = store.exportBackup() {
                        FilePanels.save(data: data, suggestedName: "PostmanSwift-backup.json")
                    }
                }
            ]
        )
        .offset(x: -7)
    }

    private var searchBinding: Binding<String> {
        if store.sidebarMode == .history {
            return Binding(
                get: { historySearch },
                set: { newValue in
                    historySearch = newValue
                    scheduleHistorySearch(newValue)
                }
            )
        }
        return $collectionSearch
    }

    /// The history query lives here instead of on `AppStore`: typing used to publish a store-wide
    /// change (and hit SQLite) on every keystroke. Refetches are debounced to 300ms.
    private func scheduleHistorySearch(_ text: String) {
        historySearchTask?.cancel()
        historySearchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            store.refreshHistory(search: text)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if store.sidebarMode == .mock {
            MockServiceListView(server: store.mockServer)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if store.sidebarMode == .collections {
                        if collectionSearch.trimmingCharacters(in: .whitespaces).isEmpty {
                            ForEach(store.library.collections) { collection in
                                collectionSection(collection)
                            }
                            if store.library.collections.isEmpty {
                                EmptyStateView(
                                    icon: "folder.badge.plus",
                                    title: "No collections",
                                    message: "Create a collection or import a Postman collection to get started.",
                                    actionTitle: "Create collection",
                                    action: { store.newCollection() }
                                )
                                .frame(height: 220)
                            }
                        } else {
                            ForEach(searchMatches) { match in
                                Button {
                                    store.openRequest(collectionID: match.collectionID, item: match.item)
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            MethodBadge(method: match.item.request?.method ?? "GET", fontSize: 9)
                                            Text(match.item.name)
                                                .font(.system(size: 12))
                                                .lineLimit(1)
                                        }
                                        Text("\(match.collectionName)\(match.folderPath.isEmpty ? "" : " / " + match.folderPath)")
                                            .font(.system(size: 10))
                                            .foregroundStyle(Theme.tertiaryText)
                                            .lineLimit(1)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 4)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } else {
                        historySection
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    private func collectionSection(_ collection: PMCollection) -> some View {
        let isCollapsed = collapsedCollections.contains(collection.id)
        let isActive = store.activeTab?.collectionID == collection.id
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.tertiaryText)
                    .frame(width: 9)
                Image(systemName: isCollapsed ? "folder" : "folder.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.accent.opacity(0.9))
                    .frame(width: 13)
                Text(collection.info.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 2)
                Text("\(CollectionTree.flatten(collection).count)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Theme.tertiaryText)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.1), in: Capsule())
            }
            .padding(.leading, 10)
            .padding(.trailing, 10)
            .frame(height: 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isActive ? Theme.accentSoft.opacity(0.7) : Color.secondary.opacity(0.055))
            .overlay(alignment: .bottom) {
                if rootDropCollectionID == collection.id {
                    Rectangle()
                        .fill(Theme.accent)
                        .frame(height: 2)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if isCollapsed {
                    collapsedCollections.remove(collection.id)
                } else {
                    collapsedCollections.insert(collection.id)
                }
            }
            .onDrop(of: [.text], delegate: RootLevelDropDelegate(
                collectionID: collection.id,
                store: store,
                draggingItemID: $draggingItemID,
                targetedCollectionID: $rootDropCollectionID
            ))
            .contextMenu {
                Button("New Request") {
                    store.createRequest(collectionID: collection.id, parentID: nil)
                }
                Button("New Folder") {
                    store.newFolder(collectionID: collection.id, parentID: nil)
                }
                Divider()
                Button("Authorization…") {
                    activeSheet = .auth(
                        id: UUID(),
                        title: "\(collection.info.name) Authorization",
                        initial: collection.auth ?? .inherit,
                        inherited: .none,
                        inheritedLabel: "No parent",
                        onSave: { store.setCollectionAuth(id: collection.id, auth: $0) }
                    )
                }
                Button("Variables…") {
                    activeSheet = .variables(
                        id: UUID(),
                        title: "\(collection.info.name) Variables",
                        initial: collection.variable ?? [],
                        onSave: { store.setCollectionVariables(id: collection.id, values: $0) }
                    )
                }
                Button("Pre-request Script…") {
                    activeSheet = .script(
                        id: UUID(),
                        title: "\(collection.info.name) Pre-request Script",
                        phase: "prerequest",
                        initial: collection.preRequestScript,
                        onSave: { store.setCollectionScript(id: collection.id, listen: "prerequest", source: $0) }
                    )
                }
                Button("Tests…") {
                    activeSheet = .script(
                        id: UUID(),
                        title: "\(collection.info.name) Tests",
                        phase: "test",
                        initial: collection.testScript,
                        onSave: { store.setCollectionScript(id: collection.id, listen: "test", source: $0) }
                    )
                }
                Divider()
                Button("Rename") {
                    renameTarget = RenameTarget(name: collection.info.name, kind: .collection(collection.id))
                }
                Button("Export Collection…") {
                    if let data = store.exportCollection(id: collection.id) {
                        FilePanels.save(data: data, suggestedName: "\(collection.info.name).postman_collection.json")
                    }
                }
                Divider()
                Button("Delete", role: .destructive) {
                    deleteTarget = DeleteTarget(label: collection.info.name, kind: .collection(collection.id))
                }
            }

            if !isCollapsed {
                if collection.items.isEmpty {
                    Text("No requests yet")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiaryText)
                        .padding(.leading, 44)
                        .padding(.vertical, 3)
                } else {
                    VStack(spacing: 1) {
                        ForEach(collection.items) { item in
                            CollectionItemRow(
                                collectionID: collection.id,
                                parentID: nil,
                                item: item,
                                level: 1,
                                expandedFolders: $expandedFolders,
                                draggingItemID: $draggingItemID,
                                draggingSubtreeIDs: $draggingSubtreeIDs,
                                dropHint: $itemDropHint,
                                onRename: { renameTarget = RenameTarget(name: $0.name, kind: .item($0.id)) },
                                onDelete: { deleteTarget = DeleteTarget(label: $0.name, kind: .item($0.id)) }
                            )
                        }
                    }
                    .padding(.leading, 18)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(isActive ? 0.04 : 0.02))
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill((isActive ? Theme.accent : Theme.border).opacity(isActive ? 0.75 : 0.9))
                            .frame(width: 1.5)
                            .padding(.leading, 12)
                            .padding(.vertical, 3)
                    }
                }
            }
        }
        .padding(.vertical, 3)
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text("History")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                IconButton(systemName: "arrow.clockwise", help: "Refresh") {
                    store.refreshHistory(search: historySearch)
                }
                IconButton(systemName: "trash", help: "Clear history") {
                    store.clearHistory()
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 4)

            if store.history.isEmpty {
                EmptyStateView(icon: "clock", title: "No history", message: "Requests you send will appear here.")
                    .frame(height: 180)
            }

            ForEach(store.history) { entry in
                let display = store.historyDisplay[entry.id]
                Button {
                    store.openHistory(entry)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            MethodBadge(method: display?.method ?? entry.method, fontSize: 9)
                            Text(display?.url ?? entry.url)
                                .font(.system(size: 11, design: .monospaced))
                                .lineLimit(1)
                            Spacer(minLength: 2)
                            Text("\(display?.statusCode ?? entry.statusCode)")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Theme.statusColor(display?.statusCode ?? entry.statusCode))
                        }
                        HStack(spacing: 6) {
                            Text(display?.timeText ?? RelativeTime.string(entry.timestamp))
                            if let name = display?.requestName ?? entry.requestName, !name.isEmpty {
                                Text("·")
                                Text(name)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            Spacer()
                            Text(display?.sizeText ?? ContentUtilities.sizeDescription(entry.responseSize))
                            Text(display?.durationText ?? ContentUtilities.durationDescription(entry.duration))
                        }
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.tertiaryText)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Open") { store.openHistory(entry) }
                    Button("Copy URL") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(entry.url, forType: .string)
                    }
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 6) {
            HStack(spacing: 1) {
                footerButton("terminal", "Console") { ui.showConsole = true }
                footerButton("play.circle", "Runner") { ui.showRunner = true }
                footerButton("bolt.horizontal", "WebSocket") { ui.showWebSocket = true }
                environmentFooterButton
                footerButton("circle.grid.2x2", "Cookies") { ui.showCookies = true }
            }
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .glassCapsule()
            Spacer()
            themeMenu
            footerButton("gearshape", "Settings") { ui.showSettings = true }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var themeMenu: some View {
        Menu {
            Button { store.setTheme("light") } label: {
                Label("Light", systemImage: store.library.settings.theme == "light" ? "checkmark" : "sun.max")
            }
            Button { store.setTheme("dark") } label: {
                Label("Dark", systemImage: store.library.settings.theme == "dark" ? "checkmark" : "moon")
            }
            Button { store.setTheme("system") } label: {
                Label("Follow System", systemImage: store.library.settings.theme == "system" ? "checkmark" : "circle.lefthalf.filled")
            }
        } label: {
            Image(systemName: themeIcon)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Appearance")
        .help("Appearance")
    }

    private var themeIcon: String {
        switch store.library.settings.theme {
        case "light": return "sun.max"
        case "dark": return "moon"
        default: return "circle.lefthalf.filled"
        }
    }

    private func footerButton(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var environmentFooterButton: some View {
        Button {
            store.openEnvironments()
        } label: {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "globe")
                    .font(.system(size: 12))
                    .foregroundStyle(store.workspace == .environments ? Theme.accent : Theme.secondaryText)
                Circle()
                    .fill(EnvironmentPalette.color(for: store.library.activeEnvironmentID ?? "globals"))
                    .frame(width: 5, height: 5)
                    .overlay(Circle().stroke(Theme.panel, lineWidth: 1))
            }
            .frame(width: 28, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Environments")
    }

    // MARK: - Helpers

    private var defaultCollectionID: String? {
        store.activeTab?.collectionID ?? store.library.collections.first?.id
    }

    private var renamePresented: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }

    private var deletePresented: Binding<Bool> {
        Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
    }

    private func performRename() {
        guard let target = renameTarget else { return }
        let name = target.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { renameTarget = nil; return }
        switch target.kind {
        case .collection(let id): store.renameCollection(id: id, to: name)
        case .item(let id): store.rename(itemID: id, to: name)
        }
        renameTarget = nil
    }

    private func performDelete() {
        guard let target = deleteTarget else { return }
        switch target.kind {
        case .collection(let id): store.deleteCollection(id: id)
        case .item(let id): store.delete(itemID: id)
        }
        deleteTarget = nil
    }

    private var searchMatches: [SearchMatch] {
        let query = collectionSearch.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return [] }
        var results: [SearchMatch] = []
        for collection in store.library.collections {
            func walk(_ items: [CollectionItem], path: [String]) {
                for item in items {
                    if item.isFolder {
                        walk(item.item ?? [], path: path + [item.name])
                    } else if item.name.lowercased().contains(query)
                                || (item.request?.rawURL.lowercased().contains(query) ?? false) {
                        results.append(SearchMatch(collectionID: collection.id, collectionName: collection.info.name, folderPath: path.joined(separator: " / "), item: item))
                    }
                }
            }
            walk(collection.items, path: [])
        }
        return results
    }
}

private struct SearchMatch: Identifiable {
    var id: String { item.id }
    let collectionID: String
    let collectionName: String
    let folderPath: String
    let item: CollectionItem
}

enum SidebarDropPosition: Equatable {
    case before
    case inside
    case after
}

struct SidebarItemDropHint: Equatable {
    var itemID: String
    var position: SidebarDropPosition
}

/// Row-level drop target for the collection tree: top/bottom edge reorders among
/// siblings, the middle band of a folder row drops the item inside it.
@MainActor
private struct CollectionItemDropDelegate: DropDelegate {
    let target: CollectionItem
    let targetParentID: String?
    let store: AppStore
    let draggingItemID: Binding<String?>
    let draggingSubtreeIDs: Binding<Set<String>>
    let dropHint: Binding<SidebarItemDropHint?>
    let expandedFolders: Binding<Set<String>>
    let siblings: () -> [CollectionItem]

    private let rowHeight: CGFloat = 26

    func validateDrop(info: DropInfo) -> Bool {
        guard let dragged = draggingItemID.wrappedValue, dragged != target.id else { return false }
        return position(for: info) != nil
    }

    func dropEntered(info: DropInfo) {
        updateHint(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateHint(info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        clearHint()
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            clearHint()
            draggingItemID.wrappedValue = nil
            draggingSubtreeIDs.wrappedValue = []
        }
        guard let dragged = draggingItemID.wrappedValue, dragged != target.id,
              let position = position(for: info) else { return false }
        return apply(dragged: dragged, position: position)
    }

    private func updateHint(_ info: DropInfo) {
        guard let dragged = draggingItemID.wrappedValue, dragged != target.id,
              let position = position(for: info) else {
            clearHint()
            return
        }
        let hint = SidebarItemDropHint(itemID: target.id, position: position)
        if dropHint.wrappedValue != hint { dropHint.wrappedValue = hint }
    }

    private func clearHint() {
        if dropHint.wrappedValue?.itemID == target.id { dropHint.wrappedValue = nil }
    }

    private func position(for info: DropInfo) -> SidebarDropPosition? {
        if target.isFolder, (8...18).contains(info.location.y), canDrop(into: target.id) {
            return .inside
        }
        guard canDrop(into: targetParentID) else { return nil }
        return info.location.y < rowHeight / 2 ? .before : .after
    }

    private func canDrop(into parentID: String?) -> Bool {
        guard let parentID else { return true }
        return !draggingSubtreeIDs.wrappedValue.contains(parentID)
    }

    private func apply(dragged: String, position: SidebarDropPosition) -> Bool {
        switch position {
        case .inside:
            let moved = store.moveItem(itemID: dragged, toParentID: target.id, beforeSiblingID: nil)
            if moved { expandedFolders.wrappedValue.insert(target.id) }
            return moved
        case .before:
            return store.moveItem(itemID: dragged, toParentID: targetParentID, beforeSiblingID: target.id)
        case .after:
            let list = siblings()
            if let index = list.firstIndex(where: { $0.id == target.id }), index + 1 < list.count {
                return store.moveItem(itemID: dragged, toParentID: targetParentID, beforeSiblingID: list[index + 1].id)
            }
            return store.moveItem(itemID: dragged, toParentID: targetParentID, beforeSiblingID: nil)
        }
    }
}

/// Collection header drop target: moves an item of this collection back to the root, at the end.
@MainActor
private struct RootLevelDropDelegate: DropDelegate {
    let collectionID: String
    let store: AppStore
    let draggingItemID: Binding<String?>
    let targetedCollectionID: Binding<String?>

    func validateDrop(info: DropInfo) -> Bool {
        guard let dragged = draggingItemID.wrappedValue,
              let collection = store.collection(id: collectionID) else { return false }
        return CollectionTree.find(collection.items, id: dragged) != nil
    }

    func dropEntered(info: DropInfo) {
        targetedCollectionID.wrappedValue = collectionID
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        targetedCollectionID.wrappedValue = collectionID
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if targetedCollectionID.wrappedValue == collectionID {
            targetedCollectionID.wrappedValue = nil
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            targetedCollectionID.wrappedValue = nil
            draggingItemID.wrappedValue = nil
        }
        guard let dragged = draggingItemID.wrappedValue, validateDrop(info: info) else { return false }
        return store.moveItem(itemID: dragged, toParentID: nil, beforeSiblingID: nil)
    }
}

private struct RenameTarget {
    enum Kind {
        case item(String)
        case collection(String)
    }

    var name: String
    let kind: Kind
}

private struct DeleteTarget {
    enum Kind {
        case item(String)
        case collection(String)
    }

    let label: String
    let kind: Kind
}

private struct CollectionItemRow: View {
    @Environment(AppStore.self) private var store
    let collectionID: String
    let parentID: String?
    let item: CollectionItem
    let level: Int
    @Binding var expandedFolders: Set<String>
    @Binding var draggingItemID: String?
    @Binding var draggingSubtreeIDs: Set<String>
    @Binding var dropHint: SidebarItemDropHint?
    var onRename: (CollectionItem) -> Void
    var onDelete: (CollectionItem) -> Void
    @State private var activeSheet: SidebarSheet?

    private var isExpanded: Bool { expandedFolders.contains(item.id) }
    private var isSelected: Bool { store.selectedItemID == item.id }
    private var isDirty: Bool {
        store.tabs.contains { $0.itemID == item.id && $0.collectionID == collectionID && $0.isDirty }
    }

    var body: some View {
        VStack(spacing: 0) {
            row
            if item.isFolder, isExpanded {
                ForEach(item.item ?? []) { child in
                    CollectionItemRow(
                        collectionID: collectionID,
                        parentID: item.id,
                        item: child,
                        level: level + 1,
                        expandedFolders: $expandedFolders,
                        draggingItemID: $draggingItemID,
                        draggingSubtreeIDs: $draggingSubtreeIDs,
                        dropHint: $dropHint,
                        onRename: onRename,
                        onDelete: onDelete
                    )
                }
            }
        }
        .sheet(item: $activeSheet) { sheet in
            SidebarSheetView(sheet: sheet)
                .background(Theme.editor)
        }
    }

    private var row: some View {
        HStack(spacing: 0) {
            indentGuides
            if item.isFolder {
                Button { toggleFolder() } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.tertiaryText)
                        .frame(width: 16, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Image(systemName: isExpanded ? "folder.fill" : "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.accent.opacity(0.85))
                    .frame(width: 38, alignment: .leading)
                Text(item.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(item.item?.count ?? 0)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Theme.tertiaryText)
                    .padding(.horizontal, 4)
            } else {
                // Keep the disclosure column even for requests so folders and requests share one
                // vertical marker line and their names line up.
                Color.clear.frame(width: 16, height: 26)
                MethodBadge(method: item.request?.method ?? "GET", fontSize: 9)
                    .frame(width: 38, alignment: .leading)
                Text(item.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if isDirty {
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 5, height: 5)
                }
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .frame(height: 26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .overlay(alignment: .leading) {
            if isSelected && !item.isFolder {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Theme.accent)
                    .frame(width: 2, height: 14)
                    .padding(.leading, 1)
            }
        }
        .overlay(alignment: .top) {
            if isDropHint(.before) {
                Rectangle()
                    .fill(Theme.accent)
                    .frame(height: 2)
            }
        }
        .overlay(alignment: .bottom) {
            if isDropHint(.after) {
                Rectangle()
                    .fill(Theme.accent)
                    .frame(height: 2)
            }
        }
        .overlay {
            if isDropHint(.inside) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Theme.accent.opacity(0.12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(Theme.accent.opacity(0.8), lineWidth: 1)
                    }
            }
        }
        .contentShape(Rectangle())
        .onDrag({
            dropHint = nil
            draggingSubtreeIDs = CollectionTree.subtreeIDs(item)
            draggingItemID = item.id
            return NSItemProvider(object: item.id as NSString)
        }, preview: {
            dragPreview
        })
        .onDrop(of: [.text], delegate: CollectionItemDropDelegate(
            target: item,
            targetParentID: parentID,
            store: store,
            draggingItemID: $draggingItemID,
            draggingSubtreeIDs: $draggingSubtreeIDs,
            dropHint: $dropHint,
            expandedFolders: $expandedFolders,
            siblings: { siblings }
        ))
        .onTapGesture {
            if item.isFolder {
                toggleFolder()
            } else {
                store.openRequest(collectionID: collectionID, item: item)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            if item.isFolder {
                toggleFolder()
            } else {
                store.openRequest(collectionID: collectionID, item: item)
            }
        }
        .contextMenu {
            if item.isFolder {
                folderMenu
            } else {
                requestMenu
            }
        }
    }


    private var rowBackground: Color {
        if isSelected && !item.isFolder { return Theme.accent.opacity(0.16) }
        if isSelected { return Theme.accentSoft }
        if item.isFolder { return Color.secondary.opacity(0.04) }
        return .clear
    }

    private var siblings: [CollectionItem] {
        guard let collection = store.collection(id: collectionID) else { return [] }
        if let parentID { return CollectionTree.find(collection.items, id: parentID)?.item ?? [] }
        return collection.items
    }

    private func isDropHint(_ position: SidebarDropPosition) -> Bool {
        dropHint?.itemID == item.id && dropHint?.position == position
    }

    /// Compact, opaque preview: the default snapshot of the row inside the glass sidebar
    /// renders as a washed-out duplicate that follows the cursor.
    private var dragPreview: some View {
        HStack(spacing: 6) {
            if item.isFolder {
                Image(systemName: "folder.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.accent)
            } else {
                MethodBadge(method: item.request?.method ?? "GET", fontSize: 9)
            }
            Text(item.name)
                .font(.system(size: 12))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: 220, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 0.5)
        }
        .padding(3)
    }

    private var indentGuides: some View {
        HStack(spacing: 0) {
            ForEach(0..<max(0, level - 1), id: \.self) { _ in
                Rectangle()
                    .fill(Theme.border.opacity(0.65))
                    .frame(width: 1, height: 26)
                    .frame(width: 16, alignment: .leading)
            }
        }
    }

    private func toggleFolder() {
        store.selectedItemID = item.id
        if isExpanded {
            expandedFolders.remove(item.id)
        } else {
            expandedFolders.insert(item.id)
        }
    }

    @ViewBuilder
    private var folderMenu: some View {
        Button("New Request") { store.createRequest(collectionID: collectionID, parentID: item.id) }
        Button("New Folder") { store.newFolder(collectionID: collectionID, parentID: item.id) }
        Divider()
        Button("Authorization…") {
            let collection = store.collection(id: collectionID)
            activeSheet = .auth(
                id: UUID(),
                title: "\(item.name) Authorization",
                initial: item.auth ?? .inherit,
                inherited: collection?.auth ?? .none,
                inheritedLabel: collection?.info.name ?? "collection",
                onSave: { store.setFolderAuth(collectionID: collectionID, itemID: item.id, auth: $0) }
            )
        }
        Button("Variables…") {
            activeSheet = .variables(
                id: UUID(),
                title: "\(item.name) Variables",
                initial: item.variable ?? [],
                onSave: { store.setFolderVariables(collectionID: collectionID, itemID: item.id, values: $0) }
            )
        }
        Button("Pre-request Script…") {
            activeSheet = .script(
                id: UUID(),
                title: "\(item.name) Pre-request Script",
                phase: "prerequest",
                initial: item.preRequestScript,
                onSave: { store.setFolderScript(collectionID: collectionID, itemID: item.id, listen: "prerequest", source: $0) }
            )
        }
        Button("Tests…") {
            activeSheet = .script(
                id: UUID(),
                title: "\(item.name) Tests",
                phase: "test",
                initial: item.testScript,
                onSave: { store.setFolderScript(collectionID: collectionID, itemID: item.id, listen: "test", source: $0) }
            )
        }
        Divider()
        Button("Rename") { onRename(item) }
        Button("Duplicate") { store.duplicate(itemID: item.id) }
        Button("Delete", role: .destructive) { onDelete(item) }
    }

    @ViewBuilder
    private var requestMenu: some View {
        Button("Open") { store.openRequest(collectionID: collectionID, item: item) }
        Button("Duplicate") { store.duplicate(itemID: item.id) }
        Button("Rename") { onRename(item) }
        Divider()
        Button("Delete", role: .destructive) { onDelete(item) }
    }
}
