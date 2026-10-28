import SwiftUI

struct KeyValueEditor: View {
    @Binding var rows: [KeyValue]
    var keyPlaceholder: String = "Key"
    var valuePlaceholder: String = "Value"
    var showsDescription = false
    var showsFilePicker = false
    var variables: [VariableSuggestion] = []
    var onChange: (() -> Void)?
    @State private var isBulkEditing = false
    @State private var bulkText = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            if isBulkEditing {
                bulkEditor
            } else {
                if rows.isEmpty {
                    HStack {
                        Text("No entries yet.")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.tertiaryText)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                } else {
                    ForEach($rows) { $row in
                        rowView($row)
                        Divider()
                    }
                }
                HStack(spacing: 12) {
                    Button {
                        rows.append(KeyValue())
                        onChange?()
                    } label: {
                        Label("Add", systemImage: "plus")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                    Button {
                        startBulkEdit()
                    } label: {
                        Label("Bulk Edit", systemImage: "square.and.pencil")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.secondaryText)
                    Spacer()
                    Text("\(rows.filter(\.isEnabled).count) enabled")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.tertiaryText)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
    }

    private var bulkEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $bulkText)
                .font(.system(size: 11, design: .monospaced))
                .frame(minHeight: 140)
                .padding(6)
                .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border))
            HStack {
                Text("One entry per line: Key: Value. Prefix // to disable a row.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiaryText)
                Spacer()
                Button("Cancel") { isBulkEditing = false }
                Button("Apply") { applyBulkEdit() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
    }

    private func startBulkEdit() {
        bulkText = rows.map { row in
            (row.disabled ? "// " : "") + "\(row.key): \(row.value)"
        }.joined(separator: "\n")
        isBulkEditing = true
    }

    private func applyBulkEdit() {
        var parsed: [KeyValue] = []
        for rawLine in bulkText.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            var disabled = false
            if line.hasPrefix("//") {
                disabled = true
                line = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
            guard !line.isEmpty else { continue }
            if let separator = line.firstIndex(where: { $0 == ":" || $0 == "=" }) {
                let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
                parsed.append(KeyValue(key: key, value: value, disabled: disabled))
            } else {
                parsed.append(KeyValue(key: line, value: "", disabled: disabled))
            }
        }
        rows = parsed
        isBulkEditing = false
        onChange?()
    }

    private var header: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 16)
            Text(keyPlaceholder.uppercased())
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(valuePlaceholder.uppercased())
                .frame(maxWidth: .infinity, alignment: .leading)
            if showsDescription {
                Text("DESCRIPTION")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if showsFilePicker {
                Text("TYPE")
                    .frame(width: 62, alignment: .leading)
            }
            Color.clear.frame(width: 22)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(Theme.tertiaryText)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.05))
        .overlay(alignment: .bottom) { Divider() }
    }

    private func rowView(_ row: Binding<KeyValue>) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { !row.wrappedValue.disabled },
                set: { row.wrappedValue.disabled = !$0; onChange?() }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .frame(width: 16)

            VariableTextField(
                text: Binding(
                    get: { row.wrappedValue.key },
                    set: { row.wrappedValue.key = $0; onChange?() }
                ),
                placeholder: keyPlaceholder,
                fontSize: 11,
                monospaced: true,
                variables: variables
            )
            .frame(maxWidth: .infinity)

            if showsFilePicker, row.wrappedValue.type?.lowercased() == "file" {
                HStack(spacing: 4) {
                    Text(row.wrappedValue.value.isEmpty ? "Choose file…" : row.wrappedValue.value)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(row.wrappedValue.value.isEmpty ? Theme.tertiaryText : Theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Button("Browse") {
                        if let url = FilePanels.openFile() {
                            row.wrappedValue.type = "file"
                            row.wrappedValue.src = .string(url.path)
                            row.wrappedValue.value = url.path
                            onChange?()
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.accent)
                }
                .frame(maxWidth: .infinity)
            } else {
                VariableTextField(
                    text: Binding(
                        get: { row.wrappedValue.value },
                        set: { row.wrappedValue.value = $0; onChange?() }
                    ),
                    placeholder: valuePlaceholder,
                    fontSize: 11,
                    monospaced: true,
                    variables: variables
                )
                .frame(maxWidth: .infinity)
            }

            if showsDescription {
                TextField("Description", text: Binding(
                    get: { row.wrappedValue.description?.content ?? "" },
                    set: {
                        row.wrappedValue.description = $0.isEmpty ? nil : RichText($0)
                        onChange?()
                    }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
                .frame(maxWidth: .infinity)
            }

            if showsFilePicker {
                Menu {
                    Button("Text") {
                        row.wrappedValue.type = "text"
                        row.wrappedValue.src = nil
                        onChange?()
                    }
                    Button("File") {
                        row.wrappedValue.type = "file"
                        onChange?()
                    }
                } label: {
                    Text(row.wrappedValue.type?.lowercased() == "file" ? "File" : "Text")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.secondaryText)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 62)
            }

            Button {
                let id = row.wrappedValue.id
                rows.removeAll { $0.id == id }
                onChange?()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiaryText)
            }
            .buttonStyle(.plain)
            .frame(width: 22)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}
