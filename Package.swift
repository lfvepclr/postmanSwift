// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PostmanSwift",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PostmanSwift", targets: ["PostmanSwift"])
    ],
    targets: [
        .executableTarget(
            name: "PostmanSwift",
            path: "Sources/PostmanSwift",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("JavaScriptCore"),
                .linkedFramework("Security"),
                .linkedFramework("WebKit"),
                .linkedFramework("Network"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("PDFKit")
            ]
        ),
        .testTarget(
            name: "PostmanSwiftTests",
            dependencies: ["PostmanSwift"],
            path: "Tests/PostmanSwiftTests"
        )
    ]
)
