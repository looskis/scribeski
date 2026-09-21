// swift-tools-version: 6.2
// Everything except the app shell lives here, so it builds and tests with the
// Command Line Tools alone. Tests use swift-testing only (XCTest is missing under CLT).
import PackageDescription

let package = Package(
    name: "Scribeski",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ScribeskiCore", targets: ["ScribeskiCore"]),
        .executable(name: "scribeski", targets: ["scribeski"]),
        // The Xcode app target (App/Scribeski.xcodeproj) links this.
        .library(name: "ScribeskiUI", targets: ["ScribeskiUI"]),
    ],
    dependencies: [
        // Suite-wide model store (DESIGN §4a). Moves to its own repo once a second tool adopts it.
        .package(path: "Packages/SuiteModelStore"),
        // Parakeet TDT (CoreML, Neural Engine) for the default ASR engine (DESIGN §3). Pre-1.0,
        // so pinned exactly. No traits: we don't need its text-normalization binary.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.16.1", traits: []),
    ],
    targets: [
        // Contracts (BUILD_PLAN §4) and pure types. No I/O.
        .target(name: "ScribeskiCore"),
        // Safari transport, page-bundle loader, job protocol.
        .target(
            name: "FormDriver",
            dependencies: ["ScribeskiCore"],
            resources: [.copy("Resources/scribeski-page.js")]
        ),
        // Prompt builder, LLM client, schema builder, verifier, scorers.
        .target(
            name: "Extraction",
            dependencies: ["ScribeskiCore", .product(name: "SuiteModelStore", package: "SuiteModelStore")]
        ),
        // SpeexDSP's echo canceller, vendored (BSD): the mic hears the call through speakers.
        .target(
            name: "CSpeexEcho",
            exclude: ["COPYING", "README.md"],
            cSettings: [
                .define("FLOATING_POINT"), .define("USE_SMALLFT"), .define("EXPORT", to: ""),
                .unsafeFlags(["-w"]), // upstream C; its warnings aren't ours to fix
            ]
        ),
        // Phase 2: call-app discovery, process tap, aggregate device, segmenter, audio tee.
        .target(name: "Capture", dependencies: ["ScribeskiCore", "CSpeexEcho"]),
        // Phase 2: Transcriber protocol, SpeechAnalyzer and Parakeet adapters, live session.
        .target(
            name: "Transcription",
            dependencies: [
                "ScribeskiCore", "Capture",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "SuiteModelStore", package: "SuiteModelStore"),
            ]
        ),
        // Phase 3: Keychain, encrypted blobs, metadata, audit log.
        .target(name: "Storage", dependencies: ["ScribeskiCore"]),
        // Phase 3: transcript → profile → extract (locked-down sidecar) → fill.
        .target(name: "Orchestrator", dependencies: ["ScribeskiCore", "Extraction", "FormDriver"]),
        // Menu-bar UI: views and the session model. Drivers plug in behind `SessionDriver`.
        .target(name: "ScribeskiUI", dependencies: [
            "ScribeskiCore", "Capture", "Transcription", "Orchestrator", "Storage", "Extraction", "FormDriver",
            .product(name: "SuiteModelStore", package: "SuiteModelStore"),
        ]),
        // Dev CLI.
        .executableTarget(
            name: "scribeski",
            dependencies: [
                "ScribeskiCore", "FormDriver", "Extraction", "Orchestrator", "Transcription",
                .product(name: "SuiteModelStore", package: "SuiteModelStore"),
            ]
        ),
        .testTarget(name: "ExtractionTests", dependencies: ["Extraction", "ScribeskiCore"]),
        .testTarget(name: "CaptureTests", dependencies: ["Capture"]),
        .testTarget(name: "StorageTests", dependencies: ["Storage", "ScribeskiCore"]),
        .testTarget(name: "OrchestratorTests", dependencies: ["Orchestrator", "FormDriver", "ScribeskiCore"]),
        .testTarget(name: "TranscriptionTests", dependencies: ["Transcription", "Capture", "ScribeskiCore"]),
        .testTarget(name: "ScribeskiUITests", dependencies: ["ScribeskiUI", "Capture", "ScribeskiCore", "Orchestrator", "FormDriver", "Transcription"]),
        .testTarget(name: "FormDriverTests", dependencies: ["FormDriver", "ScribeskiCore"]),
        .testTarget(
            name: "ScribeskiCoreTests",
            dependencies: ["ScribeskiCore"],
            resources: [.copy("Examples")]
        ),
    ]
)
