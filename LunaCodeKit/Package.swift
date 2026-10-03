// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "LunaCodeKit", platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "LunaCodeCore", targets: ["LunaCodeCore"]),
        .library(name: "LunaCodeMac", targets: ["LunaCodeMac"]),
        .library(name: "LunaCodeUI", targets: ["LunaCodeUI"])
    ],
    dependencies: [
        .package(url: "https://github.com/simonbs/Runestone.git", exact: "0.5.2"),
        .package(url: "https://github.com/simonbs/TreeSitterLanguages.git", exact: "0.1.9"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "602.0.0")
    ],
    targets: [
        .target(name: "LunaCodeCore"),
        .target(name: "LunaCodeMac", dependencies: ["LunaCodeCore"], resources: [.copy("Resources/BuildServer")]),
        .target(name: "LunaCodeUI", dependencies: ["LunaCodeCore",
            .product(name: "Runestone", package: "Runestone", condition: .when(platforms: [.iOS])),
            .product(name: "SwiftParser", package: "swift-syntax", condition: .when(platforms: [.iOS])),
            .product(name: "SwiftParserDiagnostics", package: "swift-syntax", condition: .when(platforms: [.iOS])),
            .product(name: "TreeSitterSwiftRunestone", package: "TreeSitterLanguages", condition: .when(platforms: [.iOS])),
            .product(name: "TreeSitterJSONRunestone", package: "TreeSitterLanguages", condition: .when(platforms: [.iOS])),
            .product(name: "TreeSitterJavaScriptRunestone", package: "TreeSitterLanguages", condition: .when(platforms: [.iOS])),
            .product(name: "TreeSitterCRunestone", package: "TreeSitterLanguages", condition: .when(platforms: [.iOS]))
        ]),
        .testTarget(name: "LunaCodeTests", dependencies: ["LunaCodeCore", "LunaCodeMac"])
    ], swiftLanguageModes: [.v5])
