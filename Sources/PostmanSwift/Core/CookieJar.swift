import Foundation

struct StoredCookie: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var value: String
    var domain: String
    var path: String
    var secure: Bool
    var httpOnly: Bool
    var expires: Date?
    var created: Date = Date()

    var isExpired: Bool {
        if let expires { return expires < Date() }
        return false
    }

    var displayDomain: String {
        domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
    }
}

final class CookieJar: ObservableObject {
    @Published private(set) var cookies: [StoredCookie] = []

    func load(_ values: [StoredCookie]) {
        cookies = values.filter { !$0.isExpired }
    }

    func cookies(for url: URL) -> [StoredCookie] {
        guard let host = url.host?.lowercased() else { return [] }
        let requestPath = url.path.isEmpty ? "/" : url.path
        let isHTTPS = url.scheme?.lowercased() == "https"
        return cookies
            .filter { cookie in
                guard !cookie.isExpired else { return false }
                guard !cookie.secure || isHTTPS else { return false }
                let domain = cookie.domain.lowercased()
                let domainMatches = host == domain
                    || (domain.hasPrefix(".") && host.hasSuffix(domain))
                    || host.hasSuffix("." + domain)
                guard domainMatches else { return false }
                let path = cookie.path.isEmpty ? "/" : cookie.path
                return requestPath == path || requestPath.hasPrefix(path.hasSuffix("/") ? path : path + "/") || path == "/"
            }
            .sorted { $0.path.count > $1.path.count }
    }

    func headerValue(for url: URL) -> String? {
        let matched = cookies(for: url)
        guard !matched.isEmpty else { return nil }
        return matched.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    func ingest(response: HTTPURLResponse, url: URL) {
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            guard let key = pair.key as? String else { return }
            if let existing = result[key] {
                result[key] = existing + ", " + String(describing: pair.value)
            } else {
                result[key] = String(describing: pair.value)
            }
        }
        let setCookies = headers
            .filter { $0.key.lowercased() == "set-cookie" }
            .map(\.value)
        ingest(setCookieHeaders: setCookies, url: url)
    }

    func ingest(setCookieHeaders: [String], url: URL) {
        guard !setCookieHeaders.isEmpty else { return }
        for value in setCookieHeaders {
            let parsed = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": value], for: url)
            for cookie in parsed {
                let domain = cookie.domain.isEmpty ? (url.host ?? "") : cookie.domain
                let stored = StoredCookie(
                    name: cookie.name,
                    value: cookie.value,
                    domain: domain,
                    path: cookie.path.isEmpty ? "/" : cookie.path,
                    secure: cookie.isSecure,
                    httpOnly: cookie.isHTTPOnly,
                    expires: cookie.expiresDate
                )
                upsert(stored)
            }
        }
    }

    func upsert(_ cookie: StoredCookie) {
        if let index = cookies.firstIndex(where: {
            $0.name == cookie.name && $0.domain.lowercased() == cookie.domain.lowercased() && $0.path == cookie.path
        }) {
            cookies[index] = cookie
        } else {
            cookies.append(cookie)
        }
        cookies.removeAll(where: \.isExpired)
    }

    func delete(_ cookie: StoredCookie) {
        cookies.removeAll { $0.id == cookie.id }
    }

    func clear() {
        cookies.removeAll()
    }

    func clear(domain: String) {
        cookies.removeAll { $0.domain.lowercased() == domain.lowercased() }
    }
}
