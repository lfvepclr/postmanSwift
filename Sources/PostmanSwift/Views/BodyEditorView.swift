import SwiftUI

struct BodyEditorView: View {
    @Binding var draft: RequestDraft
    var variables: [VariableSuggestion] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Picker("", selection: $draft.bodyMode) {
                    ForEach(BodyMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 620)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()

            switch draft.bodyMode {
            case .none:
                EmptyStateView(icon: "doc", title: "This request has no body", message: "Choose a body type above to send data with the request.")
                    .frame(minHeight: 200)

            case .raw:
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Picker("", selection: $draft.rawLanguage) {
                            ForEach(RawLanguage.allCases) { language in
                                Text(language.title).tag(language)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 130)
                        Text(draft.rawLanguage.contentType)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.tertiaryText)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    CodeTextEditor(text: $draft.rawBody, language: SyntaxLanguage.from(rawLanguage: draft.rawLanguage), variables: variables)
                        .frame(minHeight: 220)
                }

            case .urlencoded:
                KeyValueEditor(rows: $draft.urlencoded, keyPlaceholder: "Key", valuePlaceholder: "Value", showsDescription: true, variables: variables)

            case .formdata:
                KeyValueEditor(rows: $draft.formdata, keyPlaceholder: "Key", valuePlaceholder: "Value", showsDescription: true, showsFilePicker: true, variables: variables)

            case .graphql:
                VStack(alignment: .leading, spacing: 0) {
                    Text("Query")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                    CodeTextEditor(text: $draft.graphqlQuery, language: .graphql, variables: variables)
                        .frame(minHeight: 170)
                    Divider()
                    Text("GraphQL Variables (JSON)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                    CodeTextEditor(text: $draft.graphqlVariables, language: .json, variables: variables)
                        .frame(minHeight: 100)
                }

            case .binary:
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("File")
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 60, alignment: .leading)
                        Text(draft.binaryFilePath.isEmpty ? "No file selected" : draft.binaryFilePath)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(draft.binaryFilePath.isEmpty ? Theme.tertiaryText : Theme.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Choose File…") {
                            if let url = FilePanels.openFile() {
                                draft.binaryFilePath = url.path
                            }
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Theme.accent)
                        if !draft.binaryFilePath.isEmpty {
                            Button("Clear") { draft.binaryFilePath = "" }
                                .buttonStyle(.borderless)
                                .foregroundStyle(Theme.secondaryText)
                        }
                    }
                    Text("The selected file is streamed as the request body. Its MIME type is inferred from the extension.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiaryText)
                    Spacer()
                }
                .padding(14)
            }
        }
    }
}

struct ScriptEditorView: View {
    @Binding var text: String
    let title: String
    var snippets: [ScriptSnippet]
    var variables: [VariableSuggestion] = []
    @State private var showReference = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                    Menu("Snippets") {
                        ForEach(snippets) { snippet in
                            Button(snippet.title) {
                                insert(snippet.code)
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 90)
                    Button {
                        showReference.toggle()
                    } label: {
                        Label("API", systemImage: "book")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(showReference ? Theme.accent : Theme.secondaryText)
                    Spacer()
                    Text("JavaScript · pm.* API")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.tertiaryText)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("// Write JavaScript here. Type {{ for variables or pm. for API suggestions.")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.tertiaryText)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }
                    CodeTextEditor(text: $text, language: .javascript, variables: variables, scriptAPI: true)
                }
            }
            if showReference {
                Divider()
                ScriptReferenceView(onInsert: { insert($0) })
                    .frame(width: 300)
            }
        }
        .onDisappear {
            CompletionPopupController.shared.close()
        }
    }

    private func insert(_ snippet: String) {
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        text += snippet
    }
}

struct ScriptSnippet: Identifiable {
    var id: String { title }
    let title: String
    let code: String

    static let preRequest: [ScriptSnippet] = [
        ScriptSnippet(title: "Set an environment variable", code: "pm.environment.set(\"variable_key\", \"variable_value\");\n"),
        ScriptSnippet(title: "Get a variable", code: "const value = pm.variables.get(\"variable_key\");\nconsole.log(value);\n"),
        ScriptSnippet(title: "Set a local variable", code: "pm.variables.set(\"local_key\", \"local_value\");\n"),
        ScriptSnippet(title: "Add a header", code: "pm.request.headers.add({ key: \"X-Debug\", value: \"true\" });\n"),
        ScriptSnippet(title: "Send a request", code: "pm.sendRequest(\"https://postman-echo.com/get\", function (err, res) {\n    if (err) { console.error(err); return; }\n    console.log(res.json());\n});\n")
    ]

    static let tests: [ScriptSnippet] = [
        ScriptSnippet(title: "Status code is 200", code: "pm.test(\"Status code is 200\", function () {\n    pm.response.to.have.status(200);\n});\n"),
        ScriptSnippet(title: "Response time is below 500ms", code: "pm.test(\"Response time is below 500ms\", function () {\n    pm.expect(pm.response.responseTime).to.be.below(500);\n});\n"),
        ScriptSnippet(title: "Body contains a string", code: "pm.test(\"Body contains text\", function () {\n    pm.expect(pm.response.text()).to.include(\"expected\");\n});\n"),
        ScriptSnippet(title: "JSON field equals value", code: "pm.test(\"JSON field equals value\", function () {\n    const data = pm.response.json();\n    pm.expect(data).to.have.property(\"key\", \"value\");\n});\n"),
        ScriptSnippet(title: "Save a value for later", code: "pm.test(\"Save token\", function () {\n    const data = pm.response.json();\n    pm.environment.set(\"token\", data.token);\n});\n"),
        ScriptSnippet(title: "Set next request", code: "pm.execution.setNextRequest(\"Request Name\");\n")
    ]
}
