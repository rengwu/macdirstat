import Foundation

/// The 11 kind groups plus gray "other" (spec §6.3).
public enum TreemapKindGroup: String, CaseIterable, Hashable, Sendable {
    case code
    case image
    case video
    case audio
    case document
    case archive
    case app
    case diskImage
    case font
    case data
    case system
    case other

    /// The legend's label for this group.
    public var displayName: String {
        switch self {
        case .code: return "Code"
        case .image: return "Image"
        case .video: return "Video"
        case .audio: return "Audio"
        case .document: return "Document"
        case .archive: return "Archive"
        case .app: return "Application"
        case .diskImage: return "Disk image"
        case .font: return "Font"
        case .data: return "Data"
        case .system: return "System"
        case .other: return "Other"
        }
    }
}

/// Which palette a colour is being asked for.
public enum TreemapAppearance: Hashable, Sendable {
    case light
    case dark
}

/// An sRGB colour, framework-free.
///
/// The package cannot see CoreGraphics or AppKit (spec §4.2), so it hands the
/// view plain components; `NSColor(srgbRed:green:blue:alpha:)` is the one line
/// at the boundary. Constructed from HSL because that is how §6.3 states the
/// encoding — one hue per kind, one lightness per appearance.
public struct TreemapColor: Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// - Parameters:
    ///   - hue: degrees, `0..<360`
    ///   - saturation: `0...1`
    ///   - lightness: `0...1`
    public init(hue: Double, saturation: Double, lightness: Double) {
        let h = hue.truncatingRemainder(dividingBy: 360) / 360
        let c = (1 - abs(2 * lightness - 1)) * saturation
        let x = c * (1 - abs((h * 6).truncatingRemainder(dividingBy: 2) - 1))
        let m = lightness - c / 2
        let (r, g, b): (Double, Double, Double)
        switch h * 6 {
        case ..<1: (r, g, b) = (c, x, 0)
        case ..<2: (r, g, b) = (x, c, 0)
        case ..<3: (r, g, b) = (0, c, x)
        case ..<4: (r, g, b) = (0, x, c)
        case ..<5: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        self.init(red: r + m, green: g + m, blue: b + m)
    }
}

/// Extension → kind group → hue (spec §6.3), fixed by the ticket-01 prototype.
///
/// The table is a **default, not a contract** — §6.3 calls the hues "tunable,
/// not load-bearing". What *is* load-bearing is that it is a pure function of
/// the name: the same extension gets the same colour on every run, on every
/// machine, with no hashing and no per-scan assignment.
public enum TreemapPalette {
    public static let saturation: Double = 0.55
    public static let lightness: (light: Double, dark: Double) = (0.52, 0.60)

    /// Hues in degrees, respaced during ticket 01: `system` sat at 220, ten
    /// degrees from `code` at 210, and the two swatches were indistinguishable
    /// in the legend and in the map. Closest pair is now 25°.
    ///
    /// `other` is gray — hue 0 at zero saturation — so it never reads as a
    /// classified kind.
    public static func hue(for group: TreemapKindGroup) -> Double {
        switch group {
        case .archive: return 0
        case .audio: return 25
        case .document: return 50
        case .data: return 90
        case .image: return 150
        case .font: return 180
        case .code: return 210
        case .diskImage: return 245
        case .video: return 280
        case .system: return 310
        case .app: return 335
        case .other: return 0
        }
    }

    public static func color(for group: TreemapKindGroup, appearance: TreemapAppearance) -> TreemapColor {
        TreemapColor(
            hue: hue(for: group),
            saturation: group == .other ? 0 : saturation,
            lightness: appearance == .dark ? lightness.dark : lightness.light
        )
    }

    /// The aggregate box's neutral base fill (spec §6.2: "visibly different …
    /// **not** any single kind-hue"). The view overlays the diagonal hatch in
    /// ``mergedBoxHatchColor(_:)`` on top of it; a hatch is a drawing concern,
    /// its two colours are palette facts.
    public static func mergedBoxFillColor(_ appearance: TreemapAppearance) -> TreemapColor {
        appearance == .dark
            ? TreemapColor(red: 0x4A / 255, green: 0x4A / 255, blue: 0x50 / 255)
            : TreemapColor(red: 0xBC / 255, green: 0xBC / 255, blue: 0xC3 / 255)
    }

    public static func mergedBoxHatchColor(_ appearance: TreemapAppearance) -> TreemapColor {
        appearance == .dark
            ? TreemapColor(red: 0x82 / 255, green: 0x82 / 255, blue: 0x8C / 255)
            : TreemapColor(red: 0x8C / 255, green: 0x8C / 255, blue: 0x95 / 255)
    }

    /// The kind group a file name classifies into: lowercased text after the
    /// last dot, looked up in the fixed table. A name with no dot, a dotfile
    /// with no further extension, or an unlisted extension is ``.other``.
    public static func group(forFileNamed name: String) -> TreemapKindGroup {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return .other }
        let ext = name[name.index(after: dot)...].lowercased()
        return extensionTable[ext] ?? .other
    }

    /// The extensions that classify into each group. Directories are not in
    /// here: they carry no fill of their own (spec §6.3).
    public static func extensions(for group: TreemapKindGroup) -> [String] {
        switch group {
        case .code:
            return ["swift", "m", "c", "cpp", "h", "js", "ts", "tsx", "py", "rb",
                    "go", "rs", "java", "kt", "sh", "json", "yml", "yaml", "xml",
                    "html", "css", "md", "lock"]
        case .image:
            return ["png", "jpg", "jpeg", "gif", "heic", "tiff", "bmp", "webp",
                    "svg", "raw", "icns", "photoslibrary"]
        case .video:
            return ["mp4", "mov", "mkv", "avi", "m4v", "webm"]
        case .audio:
            return ["mp3", "aac", "m4a", "wav", "flac", "ogg", "aiff"]
        case .document:
            return ["pdf", "doc", "docx", "rtf", "txt", "pages", "epub",
                    "numbers", "key", "xls", "xlsx", "ppt", "pptx", "csv"]
        case .archive:
            return ["zip", "tar", "gz", "tgz", "bz2", "xz", "rar", "7z", "zst"]
        case .app:
            return ["app", "pkg", "ipa"]
        case .diskImage:
            return ["dmg", "iso", "img", "sparseimage", "sparsebundle"]
        case .font:
            return ["ttf", "otf", "woff", "woff2", "ttc"]
        case .data:
            return ["sqlite", "db", "dat", "bin", "log", "idx", "pack"]
        case .system:
            return ["dylib", "so", "a", "framework", "kext", "plist", "cache"]
        case .other:
            return []
        }
    }

    private static let extensionTable: [String: TreemapKindGroup] = {
        var table: [String: TreemapKindGroup] = [:]
        for group in TreemapKindGroup.allCases {
            for ext in extensions(for: group) {
                table[ext] = group
            }
        }
        return table
    }()
}
