import SwiftUI
import AppKit

struct EnvironmentWorkspaceView: View {
    @Environment(AppStore.self) private var store
    @AppStorage("showDynamicVariables") private var showDynamicVariables = false
    @State private var selection: String = "globals"

    // MARK: - 本地草稿
    // 编辑期只改草稿，避免每次按键都复制整个 Library 并写盘。
    @State private var draftRows: [KeyValue] = []
    @State private var draftName: String = ""
    /// 当前草稿对应的 selection id（"globals" 或某个 environment.id）
    @State private var draftSelectionID: String = "globals"
    /// 草稿是否有未提交的改动
    @State private var draftDirty = false
    /// 防抖任务
    @State private var flushTask: Task<Void, Never>?
    @State private var dropTargetEnvironmentID: String?

    private static let flushDelay = Duration.milliseconds(300)

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                list
                    .frame(width: 260)
                Divider()
                editor
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.editor)
        .onAppear {
            ensureSelection()
            loadDraft()
        }
        .onChange(of: selection) { _, _ in
            // 切换前先把未提交的草稿落库，再载入新草稿
            flushNow()
            loadDraft()
        }
        .onChange(of: store.library.environments.map(\.id)) { _, _ in ensureSelection() }
        .onDisappear { flushNow() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "globe")
                .foregroundStyle(Theme.accent)
            Text("Environments")
                .font(.system(size: 14, weight: .semibold))
            if let active = store.activeEnvironment {
                let color = EnvironmentPalette.color(for: active.id)
                HStack(spacing: 5) {
                    Circle().fill(color).frame(width: 6, height: 6)
                    Text(active.name)
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(color)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(color.opacity(0.12), in: Capsule())
            } else {
                Text("No active environment")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiaryText)
            }
            Spacer()
            Text("变量用 {{name}} 引用 · 值按作用域着色")
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiaryText)
            Button("Done") { store.workspace = .requests }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.panel)
    }

    private var list: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 2) {
                    listRow(
                        title: "Globals",
                        subtitle: "\(rowCount(for: "globals", fallback: store.library.globals.count)) variables",
                        id: "globals",
                        icon: "globe"
                    )
                    ForEach(Array(store.library.environments.enumerated()), id: \.element.id) { index, environment in
                        listRow(
                            title: rowTitle(for: environment),
                            subtitle: "\(rowCount(for: environment.id, fallback: environment.values.count)) variables",
                            id: environment.id,
                            icon: "square.stack.3d.up"
                        )
                        .overlay(alignment: .top) {
                            if dropTargetEnvironmentID == environment.id {
                                Rectangle()
                                    .fill(Theme.accent)
                                    .frame(height: 2)
                            }
                        }
                        .draggable(environment.id)
                        .dropDestination(for: String.self) { ids, _ in
                            dropTargetEnvironmentID = nil
                            guard let dragged = ids.first, dragged != environment.id else { return false }
                            store.moveEnvironment(id: dragged, to: index)
                            return true
                        } isTargeted: { targeted in
                            if targeted {
                                dropTargetEnvironmentID = environment.id
                            } else if dropTargetEnvironmentID == environment.id {
                                dropTargetEnvironmentID = nil
                            }
                        }
                    }
                }
                .padding(6)
            }
            Divider()
            HStack(spacing: 8) {
                Button {
                    store.addEnvironment()
                    selection = store.library.environments.last?.id ?? "globals"
                } label: {
                    Label("Add", systemImage: "plus")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                Spacer()
                if selection != "globals" {
                    Button {
                        store.deleteEnvironment(id: selection)
                        selection = "globals"
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.secondaryText)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Theme.panel)
    }

    private func listRow(title: String, subtitle: String, id: String, icon: String) -> some View {
        let color = EnvironmentPalette.color(for: id)
        let isSelected = selection == id
        let isActive = id != "globals" && store.library.activeEnvironmentID == id
        return Button {
            selection = id
        } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color)
                    .frame(width: 3, height: 28)
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? color : Theme.secondaryText)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.tertiaryText)
                }
                Spacer(minLength: 4)
                if isActive {
                    Text("ACTIVE")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(color)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(color.opacity(0.14), in: Capsule())
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(isSelected ? color.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var editor: some View {
        if selection == "globals" {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(EnvironmentPalette.globalsColor)
                            .frame(width: 3, height: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Globals")
                                .font(.system(size: 13, weight: .semibold))
                            Text("Available to every request")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.tertiaryText)
                        }
                        Spacer()
                        Button("Export") {
                            flushNow()
                            if let data = store.exportGlobals() {
                                FilePanels.save(data: data, suggestedName: "globals.postman_globals.json")
                            }
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Theme.accent)
                    }
                    Divider()
                    EnvironmentVariableList(
                        rows: draftRowsBinding,
                        scopeColor: EnvironmentPalette.globalsColor
                    )
                    dynamicVariablesCard
                }
                .padding(16)
            }
        } else if let environment = selectedEnvironment {
            let color = EnvironmentPalette.color(for: environment.id)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(color)
                            .frame(width: 3, height: 30)
                        InlineTextField(text: draftNameBinding, placeholder: "Environment name", fontSize: 13)
                            .frame(maxWidth: 300)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Theme.editor, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(Theme.border.opacity(0.8), lineWidth: 0.8)
                            )
                        if store.library.activeEnvironmentID == environment.id {
                            Text("ACTIVE")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(color)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(color.opacity(0.14), in: Capsule())
                        } else {
                            Button("设为当前") { store.setActiveEnvironment(id: environment.id) }
                                .buttonStyle(.borderless)
                                .foregroundStyle(Theme.accent)
                                .font(.system(size: 11))
                        }
                        Spacer()
                        Button("Export") {
                            flushNow()
                            let name = draftName.isEmpty ? environment.name : draftName
                            if let data = store.exportEnvironment(id: environment.id) {
                                FilePanels.save(data: data, suggestedName: "\(name).postman_environment.json")
                            }
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Theme.accent)
                        Button("Delete", role: .destructive) {
                            store.deleteEnvironment(id: environment.id)
                            selection = "globals"
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Theme.danger)
                    }
                    Divider()
                    EnvironmentVariableList(rows: draftRowsBinding, scopeColor: color)
                    Text("值为空或行被禁用时不会参与 {{变量}} 解析。Globals 的优先级低于环境变量。")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.tertiaryText)
                }
                .padding(16)
            }
        } else {
            EmptyStateView(
                icon: "globe",
                title: "No environment selected",
                message: "Add an environment to define variables for your requests."
            )
        }
    }

    private var dynamicVariablesCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Toggle(isOn: $showDynamicVariables) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("显示动态变量")
                        .font(.system(size: 12, weight: .medium))
                    Text("内置 \(DynamicVariableCatalog.all.count) 个；值为每次请求生成，同一请求内保持一致")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.tertiaryText)
                }
            }
            .toggleStyle(.checkbox)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            if showDynamicVariables {
                Divider()
                ForEach(DynamicVariableCatalog.all) { item in
                    HStack(alignment: .top, spacing: 12) {
                        Text(item.token)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color(nsColor: .systemTeal))
                            .frame(width: 210, alignment: .leading)
                            .textSelection(.enabled)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.description)
                                .font(.system(size: 11))
                            Text("示例：\(item.example)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Theme.tertiaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    Divider()
                }
            }
        }
        .background(Color.secondary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Theme.border.opacity(0.6), lineWidth: 0.6)
        )
    }

    private var selectedEnvironment: PMEnvironment? {
        guard selection != "globals" else { return nil }
        return store.library.environments.first { $0.id == selection }
    }

    private func ensureSelection() {
        if selection != "globals", !store.library.environments.contains(where: { $0.id == selection }) {
            selection = "globals"
        }
    }

    // MARK: - 草稿载入 / 提交

    /// 侧栏标题：草稿有未提交改动时优先展示草稿名称，避免防抖窗口内手感滞后。
    private func rowTitle(for environment: PMEnvironment) -> String {
        environment.id == draftSelectionID && draftDirty ? draftName : environment.name
    }

    private func rowCount(for id: String, fallback: Int) -> Int {
        id == draftSelectionID && draftDirty ? draftRows.count : fallback
    }

    /// 把当前 selection 的内容载入草稿。只在切换 selection / 首次出现时调用，
    /// 不做 store -> draft 的持续同步，避免覆盖正在编辑的草稿。
    private func loadDraft() {
        flushTask?.cancel()
        flushTask = nil
        draftDirty = false
        draftSelectionID = selection
        if selection == "globals" {
            draftRows = store.library.globals
            draftName = ""
        } else if let environment = store.library.environments.first(where: { $0.id == selection }) {
            draftRows = environment.values
            draftName = environment.name
        } else {
            draftRows = []
            draftName = ""
        }
    }

    /// 编辑即改草稿，300ms 防抖后提交一次。
    private func scheduleFlush() {
        draftDirty = true
        flushTask?.cancel()
        flushTask = Task { @MainActor in
            do {
                try await Task.sleep(for: Self.flushDelay)
            } catch {
                return // 被新的编辑或显式 flush 取消
            }
            commitDraft()
        }
    }

    /// 把草稿提交给 AppStore（每个防抖窗口最多一次 updateGlobals/updateEnvironment）。
    private func commitDraft() {
        guard draftDirty else { return }
        draftDirty = false
        let id = draftSelectionID
        if id == "globals" {
            guard store.library.globals != draftRows else { return }
            store.updateGlobals(draftRows)
        } else {
            guard var environment = store.library.environments.first(where: { $0.id == id }) else { return }
            guard environment.name != draftName || environment.values != draftRows else { return }
            environment.name = draftName
            environment.values = draftRows
            store.updateEnvironment(environment)
        }
    }

    /// 立即提交（切换 selection、视图消失、Export 前）。
    private func flushNow() {
        flushTask?.cancel()
        flushTask = nil
        commitDraft()
    }

    private var draftRowsBinding: Binding<[KeyValue]> {
        Binding(
            get: { draftRows },
            set: { rows in
                draftRows = rows
                scheduleFlush()
            }
        )
    }

    private var draftNameBinding: Binding<String> {
        Binding(
            get: { draftName },
            set: { name in
                draftName = name
                scheduleFlush()
            }
        )
    }
}

private struct EnvironmentVariableList: View {
    @Binding var rows: [KeyValue]
    let scopeColor: Color
    @State private var isPlainText = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("VARIABLES")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.tertiaryText)
                Spacer()
                Button {
                    isPlainText.toggle()
                } label: {
                    Label(isPlainText ? "表单" : "纯文本", systemImage: isPlainText ? "list.bullet" : "text.alignleft")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .help(isPlainText ? "切换回逐行表单" : "用 key: value 纯文本编辑")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            if isPlainText {
                PlainVariableEditor(rows: $rows, scopeColor: NSColor(scopeColor))
                    .frame(height: 180)
                    .background(Theme.editor)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Theme.border.opacity(0.6), lineWidth: 0.6)
                    )
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
                HStack {
                    Text("每行 key: value；// 开头表示禁用，修改会自动保存")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.tertiaryText)
                    Spacer()
                    Text("\(rows.filter(\.isEnabled).count) 启用")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.tertiaryText)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            } else {
                columnHeader
                ForEach($rows) { $row in
                    rowView($row)
                    Divider()
                }
                addFooter
            }
        }
        .background(Color.secondary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Theme.border.opacity(0.6), lineWidth: 0.6)
        )
    }

    private var columnHeader: some View {
        HStack(spacing: 8) {
            Text("ON")
                .frame(width: 30, alignment: .leading)
            Text("NAME")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("VALUE")
                .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: 24)
        }
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(Theme.tertiaryText)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.05))
    }

    private func rowView(_ row: Binding<KeyValue>) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { !row.wrappedValue.disabled },
                set: { row.wrappedValue.disabled = !$0 }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .frame(width: 30, alignment: .leading)

            InlineTextField(
                text: row.key,
                placeholder: "变量名",
                fontSize: 12,
                monospaced: true,
                textColor: .systemBlue
            )
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 4))

            InlineTextField(
                text: row.value,
                placeholder: "值",
                fontSize: 12,
                monospaced: true,
                textColor: row.wrappedValue.disabled ? .tertiaryLabelColor : NSColor(scopeColor)
            )
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 4))

            Button {
                rows.removeAll { $0.id == row.wrappedValue.id }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiaryText)
            }
            .buttonStyle(.plain)
            .frame(width: 24)
        }
        .opacity(row.wrappedValue.disabled ? 0.55 : 1)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private var addFooter: some View {
        HStack(spacing: 10) {
            Button {
                rows.append(KeyValue())
            } label: {
                Label("添加变量", systemImage: "plus")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            Spacer()
            Text("\(rows.filter(\.isEnabled).count) 启用")
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiaryText)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}


struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            Form {
                Section("Appearance") {
                    Picker("Theme", selection: Binding(
                        get: { store.library.settings.theme },
                        set: { store.setTheme($0) }
                    )) {
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                        Text("Follow System").tag("system")
                    }
                    .pickerStyle(.segmented)
                }
                Section("Request defaults") {
                    Toggle("Follow redirects", isOn: binding(\.followRedirects))
                    TextField("Max redirects", value: binding(\.maxRedirects), format: .number)
                    TextField("Timeout (seconds, 0 = default)", value: binding(\.timeoutSeconds), format: .number)
                    TextField("Max in-memory response (MB)", value: Binding(
                        get: { max(1, store.library.settings.maxInMemoryResponseBytes / 1_048_576) },
                        set: {
                            store.library.settings.maxInMemoryResponseBytes = max(1, $0) * 1_048_576
                            store.persist()
                        }
                    ), format: .number)
                    Toggle("Send cookies from the cookie jar", isOn: binding(\.sendCookies))
                    Toggle("Automatically encode URLs", isOn: binding(\.autoEncodeURL))
                    Toggle("Allow socket fallback for legacy http:// when ATS blocks it", isOn: binding(\.useSocketFallbackForLegacyHTTP))
                    Text("URLSession is always tried first. The fallback only runs when macOS 26 rejects a cleartext request with ATS error -1022.")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.tertiaryText)
                }
                Section("TLS") {
                    Toggle("Verify SSL certificates by default", isOn: binding(\.sslVerification))
                    HStack {
                        Text(store.library.settings.clientCertPath ?? "No client certificate")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Choose…") {
                            if let url = FilePanels.openFile(types: [.data]) {
                                store.library.settings.clientCertPath = url.path
                                store.persist()
                            }
                        }
                        if store.library.settings.clientCertPath != nil {
                            Button("Clear") {
                                store.library.settings.clientCertPath = nil
                                store.library.settings.clientCertPassword = nil
                                store.persist()
                            }
                        }
                    }
                    SecureField("PKCS#12 password", text: Binding(
                        get: { store.library.settings.clientCertPassword ?? "" },
                        set: { store.library.settings.clientCertPassword = $0; store.persist() }
                    ))
                }
                Section("Proxy") {
                    Toggle("Use a proxy", isOn: binding(\.proxyEnabled))
                    TextField("Host", text: binding(\.proxyHost))
                    TextField("Port", value: binding(\.proxyPort), format: .number)
                    Text("Proxy authentication is not implemented in this build.")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.tertiaryText)
                }
                Section("Data") {
                    HStack {
                        Text(store.dataDirectory.path)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([store.dataDirectory])
                        }
                    }
                    Button("Export Backup…") {
                        if let data = store.exportBackup() {
                            FilePanels.save(data: data, suggestedName: "PostmanSwift-backup.json")
                        }
                    }
                }
                Section("About") {
                    Text("PostmanSwift \(AppInfo.version) · build \(AppInfo.build)")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                    Text("Local-only native Swift client. No account, sync, telemetry or cloud features are included.")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.tertiaryText)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 600, height: 620)
    }

    private func binding<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(
            get: { store.library.settings[keyPath: keyPath] },
            set: { store.library.settings[keyPath: keyPath] = $0; store.persist() }
        )
    }
}

struct ConsoleView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var expanded: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Console")
                    .font(.system(size: 14, weight: .semibold))
                Text("\(store.console.count) entries")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiaryText)
                Spacer()
                Button("Clear") { store.console.removeAll() }
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            if store.console.isEmpty {
                EmptyStateView(icon: "terminal", title: "Console is empty", message: "Requests, responses and script logs appear here.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(store.console.reversed()) { entry in
                            entryRow(entry)
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(width: 820, height: 520)
    }

    private func entryRow(_ entry: ConsoleEntry) -> some View {
        let isExpanded = expanded.contains(entry.id)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Image(systemName: icon(for: entry.kind))
                    .font(.system(size: 10))
                    .foregroundStyle(color(for: entry.kind))
                    .frame(width: 14)
                Text(entry.kind.rawValue)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(color(for: entry.kind))
                    .frame(width: 54, alignment: .leading)
                Text(entry.title)
                    .font(.system(size: 11))
                    .lineLimit(1)
                Spacer()
                Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Theme.tertiaryText)
            }
            if isExpanded {
                Text(entry.detail)
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            if isExpanded { expanded.remove(entry.id) } else { expanded.insert(entry.id) }
        }
    }

    private func icon(for kind: ConsoleEntry.Kind) -> String {
        switch kind {
        case .request: return "arrow.up.right"
        case .response: return "arrow.down.left"
        case .script: return "chevron.left.forwardslash.chevron.right"
        case .error: return "exclamationmark.triangle"
        }
    }

    private func color(for kind: ConsoleEntry.Kind) -> Color {
        switch kind {
        case .request: return Theme.methodColor("GET")
        case .response: return Theme.success
        case .script: return Theme.secondaryText
        case .error: return Theme.danger
        }
    }
}

struct CookiesView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Cookies")
                    .font(.system(size: 14, weight: .semibold))
                Text("\(store.cookieJar.cookies.count) stored")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiaryText)
                Spacer()
                Button("Delete All") { store.clearCookies() }
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            if store.cookieJar.cookies.isEmpty {
                EmptyStateView(icon: "circle.grid.2x2", title: "No cookies", message: "Cookies set by responses are stored locally and sent on matching requests.")
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        HStack {
                            Text("NAME").frame(width: 140, alignment: .leading)
                            Text("VALUE").frame(maxWidth: .infinity, alignment: .leading)
                            Text("DOMAIN").frame(width: 170, alignment: .leading)
                            Text("PATH").frame(width: 90, alignment: .leading)
                            Text("EXPIRES").frame(width: 130, alignment: .leading)
                            Color.clear.frame(width: 26)
                        }
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.tertiaryText)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Color.secondary.opacity(0.05))
                        ForEach(store.cookieJar.cookies) { cookie in
                            HStack(alignment: .top) {
                                Text(cookie.name).frame(width: 140, alignment: .leading)
                                Text(cookie.value).frame(maxWidth: .infinity, alignment: .leading)
                                Text(cookie.displayDomain).frame(width: 170, alignment: .leading)
                                Text(cookie.path).frame(width: 90, alignment: .leading)
                                Text(cookie.expires.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "session")
                                    .frame(width: 130, alignment: .leading)
                                Button {
                                    store.deleteCookie(cookie)
                                } label: {
                                    Image(systemName: "trash").font(.system(size: 10))
                                }
                                .buttonStyle(.plain)
                                .frame(width: 26)
                            }
                            .font(.system(size: 10, design: .monospaced))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 5)
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(width: 900, height: 480)
    }
}
