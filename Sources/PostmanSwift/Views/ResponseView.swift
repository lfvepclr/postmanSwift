import SwiftUI
import AppKit

struct ResponseView: View {
    @Environment(AppStore.self) private var store
    @Bindable var tab: RequestTab
    @State private var selectedPDFIndex = 0
    @State private var expandedHeaderSections: Set<String> = []
    @AppStorage("workspaceSplitOrientation") private var workspaceOrientation = "stacked"
    @State private var pdfViewer: PDFViewerPayload?
    @State private var imageViewer: ImageViewerPayload?

    private var sections: [ResponseSection] {
        ResponseSection.allCases.filter { $0 != .visualizer || tab.visualizerHTML != nil }
    }

    private var historyRefreshToken: String {
        "\(tab.itemID ?? "-")|\(tab.response?.result.statusCode ?? 0)|\(tab.response?.byteCount ?? 0)"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if tab.isSending {
                sendingState
            } else if tab.isLoadingHistoryResponse {
                loadingState
            } else if let error = tab.errorMessage {
                errorState(error)
            } else if let response = tab.response {
                responseTabs
                Divider()
                responseContent(response)
            } else {
                emptyState
            }
        }
        .background(Theme.editor)
        .sheet(item: $pdfViewer) { payload in
            PDFViewerSheet(payload: payload)
        }
        .sheet(item: $imageViewer) { payload in
            ImageViewerSheet(payload: payload)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 9) {
            Text("Response")
                .font(.system(size: 12, weight: .semibold))
            if let response = tab.response, !tab.isSending {
                StatusBadge(code: response.result.statusCode, text: response.result.statusText)
                Text(ContentUtilities.durationDescription(response.result.duration))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
                Text(ContentUtilities.sizeDescription(response.byteCount))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
                if !response.result.redirects.isEmpty {
                    Text("\(response.result.redirects.count) redirect")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.tertiaryText)
                }
            }
            if tab.isSending {
                ProgressView().controlSize(.small)
                Text("Sending…")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            IconButton(
                systemName: workspaceOrientation == "sideBySide" ? "rectangle.split.1x2" : "rectangle.split.2x1",
                help: workspaceOrientation == "sideBySide" ? "切换到上下布局" : "切换到左右布局"
            ) {
                workspaceOrientation = workspaceOrientation == "sideBySide" ? "stacked" : "sideBySide"
            }
            if let response = tab.response {
                IconButton(systemName: "doc.on.doc", help: "Copy response body") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(response.text ?? "", forType: .string)
                }
                IconButton(systemName: "square.and.arrow.down", help: "Save response body") {
                    saveResponse(response)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    private var responseTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(sections) { section in
                    SectionTabButton(
                        title: section.rawValue,
                        isSelected: tab.responseSection == section,
                        badge: section == .history ? tab.testResults.count : 0
                    ) {
                        tab.responseSection = section
                    }
                }
                Spacer(minLength: 12)
                if !tab.testResults.isEmpty {
                    let passed = tab.testResults.filter(\.passed).count
                    Text("\(passed)/\(tab.testResults.count) tests passed")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(passed == tab.testResults.count ? Theme.success : Theme.danger)
                        .padding(.trailing, 10)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 6)
        }
    }

    // MARK: - States

    private var sendingState: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Waiting for response…")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Loading saved response…")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 24))
                .foregroundStyle(Theme.danger)
            Text("Could not send request")
                .font(.system(size: 13, weight: .semibold))
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
                .textSelection(.enabled)
            Button("Retry") { store.send(tab) }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    private var emptyState: some View {
        EmptyStateView(
            icon: "arrow.up.forward.app",
            title: "No response yet",
            message: "Send the request to see the status, headers, cookies and body here."
        )
    }

    // MARK: - Content

    @ViewBuilder
    private func responseContent(_ response: ResponseRecord) -> some View {
        switch tab.responseSection {
        case .headers:
            headersView(response)
        case .payload:
            payloadView(response)
        case .preview:
            bodyView(response)
        case .timing:
            performanceView(response)
        case .cookies:
            cookiesView(response)
        case .history:
            ExecutionHistorySection(
                itemID: tab.itemID,
                refreshToken: historyRefreshToken,
                testResults: tab.testResults
            )
        case .visualizer:
            if let html = tab.visualizerHTML {
                WebPreviewView(html: html, baseURL: nil)
            } else {
                EmptyStateView(icon: "chart.bar", title: "No visualization", message: "Call pm.visualizer.set() in the Tests script to render one.")
            }
        }
    }

    private func payloadView(_ response: ResponseRecord) -> some View {
        let prepared = response.prepared
        let queryItems = prepared.flatMap {
            URLComponents(url: $0.url, resolvingAgainstBaseURL: false)?.queryItems
        } ?? []
        let body = prepared?.body
        let hasBody = !(body?.isEmpty ?? true)
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if queryItems.isEmpty && !hasBody {
                    EmptyStateView(
                        icon: "shippingbox",
                        title: "No payload",
                        message: "This request has no query parameters or body."
                    )
                    .frame(minHeight: 200)
                } else {
                    if !queryItems.isEmpty {
                        sectionTitle("Query String Parameters (\(queryItems.count))")
                        ForEach(Array(queryItems.enumerated()), id: \.offset) { _, item in
                            headerRow(key: item.name, value: item.value ?? "")
                            Divider()
                        }
                    }
                    if let body, !body.isEmpty {
                        sectionTitle("Request Payload")
                        payloadBodyView(body, mime: prepared?.headers.first { $0.key.lowercased() == "content-type" }?.value)
                    }
                }
            }
        }
    }

    private func payloadBodyView(_ data: Data, mime: String?) -> some View {
        let formatted = Self.formattedPayload(data)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if let mime, !mime.isEmpty {
                    Text(mime)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.tertiaryText)
                }
                Text(ContentUtilities.sizeDescription(data.count))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiaryText)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            CodeTextView(
                text: formatted.text,
                language: formatted.language,
                wrapVeryLongLines: true,
                maxDisplayBytes: 200_000
            )
            .frame(minHeight: 120)
        }
    }

    private struct FormattedPayload {
        let text: String
        let language: SyntaxLanguage
    }

    private static func formattedPayload(_ data: Data) -> FormattedPayload {
        if let object = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: pretty, encoding: .utf8) {
            return FormattedPayload(text: text, language: .json)
        }
        return FormattedPayload(text: String(decoding: data, as: UTF8.self), language: .plain)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.tertiaryText)
            .textCase(.uppercase)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.04))
            .overlay(alignment: .bottom) { Divider() }
    }

    private func generalRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 160, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    private func statusGeneralRow(_ response: ResponseRecord) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text("Status Code")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 160, alignment: .leading)
            StatusBadge(code: response.result.statusCode, text: response.result.statusText)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    private func headerRow(key: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(key)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 200, alignment: .leading)
                .textSelection(.enabled)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    private func collapsibleHeaderSection(_ title: String, headers: [KeyValue], id: String) -> some View {
        let expanded = expandedHeaderSections.contains(id)
        return VStack(spacing: 0) {
            Button {
                if expanded {
                    expandedHeaderSections.remove(id)
                } else {
                    expandedHeaderSections.insert(id)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.tertiaryText)
                        .frame(width: 10)
                    Text("\(title) (\(headers.count))")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
                .background(Color.secondary.opacity(0.04))
            }
            .buttonStyle(.plain)
            Divider()
            if expanded {
                if headers.isEmpty {
                    Text("None")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiaryText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                        headerRow(key: header.key, value: header.value)
                        Divider()
                    }
                }
            }
        }
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.tertiaryText)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    private func performanceView(_ response: ResponseRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let timings = response.result.timings {
                    timingRow("DNS Lookup", timings.dns, total: timings.total)
                    timingRow("Socket Connect", timings.connect, total: timings.total)
                    timingRow("TLS Handshake", timings.tls, total: timings.total)
                    timingRow("Request Sent", timings.request, total: timings.total)
                    timingRow("Waiting (TTFB)", timings.ttfb, total: timings.total)
                    timingRow("Download", timings.download, total: timings.total)
                    timingRow("Total", timings.total, total: timings.total)
                    Divider().padding(.vertical, 4)
                    detailRow("Protocol", timings.protocolName ?? "—")
                    detailRow("Remote", timings.remoteAddress ?? "—")
                    detailRow("Size", ContentUtilities.sizeDescription(response.byteCount))
                } else {
                    EmptyStateView(
                        icon: "clock",
                        title: "No timing data",
                        message: "Timing metrics are collected for new requests. Send again to populate this tab."
                    )
                    .frame(minHeight: 200)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func timingRow(_ title: String, _ milliseconds: Double?, total: Double) -> some View {
        let value = milliseconds ?? 0
        let fraction = total > 0 ? min(1, value / total) : 0
        return HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 120, alignment: .leading)
            GeometryReader { geometry in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.accent.opacity(milliseconds == nil ? 0.12 : 0.55))
                    .frame(width: max(1, geometry.size.width * fraction), height: 8)
                    .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 18)
            Text(milliseconds.map { String(format: "%.1f ms", $0) } ?? "—")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.tertiaryText)
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
    }

    private func bodyView(_ response: ResponseRecord) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("", selection: $tab.displayMode) {
                    ForEach(BodyDisplayMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .tint(Theme.accent)
                .frame(width: 140)
                if let mime = response.result.mimeType {
                    Text(mime)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.tertiaryText)
                }
                Spacer()
                Text(ContentUtilities.sizeDescription(response.byteCount))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()

            if tab.isRestoringResponse || response.isEvicted {
                restoringState
            } else {
                switch tab.displayMode {
                case .preview:
                    previewView(response)
                case .raw:
                    RawResponseText(response: response)
                }
            }
        }
    }

    private var restoringState: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("正在恢复大响应…")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noBodyView: some View {
        EmptyStateView(icon: "doc", title: "No body", message: "This response has no displayable text body.")
    }

    @ViewBuilder
    private func previewView(_ response: ResponseRecord) -> some View {
        let mime = (response.result.mimeType ?? "").lowercased()
        let head = textHead(response.text)
        if response.isEvicted || tab.isRestoringResponse {
            restoringState
        } else if let tree = response.tree {
            JSONTreeView(
                presentation: tree,
                onOpenPDF: { base64, name in
                    pdfViewer = PDFViewerPayload(base64: base64, name: name)
                },
                onOpenImage: { base64, name in
                    imageViewer = ImageViewerPayload(base64: base64, name: name)
                }
            )
            .equatable()
            .id(tree.id)
        } else if !response.embeddedPDFs.isEmpty {
            pdfPreview(response)
        } else if mime.hasPrefix("image/"), !response.result.isBodyFileBacked, let image = NSImage(data: response.result.body) {
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 1200, maxHeight: 1200)
                    .padding(12)
            }
        } else if mime.contains("html") || head.hasPrefix("<!doctype html") {
            WebPreviewView(html: response.text ?? "", baseURL: response.result.finalURL)
        } else {
            if let text = response.text, !text.isEmpty {
                CodeTextView(
                    text: limited(text, cap: 2_000_000),
                    language: SyntaxLanguage.detect(mime: response.result.mimeType, text: text),
                    wrapVeryLongLines: true,
                    maxDisplayBytes: 1_000_000
                )
            } else {
                EmptyStateView(icon: "eye", title: "No preview available", message: "Use Raw to inspect this response body.")
            }
        }
    }

    /// Cheap head-of-body probe; never materialises the full response text just to sniff a MIME type.
    private func textHead(_ text: String?) -> String {
        guard let text else { return "" }
        let sample = text.utf8.count > 4_096 ? String(text.prefix(4_096)) : text
        return sample.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64).lowercased()
    }

    private func pdfPreview(_ response: ResponseRecord) -> some View {
        let pdfs = response.embeddedPDFs
        let index = min(max(0, selectedPDFIndex), pdfs.count - 1)
        let pdf = pdfs[index]
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.richtext")
                    .foregroundStyle(Theme.accent)
                Text("PDF")
                    .font(.system(size: 11, weight: .semibold))
                Text(pdf.name)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(ContentUtilities.sizeDescription(pdf.byteCount))
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.tertiaryText)
                if pdfs.count > 1 {
                    Menu("\(index + 1)/\(pdfs.count)") {
                        ForEach(Array(pdfs.enumerated()), id: \.offset) { offset, item in
                            Button(item.name) { selectedPDFIndex = offset }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 80)
                }
                Spacer()
                Button("Save PDF") {
                    FilePanels.save(data: pdf.data, suggestedName: pdf.name.hasSuffix(".pdf") ? pdf.name : "\(pdf.name).pdf")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.accent)
                .font(.system(size: 10))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            PDFPreviewView(data: pdf.data)
        }
    }

    private func cookiesView(_ response: ResponseRecord) -> some View {
        let cookies = store.cookieJar.cookies(for: response.result.finalURL)
        return ScrollView {
            if cookies.isEmpty {
                EmptyStateView(icon: "circle.grid.2x3", title: "No cookies", message: "This response did not set any cookies for \(response.result.finalURL.host ?? "this host").")
                    .frame(minHeight: 180)
            } else {
                VStack(spacing: 0) {
                    ForEach(cookies) { cookie in
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(cookie.name)
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                Text(cookie.value)
                                    .font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 3) {
                                Text(cookie.displayDomain + cookie.path)
                                Text(cookie.expires.map { "expires \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "session")
                            }
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.tertiaryText)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        Divider()
                    }
                }
            }
        }
    }

    private func headersView(_ response: ResponseRecord) -> some View {
        let prepared = response.prepared
        let requestHeaders = prepared?.headers.filter(\.isEnabled) ?? []
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                sectionTitle("General")
                generalRow("Request URL", prepared?.url.absoluteString ?? response.result.finalURL.absoluteString)
                generalRow("Request Method", prepared?.method ?? tab.draft.method)
                statusGeneralRow(response)
                generalRow("Remote Address", response.result.timings?.remoteAddress ?? "—")
                generalRow("Protocol", response.result.timings?.protocolName ?? "—")
                collapsibleHeaderSection("Response headers", headers: response.result.headers, id: "response")
                collapsibleHeaderSection("Request headers", headers: requestHeaders, id: "request")
            }
        }
    }

    // MARK: - Helpers

    private func limited(_ text: String, cap: Int? = nil) -> String {
        let limit = max(1, cap ?? min(2_000_000, store.library.settings.maxResponseDisplayBytes))
        guard text.utf8.count > limit else { return text }
        let prefix = String(text.prefix(limit / 2))
        return prefix + "\n\n… response truncated for display at \(ContentUtilities.sizeDescription(limit)). Use Save to export the full body."
    }

    private func saveResponse(_ response: ResponseRecord) {
        let mime = (response.result.mimeType ?? "").lowercased()
        let fileName: String
        if mime.contains("json") { fileName = "response.json" }
        else if mime.contains("html") { fileName = "response.html" }
        else if mime.contains("xml") { fileName = "response.xml" }
        else if mime.contains("image/png") { fileName = "response.png" }
        else if mime.contains("image/jpeg") { fileName = "response.jpg" }
        else { fileName = "response.txt" }
        if let fileURL = response.result.bodyFileURL {
            FilePanels.save(fileURL: fileURL, suggestedName: fileName)
        } else {
            FilePanels.save(data: response.result.body, suggestedName: fileName)
        }
    }
}

// MARK: - Execution history

private struct ExecutionHistorySection: View {
    @Environment(AppStore.self) private var store
    let itemID: String?
    let refreshToken: String
    let testResults: [TestResult]

    @State private var entries: [HistoryEntry] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                title("本次执行")
                if testResults.isEmpty {
                    Text("没有脚本断言。只有在 Tests 脚本里调用 pm.test(...) 才会记录断言结果；执行历史不受影响。")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.tertiaryText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(testResults) { result in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: result.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(result.passed ? Theme.success : Theme.danger)
                                .font(.system(size: 12))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.name)
                                    .font(.system(size: 11, weight: .medium))
                                if let error = result.errorMessage, !error.isEmpty {
                                    Text(error)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(Theme.danger)
                                        .textSelection(.enabled)
                                }
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        Divider()
                    }
                }

                title("最近执行" + (entries.isEmpty ? "" : " (\(entries.count))"))
                if itemID == nil {
                    Text("这个标签页不对应集合请求，因此没有执行历史。")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.tertiaryText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                } else if entries.isEmpty {
                    Text("还没有执行记录。发送请求后，这里会按时间列出每次运行的状态、耗时和大小。")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.tertiaryText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(entries) { entry in
                        Button {
                            store.openHistory(entry)
                        } label: {
                            historyRow(entry)
                        }
                        .buttonStyle(.plain)
                        .help("用新标签页打开这次响应")
                        Divider()
                    }
                }
            }
            .padding(.bottom, 8)
        }
        .task(id: refreshToken) { reload() }
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.tertiaryText)
            .textCase(.uppercase)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.04))
            .overlay(alignment: .bottom) { Divider() }
    }

    private func historyRow(_ entry: HistoryEntry) -> some View {
        HStack(spacing: 10) {
            StatusBadge(code: entry.statusCode, text: HTTPClient.reason(for: entry.statusCode))
            Text(RelativeTime.string(entry.timestamp))
                .font(.system(size: 10))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 70, alignment: .leading)
            Text(ContentUtilities.durationDescription(entry.duration))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 70, alignment: .trailing)
            Text(ContentUtilities.sizeDescription(entry.responseSize))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.tertiaryText)
                .frame(width: 70, alignment: .trailing)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Theme.tertiaryText)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private func reload() {
        guard let itemID else {
            entries = []
            return
        }
        entries = store.recentHistory(itemID: itemID)
    }
}

/// Raw view: renders the complete body with no display cap. File-backed responses are read
/// off the main thread; very long lines disable wrapping so TextKit 2 can lay out lazily.
private struct RawResponseText: View {
    let response: ResponseRecord

    @State private var text: String?
    @State private var isLoading = false
    @State private var binaryNotice = false

    private var loadKey: String {
        "\(response.result.size)|\(response.result.bodyFileURL?.path ?? "-")|\(response.text?.utf8.count ?? -1)"
    }

    var body: some View {
        ZStack {
            if let text {
                CodeTextView(
                    text: text,
                    language: .plain,
                    wrapVeryLongLines: true,
                    maxDisplayBytes: nil
                )
            } else if isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在读取完整响应（\(ContentUtilities.sizeDescription(response.byteCount))）…")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            } else if binaryNotice {
                EmptyStateView(icon: "doc", title: "Binary body", message: "This response is not text. Use Save or the Preview tab to inspect it.")
            } else {
                EmptyStateView(icon: "doc", title: "No body", message: "This response has no displayable text body.")
            }
        }
        .task(id: loadKey) { await load() }
    }

    private func load() async {
        if let fileURL = response.result.bodyFileURL {
            isLoading = true
            text = nil
            binaryNotice = false
            let mime = response.result.mimeType
            let loaded = await Task.detached(priority: .userInitiated) { () -> String? in
                guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else { return nil }
                return ContentUtilities.decodeText(data, mime: mime)
            }.value
            guard !Task.isCancelled else { return }
            isLoading = false
            text = loaded
            binaryNotice = loaded == nil
            return
        }

        if let existing = response.text, !existing.isEmpty {
            text = existing
            binaryNotice = false
            return
        }

        if response.result.body.isEmpty {
            text = nil
            binaryNotice = false
            return
        }
        let mime = response.result.mimeType
        let body = response.result.body
        let decoded = await Task.detached(priority: .userInitiated) {
            ContentUtilities.decodeText(body, mime: mime)
        }.value
        text = decoded
        binaryNotice = decoded == nil
    }
}
