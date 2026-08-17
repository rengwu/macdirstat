import Foundation
import ScanCore

/// A clock that only moves when a test moves it.
///
/// Throttling is the one part of the engine whose correctness is a statement
/// about *time*, and a test that asserts it against the wall clock asserts the
/// speed of the machine instead. Driving time by hand makes "≤ 15 Hz" an exact
/// claim.
public final class VirtualClock: ScanClock, @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: TimeInterval

    public init(now: TimeInterval = 0) {
        self.seconds = now
    }

    public var now: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return seconds
    }

    public func advance(by interval: TimeInterval) {
        lock.lock()
        seconds += interval
        lock.unlock()
    }
}

/// Records every start/stop of security-scoped access, so a test can prove the
/// claim is balanced **exactly once** on success, failure, cancellation and
/// replacement (spec §9.2).
public final class SpySecurityScopedAccess: SecurityScopedAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    private var stops = 0
    private let startResult: Bool

    /// - Parameter startSucceeds: what `startAccessing` reports. `false` models
    ///   a URL that carries no security scope, for which no stop is owed.
    public init(startSucceeds: Bool = true) {
        self.startResult = startSucceeds
    }

    public var startCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return starts
    }

    public var stopCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return stops
    }

    public func startAccessing(_ url: URL) -> Bool {
        lock.lock()
        starts += 1
        lock.unlock()
        return startResult
    }

    public func stopAccessing(_ url: URL) {
        lock.lock()
        stops += 1
        lock.unlock()
    }
}
