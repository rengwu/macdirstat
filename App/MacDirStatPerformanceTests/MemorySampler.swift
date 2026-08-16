import Darwin
import Foundation

/// This process's memory, read from the kernel rather than from a counter the
/// suite keeps itself.
///
/// **Physical footprint, not resident size, is the number the ceiling is
/// about.** `phys_footprint` is what macOS charges a process — dirty and
/// compressed anonymous memory plus its share of dirty file-backed pages — and
/// it is what jetsam and the memory-pressure machinery act on. `resident_size`
/// omits everything the compressor has swallowed, so on a machine under
/// pressure it *falls* as the process gets worse. Both are recorded; the
/// assertion is on the footprint.
enum MemoryProbe {
    struct Sample: Equatable {
        var physicalFootprint: UInt64
        var residentSize: UInt64
    }

    static func sample() -> Sample {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return Sample(physicalFootprint: 0, residentSize: 0) }
        return Sample(
            physicalFootprint: UInt64(info.phys_footprint),
            residentSize: UInt64(info.resident_size)
        )
    }

    /// The kernel's own high-water mark for resident size since launch, in
    /// bytes on Darwin. A cross-check on the sampler: a peak the sampler missed
    /// between two ticks still shows up here.
    static func peakResidentSizeSinceLaunch() -> UInt64 {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return UInt64(usage.ru_maxrss)
    }
}

/// Samples memory on its own thread for the duration of one rung.
///
/// A scan is one long synchronous run inside a detached task, so nothing on the
/// scanning side can be relied on to sample itself; and the peak of interest
/// may well be in the middle rather than at the end. A separate thread ticking
/// every few milliseconds is the cheapest honest answer — and `sample()` is
/// public so a test can also force a reading at a moment it knows matters, such
/// as the instant a terminal snapshot arrives.
final class PeakMemorySampler {
    private let interval: TimeInterval
    private let lock = NSLock()
    private var isRunning = false
    private var peak = MemoryProbe.Sample(physicalFootprint: 0, residentSize: 0)
    private var baseline = MemoryProbe.Sample(physicalFootprint: 0, residentSize: 0)
    private var samples = 0

    init(interval: TimeInterval = 0.01) {
        self.interval = interval
    }

    private(set) var startedAt: Date = .distantPast

    func start() {
        let first = MemoryProbe.sample()
        lock.lock()
        isRunning = true
        baseline = first
        peak = first
        samples = 1
        lock.unlock()
        startedAt = Date()

        let thread = Thread { [weak self] in
            while let self, self.tick() {
                Thread.sleep(forTimeInterval: self.interval)
            }
        }
        thread.name = "MacDirStat performance memory sampler"
        // Above the default so the sampler is not the thing that gets starved
        // when the scan saturates the machine; still below the scan itself.
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    @discardableResult
    func sample() -> MemoryProbe.Sample {
        let current = MemoryProbe.sample()
        lock.lock()
        peak.physicalFootprint = max(peak.physicalFootprint, current.physicalFootprint)
        peak.residentSize = max(peak.residentSize, current.residentSize)
        samples += 1
        lock.unlock()
        return current
    }

    struct Reading {
        var baseline: MemoryProbe.Sample
        var peak: MemoryProbe.Sample
        var final: MemoryProbe.Sample
        var sampleCount: Int
        var elapsed: TimeInterval
        /// Peak footprint less what the process already held when the rung
        /// began. Every rung runs in one host process, so the absolute peak
        /// carries whatever an earlier rung left behind; the delta is what
        /// *this* rung cost. The 8 GiB bar is on the absolute figure, because
        /// that is the number the machine has to survive.
        var footprintDelta: UInt64 {
            peak.physicalFootprint > baseline.physicalFootprint
                ? peak.physicalFootprint - baseline.physicalFootprint
                : 0
        }
    }

    @discardableResult
    func stop() -> Reading {
        let last = sample()
        lock.lock()
        isRunning = false
        let reading = Reading(
            baseline: baseline,
            peak: peak,
            final: last,
            sampleCount: samples,
            elapsed: Date().timeIntervalSince(startedAt)
        )
        lock.unlock()
        return reading
    }

    private func tick() -> Bool {
        let current = MemoryProbe.sample()
        lock.lock()
        defer { lock.unlock() }
        guard isRunning else { return false }
        peak.physicalFootprint = max(peak.physicalFootprint, current.physicalFootprint)
        peak.residentSize = max(peak.residentSize, current.residentSize)
        samples += 1
        return true
    }
}

extension UInt64 {
    /// Bytes as GiB, for a message a human reads once and understands.
    var formattedAsGibibytes: String {
        String(format: "%.3f GiB", Double(self) / 1_073_741_824)
    }

    var formattedAsMebibytes: String {
        String(format: "%.1f MiB", Double(self) / 1_048_576)
    }
}
