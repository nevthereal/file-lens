// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FileLens",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "FileLens", targets: ["FileLens"])],
    targets: [
        .executableTarget(name: "FileLens"),
        .testTarget(name: "FileLensTests", dependencies: ["FileLens"])
    ],
    swiftLanguageModes: [.v5]
)
