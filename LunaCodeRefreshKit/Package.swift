// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "LunaCodeRefreshKit", platforms: [.iOS(.v26), .macOS(.v15)],
 products: [.library(name: "LunaCodeRefresh", targets: ["LunaCodeRefresh"])],
 dependencies: [.package(path: "../LunaCodeKit"), .package(path: "Vendor/DeviceGateway"),
 .package(url: "https://github.com/SideStore/SideSign.git", revision: "752d1ef602aa792a432ffa1e71646dc1ecf7363c")],
 targets: [.target(name: "LunaCodeRefresh", dependencies: [.product(name: "LunaCodeCore", package: "LunaCodeKit"),
 .product(name: "SideSign", package: "SideSign"), .product(name: "IdeviceGateway", package: "DeviceGateway")]),
 .testTarget(name: "LunaCodeRefreshTests", dependencies: ["LunaCodeRefresh", .product(name: "IdeviceGateway", package: "DeviceGateway"), .product(name: "SideSign", package: "SideSign")])], swiftLanguageModes: [.v5])
