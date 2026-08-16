import Darwin
import Foundation
import XCTest

/// The machine and build a set of numbers was taken on.
///
/// A memory figure without this is an anecdote. §8.1 states every bar against
/// one reference machine (M1, 8 GB, NVMe), so a record has to say plainly what
/// it actually ran on — including when that was *not* the reference machine, so
/// a reader can discount it rather than be misled by it.
struct PerformanceEnvironment: Codable, Equatable {
    var operatingSystem: String
    var hardwareModel: String
    var processor: String
    var architecture: String
    var processorCount: Int
    var physicalMemoryBytes: UInt64
    var buildConfiguration: String
    var sanitizers: String
    var generatorVersion: String
    var generatorSeed: String

    static func current() -> PerformanceEnvironment {
        let info = ProcessInfo.processInfo
        let version = info.operatingSystemVersion
        return PerformanceEnvironment(
            operatingSystem: "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
                + " (\(sysctlString("kern.osversion")))",
            hardwareModel: sysctlString("hw.model"),
            processor: sysctlString("machdep.cpu.brand_string"),
            architecture: currentArchitecture,
            processorCount: info.processorCount,
            physicalMemoryBytes: info.physicalMemory,
            buildConfiguration: buildConfiguration,
            // The plan disables all of them (spec §9.1); this reads what the
            // process actually has, so a record cannot claim otherwise.
            sanitizers: detectedSanitizers,
            generatorVersion: ScaleGenerator.version,
            generatorSeed: "0x" + String(ScaleGenerator.seed, radix: 16, uppercase: true)
        )
    }

    private static var buildConfiguration: String {
        #if DEBUG
        return "Debug"
        #else
        return "Release"
        #endif
    }

    private static var currentArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private static var detectedSanitizers: String {
        let environment = ProcessInfo.processInfo.environment
        var found: [String] = []
        if environment["DYLD_INSERT_LIBRARIES"]?.contains("libclang_rt.tsan") == true { found.append("thread") }
        if environment["DYLD_INSERT_LIBRARIES"]?.contains("libclang_rt.asan") == true { found.append("address") }
        if environment["NSZombieEnabled"] == "YES" { found.append("zombies") }
        if environment["MallocScribble"] == "1" { found.append("malloc-scribble") }
        return found.isEmpty ? "none" : found.joined(separator: ", ")
    }

    private static func sysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: buffer)
    }
}

/// One rung's result — everything the ticket asks a record to capture.
struct RungRecord: Codable, Equatable {
    var rung: String
    var entryCount: Int
    var directoryCount: Int
    var fileCount: Int
    var logicalBytes: Int64
    var attributedBytes: Int64
    var maximumDepth: Int

    var listOperations: Int
    var metadataOperations: Int
    var volumeInfoOperations: Int
    var totalOperations: Int
    var entriesReturned: Int

    /// The figure the §8.4 ceiling is asserted on.
    var peakFootprintBytes: UInt64
    var peakResidentBytes: UInt64
    var baselineFootprintBytes: UInt64
    /// Peak less baseline — a **lower bound** on what this rung cost, not the
    /// cost. See `measurementNotes` in the document.
    var footprintDeltaBytes: UInt64
    var bytesOfFootprintPerEntry: Double
    var memorySampleCount: Int

    var terminalState: String
    var completeness: String
    var errorTotal: Int
    var errorsTruncated: Bool
    var exclusionTotal: Int
    var hardLinkDuplicates: Int

    /// Diagnostic only. §8.2 refuses a wall-clock bar outright: the number is
    /// here so a regression is visible to a human, and it is asserted nowhere.
    var diagnosticElapsedSeconds: Double
    var diagnosticEntriesPerSecond: Double

    /// Treemap-at-scale figures, where the rung was laid out.
    var treemapViewport: String?
    var treemapVisibleBoxCount: Int?
    var treemapAggregateBoxCount: Int?
    var treemapMergedItemCount: Int?
    var treemapMaximumMergeRounds: Int?
    var treemapReachedRoundCap: Bool?
    var treemapDiagnosticLayoutSeconds: Double?
}

/// The whole record, accumulated across the suite and written out as it grows.
///
/// XCTest gives no "after every test in the bundle" hook that survives a
/// failure, and the rungs are spread over several classes whose order is not
/// ours to choose. So the file is rewritten after each rung: whatever ran is on
/// disk, complete and valid JSON, even if a later rung crashes the process —
/// which, on a suite whose whole subject is memory exhaustion, is a case worth
/// designing for.
final class PerformanceRecordStore {
    static let shared = PerformanceRecordStore()

    private let lock = NSLock()
    private let environment = PerformanceEnvironment.current()
    private var rungs: [RungRecord] = []
    private let startedAt = Date()

    private struct Document: Codable {
        var recordedAt: String
        var environment: PerformanceEnvironment
        var isReferenceMachine: Bool
        var referenceMachineNote: String
        var measurementNotes: [String]
        var rungs: [RungRecord]
    }

    /// What a reader has to know to interpret the columns without being misled.
    private static let measurementNotes = [
        """
        `peakFootprintBytes` is `task_vm_info.phys_footprint` — the figure macOS charges the \
        process and acts on under memory pressure — sampled every 10 ms on a separate thread \
        and again at every tree snapshot. It is the only number the §8.4 ceiling is asserted on.
        """,
        """
        `footprintDeltaBytes` (peak less this rung's starting footprint) is a **lower bound**, \
        not the rung's cost. Every rung runs in the one host process and macOS's allocator does \
        not hand freed pages straight back, so a rung that fits inside the arena an earlier rung \
        already grew shows a delta near zero. Where a rung ran from a low baseline — Large is \
        the one that matters — the delta is real.
        """,
        """
        Elapsed time and entries per second are diagnostic and are asserted nowhere: §8.2 \
        refuses a wall-clock or throughput bar outright, because scan speed is disk-bound and \
        not ours to own. The scripted rungs do no I/O at all, so their elapsed figures measure \
        the engine's own arithmetic and nothing else.
        """,
        """
        Rungs whose name ends `-materialized` were written to a real disk as sparse files and \
        scanned through the production `FileManagerDirectoryProbe`; every other rung was \
        computed on demand by the lazy generator and touched no filesystem. A materialized \
        rung's operation counts read zero because the production probe carries no counters — \
        the operation-count claims are proven on the scripted rungs, where the probe does.
        """
    ]

    /// §8.1 fixes the reference machine at an Apple Silicon M1 with 8 GB. A run
    /// on anything else is still worth recording — it is just not the run the
    /// bar was written against, and the record has to say so in the file rather
    /// than in somebody's memory of the afternoon.
    private var isReferenceMachine: Bool {
        environment.architecture == "arm64"
            && environment.physicalMemoryBytes <= 9_000_000_000
            && environment.processor.contains("M1")
    }

    private var referenceMachineNote: String {
        isReferenceMachine
            ? "Reference machine (spec §8.1): Apple Silicon M1, 8 GB, NVMe."
            : """
              NOT the reference machine of spec §8.1 (M1 / 8 GB / NVMe). Ran on \
              \(environment.processor) with \(environment.physicalMemoryBytes.formattedAsGibibytes) \
              of memory. The 8 GiB ceiling is asserted unchanged, because it is a ceiling on the \
              process and not on the host; but a machine with more memory swaps later, so a run \
              here can pass where the reference machine would thrash.
              """
    }

    func append(_ record: RungRecord, attachingTo testCase: XCTestCase? = nil) {
        lock.lock()
        rungs.removeAll { $0.rung == record.rung }
        rungs.append(record)
        let document = Document(
            recordedAt: ISO8601DateFormatter().string(from: startedAt),
            environment: environment,
            isReferenceMachine: isReferenceMachine,
            referenceMachineNote: referenceMachineNote,
            measurementNotes: Self.measurementNotes,
            rungs: rungs.sorted { $0.rung < $1.rung }
        )
        lock.unlock()

        guard let data = try? Self.encoder.encode(document) else { return }
        let directory = PerformanceRunPolicy.recordDirectory
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("MacDirStatPerformance", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("performance-record.json")
        try? data.write(to: url, options: .atomic)

        if let testCase {
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "performance-record-\(record.rung).json"
            attachment.lifetime = .keepAlways
            testCase.add(attachment)
        }
        print("[performance] \(Self.summary(of: record))")
        print("[performance] record written to \(url.path)")
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    static func summary(of record: RungRecord) -> String {
        """
        \(record.rung): \(record.entryCount) entries, \
        \(record.logicalBytes.formattedAsGibibytesSigned) logical, \
        \(record.totalOperations) operations, \
        peak footprint \(record.peakFootprintBytes.formattedAsGibibytes) \
        (from \(record.baselineFootprintBytes.formattedAsMebibytes), \
        +\(record.footprintDeltaBytes.formattedAsMebibytes) ≥ this rung's cost), \
        \(record.terminalState)/\(record.completeness), \
        \(String(format: "%.2f", record.diagnosticElapsedSeconds)) s [diagnostic]
        """
    }
}

extension Int64 {
    var formattedAsGibibytesSigned: String {
        String(format: "%.2f GiB", Double(self) / 1_073_741_824)
    }
}
