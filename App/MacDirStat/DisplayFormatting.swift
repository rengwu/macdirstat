import Foundation

/// All user-facing numeric formatting. `ByteCountFormatter` is intentionally
/// absent because it does not emit the IEC labels fixed by the specification.
///
/// The three `NumberFormatter`s each instance needs are built once, in
/// ``Storage``, and never reconfigured afterwards. Building one per call was
/// measurable: these methods run per tree cell, per progress tick and per
/// aggregate treemap label, and a Foundation formatter is not cheap to make.
/// Reuse is only safe because no formatting method mutates one — a formatter
/// that is configured in place per call cannot be shared, which is why the
/// three configurations live in three formatters rather than one.
struct DisplayFormatter {
    private static let units = ["bytes", "KiB", "MiB", "GiB", "TiB", "PiB"]

    let locale: Locale
    private let storage: Storage

    init(locale: Locale = .current) {
        self.locale = locale
        self.storage = Storage(locale: locale)
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

        return "\(storage.percentage.string(from: NSNumber(value: clamped)) ?? "0.0")%"
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
        storage.integer.string(from: NSNumber(value: value)) ?? String(value)
    }

    private func significant(_ value: Double) -> String {
        storage.significant.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// The three formatters, held by reference so that copying the value facade
    /// — which happens on every `init` a view controller takes — shares them
    /// instead of rebuilding them.
    private final class Storage {
        let integer: NumberFormatter
        let significant: NumberFormatter
        let percentage: NumberFormatter

        init(locale: Locale) {
            integer = Storage.decimal(locale: locale)
            integer.minimumFractionDigits = 0
            integer.maximumFractionDigits = 0
            integer.usesGroupingSeparator = true

            significant = Storage.decimal(locale: locale)
            significant.usesSignificantDigits = true
            significant.minimumSignificantDigits = 3
            significant.maximumSignificantDigits = 3
            significant.usesGroupingSeparator = true
            significant.roundingMode = .halfUp

            percentage = Storage.decimal(locale: locale)
            percentage.minimumFractionDigits = 1
            percentage.maximumFractionDigits = 1
            percentage.roundingMode = .halfUp
        }

        private static func decimal(locale: Locale) -> NumberFormatter {
            let formatter = NumberFormatter()
            formatter.locale = locale
            formatter.numberStyle = .decimal
            formatter.generatesDecimalNumbers = true
            return formatter
        }
    }
}
