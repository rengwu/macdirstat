import AppKit

enum SourceEligibility: Equatable {
    case eligible
    case ineligible(reason: String)
}

struct VolumeSourceFacts: Equatable {
    let url: URL
    let name: String
    var isLocal: Bool
    var isInternal: Bool
    var isRemovable: Bool
    var isUbiquitous: Bool
    var isDiskImage: Bool
    var totalCapacity: Int64?
    var availableCapacity: Int64?

    init(
        url: URL,
        name: String,
        isLocal: Bool,
        isInternal: Bool = false,
        isRemovable: Bool = false,
        isUbiquitous: Bool = false,
        isDiskImage: Bool = false,
        totalCapacity: Int64? = nil,
        availableCapacity: Int64? = nil
    ) {
        self.url = url
        self.name = name
        self.isLocal = isLocal
        self.isInternal = isInternal
        self.isRemovable = isRemovable
        self.isUbiquitous = isUbiquitous
        self.isDiskImage = isDiskImage
        self.totalCapacity = totalCapacity
        self.availableCapacity = availableCapacity
    }
}

struct SourceChoice: Equatable {
    let url: URL
    let name: String
    let detail: String
    let eligibility: SourceEligibility
    let totalCapacity: Int64?
    let availableCapacity: Int64?
}

enum SourceChooserModel {
    static func classify(_ facts: VolumeSourceFacts) -> SourceChoice {
        let eligibility: SourceEligibility
        if !facts.isLocal {
            eligibility = .ineligible(reason: "Network volumes aren’t supported.")
        } else if facts.isUbiquitous {
            eligibility = .ineligible(reason: "Cloud storage roots aren’t supported.")
        } else if facts.isDiskImage {
            eligibility = .ineligible(reason: "Disk images aren’t supported.")
        } else {
            eligibility = .eligible
        }

        let detail: String
        if facts.isInternal {
            detail = "Internal disk"
        } else if facts.isLocal {
            detail = "External disk"
        } else {
            detail = "Network volume"
        }
        return SourceChoice(
            url: facts.url,
            name: facts.name,
            detail: detail,
            eligibility: eligibility,
            totalCapacity: facts.totalCapacity,
            availableCapacity: facts.availableCapacity
        )
    }

    /// The accepted prototype intentionally hides ineligible sources. Their
    /// classifications remain explicit and unit-testable at the model seam.
    static func visibleChoices(from candidates: [VolumeSourceFacts]) -> [SourceChoice] {
        candidates.map(classify).filter { $0.eligibility == .eligible }
    }

    static func mountedVolumeFacts(fileManager: FileManager = .default) -> [VolumeSourceFacts] {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeIsLocalKey,
            .volumeIsInternalKey,
            .volumeIsRemovableKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .isUbiquitousItemKey,
        ]
        let urls = fileManager.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys),
            options: [.skipHiddenVolumes]
        ) ?? []

        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
            return VolumeSourceFacts(
                url: url,
                name: values.volumeName ?? url.lastPathComponent,
                isLocal: values.volumeIsLocal ?? true,
                isInternal: values.volumeIsInternal ?? false,
                isRemovable: values.volumeIsRemovable ?? false,
                isUbiquitous: values.isUbiquitousItem ?? false,
                // Big Sur has no reliable first-party resource key for a
                // directly selected disk-image volume; the accepted spec
                // records this residual gap instead of guessing.
                isDiskImage: false,
                totalCapacity: values.volumeTotalCapacity.map(Int64.init),
                availableCapacity: values.volumeAvailableCapacity.map(Int64.init)
            )
        }
    }
}

@MainActor
final class SourceChooserViewController: NSViewController {
    var onSelect: ((SourceChoice) -> Void)?
    var onChooseFolder: (() -> Void)?
    var onCancel: (() -> Void)?

    private let choices: [SourceChoice]
    private var indexedChoices: [Int: SourceChoice] = [:]

    init(choices: [SourceChoice]) {
        self.choices = choices
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 560, height: 360)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = NSView(frame: NSRect(origin: .zero, size: preferredContentSize))
        root.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Choose a Source")
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        let sourceStack = NSStackView()
        sourceStack.orientation = .vertical
        sourceStack.alignment = .leading
        sourceStack.spacing = 4

        for (index, choice) in choices.enumerated() {
            indexedChoices[index] = choice
            let button = NSButton(title: "", target: self, action: #selector(selectSource(_:)))
            button.tag = index
            button.bezelStyle = .inline
            button.image = NSImage(named: NSImage.computerName)
            button.imagePosition = .imageLeading
            button.alignment = .left
            let label = NSMutableAttributedString(
                string: choice.name,
                attributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .semibold)]
            )
            label.append(NSAttributedString(
                string: "\n\(choice.detail)",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            ))
            button.attributedTitle = label
            button.toolTip = choice.url.path
            sourceStack.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: sourceStack.widthAnchor).isActive = true
            button.heightAnchor.constraint(equalToConstant: 42).isActive = true
        }

        if choices.isEmpty {
            let noVolumes = NSTextField(labelWithString: "No eligible disks are mounted.")
            noVolumes.textColor = .secondaryLabelColor
            sourceStack.addArrangedSubview(noVolumes)
        }

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.documentView = sourceStack
        sourceStack.frame = NSRect(
            x: 0,
            y: 0,
            width: 520,
            height: max(220, CGFloat(max(1, choices.count)) * 46)
        )

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let folder = NSButton(title: "Choose Folder…", target: self, action: #selector(chooseFolder(_:)))
        folder.keyEquivalent = "\r"
        folder.bezelStyle = .rounded

        let buttons = NSStackView(views: [cancel, folder])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        [title, scrollView, buttons].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            scrollView.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            buttons.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 12),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])
        view = root
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    @objc private func selectSource(_ sender: NSButton) {
        guard let choice = indexedChoices[sender.tag] else { return }
        onSelect?(choice)
    }

    @objc private func chooseFolder(_ sender: Any?) {
        onChooseFolder?()
    }

    @objc private func cancelPressed(_ sender: Any?) {
        cancelOperation(sender)
    }
}
