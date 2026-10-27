// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WindowSwitcher",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "WindowSwitcher", targets: ["WindowSwitcher"])],
    targets: [.executableTarget(name: "WindowSwitcher")],
    swiftLanguageVersions: [.v5]
)
