import SwiftUI
import AppKit

struct RequestEditorView: View {
    @Environment(AppStore.self) private var store
    @Bindable var tab: RequestTab

    private let methods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]
    @State private var urlSyncTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 8) {
                urlBar
                sendButton
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
            Divider()
            sectionTabs
            Divider()
            sectionContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.editor)
        .onChange(of: tab.requestSection) { _, _ in
            CompletionPopupController.shared.close()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            TextField("Request name", text: $tab.draft.name)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: 360)
            if tab.isDirty {
                Text("Unsaved")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
            Spacer()

            if tab.collectionID != nil {
                Button("Save") { store.save(tab) }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .controlSize(.small)
                    .disabled(!tab.isDirty)
            } else {
                Menu("Save to…") {
                    ForEach(store.library.collections) { collection in
                        Button(collection.info.name) {
                            tab.collectionID = collection.id
                            store.save(tab)
                        }
                    }
                }
                .controlSize(.small)
            }

            IconButton(systemName: "chevron.left.forwardslash.chevron.right", help: "Code snippet") {
                store.openCodeSnippet(tab)
            }

            Menu {
                Button("Copy URL") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(tab.draft.urlRaw, forType: .string)
                }
                Button("Copy as cURL") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(store.codeSnippet(for: tab, language: .curl), forType: .string)
                }
                if tab.itemID != nil {
                    Divider()
                    Button("Duplicate Request") {
                        if let itemID = tab.itemID { store.duplicate(itemID: itemID) }
                    }
                }
                if tab.savedSnapshot != nil {
                    Button("Revert to Saved") {
                        if let snapshot = tab.savedSnapshot { tab.draft = snapshot }
                    }
                }
                Divider()
                Button("Close Tab") { store.requestClose(tab) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 24, height: 22)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.top, 9)
        .padding(.bottom, 7)
    }

    // MARK: - URL bar

    private var urlBar: some View {
        HStack(spacing: 0) {
            Menu {
                ForEach(methods, id: \.self) { method in
                    Button(method) { tab.draft.method = method }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(tab.draft.method)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.methodColor(tab.draft.method))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(Theme.tertiaryText)
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            Divider().frame(height: 18)

            VariableTextField(
                text: urlBinding,
                placeholder: "Enter request URL",
                fontSize: 12,
                monospaced: true,
                variables: variables,
                onSubmit: { store.send(tab) }
            )
            .padding(.horizontal, 9)
            .frame(height: 30)

            if !tab.draft.urlRaw.isEmpty {
                IconButton(systemName: "doc.on.doc", help: "Copy URL") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(tab.draft.urlRaw, forType: .string)
                }
            }
        }
        .background {
            if #available(macOS 26.0, *) {
                Capsule().fill(.clear).glassEffect(.regular, in: .capsule)
            } else {
                Capsule().fill(Color.secondary.opacity(0.07))
            }
        }
        .overlay(Capsule().strokeBorder(Theme.border.opacity(0.8), lineWidth: 0.7))
        .clipShape(Capsule())
    }

    private var sendButton: some View {
        Button {
            store.send(tab)
        } label: {
            HStack(spacing: 5) {
                if tab.isSending {
                    ProgressView().controlSize(.small)
                }
                Text(tab.isSending ? "Sending" : "Send")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(width: 78, height: 30)
            .background(
                Theme.accent.opacity(tab.isSending ? 0.65 : 1),
                in: Capsule()
            )
            .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .disabled(tab.isSending)
        .help("Send request (⌘↩)")
    }

    private var variables: [VariableSuggestion] {
        store.variableSuggestions(for: tab)
    }

    private var urlBinding: Binding<String> {
        Binding(
            get: { tab.draft.urlRaw },
            set: { newValue in
                tab.draft.urlRaw = newValue
                let parsed = URLUtilities.parseQuery(from: newValue)
                if !parsed.isEmpty || newValue.contains("?") {
                    tab.draft.params = parsed.filter { !$0.key.isEmpty || !$0.value.isEmpty }
                }
            }
        )
    }

    private func syncURLFromParams() {
        let base = URLUtilities.splitRaw(tab.draft.urlRaw).base
        tab.draft.urlRaw = URLUtilities.buildRaw(base: base, params: tab.draft.params)
    }

    /// Rebuilding the URL on every keystroke re-rendered the whole editor, which could
    /// interrupt the field editor while typing. Coalesce the reverse sync instead.
    private func scheduleURLSync() {
        urlSyncTask?.cancel()
        urlSyncTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            syncURLFromParams()
        }
    }

    // MARK: - Section tabs

    private var sectionTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(RequestSection.allCases) { section in
                    SectionTabButton(
                        title: section.rawValue,
                        isSelected: tab.requestSection == section,
                        badge: badge(for: section)
                    ) {
                        tab.requestSection = section
                    }
                }
            }
            .padding(.horizontal, 6)
        }
    }

    private func badge(for section: RequestSection) -> Int {
        switch section {
        case .params:
            return tab.draft.params.filter { $0.isEnabled && !($0.key.isEmpty && $0.value.isEmpty) }.count
        case .headers:
            return tab.draft.headers.filter { $0.isEnabled && !$0.key.isEmpty }.count
        case .body:
            return tab.draft.bodyMode == .none ? 0 : 1
        case .tests:
            return tab.draft.testScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : 1
        default:
            return 0
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var sectionContent: some View {
        switch tab.requestSection {
        case .params:
            ScrollView {
                KeyValueEditor(
                    rows: $tab.draft.params,
                    keyPlaceholder: "Query Param",
                    valuePlaceholder: "Value",
                    showsDescription: true,
                    variables: variables,
                    onChange: scheduleURLSync
                )
            }

        case .authorization:
            ScrollView {
                AuthEditorView(
                    auth: $tab.draft.auth,
                    inheritedAuth: inheritedAuth.0,
                    inheritedLabel: inheritedAuth.1,
                    variables: variables
                )
            }

        case .headers:
            ScrollView {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Menu("Presets") {
                            if store.library.headerPresets.isEmpty {
                                Text("No header presets")
                            } else {
                                ForEach(store.library.headerPresets) { preset in
                                    Button(preset.name) {
                                        tab.draft.headers.append(contentsOf: preset.header)
                                    }
                                }
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 90)
                        Spacer()
                        Text("Content-Type, Host and Cookie are added automatically when needed")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.tertiaryText)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    KeyValueEditor(
                        rows: $tab.draft.headers,
                        keyPlaceholder: "Header",
                        valuePlaceholder: "Value",
                        showsDescription: true,
                        variables: variables
                    )
                }
            }

        case .body:
            BodyEditorView(draft: $tab.draft, variables: variables)

        case .preRequest:
            ScriptEditorView(
                text: $tab.draft.preRequestScript,
                title: "Pre-request Script",
                snippets: ScriptSnippet.preRequest,
                variables: variables
            )

        case .tests:
            ScriptEditorView(
                text: $tab.draft.testScript,
                title: "Tests",
                snippets: ScriptSnippet.tests,
                variables: variables
            )

        case .settings:
            ScrollView {
                RequestSettingsView(draft: $tab.draft)
            }
        }
    }

    private var inheritedAuth: (Auth, String) {
        guard let collectionID = tab.collectionID, let collection = store.collection(id: collectionID) else {
            return (.none, "parent")
        }
        if let itemID = tab.itemID, let chain = CollectionTree.path(to: itemID, in: collection.items) {
            let label = chain.dropLast().last?.name ?? collection.info.name
            return (CollectionTree.effectiveAuth(collection: collection, itemID: itemID), label)
        }
        return (collection.auth ?? .none, collection.info.name)
    }
}

struct RequestSettingsView: View {
    @Binding var draft: RequestDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Request settings")
                .font(.system(size: 12, weight: .semibold))
            Toggle("Automatically follow redirects", isOn: $draft.followRedirects)
                .toggleStyle(.checkbox)
            Toggle("Enable SSL certificate verification", isOn: $draft.strictSSL)
                .toggleStyle(.checkbox)
            Text("These options override the app defaults for this request only.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiaryText)

            Divider()

            Text("Description")
                .font(.system(size: 12, weight: .semibold))
            TextEditor(text: $draft.description)
                .font(.system(size: 12))
                .frame(minHeight: 140)
                .padding(6)
                .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border))
            Spacer()
        }
        .padding(16)
    }
}
