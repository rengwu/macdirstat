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

        // The scripted probe, the virtual clock and the security-scope spy
        // (spec §9.2). A target rather than test-target sources, so every
        // suite shares one set of doubles and the shipping library carries
        // none of them. No product: nothing outside this package links it.
        .target(name: "ScanCoreTestSupport", dependencies: ["ScanCore"]),

        // Pure scanner: fake DirectoryProbe, virtual clock, event/state,
        // aggregation, errors, cancellation (spec §9.1).
        .testTarget(name: "ScanCoreTests", dependencies: ["ScanCore", "ScanCoreTestSupport"]),

        // Production FileManager probe against a small temporary tree (spec §9.1).
        .testTarget(name: "ScanCoreFileSystemTests", dependencies: ["ScanCore", "ScanCoreTestSupport"]),
    ]
)
