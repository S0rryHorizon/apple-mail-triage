// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "MailBridge",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "MailBridgeCore", targets: ["MailBridgeCore"]),
    .executable(name: "MailBridge", targets: ["MailBridge"]),
    .executable(name: "MailBridgeSelfTest", targets: ["MailBridgeSelfTest"]),
  ],
  targets: [
    .target(name: "MailBridgeCore"),
    .target(
      name: "MailBridgeRuntime",
      dependencies: ["MailBridgeCore"],
      linkerSettings: [.linkedLibrary("sqlite3")]
    ),
    .executableTarget(name: "MailBridge", dependencies: ["MailBridgeRuntime", "MailBridgeCore"]),
    .executableTarget(name: "MailBridgeSelfTest", dependencies: ["MailBridgeCore"]),
    .executableTarget(
      name: "MailBridgeSyntheticDemo",
      dependencies: ["MailBridgeRuntime", "MailBridgeCore"]
    ),
    .executableTarget(
      name: "MailBridgeSyntheticTests",
      dependencies: ["MailBridgeRuntime", "MailBridgeCore"],
      path: "Tests/Swift"
    ),
  ]
)
