import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum FilePanels {
    @discardableResult
    static func save(data: Data, suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Copies an already-spilled response body without loading it back into memory.
    @discardableResult
    static func save(fileURL: URL, suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let destination = panel.url else { return nil }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: fileURL, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    static func open(types: [UTType] = [.json, .commaSeparatedText, .plainText], allowsMultiple: Bool = false) -> [URL] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = allowsMultiple
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return [] }
        return panel.urls
    }

    static func openFile(types: [UTType] = [.item]) -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}

struct VisualizerRenderer {
    static func html(template: String, dataJSON: String?) -> String {
        var html = template
        if let dataJSON, let data = dataJSON.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (key, value) in object {
                let replacement = String(describing: value)
                html = html.replacingOccurrences(of: "{{\(key)}}", with: replacement)
            }
            if !html.contains("<html") {
                html = "<html><body>\(html)</body></html>"
            }
            let script = "<script>window.pmData = \(dataJSON);</script>"
            if let range = html.range(of: "</body>", options: .backwards) {
                html.insert(contentsOf: script, at: range.lowerBound)
            } else {
                html += script
            }
        }
        if !html.localizedCaseInsensitiveContains("<html") {
            html = """
            <html><head><meta name="viewport" content="width=device-width, initial-scale=1">
            <style>body{font-family:-apple-system;margin:16px;color:#222}</style></head>
            <body>\(html)</body></html>
            """
        }
        return html
    }
}
