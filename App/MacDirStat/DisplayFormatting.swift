import Foundation

/// All user-facing numeric formatting. `ByteCountFormatter` is intentionally
/// absent because it does not emit the IEC labels fixed by the specification.
struct DisplayFormatter {
    private static let units = ["bytes", "KiB", "MiB", "GiB", "TiB", "PiB"]

    let locale: Locale

    init(locale: Locale = .current) {
        self.locale = locale
    }

    func bytes(_ byteCount: Int64) -> String {
        let value = max(0, byteCount)
        guard value != 0 else { return "0 bytes" }
        guard value != 1 else { return "1 byte" }

        var scaled = Double(value)
        var unitIndex = 0
        while scaled >= 1_024, unitIndex < Self.units.count - 1 {
            scaled /= 1_024
            unitIndex += 1
        }

        if unitIndex == 0 {
            return "\(integer(value)) bytes"
        }
        return "\(significant(scaled)) \(Self.units[unitIndex])"
    }

    func exactBytes(_ byteCount: Int64) -> String {
        let value = max(0, byteCount)
        if value == 0 { return "0 bytes" }
        if value == 1 { return "1 byte" }
        return "\(integer(value)) bytes"
    }

    func count(_ value: Int64) -> String {
        integer(max(0, value))
    }

    /// A percentage value, where `12.3` means 12.3%.
    func percentage(_ value: Double) -> String {
        let clamped = min(100, max(0, value))
        if clamped == 0 { return "0%" }
        if clamped > 0, clamped < 0.05 { return "< 0.1%" }

        let formatter = decimalFormatter()
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        formatter.roundingMode = .halfUp
        return "\(formatter.string(from: NSNumber(value: clamped)) ?? "0.0")%"
    }

    func share(childBytes: Int64, parentBytes: Int64) -> String {
        guard parentBytes > 0 else { return percentage(0) }
        return percentage(Double(max(0, childBytes)) / Double(parentBytes) * 100)
    }

    func elapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Items per second, and deliberately not bytes per second.
    ///
    /// The scanner reads directory listings and never file contents, so a byte
    /// rate here was never a disk speed — before ticket 13 it was not even a
    /// rate of real bytes. Entries met over elapsed time is the only figure on
    /// that card that measures anything.
    func throughput(_ itemsPerSecond: Double) -> String {
        "\(count(Int64(max(0, itemsPerSecond)))) items/s"
    }

    private func integer(_ value: Int64) -> String {
        let formatter = decimalFormatter()
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 0
        formatter.usesGroupingSeparator = true
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private func significant(_ value: Double) -> String {
        let formatter = decimalFormatter()
        formatter.usesSignificantDigits = true
        formatter.minimumSignificantDigits = 3
        formatter.maximumSignificantDigits = 3
        formatter.usesGroupingSeparator = true
        formatter.roundingMode = .halfUp
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private func decimalFormatter() -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.generatesDecimalNumbers = true
        return formatter
    }
}
