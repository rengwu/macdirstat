// swift-tools-version:5.9
// TreemapLayout — the Foundation-only rectangle layout (spec §4.2, §6).

import PackageDescription

let package = Package(
    name: "TreemapLayout",
    // Deployment floor: macOS 14.
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TreemapLayout", targets: ["TreemapLayout"])
    ],
    targets: [
        // Foundation only — not even CoreGraphics: the geometry types are the
        // package's own, so the layout stays a pure, headlessly testable
        // function of (tree, viewport). Scripts/check-package-purity.sh
        // enforces this from the compiler's own import list.
        .target(name: "TreemapLayout"),

        // Pure geometry, merge buckets, hit testing, palette classification
        // (spec §9.1).
        .testTarget(name: "TreemapLayoutTests", dependencies: ["TreemapLayout"]),
    ]
)
