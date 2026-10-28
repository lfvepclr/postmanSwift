import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Sidebar

struct MockServiceListView: View {
    @Environment(AppStore.self) private var store
    @ObservedObject var server: MockServer
    @State private var search = ""
    @State private var draggingServiceID: String?
    @State private var serviceDropHint: MockDropHint?

    private var isFiltering: Bool {
        !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var services: [MockService] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return store.library.mockServices }
        return store.library.mockServices.filter {
            $0.name.lowercased().contains(query) || $0.normalizedPrefix.lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Mock Services")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                Button {
                    store.addMockService()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 22, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Add mock service")
            }
            .padding(.horizontal, 10)
            .padding(.top, 2)
            .padding(.bottom, 6)

            SearchField(text: $search, placeholder: "Search mock services")
                .padding(.horizontal, 10)
                .padding(.bottom, 6)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(services) { service in
                        serviceRow(service)
                    }
                    if services.isEmpty {
                        EmptyStateView(
                            icon: "server.rack",
                            title: store.library.mockServices.isEmpty ? "No mock services" : "No matches",
                            message: store.library.mockServices.isEmpty
                                ? "Add a service, define cases, then start the server."
                                : "Try a different name or prefix."
                        )
                        .frame(height: 220)
                    }
                }
                .padding(.vertical, 4)
            }

            Divider()
            HStack(spacing: 6) {
                Circle()
                    .fill(server.isRunning ? Theme.success : Theme.tertiaryText)
                    .frame(width: 6, height: 6)
                Text(server.isRunning ? "Running · \(server.port)" : "Stopped")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(server.isRunning ? Theme.success : Theme.secondaryText)
                Spacer()
                if server.isRunning {
                    Text("\(server.requestCount) req")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Theme.tertiaryText)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .onAppear { store.ensureMockSelection() }
        .onChange(of: store.library.mockServices.count) { _, _ in
            store.ensureMockSelection()
        }
    }

    private func serviceRow(_ service: MockService) -> some View {
        MockServiceRow(
            service: service,
            dragEnabled: !isFiltering,
            draggingServiceID: $draggingServiceID,
            dropHint: $serviceDropHint
        )
    }
}

// MARK: - Workspace

struct MockWorkspaceView: View {
    @Environment(AppStore.self) private var store
    @ObservedObject var server: MockServer

    @State private var portText = "9020"
    @State private var localMessage: String?
    @State private var isGenerating = false
    @State private var draggingCaseID: String?
    @State private var caseDropHint: MockDropHint?

    private let methods = ["ANY", "GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let localMessage {
                noticeBar(localMessage)
                Divider()
            }
            if let service = store.selectedMockService {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        serviceEditor(service)
                        Divider()
                        casesSection(service)
                        if let mockCase = store.selectedMockCase {
                            Divider()
                            caseEditor(mockCase)
                        }
                    }
                    .padding(16)
                }
                .background(Theme.editor)
            } else {
                EmptyStateView(
                    icon: "server.rack",
                    title: "No mock service",
                    message: "Choose a service on the left, or add one to define cases and start the server.",
                    actionTitle: "Add Service",
                    action: { store.addMockService() }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.editor)
            }
            Divider()
            serverBar
        }
        .background(Theme.editor)
        .onAppear {
            store.ensureMockSelection()
            if server.isRunning { portText = String(server.port) }
        }
        .onChange(of: store.library.mockServices.count) { _, _ in
            store.ensureMockSelection()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "server.rack")
                .foregroundStyle(Theme.accent)
            Text("Mock API")
                .font(.system(size: 14, weight: .semibold))
            stateBadge
            Spacer()
            HStack(spacing: 6) {
                Text("Port")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondaryText)
                TextField("9020", text: $portText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 64)
                    .disabled(server.isRunning)
            }
            if server.isRunning {
                Button("Stop") { store.stopMockServer() }
                    .buttonStyle(.bordered)
            } else {
                Button("Start") { startServer() }
                    .buttonStyle(PrimaryButtonStyle())
            }
            Button {
                Task { @MainActor in await generateRequests() }
            } label: {
                HStack(spacing: 5) {
                    if isGenerating {
                        ProgressView().controlSize(.small)
                    }
                    Text(isGenerating ? "生成中…" : "生成请求集合")
                }
            }
            .buttonStyle(.bordered)
            .disabled(store.selectedMockService == nil || isGenerating)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.panel)
    }

    private var stateBadge: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(server.isRunning ? Theme.success : Theme.tertiaryText)
                .frame(width: 6, height: 6)
            Text(server.isRunning ? "Running · \(server.port)" : "Stopped")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(server.isRunning ? Theme.success : Theme.secondaryText)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background((server.isRunning ? Theme.success : Color.secondary).opacity(0.1), in: Capsule())
    }

    private func noticeBar(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.success)
            Text(message)
                .font(.system(size: 11))
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Button {
                localMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.tertiaryText)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Theme.success.opacity(0.08))
    }

    private func serviceEditor(_ service: MockService) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Service")
                .font(.system(size: 12, weight: .semibold))
            HStack(spacing: 10) {
                TextField("Service name", text: serviceBinding(\.name, fallback: ""))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: 260)
                TextField("Prefix, e.g. /api", text: serviceBinding(\.prefix, fallback: "/api"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 160)
                Toggle("Enabled", isOn: serviceBinding(\.enabled, fallback: true))
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Delete", role: .destructive) {
                    store.deleteMockService(id: service.id)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.danger)
            }
            Text("Base URL: http://127.0.0.1:\(server.isRunning ? String(server.port) : portText)\(service.normalizedPrefix)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.tertiaryText)
        }
    }

    private func casesSection(_ service: MockService) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Cases")
                    .font(.system(size: 12, weight: .semibold))
                Text("\(service.cases.count)")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.tertiaryText)
                Spacer()
                Button {
                    store.addMockCase(serviceID: service.id)
                } label: {
                    Label("Add Case", systemImage: "plus")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
            }
            VStack(spacing: 0) {
                ForEach(service.cases) { mockCase in
                    MockCaseRow(
                        serviceID: service.id,
                        mockCase: mockCase,
                        isSelected: store.selectedMockCaseID == mockCase.id,
                        draggingCaseID: $draggingCaseID,
                        dropHint: $caseDropHint
                    )
                }
            }
            .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func caseEditor(_ mockCase: MockCase) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Case")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("Match: \(mockCase.method.uppercased()) \(mockCase.normalizedPath)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.tertiaryText)
            }
            HStack(spacing: 10) {
                TextField("Case name", text: caseBinding(\.name, fallback: ""))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .frame(maxWidth: 240)
                Picker("", selection: caseBinding(\.method, fallback: "GET")) {
                    ForEach(methods, id: \.self) { method in
                        Text(method).tag(method)
                    }
                }
                .labelsHidden()
                .frame(width: 100)
                TextField("/path", text: caseBinding(\.path, fallback: "/"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: 220)
                Spacer()
            }
            HStack(spacing: 10) {
                Text("Status")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                TextField("200", value: caseBinding(\.statusCode, fallback: 200), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                Text("Delay")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                TextField("0", value: caseBinding(\.delayMilliseconds, fallback: 0), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                Text("ms")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiaryText)
                Spacer()
            }
            Text("Response headers")
                .font(.system(size: 11, weight: .medium))
            KeyValueEditor(
                rows: caseHeadersBinding,
                keyPlaceholder: "Header",
                valuePlaceholder: "Value",
                variables: store.variableSuggestions(for: nil)
            )
            Text("Response body")
                .font(.system(size: 11, weight: .medium))
            CodeTextEditor(
                text: caseBodyBinding,
                language: .json,
                variables: store.variableSuggestions(for: nil),
                focusToken: mockCase.id,
                focusOnAppear: true
            )
            .frame(minHeight: 130)
            Text("Request body used by generated test requests")
                .font(.system(size: 11, weight: .medium))
            CodeTextEditor(text: caseRequestBodyBinding, language: .json, variables: store.variableSuggestions(for: nil))
                .frame(minHeight: 80)
            Text("模板变量：{{request.method}}、{{request.path}}、{{request.query}}、{{request.body}}、{{request.bodyJson}}")
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiaryText)
        }
    }

    private var serverBar: some View {
        HStack(spacing: 10) {
            if server.isRunning {
                Circle().fill(Theme.success).frame(width: 6, height: 6)
                Text("http://127.0.0.1:\(server.port)")
                    .font(.system(size: 10, design: .monospaced))
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("http://127.0.0.1:\(server.port)", forType: .string)
                }
                .buttonStyle(.borderless)
                Text("· \(server.requestCount) requests")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiaryText)
                if let last = server.lastRequest {
                    Text("· \(last)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.tertiaryText)
                        .lineLimit(1)
                }
            } else {
                Text("Start the mock server, then send the generated requests from their collection.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiaryText)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.04))
    }

    // MARK: - Bindings

    private func serviceBinding<T>(_ keyPath: WritableKeyPath<MockService, T>, fallback: T) -> Binding<T> {
        Binding(
            get: { store.selectedMockService?[keyPath: keyPath] ?? fallback },
            set: { value in
                guard var service = store.selectedMockService else { return }
                service[keyPath: keyPath] = value
                store.updateMockService(service)
            }
        )
    }

    private func caseBinding<T>(_ keyPath: WritableKeyPath<MockCase, T>, fallback: T) -> Binding<T> {
        Binding(
            get: { store.selectedMockCase?[keyPath: keyPath] ?? fallback },
            set: { value in
                guard var mockCase = store.selectedMockCase, let serviceID = store.selectedMockService?.id else { return }
                mockCase[keyPath: keyPath] = value
                store.updateMockCase(serviceID: serviceID, mockCase: mockCase)
            }
        )
    }

    private var caseHeadersBinding: Binding<[KeyValue]> {
        caseBinding(\.headers, fallback: [])
    }

    private var caseBodyBinding: Binding<String> {
        caseBinding(\.body, fallback: "")
    }

    private var caseRequestBodyBinding: Binding<String> {
        caseBinding(\.requestBody, fallback: "")
    }

    private func startServer() {
        guard let port = UInt16(portText), port >= 1024 else {
            localMessage = "请输入 1024–65535 之间的端口。"
            return
        }
        let enabled = store.library.mockServices.filter(\.enabled)
        guard !enabled.isEmpty else {
            localMessage = "请至少启用一个 Mock 服务。"
            return
        }
        do {
            try store.mockServer.start(port: port, services: enabled)
        } catch {
            localMessage = error.localizedDescription
        }
    }

    private func generateRequests() async {
        guard !isGenerating, let service = store.selectedMockService else { return }
        guard !service.cases.isEmpty else {
            localMessage = "当前服务还没有 case。"
            return
        }
        isGenerating = true
        defer { isGenerating = false }
        let port = server.isRunning ? server.port : (UInt16(portText) ?? 9020)
        if let name = await store.generateMockCollection(serviceID: service.id, port: port) {
            localMessage = "已生成集合「\(name)」，共 \(service.cases.count) 个请求。切换到 Collections 即可发送。"
        }
    }
}

// MARK: - Drag & drop

private enum MockDropEdge: Equatable {
    case before
    case after
}

private struct MockDropHint: Equatable {
    var itemID: String
    var edge: MockDropEdge
}

private struct MockRowHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

@MainActor
private struct MockRowDropDelegate: DropDelegate {
    let targetID: String
    let rowHeight: CGFloat
    let canDrop: Bool
    let draggingID: Binding<String?>
    let hint: Binding<MockDropHint?>
    let onDrop: (String, MockDropEdge) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        guard canDrop, let dragged = draggingID.wrappedValue else { return false }
        return dragged != targetID
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
            draggingID.wrappedValue = nil
        }
        guard canDrop, let dragged = draggingID.wrappedValue, dragged != targetID else { return false }
        let edge: MockDropEdge = info.location.y < rowHeight / 2 ? .before : .after
        return onDrop(dragged, edge)
    }

    private func updateHint(_ info: DropInfo) {
        guard canDrop, let dragged = draggingID.wrappedValue, dragged != targetID else {
            clearHint()
            return
        }
        let edge: MockDropEdge = info.location.y < rowHeight / 2 ? .before : .after
        let next = MockDropHint(itemID: targetID, edge: edge)
        if hint.wrappedValue != next { hint.wrappedValue = next }
    }

    private func clearHint() {
        if hint.wrappedValue?.itemID == targetID { hint.wrappedValue = nil }
    }
}

private struct MockServiceRow: View {
    @Environment(AppStore.self) private var store
    let service: MockService
    let dragEnabled: Bool
    @Binding var draggingServiceID: String?
    @Binding var dropHint: MockDropHint?
    @State private var height: CGFloat = 42

    private var isSelected: Bool { store.selectedMockServiceID == service.id }

    var body: some View {
        if dragEnabled {
            row
                .onDrag({
                    dropHint = nil
                    draggingServiceID = service.id
                    return NSItemProvider(object: service.id as NSString)
                }, preview: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(service.enabled ? Theme.success : Theme.tertiaryText)
                            .frame(width: 5, height: 5)
                        Text(service.name)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Theme.border, lineWidth: 0.5)
                    }
                    .padding(3)
                })
                .onDrop(of: [.text], delegate: MockRowDropDelegate(
                    targetID: service.id,
                    rowHeight: height,
                    canDrop: true,
                    draggingID: $draggingServiceID,
                    hint: $dropHint,
                    onDrop: move
                ))
        } else {
            row
        }
    }

    private var row: some View {
        Button {
            store.selectMockService(service.id)
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(service.enabled ? Theme.success : Theme.tertiaryText)
                    .frame(width: 5, height: 5)
                VStack(alignment: .leading, spacing: 1) {
                    Text(service.name)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)
                    Text(service.normalizedPrefix + " · \(service.cases.count) cases")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Theme.tertiaryText)
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Theme.accent.opacity(0.16) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Delete Service", role: .destructive) {
                store.deleteMockService(id: service.id)
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: MockRowHeightKey.self, value: proxy.size.height)
            }
        }
        .onPreferenceChange(MockRowHeightKey.self) { height = $0 }
        .overlay(alignment: .top) {
            if isHint(.before) {
                Rectangle().fill(Theme.accent).frame(height: 2)
            }
        }
        .overlay(alignment: .bottom) {
            if isHint(.after) {
                Rectangle().fill(Theme.accent).frame(height: 2)
            }
        }
    }

    private func isHint(_ edge: MockDropEdge) -> Bool {
        dropHint?.itemID == service.id && dropHint?.edge == edge
    }

    private func move(_ dragged: String, _ edge: MockDropEdge) -> Bool {
        guard let from = store.library.mockServices.firstIndex(where: { $0.id == dragged }),
              let target = store.library.mockServices.firstIndex(where: { $0.id == service.id }) else { return false }
        store.moveMockService(from: from, to: edge == .before ? target : target + 1)
        return true
    }
}

private struct MockCaseRow: View {
    @Environment(AppStore.self) private var store
    let serviceID: String
    let mockCase: MockCase
    let isSelected: Bool
    @Binding var draggingCaseID: String?
    @Binding var dropHint: MockDropHint?
    @State private var height: CGFloat = 28

    var body: some View {
        row
            .onDrag({
                dropHint = nil
                draggingCaseID = mockCase.id
                return NSItemProvider(object: mockCase.id as NSString)
            }, preview: {
                HStack(spacing: 6) {
                    Text(mockCase.method.uppercased())
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.methodColor(mockCase.method.uppercased() == "ANY" ? "GET" : mockCase.method))
                    Text(mockCase.name)
                        .font(.system(size: 12))
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Theme.border, lineWidth: 0.5)
                }
                .padding(3)
            })
            .onDrop(of: [.text], delegate: MockRowDropDelegate(
                targetID: mockCase.id,
                rowHeight: height,
                canDrop: true,
                draggingID: $draggingCaseID,
                hint: $dropHint,
                onDrop: move
            ))
    }

    private var row: some View {
        HStack(spacing: 8) {
            Text(mockCase.method.uppercased())
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.methodColor(mockCase.method.uppercased() == "ANY" ? "GET" : mockCase.method))
                .frame(width: 42, alignment: .leading)
            Text(mockCase.name)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
            Text(mockCase.normalizedPath)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
            Spacer()
            if mockCase.delayMilliseconds > 0 {
                Text("\(mockCase.delayMilliseconds) ms")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.warning)
            }
            Text("\(mockCase.effectiveStatusCode)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.statusColor(mockCase.effectiveStatusCode))
                .frame(width: 30, alignment: .trailing)
            Button {
                store.deleteMockCase(serviceID: serviceID, caseID: mockCase.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.tertiaryText)
            }
            .buttonStyle(.plain)
            .frame(width: 20)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isSelected ? Theme.accentSoft : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { store.selectMockCase(mockCase.id) }
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: MockRowHeightKey.self, value: proxy.size.height)
            }
        }
        .onPreferenceChange(MockRowHeightKey.self) { height = $0 }
        .overlay(alignment: .top) {
            if isHint(.before) {
                Rectangle().fill(Theme.accent).frame(height: 2)
            }
        }
        .overlay(alignment: .bottom) {
            if isHint(.after) {
                Rectangle().fill(Theme.accent).frame(height: 2)
            }
        }
    }

    private func isHint(_ edge: MockDropEdge) -> Bool {
        dropHint?.itemID == mockCase.id && dropHint?.edge == edge
    }

    private func move(_ dragged: String, _ edge: MockDropEdge) -> Bool {
        guard let cases = store.library.mockServices.first(where: { $0.id == serviceID })?.cases,
              let from = cases.firstIndex(where: { $0.id == dragged }),
              let target = cases.firstIndex(where: { $0.id == mockCase.id }) else { return false }
        store.moveMockCase(serviceID: serviceID, from: from, to: edge == .before ? target : target + 1)
        return true
    }
}
