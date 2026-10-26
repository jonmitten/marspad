// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "MarsPad", platforms: [.macOS(.v13)], products: [.executable(name: "MarsPad", targets: ["MarsPad"])], targets: [.executableTarget(name: "MarsPad", resources: [.copy("Resources/BlankProject.json.gz")]), .testTarget(name: "MarsPadTests", dependencies: ["MarsPad"])])
