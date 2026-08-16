// swift-tools-version:5.7
// ScanCore — the Foundation-only scan engine (spec §4.2, §5).

import PackageDescription

let package = Package(
    name: "ScanCore",
    // Deployment floor fixed at macOS 11.0 (spec §4.2).
    platforms: [.macOS(.v11)],
    products: [
        .library(name: "ScanCore", targets: ["ScanCore"])
    ],
    targets: [
        // Foundation only. No UI framework may be imported here or in the tests;
        // Scripts/check-package-purity.sh enforces this from the compiler's own
        // import list.
        .target(name: "ScanCore"),

        // Pure scanner: fake DirectoryProbe, virtual clock, event/state,
        // aggregation, errors, cancellation (spec §9.1).
        .testTarget(name: "ScanCoreTests", dependencies: ["ScanCore"]),

        // Production FileManager probe against a small temporary tree (spec §9.1).
        .testTarget(name: "ScanCoreFileSystemTests", dependencies: ["ScanCore"]),
    ]
)
