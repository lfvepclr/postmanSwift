import Foundation
import JavaScriptCore
import CryptoKit

enum ScriptPhase: String {
    case preRequest = "prerequest"
    case test = "test"
}

struct VariableMutation: Hashable {
    enum Scope: String {
        case environment, globals, collectionVariables, variables, iterationData
    }

    var scope: Scope
    var key: String
    var value: String?
    var clearAll: Bool = false
}

struct RequestMutation {
    var method: String?
    var url: String?
    var headers: [KeyValue]?
}

struct ScriptInfo {
    var requestName: String
    var requestID: String
    var iteration: Int = 0
    var iterationCount: Int = 1
    var eventName: String
}

struct ScriptOutcome {
    var console: [ConsoleEntry] = []
    var tests: [TestResult] = []
    var mutations: [VariableMutation] = []
    var requestMutation: RequestMutation?
    var visualizerTemplate: String?
    var visualizerData: String?
    var nextRequest: String?
    var error: String?
}

private final class ScriptBridge {
    var outcome = ScriptOutcome()
    var context: VariableContext
    var settings: AppSettings
    var cookieJar: CookieJar?
    var request: PreparedRequest
    var response: HTTPResult?

    init(context: VariableContext, settings: AppSettings, cookieJar: CookieJar?, request: PreparedRequest, response: HTTPResult?) {
        self.context = context
        self.settings = settings
        self.cookieJar = cookieJar
        self.request = request
        self.response = response
    }

    func lookup(_ key: String) -> String? {
        context.value(for: key)
    }

    func setVariable(scope: String, key: String, value: String) {
        guard let parsed = VariableMutation.Scope(rawValue: scope) else { return }
        switch parsed {
        case .environment: context.environment[key] = value
        case .globals: context.globals[key] = value
        case .collectionVariables: context.collection[key] = value
        case .variables: context.local[key] = value
        case .iterationData: context.data[key] = value
        }
        outcome.mutations.append(VariableMutation(scope: parsed, key: key, value: value))
    }

    func unsetVariable(scope: String, key: String) {
        guard let parsed = VariableMutation.Scope(rawValue: scope) else { return }
        switch parsed {
        case .environment: context.environment.removeValue(forKey: key)
        case .globals: context.globals.removeValue(forKey: key)
        case .collectionVariables: context.collection.removeValue(forKey: key)
        case .variables: context.local.removeValue(forKey: key)
        case .iterationData: context.data.removeValue(forKey: key)
        }
        outcome.mutations.append(VariableMutation(scope: parsed, key: key, value: nil))
    }

    func clear(scope: String) {
        guard let parsed = VariableMutation.Scope(rawValue: scope) else { return }
        switch parsed {
        case .environment: context.environment.removeAll()
        case .globals: context.globals.removeAll()
        case .collectionVariables: context.collection.removeAll()
        case .variables: context.local.removeAll()
        case .iterationData: context.data.removeAll()
        }
        outcome.mutations.append(VariableMutation(scope: parsed, key: "", value: nil, clearAll: true))
    }

    func send(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return errorJSON("Invalid request object for pm.sendRequest")
        }
        do {
            let prepared = try buildRequest(object)
            let result = try perform(prepared)
            return responseJSON(result) ?? "{}"
        } catch {
            return errorJSON(error.localizedDescription)
        }
    }

    private func buildRequest(_ object: [String: Any]) throws -> PreparedRequest {
        let method = (object["method"] as? String) ?? "GET"
        var url = ""
        if let string = object["url"] as? String {
            url = string
        } else if let urlObject = object["url"] as? [String: Any] {
            url = (urlObject["raw"] as? String) ?? ""
            if url.isEmpty, let host = urlObject["host"] as? [String] {
                url = (urlObject["protocol"] as? String ?? "http") + "://" + host.joined(separator: ".")
                if let path = urlObject["path"] as? [String] {
                    url += "/" + path.joined(separator: "/")
                }
            }
        }
        url = context.resolve(url)
        guard !url.isEmpty else { throw RequestBuildError.emptyURL }

        var headers: [KeyValue] = []
        if let headerArray = object["header"] as? [[String: Any]] {
            headers = headerArray.compactMap { row in
                guard let key = row["key"] as? String else { return nil }
                return KeyValue(key: context.resolve(key), value: context.resolve((row["value"] as? String) ?? ""), disabled: row["disabled"] as? Bool ?? false)
            }
        } else if let headerObject = object["header"] as? [String: Any] {
            headers = headerObject.map { KeyValue(key: context.resolve($0.key), value: context.resolve(String(describing: $0.value))) }
        }

        var bodyData: Data?
        var contentType: String?
        if let body = object["body"] as? [String: Any] {
            if let raw = body["raw"] as? String {
                bodyData = context.resolve(raw).data(using: .utf8)
                if let options = body["options"] as? [String: Any],
                   let rawOptions = options["raw"] as? [String: Any],
                   let language = rawOptions["language"] as? String {
                    contentType = RawLanguage(rawValue: language)?.contentType
                }
            } else if let mode = body["mode"] as? String, mode == "urlencoded",
                      let rows = body["urlencoded"] as? [[String: Any]] {
                let pairs = rows.compactMap { row -> String? in
                    guard let key = row["key"] as? String else { return nil }
                    if row["disabled"] as? Bool == true { return nil }
                    return "\(URLUtilities.encodeQueryComponent(context.resolve(key)))=\(URLUtilities.encodeQueryComponent(context.resolve((row["value"] as? String) ?? "")))"
                }
                bodyData = pairs.joined(separator: "&").data(using: .utf8)
                contentType = "application/x-www-form-urlencoded"
            }
        }
        if let contentType, !headers.contains(where: { $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame }) {
            headers.append(KeyValue(key: "Content-Type", value: contentType))
        }
        let normalizedURL = URLUtilities.normalize(url)
        guard let urlValue = URL(string: normalizedURL) else { throw RequestBuildError.invalidURL(url) }
        if let jar = cookieJar, settings.sendCookies, let cookie = jar.headerValue(for: urlValue),
           !headers.contains(where: { $0.key.caseInsensitiveCompare("Cookie") == .orderedSame }) {
            headers.append(KeyValue(key: "Cookie", value: cookie))
        }
        return PreparedRequest(method: method, url: urlValue, headers: headers, body: bodyData)
    }

    private func perform(_ prepared: PreparedRequest) throws -> HTTPResult {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<HTTPResult, Error> = .failure(URLError(.unknown))
        let client = HTTPClient(settings: settings, cookieJar: cookieJar)
        Task {
            do {
                result = .success(try await client.send(prepared))
            } catch {
                result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        switch result {
        case .success(let response): return response
        case .failure(let error): throw error
        }
    }

    private func responseJSON(_ result: HTTPResult) -> String? {
        let payload: [String: Any] = [
            "code": result.statusCode,
            "status": result.statusText,
            "responseTime": result.duration * 1000,
            "responseSize": result.size,
            "headers": result.headers.map { ["key": $0.key, "value": $0.value] },
            "text": result.text ?? "",
            "cookies": []
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func errorJSON(_ message: String) -> String {
        let payload: [String: Any] = ["error": message]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return "{\"error\":\"unknown\"}" }
        return String(data: data, encoding: .utf8) ?? "{\"error\":\"unknown\"}"
    }
}

final class ScriptRunner {
    private let settings: AppSettings
    private let cookieJar: CookieJar?

    private static let virtualMachineKey = "com.postmanswift.script.virtual-machine"

    /// Each run still gets a fresh `JSContext` (the prelude and user scripts declare top-level
    /// globals, so reusing a context would leak between requests). Reusing the `JSVirtualMachine`
    /// on the same thread avoids rebuilding the runtime for every pre-request/test script.
    private static func makeContext() -> JSContext? {
        let thread = Thread.current
        let machine: JSVirtualMachine
        if let existing = thread.threadDictionary[virtualMachineKey] as? JSVirtualMachine {
            machine = existing
        } else {
            machine = JSVirtualMachine()
            thread.threadDictionary[virtualMachineKey] = machine
        }
        return JSContext(virtualMachine: machine)
    }

    init(settings: AppSettings, cookieJar: CookieJar?) {
        self.settings = settings
        self.cookieJar = cookieJar
    }

    func run(
        source: String,
        phase: ScriptPhase,
        context: VariableContext,
        request: PreparedRequest,
        response: HTTPResult?,
        info: ScriptInfo
    ) -> ScriptOutcome {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ScriptOutcome() }

        let bridge = ScriptBridge(context: context, settings: settings, cookieJar: cookieJar, request: request, response: response)
        guard let jsContext = Self.makeContext() else {
            var outcome = ScriptOutcome()
            outcome.error = "Unable to create JavaScript context."
            return outcome
        }

        jsContext.exceptionHandler = { _, exception in
            let message = exception?.toString() ?? "Unknown JavaScript error"
            bridge.outcome.error = message
            bridge.outcome.console.append(ConsoleEntry(kind: .error, title: "Script error", detail: message))
        }

        installBridges(in: jsContext, bridge: bridge, phase: phase, info: info, context: context)

        let requestObject: [String: Any] = [
            "method": request.method,
            "url": request.url.absoluteString,
            "headers": request.headers.filter(\.isEnabled).map { ["key": $0.key, "value": $0.value] },
            "body": request.body.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        ]
        let responseObject: [String: Any]? = response.map { result in
            [
                "code": result.statusCode,
                "status": result.statusText,
                "responseTime": result.duration * 1000,
                "responseSize": result.size,
                "headers": result.headers.map { ["key": $0.key, "value": $0.value] },
                "body": result.text ?? "",
                "mimeType": result.mimeType ?? ""
            ]
        }
        let variablesObject: [String: Any] = [
            "globals": context.globals,
            "environment": context.environment,
            "collectionVariables": context.collection,
            "variables": context.local,
            "iterationData": context.data
        ]
        let infoObject: [String: Any] = [
            "eventName": info.eventName,
            "iteration": info.iteration,
            "iterationCount": info.iterationCount,
            "requestName": info.requestName,
            "requestId": info.requestID
        ]
        let cookiesObject: [String: String] = {
            guard let jar = cookieJar else { return [:] }
            return jar.cookies(for: request.url).reduce(into: [:]) { $0[$1.name] = $1.value }
        }()

        if let data = try? JSONSerialization.data(withJSONObject: requestObject),
           let json = String(data: data, encoding: .utf8) {
            jsContext.evaluateScript("var __req = \(json);")
        }
        if let responseObject, let data = try? JSONSerialization.data(withJSONObject: responseObject),
           let json = String(data: data, encoding: .utf8) {
            jsContext.evaluateScript("var __res = \(json);")
        } else {
            jsContext.evaluateScript("var __res = null;")
        }
        if let data = try? JSONSerialization.data(withJSONObject: variablesObject),
           let json = String(data: data, encoding: .utf8) {
            jsContext.evaluateScript("var __vars = \(json);")
        }
        if let data = try? JSONSerialization.data(withJSONObject: infoObject),
           let json = String(data: data, encoding: .utf8) {
            jsContext.evaluateScript("var __info = \(json);")
        }
        if let data = try? JSONSerialization.data(withJSONObject: cookiesObject),
           let json = String(data: data, encoding: .utf8) {
            jsContext.evaluateScript("var __cookies = \(json);")
        }

        jsContext.evaluateScript(Self.prelude)
        if let exception = jsContext.exception {
            bridge.outcome.error = "Sandbox initialization failed: \(exception.toString() ?? "")"
            jsContext.exception = nil
            return bridge.outcome
        }

        jsContext.evaluateScript(source)
        if let exception = jsContext.exception {
            bridge.outcome.error = exception.toString() ?? "Script error"
            bridge.outcome.console.append(ConsoleEntry(kind: .error, title: "Script error", detail: exception.toString() ?? ""))
            jsContext.exception = nil
        }

        if let mutation = jsContext.objectForKeyedSubscript("__pmCollectRequestMutation")?.call(withArguments: [])?.toString(),
           let data = mutation.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let headers = (object["headers"] as? [[String: Any]])?.compactMap { row -> KeyValue? in
                guard let key = row["key"] as? String else { return nil }
                return KeyValue(key: key, value: (row["value"] as? String) ?? "", disabled: row["disabled"] as? Bool ?? false)
            }
            bridge.outcome.requestMutation = RequestMutation(
                method: object["method"] as? String,
                url: object["url"] as? String,
                headers: headers
            )
        }

        return bridge.outcome
    }

    private func installBridges(in jsContext: JSContext, bridge: ScriptBridge, phase: ScriptPhase, info: ScriptInfo, context: VariableContext) {
        let logBlock: @convention(block) (String, String) -> Void = { level, message in
            let kind: ConsoleEntry.Kind = level == "error" ? .error : .script
            bridge.outcome.console.append(ConsoleEntry(kind: kind, title: "console.\(level)", detail: message))
        }
        jsContext.setObject(logBlock, forKeyedSubscript: "__pmLog" as NSString)

        let lookupBlock: @convention(block) (String) -> String? = { key in bridge.lookup(key) }
        jsContext.setObject(lookupBlock, forKeyedSubscript: "__pmLookup" as NSString)

        let dynamicBlock: @convention(block) (String) -> String? = { name in
            guard name.hasPrefix("$") else { return nil }
            return context.dynamicProvider.value(for: name)
        }
        jsContext.setObject(dynamicBlock, forKeyedSubscript: "__pmDynamic" as NSString)

        let setBlock: @convention(block) (String, String, String) -> Void = { scope, key, value in
            bridge.setVariable(scope: scope, key: key, value: value)
        }
        jsContext.setObject(setBlock, forKeyedSubscript: "__pmSetVariable" as NSString)

        let unsetBlock: @convention(block) (String, String) -> Void = { scope, key in
            bridge.unsetVariable(scope: scope, key: key)
        }
        jsContext.setObject(unsetBlock, forKeyedSubscript: "__pmUnsetVariable" as NSString)

        let clearBlock: @convention(block) (String) -> Void = { scope in bridge.clear(scope: scope) }
        jsContext.setObject(clearBlock, forKeyedSubscript: "__pmClearScope" as NSString)

        let assertionBlock: @convention(block) (String, Bool, String?) -> Void = { name, passed, error in
            bridge.outcome.tests.append(TestResult(name: name, passed: passed, errorMessage: error))
        }
        jsContext.setObject(assertionBlock, forKeyedSubscript: "__pmAssertion" as NSString)

        let sendBlock: @convention(block) (String) -> String = { json in bridge.send(json) }
        jsContext.setObject(sendBlock, forKeyedSubscript: "__pmSendRequest" as NSString)

        let visualizerBlock: @convention(block) (String, String) -> Void = { template, data in
            bridge.outcome.visualizerTemplate = template
            bridge.outcome.visualizerData = data
        }
        jsContext.setObject(visualizerBlock, forKeyedSubscript: "__pmVisualizer" as NSString)

        let nextBlock: @convention(block) (String) -> Void = { name in bridge.outcome.nextRequest = name }
        jsContext.setObject(nextBlock, forKeyedSubscript: "__pmNextRequest" as NSString)

        let infoBlock: @convention(block) () -> String = {
            let object: [String: Any] = [
                "eventName": info.eventName,
                "iteration": info.iteration,
                "iterationCount": info.iterationCount,
                "requestName": info.requestName,
                "requestId": info.requestID,
                "phase": phase.rawValue
            ]
            let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
            return String(data: data, encoding: .utf8) ?? "{}"
        }
        jsContext.setObject(infoBlock, forKeyedSubscript: "__pmInfoJSON" as NSString)

        let cryptoBlock: @convention(block) (String, String, String) -> String = { algorithm, text, key in
            let data = Data(text.utf8)
            let keyData = Data(key.utf8)
            var digest: Data?
            switch algorithm.uppercased() {
            case "MD5":
                digest = Data(Insecure.MD5.hash(data: data))
            case "SHA1":
                digest = Data(Insecure.SHA1.hash(data: data))
            case "SHA256":
                digest = Data(SHA256.hash(data: data))
            case "SHA512":
                digest = Data(SHA512.hash(data: data))
            case "HMAC-MD5":
                if !keyData.isEmpty {
                    digest = Data(HMAC<Insecure.MD5>.authenticationCode(for: data, using: SymmetricKey(data: keyData)))
                }
            case "HMAC-SHA1":
                if !keyData.isEmpty {
                    digest = Data(HMAC<Insecure.SHA1>.authenticationCode(for: data, using: SymmetricKey(data: keyData)))
                }
            case "HMAC-SHA256":
                if !keyData.isEmpty {
                    digest = Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: keyData)))
                }
            case "HMAC-SHA512":
                if !keyData.isEmpty {
                    digest = Data(HMAC<SHA512>.authenticationCode(for: data, using: SymmetricKey(data: keyData)))
                }
            default:
                break
            }
            let hex = digest?.map { String(format: "%02x", $0) }.joined() ?? ""
            let base64 = digest?.base64EncodedString() ?? ""
            let payload: [String: Any] = ["hex": hex, "base64": base64]
            let json = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
            return String(data: json, encoding: .utf8) ?? "{\"hex\":\"\",\"base64\":\"\"}"
        }
        jsContext.setObject(cryptoBlock, forKeyedSubscript: "__pmCrypto" as NSString)

        let base64EncodeBlock: @convention(block) (String) -> String = { text in
            Data(text.utf8).base64EncodedString()
        }
        jsContext.setObject(base64EncodeBlock, forKeyedSubscript: "__pmBase64Encode" as NSString)

        let base64DecodeBlock: @convention(block) (String) -> String = { text in
            guard let data = Data(base64Encoded: text) else { return "" }
            return String(data: data, encoding: .utf8) ?? ""
        }
        jsContext.setObject(base64DecodeBlock, forKeyedSubscript: "__pmBase64Decode" as NSString)
    }

    private static let prelude = #"""
    var __pmScopes = { globals: __vars.globals || {}, environment: __vars.environment || {},
                       collectionVariables: __vars.collectionVariables || {}, variables: __vars.variables || {},
                       iterationData: __vars.iterationData || {} };
    var __pmRequestState = { method: __req.method, url: __req.url,
                             headers: (__req.headers || []).map(function (h) { return { key: h.key, value: h.value, disabled: false }; }),
                             body: __req.body || "" };

    function __pmQueryParam(key, value) {
      return { key: key, value: value, toString: function () { return this.value; }, valueOf: function () { return this.value; } };
    }
    function __pmParseQuery(text) {
      var url = String(text === undefined ? __pmRequestState.url : text);
      var mark = url.indexOf("?");
      if (mark < 0) { return []; }
      var query = url.substring(mark + 1);
      if (!query) { return []; }
      var result = [];
      var parts = query.split("&");
      for (var i = 0; i < parts.length; i++) {
        var pair = parts[i].split("=");
        var key = decodeURIComponent(pair[0] || "");
        var value = decodeURIComponent(pair.slice(1).join("=") || "");
        result.push(__pmQueryParam(key, value));
      }
      return result;
    }
    function __pmToBytesText(value) {
      if (value === null || value === undefined) { return ""; }
      if (typeof value === "string") { return value; }
      if (typeof value === "number" || typeof value === "boolean") { return String(value); }
      if (value.__text !== undefined) { return value.__text; }
      if (value.__hex !== undefined) { return value.__hex; }
      return String(value);
    }
    function __pmWordArray(json, text) {
      var parsed = { hex: "", base64: "" };
      try { parsed = JSON.parse(json); } catch (e) { parsed = { hex: "", base64: "" }; }
      return {
        __text: text,
        __hex: parsed.hex || "",
        __base64: parsed.base64 || "",
        toString: function (encoder) {
          if (encoder === CryptoJS.enc.Base64) { return this.__base64; }
          return this.__hex;
        }
      };
    }
    var CryptoJS = {
      MD5: function (value) { var text = __pmToBytesText(value); return __pmWordArray(__pmCrypto("MD5", text, ""), text); },
      SHA1: function (value) { var text = __pmToBytesText(value); return __pmWordArray(__pmCrypto("SHA1", text, ""), text); },
      SHA256: function (value) { var text = __pmToBytesText(value); return __pmWordArray(__pmCrypto("SHA256", text, ""), text); },
      SHA512: function (value) { var text = __pmToBytesText(value); return __pmWordArray(__pmCrypto("SHA512", text, ""), text); },
      HmacMD5: function (message, key) {
        var text = __pmToBytesText(message); return __pmWordArray(__pmCrypto("HMAC-MD5", text, __pmToBytesText(key)), text);
      },
      HmacSHA1: function (message, key) {
        var text = __pmToBytesText(message); return __pmWordArray(__pmCrypto("HMAC-SHA1", text, __pmToBytesText(key)), text);
      },
      HmacSHA256: function (message, key) {
        var text = __pmToBytesText(message); return __pmWordArray(__pmCrypto("HMAC-SHA256", text, __pmToBytesText(key)), text);
      },
      HmacSHA512: function (message, key) {
        var text = __pmToBytesText(message); return __pmWordArray(__pmCrypto("HMAC-SHA512", text, __pmToBytesText(key)), text);
      },
      enc: {
        Hex: {
          stringify: function (value) { return value && value.__hex !== undefined ? value.__hex : String(value || ""); },
          parse: function (hex) {
            return { __hex: String(hex || ""), __text: String(hex || ""), __base64: "",
                     toString: function () { return this.__hex; } };
          }
        },
        Base64: {
          stringify: function (value) {
            if (value && value.__base64) { return value.__base64; }
            return __pmBase64Encode(__pmToBytesText(value));
          },
          parse: function (text) {
            var decoded = __pmBase64Decode(String(text || ""));
            return { __text: decoded, __base64: String(text || ""), __hex: "",
                     toString: function () { return this.__text; } };
          }
        },
        Utf8: {
          stringify: function (value) { return __pmToBytesText(value); },
          parse: function (text) {
            return { __text: String(text || ""), __hex: "", __base64: "",
                     toString: function () { return this.__text; } };
          }
        }
      },
      lib: {
        WordArray: {
          create: function (words) {
            var text = String(words === undefined ? "" : words);
            return { __text: text, __hex: "", __base64: "", toString: function () { return text; } };
          }
        }
      },
      AES: {
        encrypt: function () { throw new Error("CryptoJS.AES is not implemented in this build"); },
        decrypt: function () { throw new Error("CryptoJS.AES is not implemented in this build"); }
      }
    };
    function btoa(text) { return __pmBase64Encode(String(text)); }
    function atob(text) { return __pmBase64Decode(String(text)); }

    function __pmStringify(value) {
      if (value === undefined) { return "undefined"; }
      if (value === null) { return "null"; }
      if (typeof value === "string") { return value; }
      try { return JSON.stringify(value); } catch (e) { return String(value); }
    }
    function __pmRecordLog(level, args) {
      var parts = [];
      for (var i = 0; i < args.length; i++) { parts.push(__pmStringify(args[i])); }
      __pmLog(level, parts.join(" "));
    }
    var console = {
      log: function () { __pmRecordLog("log", arguments); },
      info: function () { __pmRecordLog("info", arguments); },
      warn: function () { __pmRecordLog("warn", arguments); },
      error: function () { __pmRecordLog("error", arguments); },
      debug: function () { __pmRecordLog("debug", arguments); }
    };

    function __pmScope(name) {
      return {
        get: function (key) {
          var value = __pmScopes[name][key];
          if (value === undefined && name === "variables") { value = __pmLookup(key); }
          return value === undefined ? undefined : value;
        },
        set: function (key, value) {
          __pmScopes[name][key] = value;
          __pmSetVariable(name, String(key), String(value));
        },
        unset: function (key) {
          delete __pmScopes[name][key];
          __pmUnsetVariable(name, String(key));
        },
        clear: function () {
          __pmScopes[name] = {};
          __pmClearScope(name);
        },
        has: function (key) {
          return Object.prototype.hasOwnProperty.call(__pmScopes[name], key) ||
            (name === "variables" && __pmLookup(key) !== null);
        },
        toObject: function () { return Object.assign({}, __pmScopes[name]); },
        replaceIn: function (template) {
          return String(template).replace(/\{\{([^{}]+)\}\}/g, function (match, key) {
            var value = __pmScopes[name][key];
            if (value === undefined) { value = __pmLookup(key); }
            if ((value === undefined || value === null) && key.charAt(0) === "$") { value = __pmDynamic(key); }
            return value === undefined || value === null ? match : value;
          });
        }
      };
    }

    function __pmHeaders(list) {
      return {
        get: function (name) {
          for (var i = 0; i < list.length; i++) {
            if (String(list[i].key).toLowerCase() === String(name).toLowerCase() && !list[i].disabled) { return list[i].value; }
          }
          return undefined;
        },
        has: function (name) { return this.get(name) !== undefined; },
        add: function (item) { list.push({ key: String(item.key), value: String(item.value), disabled: false }); },
        upsert: function (item) {
          for (var i = 0; i < list.length; i++) {
            if (String(list[i].key).toLowerCase() === String(item.key).toLowerCase()) {
              list[i].value = String(item.value); list[i].disabled = false; return;
            }
          }
          this.add(item);
        },
        remove: function (name) {
          for (var i = list.length - 1; i >= 0; i--) {
            if (String(list[i].key).toLowerCase() === String(name).toLowerCase()) { list.splice(i, 1); }
          }
        },
        toObject: function () {
          var result = {};
          for (var i = 0; i < list.length; i++) { if (!list[i].disabled) { result[list[i].key] = list[i].value; } }
          return result;
        },
        all: function () { return list.slice(); }
      };
    }

    function __pmResponse(res) {
      if (!res) { return undefined; }
      var headers = __pmHeaders(res.headers || []);
      var response = {
        code: res.code,
        status: res.status,
        responseTime: res.responseTime,
        responseSize: res.responseSize,
        headers: headers,
        text: function () { return res.body || ""; },
        json: function () { return JSON.parse(res.body || "{}"); },
        reason: function () { return res.status; },
        cookies: {
          get: function (name) { return __cookies[name]; },
          has: function (name) { return __cookies[name] !== undefined; },
          toObject: function () { return Object.assign({}, __cookies); }
        }
      };
      function statusCheck(code) {
        if (res.code !== code) { throw new Error("expected response to have status code " + code + " but got " + res.code); }
      }
      function headerCheck(name, value) {
        var actual = headers.get(name);
        if (actual === undefined) { throw new Error("expected response to have header " + name); }
        if (value !== undefined && String(actual) !== String(value)) {
          throw new Error("expected header " + name + " to equal " + value + " but got " + actual);
        }
      }
      function jsonBodyCheck(path, value) {
        var body = response.json();
        var current = body;
        var parts = String(path).split(".");
        for (var i = 0; i < parts.length; i++) {
          if (current === null || current === undefined) { break; }
          current = current[parts[i]];
        }
        if (current === undefined) { throw new Error("expected JSON body to have key " + path); }
        if (value !== undefined && String(current) !== String(value)) {
          throw new Error("expected JSON key " + path + " to equal " + value + " but got " + current);
        }
      }
      response.to = {
        have: { status: statusCheck, header: headerCheck, jsonBody: jsonBodyCheck },
        not: { have: {
          status: function (code) {
            if (res.code === code) { throw new Error("expected response not to have status code " + code); }
          },
          header: function (name) {
            if (headers.get(name) !== undefined) { throw new Error("expected response not to have header " + name); }
          }
        } },
        be: {
          get ok() {
            if (res.code < 200 || res.code >= 300) { throw new Error("expected response to be ok but got " + res.code); }
            return true;
          },
          get success() {
            if (res.code < 200 || res.code >= 300) { throw new Error("expected response to be successful but got " + res.code); }
            return true;
          }
        }
      };
      return response;
    }

    var pm = {
      info: JSON.parse(__pmInfoJSON()),
      globals: __pmScope("globals"),
      environment: __pmScope("environment"),
      collectionVariables: __pmScope("collectionVariables"),
      variables: __pmScope("variables"),
      iterationData: __pmScope("iterationData"),
      request: {
        method: __pmRequestState.method,
        url: {
          toString: function () { return __pmRequestState.url; },
          get: function () { return __pmRequestState.url; },
          addQueryParams: function (value) {
            var text = typeof value === "string" ? value : String(value.key) + "=" + String(value.value);
            __pmRequestState.url += (__pmRequestState.url.indexOf("?") >= 0 ? "&" : "?") + text;
          },
          query: {
            get: function (name) {
              var params = __pmParseQuery();
              for (var i = 0; i < params.length; i++) {
                if (params[i].key === name) { return params[i]; }
              }
              return null;
            },
            has: function (name) {
              var params = __pmParseQuery();
              for (var i = 0; i < params.length; i++) { if (params[i].key === name) { return true; } }
              return false;
            },
            toObject: function () {
              var result = {};
              var params = __pmParseQuery();
              for (var i = 0; i < params.length; i++) { result[params[i].key] = params[i].value; }
              return result;
            },
            all: function () { return __pmParseQuery(); },
            add: function (item) {
              var key = typeof item === "string" ? item : item.key;
              var value = typeof item === "string" ? "" : item.value;
              __pmRequestState.url += (__pmRequestState.url.indexOf("?") >= 0 ? "&" : "?") +
                encodeURIComponent(key) + "=" + encodeURIComponent(value);
            },
            upsert: function (item) {
              var key = typeof item === "string" ? item : item.key;
              var value = typeof item === "string" ? "" : item.value;
              var params = __pmParseQuery();
              var found = false;
              for (var i = 0; i < params.length; i++) {
                if (params[i].key === key) { params[i].value = value; found = true; }
              }
              if (!found) { params.push(__pmQueryParam(key, value)); }
              var mark = __pmRequestState.url.indexOf("?");
              var base = mark < 0 ? __pmRequestState.url : __pmRequestState.url.substring(0, mark);
              var parts = [];
              for (var j = 0; j < params.length; j++) {
                parts.push(encodeURIComponent(params[j].key) + "=" + encodeURIComponent(params[j].value));
              }
              __pmRequestState.url = base + (parts.length ? "?" + parts.join("&") : "");
            },
            remove: function (name) {
              var params = __pmParseQuery().filter(function (item) { return item.key !== name; });
              var mark = __pmRequestState.url.indexOf("?");
              var base = mark < 0 ? __pmRequestState.url : __pmRequestState.url.substring(0, mark);
              var parts = [];
              for (var i = 0; i < params.length; i++) {
                parts.push(encodeURIComponent(params[i].key) + "=" + encodeURIComponent(params[i].value));
              }
              __pmRequestState.url = base + (parts.length ? "?" + parts.join("&") : "");
            }
          }
        },
        headers: __pmHeaders(__pmRequestState.headers),
        body: {
          mode: "raw",
          raw: __pmRequestState.body,
          toString: function () { return __pmRequestState.body; }
        }
      },
      response: __pmResponse(__res),
      cookies: {
        get: function (name) { return __cookies[name]; },
        has: function (name) { return __cookies[name] !== undefined; },
        toObject: function () { return Object.assign({}, __cookies); },
        jar: function () { return Object.assign({}, __cookies); }
      },
      sendRequest: function (request, callback) {
        if (typeof callback !== "function") {
          throw new Error("pm.sendRequest requires a callback in this build");
        }
        var json = typeof request === "string" ? JSON.stringify({ url: request }) : JSON.stringify(request);
        var raw = __pmSendRequest(json);
        var parsed = JSON.parse(raw);
        if (parsed.error) { callback(new Error(parsed.error), undefined); return; }
        callback(null, __pmResponse({ code: parsed.code, status: parsed.status,
          responseTime: parsed.responseTime, responseSize: parsed.responseSize,
          headers: parsed.headers || [], body: parsed.text || "" }));
      },
      visualizer: {
        set: function (template, data) { __pmVisualizer(String(template), JSON.stringify(data === undefined ? null : data)); }
      },
      execution: {
        setNextRequest: function (name) { __pmNextRequest(name === null ? "" : String(name)); }
      },
      test: function (name, assertion) {
        if (typeof assertion !== "function") { __pmAssertion(String(name), true, null); return pm; }
        if (assertion.length > 0) {
          __pmAssertion(String(name), false, "Async pm.test callbacks are not supported in this build");
          return pm;
        }
        try {
          assertion();
          __pmAssertion(String(name), true, null);
        } catch (error) {
          __pmAssertion(String(name), false, error && error.message ? error.message : String(error));
        }
        return pm;
      }
    };
    pm.environment.name = "environment";

    function Expectation(actual, negate) {
      this.actual = actual;
      this.negate = !!negate;
    }
    Expectation.prototype.__check = function (condition, message) {
      if (this.negate ? condition : !condition) { throw new Error(message); }
      return this;
    };
    Expectation.prototype.equal = function (expected) {
      return this.__check(this.actual === expected, "expected " + __pmStringify(this.actual) + (this.negate ? " not" : "") + " to equal " + __pmStringify(expected));
    };
    Expectation.prototype.eql = function (expected) {
      return this.__check(JSON.stringify(this.actual) === JSON.stringify(expected), "expected " + __pmStringify(this.actual) + (this.negate ? " not" : "") + " to deeply equal " + __pmStringify(expected));
    };
    Expectation.prototype.include = function (expected) {
      var actual = this.actual;
      var condition = typeof actual === "string" ? actual.indexOf(expected) >= 0 :
        (Array.isArray(actual) ? actual.indexOf(expected) >= 0 : false);
      return this.__check(condition, "expected " + __pmStringify(actual) + (this.negate ? " not" : "") + " to include " + __pmStringify(expected));
    };
    Expectation.prototype.match = function (pattern) {
      return this.__check(new RegExp(pattern).test(String(this.actual)), "expected " + __pmStringify(this.actual) + (this.negate ? " not" : "") + " to match " + pattern);
    };
    Expectation.prototype.property = function (name, value) {
      if (arguments.length > 1) {
        return this.__check(this.actual && this.actual[name] === value, "expected property " + name + " to equal " + __pmStringify(value));
      }
      return this.__check(this.actual !== null && this.actual !== undefined && name in Object(this.actual), "expected object to have property " + name);
    };
    Expectation.prototype.lengthOf = function (length) {
      return this.__check(this.actual && this.actual.length === length, "expected length " + length);
    };
    Expectation.prototype.above = function (value) { return this.__check(this.actual > value, "expected " + this.actual + " to be above " + value); };
    Expectation.prototype.below = function (value) { return this.__check(this.actual < value, "expected " + this.actual + " to be below " + value); };
    Expectation.prototype.least = function (value) { return this.__check(this.actual >= value, "expected " + this.actual + " to be at least " + value); };
    Expectation.prototype.most = function (value) { return this.__check(this.actual <= value, "expected " + this.actual + " to be at most " + value); };
    Expectation.prototype.a = function (type) { return this.__check(typeof this.actual === type, "expected type " + type); };
    Object.defineProperty(Expectation.prototype, "true", { get: function () { return this.__check(this.actual === true, "expected true"); } });
    Object.defineProperty(Expectation.prototype, "false", { get: function () { return this.__check(this.actual === false, "expected false"); } });
    Object.defineProperty(Expectation.prototype, "null", { get: function () { return this.__check(this.actual === null, "expected null"); } });
    Object.defineProperty(Expectation.prototype, "undefined", { get: function () { return this.__check(this.actual === undefined, "expected undefined"); } });
    Object.defineProperty(Expectation.prototype, "exist", { get: function () { return this.__check(this.actual !== null && this.actual !== undefined, "expected value to exist"); } });
    Object.defineProperty(Expectation.prototype, "empty", { get: function () { return this.__check(this.actual && this.actual.length === 0, "expected value to be empty"); } });
    Object.defineProperty(Expectation.prototype, "ok", { get: function () { return this.__check(!!this.actual, "expected value to be truthy"); } });
    Object.defineProperty(Expectation.prototype, "not", { get: function () { return new Expectation(this.actual, !this.negate); } });
    Object.defineProperty(Expectation.prototype, "be", { get: function () { return this; } });
    Object.defineProperty(Expectation.prototype, "to", { get: function () { return this; } });
    Object.defineProperty(Expectation.prototype, "have", { get: function () { return this; } });
    Object.defineProperty(Expectation.prototype, "and", { get: function () { return this; } });

    pm.expect = function (actual) { return new Expectation(actual); };

    // Legacy sandbox globals used by older collections.
    var tests = {};
    pm.globals.set = pm.globals.set.bind(pm.globals);
    function __pmLegacySet(scope, key, value) { __pmSetVariable(scope, String(key), String(value)); __pmScopes[scope][key] = value; }
    var postman = {
      setEnvironmentVariable: function (key, value) { __pmLegacySet("environment", key, value); },
      setGlobalVariable: function (key, value) { __pmLegacySet("globals", key, value); },
      getEnvironmentVariable: function (key) {
        var value = __pmScopes.environment[key]; return value === undefined ? null : value;
      },
      getGlobalVariable: function (key) {
        var value = __pmScopes.globals[key]; return value === undefined ? null : value;
      },
      clearEnvironmentVariable: function (key) { pm.environment.unset(key); },
      clearGlobalVariable: function (key) { pm.globals.unset(key); },
      setNextRequest: function (name) { __pmNextRequest(name === null ? "" : String(name)); }
    };
    var environment = __pmScopes.environment;
    var globals = __pmScopes.globals;
    var data = __pmScopes.iterationData;
    var responseBody = __res ? __res.body : "";
    var responseCode = __res ? __res.code : undefined;
    var __pmLegacyData = {};
    (function () {
      try {
        var raw = __pmRequestState.body || "";
        var trimmed = raw.replace(/^\s+/, "");
        if (trimmed.charAt(0) === "{" || trimmed.charAt(0) === "[") {
          var parsed = JSON.parse(raw);
          if (parsed && typeof parsed === "object") { Object.assign(__pmLegacyData, parsed); }
        } else if (raw.indexOf("=") >= 0) {
          var pairs = raw.split("&");
          for (var i = 0; i < pairs.length; i++) {
            var kv = pairs[i].split("=");
            __pmLegacyData[decodeURIComponent(kv[0] || "")] = decodeURIComponent(kv.slice(1).join("=") || "");
          }
        }
      } catch (e) { }
      __pmLegacyData.toString = function () { return __pmRequestState.body; };
    })();
    var request = {
      url: __pmRequestState.url,
      method: __pmRequestState.method,
      headers: pm.request.headers,
      data: __pmLegacyData,
      body: __pmRequestState.body
    };

    function __pmCollectRequestMutation() {
      return JSON.stringify({
        method: __pmRequestState.method,
        url: __pmRequestState.url,
        headers: __pmRequestState.headers.filter(function (h) { return !h.disabled; })
      });
    }
    """#
}
