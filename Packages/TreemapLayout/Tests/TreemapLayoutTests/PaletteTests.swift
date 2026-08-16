import XCTest
@testable import TreemapLayout

/// Spec §6.3 as realized in the ticket-01 prototype: a fixed
/// extension → kind-group → hue table, 11 groups plus gray "other", the same
/// colour for the same extension on every run.
final class PaletteTests: XCTestCase {
    func test_thereAreElevenGroupsPlusOther() {
        XCTAssertEqual(TreemapKindGroup.allCases.count, 12)
        XCTAssertTrue(TreemapKindGroup.allCases.contains(.other))
    }

    func test_everySettledExtensionMapsToItsGroup() {
        let expected: [TreemapKindGroup: [String]] = [
            .code: ["swift", "m", "c", "cpp", "h", "js", "ts", "tsx", "py", "rb", "go", "rs",
                    "java", "kt", "sh", "json", "yml", "yaml", "xml", "html", "css", "md", "lock"],
            .image: ["png", "jpg", "jpeg", "gif", "heic", "tiff", "bmp", "webp", "svg", "raw",
                     "icns", "photoslibrary"],
            .video: ["mp4", "mov", "mkv", "avi", "m4v", "webm"],
            .audio: ["mp3", "aac", "m4a", "wav", "flac", "ogg", "aiff"],
            .document: ["pdf", "doc", "docx", "rtf", "txt", "pages", "epub", "numbers", "key",
                        "xls", "xlsx", "ppt", "pptx", "csv"],
            .archive: ["zip", "tar", "gz", "tgz", "bz2", "xz", "rar", "7z", "zst"],
            .app: ["app", "pkg", "ipa"],
            .diskImage: ["dmg", "iso", "img", "sparseimage", "sparsebundle"],
            .font: ["ttf", "otf", "woff", "woff2", "ttc"],
            .data: ["sqlite", "db", "dat", "bin", "log", "idx", "pack"],
            .system: ["dylib", "so", "a", "framework", "kext", "plist", "cache"],
        ]

        var seen = Set<String>()
        for (group, extensions) in expected {
            XCTAssertEqual(Set(TreemapPalette.extensions(for: group)), Set(extensions), "\(group) drifted")
            for ext in extensions {
                XCTAssertEqual(TreemapPalette.group(forFileNamed: "sample.\(ext)"), group, ".\(ext)")
                XCTAssertTrue(seen.insert(ext).inserted, ".\(ext) is claimed by two groups")
            }
        }
        XCTAssertEqual(seen.count, 98)
        XCTAssertTrue(TreemapPalette.extensions(for: .other).isEmpty, "\"other\" is the fallback, not a list")
    }

    func test_classificationIsCaseInsensitiveAndUsesTheLastExtension() {
        XCTAssertEqual(TreemapPalette.group(forFileNamed: "Photo.HEIC"), .image)
        XCTAssertEqual(TreemapPalette.group(forFileNamed: "archive.tar.gz"), .archive)
        XCTAssertEqual(TreemapPalette.group(forFileNamed: "Some.Long.Name.Swift"), .code)
    }

    func test_anythingUnclassifiableIsOther() {
        for name in ["Makefile", ".zshrc", "no-extension", "trailing.", "weird.qqq", ""] {
            XCTAssertEqual(TreemapPalette.group(forFileNamed: name), .other, name)
        }
    }

    /// The respaced hues from ticket 01: `system` moved off `code`'s shoulder,
    /// leaving 25° as the closest pair instead of 10°.
    func test_theHuesAreTheRespacedOnes() {
        XCTAssertEqual(TreemapPalette.hue(for: .archive), 0)
        XCTAssertEqual(TreemapPalette.hue(for: .audio), 25)
        XCTAssertEqual(TreemapPalette.hue(for: .document), 50)
        XCTAssertEqual(TreemapPalette.hue(for: .data), 90)
        XCTAssertEqual(TreemapPalette.hue(for: .image), 150)
        XCTAssertEqual(TreemapPalette.hue(for: .font), 180)
        XCTAssertEqual(TreemapPalette.hue(for: .code), 210)
        XCTAssertEqual(TreemapPalette.hue(for: .diskImage), 245)
        XCTAssertEqual(TreemapPalette.hue(for: .video), 280)
        XCTAssertEqual(TreemapPalette.hue(for: .system), 310)
        XCTAssertEqual(TreemapPalette.hue(for: .app), 335)
    }

    func test_noTwoClassifiedHuesSitCloserThanTwentyFiveDegrees() {
        let hues = TreemapKindGroup.allCases.filter { $0 != .other }.map { TreemapPalette.hue(for: $0) }.sorted()
        for (a, b) in zip(hues, hues.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b - a, 25, "\(a)° and \(b)° are too close to tell apart")
        }
        XCTAssertGreaterThanOrEqual(360 - (hues.last! - hues.first!), 25, "the wrap-around pair is too close")
    }

    func test_darkModeChangesOnlyLightness() {
        for group in TreemapKindGroup.allCases {
            let light = TreemapPalette.color(for: group, appearance: .light)
            let dark = TreemapPalette.color(for: group, appearance: .dark)
            XCTAssertNotEqual(light, dark, "\(group) does not adapt")

            let lightSum = light.red + light.green + light.blue
            let darkSum = dark.red + dark.green + dark.blue
            XCTAssertGreaterThan(darkSum, lightSum, "\(group) is not lighter in dark mode")
        }
        XCTAssertEqual(TreemapPalette.lightness.light, 0.52)
        XCTAssertEqual(TreemapPalette.lightness.dark, 0.60)
        XCTAssertEqual(TreemapPalette.saturation, 0.55)
    }

    func test_otherIsGrayAndEveryClassifiedGroupIsNot() {
        for appearance in [TreemapAppearance.light, .dark] {
            let other = TreemapPalette.color(for: .other, appearance: appearance)
            XCTAssertEqual(other.red, other.green, accuracy: 1e-12)
            XCTAssertEqual(other.green, other.blue, accuracy: 1e-12)

            for group in TreemapKindGroup.allCases where group != .other {
                let colour = TreemapPalette.color(for: group, appearance: appearance)
                XCTAssertGreaterThan(
                    max(colour.red, colour.green, colour.blue) - min(colour.red, colour.green, colour.blue),
                    0.1, "\(group) reads as gray"
                )
            }
        }
    }

    func test_sameExtensionMeansSameColourEveryTime() {
        let names = ["a.png", "zzz.png", "Photo.PNG", "nested.name.png"]
        let colours = Set(names.map { name -> TreemapColor in
            TreemapPalette.color(for: TreemapPalette.group(forFileNamed: name), appearance: .light)
        })
        XCTAssertEqual(colours.count, 1)
    }

    func test_hslConversionMatchesKnownAnchors() {
        assertColour(TreemapColor(hue: 0, saturation: 1, lightness: 0.5), 1, 0, 0)
        assertColour(TreemapColor(hue: 120, saturation: 1, lightness: 0.5), 0, 1, 0)
        assertColour(TreemapColor(hue: 240, saturation: 1, lightness: 0.5), 0, 0, 1)
        assertColour(TreemapColor(hue: 0, saturation: 0, lightness: 0.5), 0.5, 0.5, 0.5)
        assertColour(TreemapColor(hue: 210, saturation: 0, lightness: 1), 1, 1, 1)
        // hsl(210 55% 52%) — the `code` swatch, as the prototype renders it.
        assertColour(TreemapPalette.color(for: .code, appearance: .light), 0.256, 0.520, 0.784, accuracy: 0.001)
    }

    /// The aggregate's fill must not be mistakable for a kind (spec §6.2).
    func test_theMergedFillIsNeutralAndUnlikeEveryKindHue() {
        for appearance in [TreemapAppearance.light, .dark] {
            let fill = TreemapPalette.mergedBoxFillColor(appearance)
            XCTAssertLessThan(
                max(fill.red, fill.green, fill.blue) - min(fill.red, fill.green, fill.blue), 0.05,
                "the merged fill carries a hue"
            )
            XCTAssertNotEqual(fill, TreemapPalette.mergedBoxHatchColor(appearance))
        }
    }

    private func assertColour(
        _ colour: TreemapColor,
        _ red: Double, _ green: Double, _ blue: Double,
        accuracy: Double = 1e-9,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(colour.red, red, accuracy: accuracy, "red", file: file, line: line)
        XCTAssertEqual(colour.green, green, accuracy: accuracy, "green", file: file, line: line)
        XCTAssertEqual(colour.blue, blue, accuracy: accuracy, "blue", file: file, line: line)
    }
}
