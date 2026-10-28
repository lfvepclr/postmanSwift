import XCTest
@testable import PostmanSwift

final class DynamicVariableTests: XCTestCase {
    func testCommonDynamicVariablesResolve() {
        let context = VariableContext()
        let guid = context.resolve("{{$guid}}")
        XCTAssertNotNil(UUID(uuidString: guid), "guid should be a UUID: \(guid)")
        XCTAssertTrue(Int(context.resolve("{{$timestamp}}")) != nil)
        XCTAssertTrue(ISO8601DateFormatter().date(from: context.resolve("{{$isoTimestamp}}")) != nil)
        let randomInt = Int(context.resolve("{{$randomInt}}"))
        XCTAssertNotNil(randomInt)
        XCTAssertTrue((0...1000).contains(randomInt ?? -1))
        XCTAssertTrue(["true", "false"].contains(context.resolve("{{$randomBoolean}}")))
        XCTAssertFalse(context.resolve("{{$randomFirstName}}").isEmpty)
        XCTAssertTrue(context.resolve("{{$randomEmail}}").contains("@"))
        XCTAssertEqual(context.resolve("{{$randomHexColor}}").count, 7)
        XCTAssertTrue(context.resolve("{{$randomSemver}}").split(separator: ".").count == 3)
        XCTAssertTrue(context.resolve("{{$randomNanoId}}").count == 21)
        XCTAssertNotNil(ISO8601DateFormatter().date(from: context.resolve("{{$randomDatePast}}")))
        XCTAssertFalse(context.resolve("{{$randomCreditCardNumber}}").isEmpty)
        XCTAssertFalse(context.resolve("{{$randomMimeType}}").isEmpty)
        XCTAssertFalse(context.resolve("{{$randomDirectoryPath}}").isEmpty)
    }

    func testUnknownDynamicVariableIsLeftIntact() {
        XCTAssertEqual(VariableContext().resolve("{{$notARealVariable}}"), "{{$notARealVariable}}")
    }

    func testDynamicVariableInsideEnvironmentValueResolves() {
        var context = VariableContext()
        context.environment["requestId"] = "{{$randomInt}}"
        let resolved = context.resolve("id={{requestId}}&ts={{$timestamp}}")
        XCTAssertTrue(resolved.hasPrefix("id="))
        let parts = resolved.split(separator: "&")
        XCTAssertEqual(parts.count, 2)
        XCTAssertNotNil(Int(parts[0].dropFirst(3)))
        XCTAssertTrue(parts[1].hasPrefix("ts="))
    }

    func testSameDynamicVariableKeepsOneValueWithinOneResolution() {
        let resolved = VariableContext().resolve("{{$guid}}|{{$guid}}")
        let parts = resolved.split(separator: "|")
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0], parts[1])
    }

    func testDynamicValuesStayStableAcrossRepeatedResolutionsOfOneContext() {
        let context = VariableContext()
        let first = context.resolve("{{$guid}}")
        let second = context.resolve("{{$guid}}")
        let third = context.resolve("u={{$guid}}&b={{$guid}}")
        XCTAssertEqual(first, second)
        XCTAssertTrue(third.contains("u=\(first)&b=\(first)"))
    }

    func testResetDynamicCacheGeneratesFreshValues() {
        let context = VariableContext()
        let first = context.resolve("{{$guid}}")
        context.resetDynamicCache()
        let second = context.resolve("{{$guid}}")
        XCTAssertNotEqual(first, second)
    }

    func testCatalogMatchesProviderSupport() {
        XCTAssertEqual(DynamicVariableCatalog.supportedNames, DynamicVariableProvider.supportedNames)
        for entry in DynamicVariableCatalog.all {
            XCTAssertNotNil(DynamicVariableProvider().value(for: entry.name), "catalog entry without generator: \(entry.name)")
            XCTAssertFalse(entry.description.isEmpty)
            XCTAssertFalse(entry.example.isEmpty)
        }
    }

    func testCompletionListsDynamicVariablesWithNotes() {
        let variables = DynamicVariableCatalog.all.map {
            VariableSuggestion(name: $0.name, value: $0.example, scope: "Dynamic", note: $0.description)
        }
        let text = "{{$time"
        let detected = CompletionEngine.detect(
            text: text,
            caret: (text as NSString).length,
            variables: variables,
            scriptAPI: false
        )
        let item = detected?.items.first { $0.title == "{{$timestamp}}" }
        XCTAssertNotNil(item)
        XCTAssertTrue(item?.detail.contains("Unix") ?? false)
        XCTAssertEqual(item?.insertText, "$timestamp}}")
    }
}
