// swift-tools-version: 6.2
// SuiteModelStore: one per-user, content-addressed store of model weights shared by every app in
// the suite. Standalone on purpose (it will move to its own repo): Foundation + CryptoKit only,
// no third-party dependencies, nothing imported from any app. Tests use swift-testing only.
import PackageDescription

let package = Package(
    name: "SuiteModelStore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "SuiteModelStore", targets: ["SuiteModelStore"]),
    ],
    targets: [
        .target(
            name: "SuiteModelStore",
            resources: [.copy("Resources/catalog.json")]
        ),
        .testTarget(
            name: "SuiteModelStoreTests",
            dependencies: ["SuiteModelStore"]
        ),
    ]
)
