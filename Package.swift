// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "OkDocker", platforms: [.macOS("26.0")], products: [.executable(name: "OkDocker", targets: ["OkDocker"])], targets: [.executableTarget(name: "OkDocker", path: "Sources/OkDocker", swiftSettings: [.swiftLanguageMode(.v5)]), .testTarget(name: "OkDockerTests", dependencies: ["OkDocker"], path: "tests/Swift")])
