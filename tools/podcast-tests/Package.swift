// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "PodcastTests", platforms: [.macOS(.v15)], dependencies: [.package(path: "../../LunaLibraries")], targets: [
    .testTarget(name: "PodcastTests", dependencies: [.product(name: "LunaPodcastCore", package: "LunaLibraries")], path: "Tests")
], swiftLanguageModes: [.v5])
