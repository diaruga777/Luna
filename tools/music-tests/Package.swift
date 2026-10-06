// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "MusicFileTests", platforms: [.macOS(.v15)], dependencies: [.package(path: "../../LunaLibraries")], targets: [
    .testTarget(name: "MusicFileTests", dependencies: [
        .product(name: "LunaMusicFiles", package: "LunaLibraries"),
        .product(name: "LunaVaultMacPeer", package: "LunaLibraries"),
        .product(name: "LunaVaultBEP", package: "LunaLibraries"),
    ], path: "Tests")
], swiftLanguageModes: [.v5])
