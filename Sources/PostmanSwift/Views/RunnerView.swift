import SwiftUI
import AppKit

struct RunnerView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        RunnerContent(runner: store.runner, dismiss: { dismiss() })
            .environment(store)
    }
}

private struct RunnerContent: View {
    @Environment(AppStore.self) private var store
    @ObservedObject var runner: RunnerState
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Collection Runner")
                    .font(.system(size: 14, weight: .semibold))
                if runner.isRunning, let current = runner.currentRequestName {
                    ProgressView().controlSize(.small)
                    Text(current)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                Button("Close") { dismiss() }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()

            controls
            Divider()
            summary
            Divider()
            results
        }
        .frame(width: 980, height: 600)
        .onAppear {
            if runner.selectedCollectionID == nil {
                runner.selectedCollectionID = store.library.collections.first?.id
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Picker("Collection", selection: $runner.selectedCollectionID) {
                Text("Select a collection").tag(String?.none)
                ForEach(store.library.collections) { collection in
                    Text(collection.info.name).tag(Optional(collection.id))
                }
            }
            .frame(width: 260)

            Stepper("Iterations: \(runner.iterations)", value: $runner.iterations, in: 1...100)
                .frame(width: 150)

            Stepper("Delay: \(runner.delayMilliseconds) ms", value: $runner.delayMilliseconds, in: 0...10000, step: 100)
                .frame(width: 190)

            Button {
                if let url = FilePanels.open(types: [.json, .commaSeparatedText, .plainText]).first {
                    store.loadRunnerData(from: url)
                }
            } label: {
                Label(runner.dataFileName ?? "Data File", systemImage: "doc.badge.plus")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.accent)
            if runner.dataFileName != nil {
                Button {
                    runner.dataRows = []
                    runner.dataFileName = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.tertiaryText)
                }
                .buttonStyle(.plain)
            }

            Spacer()

            if runner.isRunning {
                Button("Stop") { runner.stopRequested = true }
                    .buttonStyle(.bordered)
            } else {
                Button("Run") { store.startRunner() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(runner.selectedCollectionID == nil)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var summary: some View {
        let total = runner.results.count
        let passed = runner.results.filter(\.passed).count
        return HStack(spacing: 16) {
            Text("\(total) requests")
                .font(.system(size: 11, weight: .medium))
            Text("\(passed) passed")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.success)
            Text("\(total - passed) failed")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(total - passed > 0 ? Theme.danger : Theme.tertiaryText)
            if !runner.dataRows.isEmpty {
                Text("Data: \(runner.dataRows.count) rows")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiaryText)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(Color.secondary.opacity(0.04))
    }

    private var results: some View {
        ScrollView {
            if runner.results.isEmpty {
                EmptyStateView(icon: "play.circle", title: "No run yet", message: "Choose a collection, set iterations and hit Run. Requests run in collection order and respect setNextRequest().")
                    .frame(minHeight: 240)
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Text("REQUEST").frame(maxWidth: .infinity, alignment: .leading)
                        Text("ITER").frame(width: 50, alignment: .leading)
                        Text("STATUS").frame(width: 70, alignment: .leading)
                        Text("TESTS").frame(width: 80, alignment: .leading)
                        Text("TIME").frame(width: 80, alignment: .leading)
                        Text("RESULT").frame(width: 80, alignment: .leading)
                    }
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.tertiaryText)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(Color.secondary.opacity(0.05))

                    ForEach(runner.results) { result in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    MethodBadge(method: result.method, fontSize: 9)
                                    Text(result.name)
                                        .font(.system(size: 11))
                                }
                                if let error = result.error {
                                    Text(error)
                                        .font(.system(size: 10))
                                        .foregroundStyle(Theme.danger)
                                        .lineLimit(2)
                                }
                                let failedTests = result.tests.filter { !$0.passed }
                                if !failedTests.isEmpty {
                                    Text(failedTests.map(\.name).joined(separator: ", "))
                                        .font(.system(size: 10))
                                        .foregroundStyle(Theme.danger)
                                        .lineLimit(1)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Text("\(result.iteration)")
                                .frame(width: 50, alignment: .leading)
                            Text(result.statusCode.map(String.init) ?? "—")
                                .foregroundStyle(result.statusCode.map { Theme.statusColor($0) } ?? Theme.secondaryText)
                                .frame(width: 70, alignment: .leading)
                            Text(result.tests.isEmpty ? "—" : "\(result.tests.filter(\.passed).count)/\(result.tests.count)")
                                .foregroundStyle(result.tests.allSatisfy(\.passed) ? Theme.success : Theme.danger)
                                .frame(width: 80, alignment: .leading)
                            Text(ContentUtilities.durationDescription(result.duration))
                                .frame(width: 80, alignment: .leading)
                            HStack(spacing: 4) {
                                Image(systemName: result.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(result.passed ? Theme.success : Theme.danger)
                                Text(result.passed ? "Passed" : "Failed")
                                    .foregroundStyle(result.passed ? Theme.success : Theme.danger)
                            }
                            .frame(width: 80, alignment: .leading)
                        }
                        .font(.system(size: 10, design: .monospaced))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        Divider()
                    }
                }
            }
        }
    }
}

struct CodeSnippetView: View {
    @Environment(AppStore.self) private var store
    @Bindable var tab: RequestTab
    @State private var language: CodeLanguage = .curl
    @State private var snippet: String?
    @State private var cache: [CodeLanguage: String] = [:]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Code Snippet")
                    .font(.system(size: 14, weight: .semibold))
                Picker("", selection: $language) {
                    ForEach(CodeLanguage.allCases) { language in
                        Text(language.title).tag(language)
                    }
                }
                .labelsHidden()
                .frame(width: 200)
                Spacer()
                Button("Copy") {
                    guard let snippet else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(snippet, forType: .string)
                }
                .disabled(snippet == nil)
                Button("Close") { close() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            if let snippet {
                CodeTextView(text: snippet, fontSize: 11, language: SyntaxLanguage.from(codeLanguage: language))
            } else {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在生成代码片段…")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 800, height: 540)
        .background(Theme.editor)
        .task(id: language) { await generate() }
        .onDisappear { store.closeCodeSnippet() }
    }

    private func generate() async {
        if let cached = cache[language] {
            snippet = cached
            return
        }
        snippet = nil
        await Task.yield()
        let produced = store.codeSnippet(for: tab, language: language)
        cache[language] = produced
        snippet = produced
    }

    private func close() {
        store.closeCodeSnippet()
    }
}
