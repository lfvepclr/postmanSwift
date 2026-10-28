import Foundation

struct VariableContext {
    var globals: [String: String] = [:]
    var collection: [String: String] = [:]
    var environment: [String: String] = [:]
    var data: [String: String] = [:]
    var local: [String: String] = [:]

    /// Shared across copies of this context so `{{$timestamp}}` and friends resolve to the
    /// same value everywhere one request is built (URL, params, headers, body, scripts).
    let dynamicProvider = DynamicVariableProvider()

    /// Postman precedence: local > data > environment > collection > globals.
    func value(for name: String) -> String? {
        if let value = local[name] { return value }
        if let value = data[name] { return value }
        if let value = environment[name] { return value }
        if let value = collection[name] { return value }
        return globals[name]
    }

    func resolve(_ input: String, dynamic: DynamicVariableProvider? = nil) -> String {
        let provider = dynamic ?? dynamicProvider
        var result = input
        for _ in 0..<10 {
            var changed = false
            result = Self.replaceVariables(in: result) { name in
                if name.hasPrefix("$") { return provider.value(for: name) }
                return self.value(for: name)
            } didChange: { changed = true }
            if !changed { break }
        }
        return result
    }

    static func replaceVariables(
        in input: String,
        lookup: (String) -> String?,
        didChange: () -> Void
    ) -> String {
        guard input.contains("{{") else { return input }
        var output = ""
        var index = input.startIndex
        while let start = input[index...].range(of: "{{")?.lowerBound {
            output += input[index..<start]
            guard let end = input[start...].range(of: "}}")?.lowerBound else {
                output += input[start...]
                return output
            }
            let name = String(input[input.index(start, offsetBy: 2)..<end])
            if let value = lookup(name) {
                output += value
                didChange()
            } else {
                output += input[start..<input.index(end, offsetBy: 2)]
            }
            index = input.index(end, offsetBy: 2)
        }
        output += input[index...]
        return output
    }

    /// Clears cached dynamic values so the next request generates a fresh set.
    func resetDynamicCache() {
        dynamicProvider.reset()
    }

    var allVariableNames: [String] {
        var names = Set<String>()
        [globals, collection, environment, data, local].forEach { names.formUnion($0.keys) }
        return names.sorted()
    }
}

final class DynamicVariableProvider {
    private var cache: [String: String] = [:]

    func reset() {
        cache.removeAll()
    }

    func value(for name: String) -> String? {
        if let cached = cache[name] { return cached }
        guard let generated = Self.generate(name) else { return nil }
        cache[name] = generated
        return generated
    }

    /// Names handled by `generate`; `DynamicVariableCatalogTests` asserts this matches the
    /// catalog used for completion and hover hints.
    static let supportedNames: Set<String> = [
        "$guid",
        "$randomUUID",
        "$timestamp",
        "$isoTimestamp",
        "$randomInt",
        "$randomBoolean",
        "$randomAlphaNumeric",
        "$randomHexColor",
        "$randomFirstName",
        "$randomLastName",
        "$randomFullName",
        "$randomEmail",
        "$randomExampleEmail",
        "$randomUserName",
        "$randomPassword",
        "$randomWord",
        "$randomCity",
        "$randomCountry",
        "$randomStreetName",
        "$randomPhoneNumber",
        "$randomIP",
        "$randomIPV6",
        "$randomIPv4",
        "$randomPort",
        "$randomUserAgent",
        "$randomProtocol",
        "$randomDomainName",
        "$randomUrl",
        "$randomJobTitle",
        "$randomCompanyName",
        "$randomColor",
        "$randomCurrencyCode",
        "$randomCurrencyName",
        "$randomCurrencySymbol",
        "$randomLocale",
        "$randomLatitude",
        "$randomLongitude",
        "$randomMonth",
        "$randomWeekday",
        "$randomPrice",
        "$randomProductName",
        "$randomBS",
        "$randomAbbreviation",
        "$randomDateRecent",
        "$randomDatePast",
        "$randomDateFuture",
        "$randomLoremWord",
        "$randomLoremWords",
        "$randomLoremSentence",
        "$randomLoremSentences",
        "$randomLoremParagraph",
        "$randomLoremParagraphs",
        "$randomBankAccount",
        "$randomBankAccountName",
        "$randomBankAccountRouting",
        "$randomCreditCardNumber",
        "$randomCreditCardType",
        "$randomCreditCardCVV",
        "$randomCreditCardExpiry",
        "$randomFileName",
        "$randomCommonFileName",
        "$randomFileType",
        "$randomCommonFileType",
        "$randomFileExt",
        "$randomCommonFileExt",
        "$randomDirectoryPath",
        "$randomSemver",
        "$randomNanoId",
        "$randomMACAddress",
        "$randomMimeType",
        "$randomAvatarImage"
    ]

    private static let firstNames = ["James", "Mary", "Robert", "Patricia", "John", "Jennifer", "Michael", "Linda", "David", "Elizabeth", "William", "Barbara", "Richard", "Susan", "Joseph", "Jessica", "Thomas", "Sarah", "Charles", "Karen", "Daniel", "Wei", "Yuki", "Aarav", "Sofia", "Lucas", "Mia", "Omar", "Aisha", "Diego"]
    private static let lastNames = ["Smith", "Johnson", "Williams", "Brown", "Jones", "Garcia", "Miller", "Davis", "Rodriguez", "Martinez", "Hernandez", "Lopez", "Gonzalez", "Wilson", "Anderson", "Thomas", "Taylor", "Moore", "Jackson", "Martin", "Lee", "Chen", "Wang", "Kumar", "Patel", "Nguyen", "Kim", "Silva", "Rossi", "Müller"]
    private static let words = ["alpha", "beta", "gamma", "delta", "epsilon", "zeta", "theta", "lambda", "sigma", "omega", "river", "cloud", "stone", "forest", "silver", "orange", "bridge", "harbor", "summit", "meadow"]
    private static let cities = ["Tokyo", "London", "Paris", "Berlin", "Sydney", "Toronto", "Singapore", "Seoul", "Madrid", "Rome", "Amsterdam", "Lisbon", "Dubai", "Mumbai", "Shanghai", "São Paulo", "Cape Town", "New York", "San Francisco", "Stockholm"]
    private static let countries = ["China", "United States", "Japan", "Germany", "France", "Brazil", "India", "Canada", "Australia", "United Kingdom", "Spain", "Italy", "Netherlands", "Sweden", "Singapore", "South Korea", "Mexico", "South Africa"]
    private static let domains = ["example.com", "test.io", "mail.test", "api.local", "sample.org", "demo.net"]
    private static let companies = ["Acme", "Globex", "Initech", "Umbrella", "Hooli", "Soylent", "Vandelay", "Stark", "Wayne", "Wonka", "Cyberdyne", "Tyrell"]
    private static let jobTitles = ["Engineer", "Designer", "Analyst", "Manager", "Developer", "Architect", "Consultant", "Researcher", "Director", "Specialist"]
    private static let colors = ["red", "green", "blue", "yellow", "purple", "orange", "teal", "magenta", "cyan", "lime"]
    private static let currencies = ["USD", "EUR", "GBP", "JPY", "CNY", "AUD", "CAD", "CHF", "INR", "BRL"]
    private static let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
    private static let weekdays = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

    private static func generate(_ name: String) -> String? {
        switch name {
        case "$guid", "$randomUUID":
            return UUID().uuidString.lowercased()
        case "$timestamp":
            return String(Int(Date().timeIntervalSince1970))
        case "$isoTimestamp":
            return ISO8601DateFormatter().string(from: Date())
        case "$randomInt":
            return String(Int.random(in: 0...1000))
        case "$randomBoolean":
            return Bool.random() ? "true" : "false"
        case "$randomAlphaNumeric":
            let characters = Array("abcdefghijklmnopqrstuvwxyz0123456789")
            return String((0..<16).compactMap { _ in characters.randomElement() })
        case "$randomHexColor":
            return String(format: "#%06X", Int.random(in: 0...0xFFFFFF))
        case "$randomFirstName":
            return firstNames.randomElement()
        case "$randomLastName":
            return lastNames.randomElement()
        case "$randomFullName":
            return "\(firstNames.randomElement() ?? "Alex") \(lastNames.randomElement() ?? "Taylor")"
        case "$randomEmail", "$randomExampleEmail":
            return "\(firstNames.randomElement()?.lowercased() ?? "user").\(lastNames.randomElement()?.lowercased() ?? "test")@\(domains.randomElement() ?? "example.com")"
        case "$randomUserName":
            return "\(firstNames.randomElement()?.lowercased() ?? "user")\(Int.random(in: 1...999))"
        case "$randomPassword":
            return UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(14).description
        case "$randomWord":
            return words.randomElement()
        case "$randomCity":
            return cities.randomElement()
        case "$randomCountry":
            return countries.randomElement()
        case "$randomStreetName":
            return "\(lastNames.randomElement() ?? "Main") \(["Street", "Avenue", "Road", "Lane"].randomElement() ?? "Street")"
        case "$randomPhoneNumber":
            return "+1\(Int.random(in: 200...999))\(Int.random(in: 200...999))\(String(format: "%04d", Int.random(in: 0...9999)))"
        case "$randomIP":
            return "\(Int.random(in: 1...223)).\(Int.random(in: 0...255)).\(Int.random(in: 0...255)).\(Int.random(in: 1...254))"
        case "$randomIPV6":
            return (0..<8).map { _ in String(format: "%x", Int.random(in: 0...0xFFFF)) }.joined(separator: ":")
        case "$randomPort":
            return String(Int.random(in: 1024...65535))
        case "$randomUserAgent":
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
        case "$randomProtocol":
            return ["http", "https"].randomElement()
        case "$randomDomainName":
            return domains.randomElement()
        case "$randomUrl":
            return "https://\(domains.randomElement() ?? "example.com")/\(words.randomElement() ?? "api")"
        case "$randomJobTitle":
            return jobTitles.randomElement()
        case "$randomCompanyName":
            return companies.randomElement()
        case "$randomColor":
            return colors.randomElement()
        case "$randomCurrencyCode":
            return currencies.randomElement()
        case "$randomLocale":
            return ["en_US", "en_GB", "zh_CN", "ja_JP", "de_DE", "fr_FR", "es_ES"].randomElement()
        case "$randomLatitude":
            return String(format: "%.6f", Double.random(in: -90...90))
        case "$randomLongitude":
            return String(format: "%.6f", Double.random(in: -180...180))
        case "$randomMonth":
            return months.randomElement()
        case "$randomWeekday":
            return weekdays.randomElement()
        case "$randomPrice":
            return String(format: "%.2f", Double.random(in: 1...1000))
        case "$randomProductName":
            return "\(companies.randomElement() ?? "Acme") \(words.randomElement()?.capitalized ?? "Widget")"
        case "$randomBS":
            return "\(words.randomElement() ?? "synergize") \(words.randomElement() ?? "platforms")"
        case "$randomAbbreviation":
            return ["API", "SDK", "HTTP", "JSON", "SQL", "CLI", "URL", "RPC", "TLS", "DNS"].randomElement()
        case "$randomDateRecent":
            let date = Date().addingTimeInterval(-Double.random(in: 0...2_592_000))
            return ISO8601DateFormatter().string(from: date)
        case "$randomDatePast":
            let date = Date(timeIntervalSince1970: Double.random(in: 0...Date().timeIntervalSince1970))
            return ISO8601DateFormatter().string(from: date)
        case "$randomDateFuture":
            let date = Date().addingTimeInterval(Double.random(in: 0...315_360_000))
            return ISO8601DateFormatter().string(from: date)
        case "$randomLoremWord":
            return words.randomElement()
        case "$randomLoremWords":
            return (0..<3).compactMap { _ in words.randomElement() }.joined(separator: " ")
        case "$randomLoremSentence":
            return sentence()
        case "$randomLoremSentences":
            return (0..<3).map { _ in sentence() }.joined(separator: " ")
        case "$randomLoremParagraph":
            return (0..<4).map { _ in sentence() }.joined(separator: " ")
        case "$randomLoremParagraphs":
            return (0..<3).map { _ in (0..<4).map { _ in sentence() }.joined(separator: " ") }.joined(separator: "\n\n")
        case "$randomBankAccount":
            return digits(Int.random(in: 8...12))
        case "$randomBankAccountName":
            return ["Checking", "Savings", "Business Checking", "Money Market"].randomElement()
        case "$randomBankAccountRouting":
            return digits(9)
        case "$randomCreditCardNumber":
            return digits(16)
        case "$randomCreditCardType":
            return ["Visa", "Mastercard", "American Express", "Discover"].randomElement()
        case "$randomCreditCardCVV":
            return digits(3)
        case "$randomCreditCardExpiry":
            let month = Int.random(in: 1...12)
            let year = Int.random(in: 27...33)
            return String(format: "%02d/%02d", month, year)
        case "$randomCurrencyName":
            return ["United States Dollar", "Euro", "British Pound", "Japanese Yen", "Chinese Yuan", "Australian Dollar"].randomElement()
        case "$randomCurrencySymbol":
            return ["$", "€", "£", "¥", "A$", "C$"].randomElement()
        case "$randomFileName", "$randomCommonFileName":
            return "\(words.randomElement() ?? "file")-\(Int.random(in: 100...999)).\(["json", "txt", "png", "jpg", "csv", "xml", "pdf"].randomElement() ?? "txt")"
        case "$randomFileType", "$randomCommonFileType":
            return ["image", "video", "audio", "application", "text"].randomElement()
        case "$randomFileExt", "$randomCommonFileExt":
            return ["json", "txt", "png", "jpg", "csv", "xml", "pdf"].randomElement()
        case "$randomDirectoryPath":
            return "/\(words.randomElement() ?? "data")/\(words.randomElement() ?? "exports")"
        case "$randomSemver":
            return "\(Int.random(in: 0...5)).\(Int.random(in: 0...9)).\(Int.random(in: 0...20))"
        case "$randomNanoId":
            return alphanumeric(21)
        case "$randomMACAddress":
            return (0..<6).map { _ in String(format: "%02X", Int.random(in: 0...255)) }.joined(separator: ":")
        case "$randomMimeType":
            return ["application/json", "application/xml", "text/plain", "text/html", "image/png", "application/pdf"].randomElement()
        case "$randomAvatarImage":
            return "https://example.com/avatars/\(UUID().uuidString.lowercased()).png"
        case "$randomIPv4":
            return "\(Int.random(in: 1...223)).\(Int.random(in: 0...255)).\(Int.random(in: 0...255)).\(Int.random(in: 1...254))"
        default:
            return nil
        }
    }

    private static func digits(_ count: Int) -> String {
        String((0..<count).compactMap { _ in "0123456789".randomElement() })
    }

    private static func alphanumeric(_ count: Int) -> String {
        let characters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String((0..<count).compactMap { _ in characters.randomElement() })
    }

    private static func sentence() -> String {
        let text = (0..<Int.random(in: 4...8)).compactMap { _ in words.randomElement() }.joined(separator: " ")
        return text.prefix(1).uppercased() + String(text.dropFirst()) + "."
    }
}
