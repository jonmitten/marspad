// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "MarsPad", platforms: [.macOS(.v13)], products: [.executable(name: "MarsPad", targets: ["MarsPad"])], targets: [.executableTarget(name: "MarsPad"), .testTarget(name: "MarsPadTests", dependencies: ["MarsPad"])])
