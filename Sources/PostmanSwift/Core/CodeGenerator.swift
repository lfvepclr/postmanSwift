import Foundation

enum CodeLanguage: String, CaseIterable, Identifiable {
    case curl, swift, python, javascript, go, java, csharp, php, ruby, kotlin, rust, powershell, http

    var id: String { rawValue }

    var title: String {
        switch self {
        case .curl: return "cURL"
        case .swift: return "Swift (URLSession)"
        case .python: return "Python (requests)"
        case .javascript: return "JavaScript (fetch)"
        case .go: return "Go (net/http)"
        case .java: return "Java (OkHttp)"
        case .csharp: return "C# (RestSharp)"
        case .php: return "PHP (cURL)"
        case .ruby: return "Ruby (Net::HTTP)"
        case .kotlin: return "Kotlin (OkHttp)"
        case .rust: return "Rust (reqwest)"
        case .powershell: return "PowerShell"
        case .http: return "HTTP"
        }
    }
}

enum CodeGenerator {
    static func generate(_ request: PreparedRequest, language: CodeLanguage) -> String {
        switch language {
        case .curl: return curl(request)
        case .swift: return swift(request)
        case .python: return python(request)
        case .javascript: return javascript(request)
        case .go: return go(request)
        case .java: return java(request)
        case .csharp: return csharp(request)
        case .php: return php(request)
        case .ruby: return ruby(request)
        case .kotlin: return kotlin(request)
        case .rust: return rust(request)
        case .powershell: return powershell(request)
        case .http: return http(request)
        }
    }

    private static func bodyText(_ request: PreparedRequest) -> String? {
        guard let body = request.body, !body.isEmpty else { return nil }
        return String(data: body, encoding: .utf8)
    }

    private static func shellEscaped(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func curl(_ request: PreparedRequest) -> String {
        var lines = ["curl --request \(request.method) \\", "  --url \(shellEscaped(request.url.absoluteString)) \\"]
        for header in request.headers where header.isEnabled && !header.key.isEmpty {
            lines.append("  --header \(shellEscaped("\(header.key): \(header.value)")) \\")
        }
        if let body = bodyText(request) {
            lines.append("  --data-raw \(shellEscaped(body)) \\")
        }
        if let last = lines.last, last.hasSuffix(" \\") {
            lines[lines.count - 1] = String(last.dropLast(2))
        }
        return lines.joined(separator: "\n")
    }

    private static func swift(_ request: PreparedRequest) -> String {
        var lines: [String] = []
        lines.append("import Foundation")
        lines.append("")
        lines.append("var request = URLRequest(url: URL(string: \"\(escape(request.url.absoluteString))\")!)")
        lines.append("request.httpMethod = \"\(request.method)\"")
        for header in request.headers where header.isEnabled && !header.key.isEmpty {
            lines.append("request.setValue(\"\(escape(header.value))\", forHTTPHeaderField: \"\(escape(header.key))\")")
        }
        if let body = bodyText(request) {
            lines.append("request.httpBody = \"\"\"")
            lines.append(body.replacingOccurrences(of: "\"\"\"", with: "\\\"\\\"\\\""))
            lines.append("\"\"\".data(using: .utf8)")
        }
        lines.append("")
        lines.append("let (data, response) = try await URLSession.shared.data(for: request)")
        lines.append("print(String(data: data, encoding: .utf8) ?? \"\")")
        return lines.joined(separator: "\n")
    }

    private static func python(_ request: PreparedRequest) -> String {
        var lines = ["import requests", ""]
        let url = request.url.absoluteString
        lines.append("url = \"\(escape(url))\"")
        if !request.headers.isEmpty {
            lines.append("headers = {")
            for header in request.headers where header.isEnabled && !header.key.isEmpty {
                lines.append("    \"\(escape(header.key))\": \"\(escape(header.value))\",")
            }
            lines.append("}")
        }
        if let body = bodyText(request) {
            lines.append("payload = \"\"\"\(body.replacingOccurrences(of: "\"\"\"", with: "\\\"\\\"\\\""))\"\"\"")
        }
        let args = [
            "\"\(request.method)\"",
            "url",
            request.headers.isEmpty ? nil : "headers=headers",
            bodyText(request) == nil ? nil : "data=payload"
        ].compactMap { $0 }
        lines.append("response = requests.request(\(args.joined(separator: ", ")))")
        lines.append("print(response.text)")
        return lines.joined(separator: "\n")
    }

    private static func javascript(_ request: PreparedRequest) -> String {
        var lines = ["const options = {", "  method: \"\(request.method)\","]
        if !request.headers.isEmpty {
            lines.append("  headers: {")
            for header in request.headers where header.isEnabled && !header.key.isEmpty {
                lines.append("    \"\(escape(header.key))\": \"\(escape(header.value))\",")
            }
            lines.append("  },")
        }
        if let body = bodyText(request) {
            lines.append("  body: `\(body.replacingOccurrences(of: "`", with: "\\`").replacingOccurrences(of: "${", with: "\\${"))}`,")
        }
        lines.append("};")
        lines.append("")
        lines.append("const response = await fetch(\"\(escape(request.url.absoluteString))\", options);")
        lines.append("console.log(await response.text());")
        return lines.joined(separator: "\n")
    }

    private static func go(_ request: PreparedRequest) -> String {
        var lines = ["package main", "", "import (", "    \"fmt\"", "    \"io\"", "    \"net/http\"", "    \"strings\"", ")", ""]
        lines.append("func main() {")
        if let body = bodyText(request) {
            lines.append("    body := strings.NewReader(\(goQuote(body)))")
        } else {
            lines.append("    var body io.Reader")
        }
        lines.append("    req, err := http.NewRequest(\"\(request.method)\", \"\(escape(request.url.absoluteString))\", body)")
        lines.append("    if err != nil { panic(err) }")
        for header in request.headers where header.isEnabled && !header.key.isEmpty {
            lines.append("    req.Header.Set(\"\(escape(header.key))\", \"\(escape(header.value))\")")
        }
        lines.append("    resp, err := http.DefaultClient.Do(req)")
        lines.append("    if err != nil { panic(err) }")
        lines.append("    defer resp.Body.Close()")
        lines.append("    data, _ := io.ReadAll(resp.Body)")
        lines.append("    fmt.Println(string(data))")
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    private static func java(_ request: PreparedRequest) -> String {
        var lines = [
            "import okhttp3.*;", "import java.io.IOException;", "",
            "public class Main {",
            "  public static void main(String[] args) throws IOException {",
            "    OkHttpClient client = new OkHttpClient();"
        ]
        if let body = bodyText(request) {
            lines.append("    RequestBody body = RequestBody.create(\(javaQuote(body)), MediaType.parse(\"text/plain\"));")
        } else {
            lines.append("    RequestBody body = null;")
        }
        lines.append("    Request request = new Request.Builder()")
        lines.append("        .url(\"\(escape(request.url.absoluteString))\")")
        for header in request.headers where header.isEnabled && !header.key.isEmpty {
            lines.append("        .addHeader(\"\(escape(header.key))\", \"\(escape(header.value))\")")
        }
        lines.append("        .method(\"\(request.method)\", body)")
        lines.append("        .build();")
        lines.append("    try (Response response = client.newCall(request).execute()) {")
        lines.append("      System.out.println(response.body().string());")
        lines.append("    }")
        lines.append("  }")
        lines.append("}")
        return lines.joined(separator: "\n")
    }


    private static func csharp(_ request: PreparedRequest) -> String {
        var lines = [
            "using RestSharp;", "",
            "var client = new RestClient(\"\(escape(request.url.absoluteString))\");",
            "var request = new RestRequest(\"\(escape(request.method))\");"
        ]
        for header in request.headers where header.isEnabled && !header.key.isEmpty {
            lines.append("request.AddHeader(\"\(escape(header.key))\", \"\(escape(header.value))\");")
        }
        if let body = bodyText(request) {
            lines.append("request.AddParameter(\"text/plain\", \(csharpQuote(body)), ParameterType.RequestBody);")
        }
        lines += [
            "",
            "var response = await client.ExecuteAsync(request);",
            "Console.WriteLine(response.Content);"
        ]
        return lines.joined(separator: "\n")
    }

    private static func php(_ request: PreparedRequest) -> String {
        var lines = ["<?php", "$ch = curl_init();", "curl_setopt_array($ch, ["]
        lines.append("    CURLOPT_URL => \(phpQuote(request.url.absoluteString)),")
        lines.append("    CURLOPT_RETURNTRANSFER => true,")
        lines.append("    CURLOPT_CUSTOMREQUEST => \"\(request.method)\"," )
        let headers = request.headers.filter { $0.isEnabled && !$0.key.isEmpty }
        if !headers.isEmpty {
            lines.append("    CURLOPT_HTTPHEADER => [")
            for header in headers {
                lines.append("        \(phpQuote("\(header.key): \(header.value)")),")
            }
            lines.append("    ],")
        }
        if let body = bodyText(request) {
            lines.append("    CURLOPT_POSTFIELDS => \(phpQuote(body)),")
        }
        lines += [
            "]);",
            "$response = curl_exec($ch);",
            "curl_close($ch);",
            "echo $response;"
        ]
        return lines.joined(separator: "\n")
    }

    private static func ruby(_ request: PreparedRequest) -> String {
        let methodClass: String
        switch request.method.uppercased() {
        case "GET": methodClass = "Get"
        case "POST": methodClass = "Post"
        case "PUT": methodClass = "Put"
        case "PATCH": methodClass = "Patch"
        case "DELETE": methodClass = "Delete"
        case "HEAD": methodClass = "Head"
        default: methodClass = "Get"
        }
        var lines = [
            "require 'net/http'",
            "uri = URI(\(rubyQuote(request.url.absoluteString)))",
            "req = Net::HTTP::\(methodClass).new(uri)"
        ]
        for header in request.headers where header.isEnabled && !header.key.isEmpty {
            lines.append("req[\(rubyQuote(header.key))] = \(rubyQuote(header.value))")
        }
        if let body = bodyText(request) {
            lines.append("req.body = \(rubyQuote(body))")
        }
        lines += [
            "res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https') { |http| http.request(req) }",
            "puts res.body"
        ]
        return lines.joined(separator: "\n")
    }

    private static func kotlin(_ request: PreparedRequest) -> String {
        var lines = [
            "import okhttp3.*", "import java.io.IOException", "",
            "val client = OkHttpClient()"
        ]
        if let body = bodyText(request) {
            lines.append("val body = \(javaQuote(body)).toRequestBody(\"text/plain\".toMediaType())")
        } else {
            lines.append("val body: RequestBody? = null")
        }
        lines.append("val request = Request.Builder()")
        lines.append("    .url(\(javaQuote(request.url.absoluteString)))")
        for header in request.headers where header.isEnabled && !header.key.isEmpty {
            lines.append("    .addHeader(\(javaQuote(header.key)), \(javaQuote(header.value)))")
        }
        lines.append("    .method(\"\(request.method)\"," )
        lines.append("    .build()")
        lines.append("client.newCall(request).execute().use { response ->")
        lines.append("    println(response.body?.string())")
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    private static func rust(_ request: PreparedRequest) -> String {
        var lines = [
            "#[tokio::main]",
            "async fn main() -> Result<(), Box<dyn std::error::Error>> {",
            "    let client = reqwest::Client::new();",
            "    let response = client"
        ]
        let method = request.method.uppercased()
        lines.append("        .request(reqwest::Method::\(method.prefix(1) + method.dropFirst().lowercased()), \(rustQuote(request.url.absoluteString)))")
        for header in request.headers where header.isEnabled && !header.key.isEmpty {
            lines.append("        .header(\(rustQuote(header.key)), \(rustQuote(header.value)))")
        }
        if let body = bodyText(request) {
            lines.append("        .body(\(rustQuote(body)))")
        }
        lines += [
            "        .send()",
            "        .await?;",
            "    println!(\"{}\", response.text().await?);",
            "    Ok(())",
            "}"
        ]
        return lines.joined(separator: "\n")
    }

    private static func powershell(_ request: PreparedRequest) -> String {
        var lines = ["$headers = @{"]
        for header in request.headers where header.isEnabled && !header.key.isEmpty {
            lines.append("    \(psQuote(header.key)) = \(psQuote(header.value))")
        }
        lines.append("}")
        var command = "Invoke-RestMethod -Uri \(psQuote(request.url.absoluteString)) -Method \(request.method.capitalized) -Headers $headers"
        if let body = bodyText(request) {
            command += " -Body \(psQuote(body))"
        }
        lines.append("$response = \(command)")
        lines.append("$response | ConvertTo-Json -Depth 10")
        return lines.joined(separator: "\n")
    }

    private static func csharpQuote(_ value: String) -> String {
        "\"" + escape(value).replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    private static func phpQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
    }

    private static func rubyQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
    }

    private static func rustQuote(_ value: String) -> String {
        "\"" + escape(value) + "\""
    }

    private static func psQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    private static func http(_ request: PreparedRequest) -> String {
        let components = URLComponents(url: request.url, resolvingAgainstBaseURL: false)
        let path = (components?.percentEncodedPath.isEmpty == false ? components?.percentEncodedPath : "/") ?? "/"
        let query = components?.percentEncodedQuery.map { "?" + $0 } ?? ""
        let host = components?.host ?? request.url.host ?? ""
        let port = components?.port.map { ":\($0)" } ?? ""
        var lines = ["\(request.method) \(path)\(query) HTTP/1.1", "Host: \(host)\(port)"]
        for header in request.headers where header.isEnabled && !header.key.isEmpty {
            lines.append("\(header.key): \(header.value)")
        }
        if let body = request.body, !body.isEmpty {
            lines.append("Content-Length: \(body.count)")
            lines.append("")
            lines.append(bodyText(request) ?? "<binary body: \(body.count) bytes>")
        } else {
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    private static func goQuote(_ value: String) -> String {
        "\"" + escape(value) + "\""
    }

    private static func javaQuote(_ value: String) -> String {
        "\"" + escape(value) + "\""
    }
}
