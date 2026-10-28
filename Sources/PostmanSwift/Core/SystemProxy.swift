import Foundation
import SystemConfiguration

enum SystemProxy {
    /// Reads the macOS system HTTP proxy. PAC/auto-configuration is not evaluated.
    static func httpProxy() -> (host: String, port: UInt16)? {
        guard let raw = SCDynamicStoreCopyProxies(nil) else { return nil }
        let proxies = raw as NSDictionary
        let enabled = boolValue(proxies[kSCPropNetProxiesHTTPEnable as String])
        guard enabled else { return nil }
        guard let host = proxies[kSCPropNetProxiesHTTPProxy as String] as? String, !host.isEmpty else {
            return nil
        }
        let portValue = intValue(proxies[kSCPropNetProxiesHTTPPort as String])
        let port = UInt16(portValue > 0 ? portValue : 8080)
        return (host, port)
    }

    private static func boolValue(_ value: Any?) -> Bool {
        if let number = value as? NSNumber { return number.boolValue }
        if let bool = value as? Bool { return bool }
        return false
    }

    private static func intValue(_ value: Any?) -> Int {
        if let number = value as? NSNumber { return number.intValue }
        if let int = value as? Int { return int }
        return 0
    }
}
