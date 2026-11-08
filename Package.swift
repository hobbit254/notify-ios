// swift-tools-version: 6.0
import Foundation
import PackageDescription

// The tests use the monorepo's conformance mock, so the public copy (github.com/hobbit254/notify-ios,
// scripts/publish-public.sh) ships without them; declare the test target only where they exist.
let hasTests = FileManager.default.fileExists(
    atPath: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Tests").path)

let package = Package(
    name: "NotifySDK",
    platforms: [.iOS(.v16), .macOS(.v13)], // macOS: so the SDK and its tests also run with `swift test`
    products: [.library(name: "NotifySDK", targets: ["NotifySDK"])],
    targets: [.target(name: "NotifySDK", linkerSettings: [.linkedLibrary("sqlite3")])]
        + (hasTests ? [.testTarget(name: "NotifySDKTests", dependencies: ["NotifySDK"])] : [])
)
