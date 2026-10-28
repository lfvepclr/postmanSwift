import Foundation
import CryptoKit

enum CryptoHelpers {
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func hmacSHA256(key: Data, data: Data) -> Data {
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key))
        return Data(mac)
    }

    static func hmacSHA1(key: Data, data: Data) -> Data {
        let mac = HMAC<Insecure.SHA1>.authenticationCode(for: data, using: SymmetricKey(data: key))
        return Data(mac)
    }

    static func base64(_ data: Data) -> String { data.base64EncodedString() }

    static func randomHex(count: Int) -> String {
        (0..<count).map { _ in String(format: "%x", Int.random(in: 0...15)) }.joined()
    }

    /// RFC 3986 encoding used by OAuth 1.0.
    static func rfc3986(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

struct AuthApplication {
    var headers: [KeyValue] = []
    var queryItems: [KeyValue] = []
    var url: URL
}

enum AuthError: LocalizedError {
    case unsupported(String)
    case missing(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let type):
            return "Auth type “\(type)” needs a challenge handshake that this build does not implement yet."
        case .missing(let field):
            return "Missing auth parameter: \(field)"
        }
    }
}

enum AuthBuilder {
    static func apply(
        auth: Auth?,
        method: String,
        url: URL,
        body: Data?,
        contentType: String?,
        context: VariableContext
    ) throws -> AuthApplication {
        guard let auth, let type = auth.type?.lowercased(), type != "noauth", type != "inherit" else {
            return AuthApplication(url: url)
        }

        func parameter(_ key: String) -> String {
            context.resolve(auth.value(key) ?? "")
        }

        switch type {
        case "basic":
            let username = parameter("username")
            let password = parameter("password")
            let token = Data("\(username):\(password)".utf8).base64EncodedString()
            return AuthApplication(headers: [KeyValue(key: "Authorization", value: "Basic \(token)")], url: url)

        case "bearer":
            let token = parameter("token")
            guard !token.isEmpty else { throw AuthError.missing("token") }
            return AuthApplication(headers: [KeyValue(key: "Authorization", value: "Bearer \(token)")], url: url)

        case "apikey":
            let key = parameter("key")
            let value = parameter("value")
            guard !key.isEmpty else { throw AuthError.missing("key") }
            let location = (parameter("in")).lowercased()
            if location == "query" {
                return AuthApplication(queryItems: [KeyValue(key: key, value: value)], url: url)
            }
            return AuthApplication(headers: [KeyValue(key: key, value: value)], url: url)

        case "oauth2":
            let token = parameter("accessToken")
            guard !token.isEmpty else { throw AuthError.missing("accessToken") }
            let location = parameter("addTokenTo").isEmpty ? "header" : parameter("addTokenTo").lowercased()
            let prefix = parameter("headerPrefix").isEmpty ? "Bearer" : parameter("headerPrefix")
            if location == "queryparams" || location == "query" {
                let key = parameter("headerPrefix").isEmpty ? "access_token" : parameter("headerPrefix")
                return AuthApplication(queryItems: [KeyValue(key: key, value: token)], url: url)
            }
            return AuthApplication(headers: [KeyValue(key: "Authorization", value: "\(prefix) \(token)")], url: url)

        case "oauth1":
            return try oauth1(auth: auth, method: method, url: url, body: body, contentType: contentType, resolve: parameter)

        case "awsv4":
            return try awsV4(auth: auth, method: method, url: url, body: body, resolve: parameter)

        case "digest", "ntlm", "hawk", "edgegrid":
            throw AuthError.unsupported(type)

        default:
            throw AuthError.unsupported(type)
        }
    }

    // MARK: - OAuth 1.0a

    private static func oauth1(
        auth: Auth,
        method: String,
        url: URL,
        body: Data?,
        contentType: String?,
        resolve: (String) -> String
    ) throws -> AuthApplication {
        let signatureMethod = resolve("signatureMethod").isEmpty ? "HMAC-SHA1" : resolve("signatureMethod").uppercased()
        guard signatureMethod == "HMAC-SHA1" else {
            throw AuthError.unsupported("oauth1-\(signatureMethod)")
        }
        let consumerKey = resolve("consumerKey")
        let consumerSecret = resolve("consumerSecret")
        guard !consumerKey.isEmpty else { throw AuthError.missing("consumerKey") }
        let token = resolve("token")
        let tokenSecret = resolve("tokenSecret")
        let nonce = resolve("nonce").isEmpty ? UUID().uuidString.replacingOccurrences(of: "-", with: "") : resolve("nonce")
        let timestamp = resolve("timestamp").isEmpty ? String(Int(Date().timeIntervalSince1970)) : resolve("timestamp")
        let version = resolve("version")
        let realm = resolve("realm")

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let existingQuery = components?.queryItems ?? []
        components?.query = nil
        guard let baseURL = components?.url else { return AuthApplication(url: url) }

        var oauthParams: [(String, String)] = [
            ("oauth_consumer_key", consumerKey),
            ("oauth_nonce", nonce),
            ("oauth_signature_method", signatureMethod),
            ("oauth_timestamp", timestamp)
        ]
        if !token.isEmpty { oauthParams.append(("oauth_token", token)) }
        if !version.isEmpty { oauthParams.append(("oauth_version", version)) }

        var signatureParams = existingQuery.map { ($0.name, $0.value ?? "") }
        signatureParams.append(contentsOf: oauthParams)
        if let body, contentType?.lowercased().contains("x-www-form-urlencoded") == true,
           let bodyText = String(data: body, encoding: .utf8) {
            for pair in bodyText.split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2 {
                    signatureParams.append((parts[0].removingPercentEncoding ?? parts[0],
                                           parts[1].removingPercentEncoding ?? parts[1]))
                }
            }
        }

        let encodedParams: [(String, String)] = signatureParams.map { pair in
            (CryptoHelpers.rfc3986(pair.0), CryptoHelpers.rfc3986(pair.1))
        }
        let sortedParams: [(String, String)] = encodedParams.sorted { left, right in
            if left.0 == right.0 { return left.1 < right.1 }
            return left.0 < right.0
        }
        let normalized: String = sortedParams.map { pair -> String in
            "\(pair.0)=\(pair.1)"
        }.joined(separator: "&")

        let baseString = "\(method.uppercased())&\(CryptoHelpers.rfc3986(baseURL.absoluteString))&\(CryptoHelpers.rfc3986(normalized))"
        let signingKey = "\(CryptoHelpers.rfc3986(consumerSecret))&\(CryptoHelpers.rfc3986(tokenSecret))"
        let signature = CryptoHelpers.base64(CryptoHelpers.hmacSHA1(key: Data(signingKey.utf8), data: Data(baseString.utf8)))
        oauthParams.append(("oauth_signature", signature))

        let addToHeader = resolve("addParamsToHeader").lowercased() != "false"
        if addToHeader {
            let header = oauthParams
                .map { "\(CryptoHelpers.rfc3986($0.0))=\"\(CryptoHelpers.rfc3986($0.1))\"" }
                .joined(separator: ",")
            let value = (realm.isEmpty ? "" : "realm=\"\(realm)\",") + header
            return AuthApplication(headers: [KeyValue(key: "Authorization", value: "OAuth " + value)], url: url)
        }

        var items = existingQuery
        items.append(contentsOf: oauthParams.map { URLQueryItem(name: $0.0, value: $0.1) })
        var final = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        final?.queryItems = items
        return AuthApplication(url: final?.url ?? url)
    }

    // MARK: - AWS Signature V4

    private static func awsV4(
        auth: Auth,
        method: String,
        url: URL,
        body: Data?,
        resolve: (String) -> String
    ) throws -> AuthApplication {
        let accessKey = resolve("accessKey")
        let secretKey = resolve("secretKey")
        let region = resolve("region").isEmpty ? "us-east-1" : resolve("region")
        let service = resolve("service").isEmpty ? "execute-api" : resolve("service")
        let sessionToken = resolve("sessionToken")
        guard !accessKey.isEmpty, !secretKey.isEmpty else { throw AuthError.missing("accessKey/secretKey") }

        let now = Date()
        let amzDateFormatter = DateFormatter()
        amzDateFormatter.locale = Locale(identifier: "en_US_POSIX")
        amzDateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        amzDateFormatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let amzDate = amzDateFormatter.string(from: now)
        amzDateFormatter.dateFormat = "yyyyMMdd"
        let dateStamp = amzDateFormatter.string(from: now)

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return AuthApplication(url: url)
        }
        let host = (components.host ?? "") + (components.port.map { ":" + String($0) } ?? "")
        var path = components.percentEncodedPath
        if path.isEmpty { path = "/" }
        let queryItems = (components.queryItems ?? [])
            .sorted { $0.name == $1.name ? ($0.value ?? "") < ($1.value ?? "") : $0.name < $1.name }
        let canonicalQuery = queryItems.map {
            "\(CryptoHelpers.rfc3986($0.name))=\(CryptoHelpers.rfc3986($0.value ?? ""))"
        }.joined(separator: "&")

        let payloadHash = CryptoHelpers.sha256Hex(body ?? Data())
        var canonicalHeaders = "host:\(host)\nx-amz-date:\(amzDate)\n"
        var signedHeaders = "host;x-amz-date"
        if !sessionToken.isEmpty {
            canonicalHeaders += "x-amz-security-token:\(sessionToken)\n"
            signedHeaders += ";x-amz-security-token"
        }
        let canonicalRequest = [
            method.uppercased(), path, canonicalQuery, canonicalHeaders, signedHeaders, payloadHash
        ].joined(separator: "\n")

        let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let stringToSign = ["AWS4-HMAC-SHA256", amzDate, scope, CryptoHelpers.sha256Hex(Data(canonicalRequest.utf8))].joined(separator: "\n")
        let kDate = CryptoHelpers.hmacSHA256(key: Data(("AWS4" + secretKey).utf8), data: Data(dateStamp.utf8))
        let kRegion = CryptoHelpers.hmacSHA256(key: kDate, data: Data(region.utf8))
        let kService = CryptoHelpers.hmacSHA256(key: kRegion, data: Data(service.utf8))
        let kSigning = CryptoHelpers.hmacSHA256(key: kService, data: Data("aws4_request".utf8))
        let signature = CryptoHelpers.hmacSHA256(key: kSigning, data: Data(stringToSign.utf8))
            .map { String(format: "%02x", $0) }.joined()

        let authorization = "AWS4-HMAC-SHA256 Credential=\(accessKey)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
        var headers = [
            KeyValue(key: "Authorization", value: authorization),
            KeyValue(key: "X-Amz-Date", value: amzDate)
        ]
        if !sessionToken.isEmpty {
            headers.append(KeyValue(key: "X-Amz-Security-Token", value: sessionToken))
        }
        return AuthApplication(headers: headers, url: url)
    }
}
