// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Qingyan",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Qingyan", targets: ["Qingyan"])],
    targets: [
        .target(name: "QingyanCore"),
        .target(name: "AudioCapture"),
        .executableTarget(name: "Qingyan", dependencies: ["QingyanCore", "AudioCapture"]),
        .executableTarget(name: "QingyanChecks", dependencies: ["QingyanCore"], path: "Tests/QingyanCoreTests")
    ],
    swiftLanguageModes: [.v5]
)
