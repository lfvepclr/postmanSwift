import SwiftUI

enum SidebarSheet: Identifiable {
    case script(id: UUID, title: String, phase: String, initial: String, onSave: (String) -> Void)
    case variables(id: UUID, title: String, initial: [KeyValue], onSave: ([KeyValue]) -> Void)
    case auth(id: UUID, title: String, initial: Auth, inherited: Auth, inheritedLabel: String, onSave: (Auth) -> Void)

    var id: UUID {
        switch self {
        case .script(let id, _, _, _, _): return id
        case .variables(let id, _, _, _): return id
        case .auth(let id, _, _, _, _, _): return id
        }
    }
}

struct SidebarSheetView: View {
    let sheet: SidebarSheet

    var body: some View {
        switch sheet {
        case .script(_, let title, let phase, let initial, let onSave):
            ScriptEditorSheet(title: title, phase: phase, initial: initial, onSave: onSave)
        case .variables(_, let title, let initial, let onSave):
            VariablesSheet(title: title, initial: initial, onSave: onSave)
        case .auth(_, let title, let initial, let inherited, let inheritedLabel, let onSave):
            AuthSheet(title: title, initial: initial, inherited: inherited, inheritedLabel: inheritedLabel, onSave: onSave)
        }
    }
}

struct ScriptEditorSheet: View {
    let title: String
    let phase: String
    let initial: String
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(title: String, phase: String, initial: String, onSave: @escaping (String) -> Void) {
        self.title = title
        self.phase = phase
        self.initial = initial
        self.onSave = onSave
        _text = State(initialValue: initial)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    onSave(text)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            ScriptEditorView(
                text: $text,
                title: phase == "prerequest" ? "Pre-request Script" : "Tests",
                snippets: phase == "prerequest" ? ScriptSnippet.preRequest : ScriptSnippet.tests
            )
        }
        .frame(width: 800, height: 560)
    }
}

struct VariablesSheet: View {
    let title: String
    let initial: [KeyValue]
    let onSave: ([KeyValue]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var values: [KeyValue]

    init(title: String, initial: [KeyValue], onSave: @escaping ([KeyValue]) -> Void) {
        self.title = title
        self.initial = initial
        self.onSave = onSave
        _values = State(initialValue: initial)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    onSave(values)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            KeyValueEditor(rows: $values, keyPlaceholder: "Variable", valuePlaceholder: "Value")
            Divider()
            Text("These variables are inherited by requests unless an environment or local variable has the same name.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .frame(width: 760, height: 500)
    }
}

struct AuthSheet: View {
    let title: String
    let initial: Auth
    let inherited: Auth
    let inheritedLabel: String
    let onSave: (Auth) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var auth: Auth

    init(title: String, initial: Auth, inherited: Auth, inheritedLabel: String, onSave: @escaping (Auth) -> Void) {
        self.title = title
        self.initial = initial
        self.inherited = inherited
        self.inheritedLabel = inheritedLabel
        self.onSave = onSave
        _auth = State(initialValue: initial)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    onSave(auth)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            ScrollView {
                AuthEditorView(auth: $auth, inheritedAuth: inherited, inheritedLabel: inheritedLabel)
            }
        }
        .frame(width: 800, height: 500)
    }
}
