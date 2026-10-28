import AppKit
import Foundation

enum AppInfo {
    /// Used when the binary runs outside an .app bundle (`swift run`), where Info.plist is absent.
    static let fallbackVersion = "1.1.0"

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? fallbackVersion
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev"
    }

    static var displayVersion: String { "\(version) (\(build))" }

    static func showAboutPanel() {
        let credits = NSAttributedString(
            string: "A local-first, native Swift API client.\nNo account, sync, telemetry or cloud features.",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "PostmanSwift",
            .applicationVersion: version,
            .version: build,
            .credits: credits
        ])
    }
}
