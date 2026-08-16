import Foundation
import ScanCore

enum ScanPhase: Equatable {
    case empty
    case scanning
    case completed
    case cancelled
    case failed
}

@MainActor
final class ScanPresentationModel {
    private let scanner: any Scanning
    private var consumingTask: Task<Void, Never>?

    private(set) var phase: ScanPhase = .empty
    private(set) var rootURL: URL?
    private(set) var mode: ScanMode = .folder
    private(set) var progress: ProgressSnapshot?
    private(set) var root: ScanNode?
    private(set) var result: ScanResult?
    private(set) var volumeCapacity: VolumeCapacity?
    private(set) var failure: ScanFailure?

    var onChange: (() -> Void)?

    init(scanner: any Scanning = Scanner()) {
        self.scanner = scanner
    }

    func start(root url: URL, mode: ScanMode) {
        consumingTask?.cancel()
        scanner.cancel()

        phase = .scanning
        rootURL = url
        self.mode = mode
        progress = nil
        root = nil
        result = nil
        volumeCapacity = nil
        failure = nil
        onChange?()

        let request = ScanRequest(
            root: url,
            mode: mode,
            probe: FileManagerDirectoryProbe(),
            options: ScanOptions(
                progressCadence: .minimumInterval(0.1),
                treeCadence: .minimumInterval(0.25)
            )
        )

        consumingTask = Task { [weak self] in
            guard let self else { return }
            let events = await scanner.scan(request)
            for await event in events {
                if Task.isCancelled { return }
                consume(event)
            }
        }
    }

    func cancel() {
        guard phase == .scanning else { return }
        scanner.cancel()
    }

    private func consume(_ event: ScanEvent) {
        switch event {
        case let .started(_, _, capacity):
            volumeCapacity = capacity
        case let .progress(snapshot):
            progress = snapshot
        case let .tree(snapshot):
            root = snapshot.root
        case let .finished(scanResult):
            result = scanResult
            root = scanResult.root
            volumeCapacity = scanResult.volumeCapacity
            phase = scanResult.reason == .cancelled ? .cancelled : .completed
        case let .failed(scanFailure):
            failure = scanFailure
            phase = .failed
        }
        onChange?()
    }
}
