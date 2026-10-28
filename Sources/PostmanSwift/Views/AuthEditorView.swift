import SwiftUI

struct AuthEditorView: View {
    @Binding var auth: Auth
    let inheritedAuth: Auth?
    let inheritedLabel: String
    var variables: [VariableSuggestion] = []

    private let types: [(id: String, title: String)] = [
        ("inherit", "Inherit auth from parent"),
        ("noauth", "No Auth"),
        ("apikey", "API Key"),
        ("bearer", "Bearer Token"),
        ("basic", "Basic Auth"),
        ("oauth2", "OAuth 2.0"),
        ("oauth1", "OAuth 1.0"),
        ("awsv4", "AWS Signature"),
        ("digest", "Digest Auth"),
        ("ntlm", "NTLM Authentication"),
        ("hawk", "Hawk Authentication"),
        ("edgegrid", "Akamai EdgeGrid")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Text("Auth Type")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 150, alignment: .trailing)
                    .padding(.top, 5)
                Picker("", selection: typeBinding) {
                    ForEach(types, id: \.id) { type in
                        Text(type.title).tag(type.id)
                    }
                }
                .labelsHidden()
                .frame(width: 300)
                Spacer()
            }

            if auth.isInherit {
                infoBox(
                    title: "Inherited from \(inheritedLabel)",
                    message: "Parent auth type: \(inheritedAuth?.type ?? "none"). Change the parent to update this request."
                )
            } else if let type = auth.type {
                fields(for: type)
            }
            Spacer()
        }
        .padding(16)
        .onAppear { ensureRows(for: auth.type ?? "inherit") }
        .onChange(of: auth.type) { _, newValue in ensureRows(for: newValue ?? "inherit") }
    }

    private var typeBinding: Binding<String> {
        Binding(
            get: { auth.type ?? "inherit" },
            set: { newValue in
                auth.type = newValue
                ensureRows(for: newValue)
            }
        )
    }

    @ViewBuilder
    private func fields(for type: String) -> some View {
        switch type {
        case "noauth":
            infoBox(title: "No Auth", message: "This request is sent without an Authorization header.")

        case "basic":
            field("Username", key: "username")
            field("Password", key: "password", secure: true)
            infoBox(title: "Authorization header", message: "Basic auth sends base64(username:password) in the Authorization header.")

        case "bearer":
            field("Token", key: "token", secure: true)

        case "apikey":
            field("Key", key: "key")
            field("Value", key: "value", secure: true)
            picker("Add to", key: "in", options: [("header", "Header"), ("query", "Query Params")], defaultValue: "header")

        case "oauth2":
            field("Access Token", key: "accessToken", secure: true)
            field("Header Prefix", key: "headerPrefix", placeholder: "Bearer")
            picker("Add token to", key: "addTokenTo", options: [("header", "Request Header"), ("queryParams", "Query Params")], defaultValue: "header")
            infoBox(title: "Token source", message: "This build uses an existing access token. The cloud token-exchange flow needs an account and is intentionally omitted.")

        case "oauth1":
            field("Consumer Key", key: "consumerKey")
            field("Consumer Secret", key: "consumerSecret", secure: true)
            field("Token", key: "token")
            field("Token Secret", key: "tokenSecret", secure: true)
            picker("Signature Method", key: "signatureMethod", options: [("HMAC-SHA1", "HMAC-SHA1")], defaultValue: "HMAC-SHA1")
            picker("Add params to", key: "addParamsToHeader", options: [("true", "Header"), ("false", "Query Params")], defaultValue: "true")
            field("Realm", key: "realm")
            field("Version", key: "version", placeholder: "1.0")
            infoBox(title: "Signing", message: "OAuth 1.0a HMAC-SHA1 signatures are generated locally for each request.")

        case "awsv4":
            field("Access Key", key: "accessKey")
            field("Secret Key", key: "secretKey", secure: true)
            field("Region", key: "region", placeholder: "us-east-1")
            field("Service", key: "service", placeholder: "execute-api")
            field("Session Token", key: "sessionToken", secure: true)
            infoBox(title: "Signing", message: "AWS Signature Version 4 is computed locally, including x-amz-date and session tokens.")

        case "digest":
            warning("Digest authentication needs a 401 challenge handshake and is not implemented in this build. Basic, Bearer, API Key, OAuth 1.0, OAuth 2.0 and AWS v4 work.")

        case "ntlm", "hawk", "edgegrid":
            warning("\(types.first(where: { $0.id == type })?.title ?? type) is not implemented in this build. Use Basic, Bearer, API Key, OAuth or AWS Signature.")

        default:
            EmptyView()
        }
    }

    private func field(_ title: String, key: String, secure: Bool = false, placeholder: String = "") -> some View {
        HStack(alignment: .center, spacing: 14) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 150, alignment: .trailing)
            if secure {
                SecureField(placeholder, text: paramBinding(key))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 320)
            } else {
                VariableTextField(
                    text: paramBinding(key),
                    placeholder: placeholder,
                    fontSize: 12,
                    monospaced: true,
                    variables: variables
                )
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .frame(width: 320)
                .background(Theme.editor, in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Theme.border.opacity(0.8), lineWidth: 0.8)
                )
            }
            Spacer()
        }
    }

    private func picker(_ title: String, key: String, options: [(String, String)], defaultValue: String) -> some View {
        HStack(spacing: 14) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 150, alignment: .trailing)
            Picker("", selection: paramBinding(key, defaultValue: defaultValue)) {
                ForEach(options, id: \.0) { option in
                    Text(option.1).tag(option.0)
                }
            }
            .labelsHidden()
            .frame(width: 200)
            Spacer()
        }
    }

    private func paramBinding(_ key: String, defaultValue: String = "") -> Binding<String> {
        Binding(
            get: { auth.value(key) ?? defaultValue },
            set: { auth.setValue($0, for: key) }
        )
    }

    private func infoBox(title: String, message: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Color.clear.frame(width: 150)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
            }
            .padding(10)
            .frame(maxWidth: 520, alignment: .leading)
            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
            Spacer()
        }
    }

    private func warning(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Color.clear.frame(width: 150)
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.warning)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
            }
            .padding(10)
            .frame(maxWidth: 560, alignment: .leading)
            .background(Theme.warning.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            Spacer()
        }
    }

    private func ensureRows(for type: String) {
        guard type != "inherit", type != "noauth" else { return }
        auth.ensureRows(Self.defaultKeys[type] ?? [], method: type)
    }

    static let defaultKeys: [String: [String]] = [
        "basic": ["username", "password"],
        "bearer": ["token"],
        "apikey": ["key", "value", "in"],
        "oauth2": ["accessToken", "headerPrefix", "addTokenTo"],
        "oauth1": ["consumerKey", "consumerSecret", "token", "tokenSecret", "signatureMethod", "addParamsToHeader", "realm", "version"],
        "awsv4": ["accessKey", "secretKey", "region", "service", "sessionToken"],
        "digest": ["username", "password"],
        "ntlm": ["username", "password", "domain"],
        "hawk": ["authId", "authKey", "algorithm"],
        "edgegrid": ["accessToken", "clientToken", "clientSecret"]
    ]
}
