import AppKit
import SwiftUI
import TreemapLayout

/// The inspector's observable state.
///
/// The pane is a self-contained SwiftUI leaf hosted by `NSHostingController` —
/// the one shape §4.1 permits SwiftUI in, and the exact use it names. It is
/// never on the hot path: it repaints once per selection change, not per frame.
@MainActor
final class InspectorState: ObservableObject {
    @Published var content: InspectorContent?
    var onOpen: () -> Void = {}
    var onReveal: () -> Void = {}
}

@MainActor
final class InspectorViewController: NSViewController {
    let state = InspectorState()
    private lazy var hosting = NSHostingController(rootView: InspectorRootView(state: state))

    var onOpen: () -> Void {
        get { state.onOpen }
        set { state.onOpen = newValue }
    }

    var onReveal: () -> Void {
        get { state.onReveal }
        set { state.onReveal = newValue }
    }

    /// What the pane is currently describing. `nil` is the "select an item"
    /// placeholder.
    var content: InspectorContent? {
        get { state.content }
        set { state.content = newValue }
    }

    override func loadView() {
        let root = BackgroundView(color: .controlBackgroundColor)
        addChild(hosting)
        let hosted = hosting.view
        hosted.translatesAutoresizingMaskIntoConstraints = false
        // The hosted view fills the pane, and must not also ask the pane to be
        // its intrinsic height. A hosting view hugs its content strongly, and
        // with this pane pinned edge-to-edge that preference propagates all the
        // way up: the split view, the container and the window's whole content
        // area collapse to the height of whatever the inspector is showing.
        // Nothing below it pushes back, so the preference has to go.
        hosted.setContentHuggingPriority(.defaultLow, for: .vertical)
        hosted.setContentHuggingPriority(.defaultLow, for: .horizontal)
        root.addSubview(hosted)
        NSLayoutConstraint.activate([
            hosted.topAnchor.constraint(equalTo: root.topAnchor),
            hosted.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            hosted.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            hosted.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }
}

struct InspectorRootView: View {
    @ObservedObject var state: InspectorState

    var body: some View {
        Group {
            if let content = state.content {
                VStack(spacing: 0) {
                    ScrollView {
                        InspectorBody(content: content)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if content.showsActions {
                        Divider()
                        HStack(spacing: 8) {
                            Spacer(minLength: 0)
                            Button(FileActionMenu.openTitle, action: state.onOpen)
                            Button(FileActionMenu.revealTitle, action: state.onReveal)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color(nsColor: .controlBackgroundColor))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("Select an item in the tree\nor treemap to see its details.")
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct InspectorBody: View {
    let content: InspectorContent

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                SwatchView(swatch: content.swatch)
                Text(content.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(2)
            }
            Text(content.subtitle)
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(content.sizeText)
                    .font(.system(size: 22, weight: .medium))
                Text(content.sizeCaption)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            // Both figures, always: the IEC one to read, the exact one to check.
            Text(content.exactBytesText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(content.rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.label)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Spacer(minLength: 10)
                        Text(row.value)
                            .font(.system(size: 11))
                            .multilineTextAlignment(.trailing)
                    }
                }
            }

            if let path = content.path {
                Text(path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(Array(content.notes.enumerated()), id: \.offset) { _, note in
                NoteView(note: note)
            }

            if !content.sampleNames.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(content.sampleNames, id: \.self) { name in
                        Text(name)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    if content.additionalSampleCount > 0 {
                        Text("…and \(content.additionalSampleCount) more")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
            }

            if let footnote = content.footnote {
                Text(footnote)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct SwatchView: View {
    let swatch: InspectorContent.Swatch

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(color)
            .frame(width: 11, height: 11)
    }

    private var color: Color {
        switch swatch {
        case .directory, .merged:
            return .secondary
        case .kind(let group):
            let value = TreemapPalette.color(for: group, appearance: .light)
            return Color(.sRGB, red: value.red, green: value.green, blue: value.blue, opacity: 1)
        }
    }
}

private struct NoteView: View {
    let note: InspectorContent.Note

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(note.glyph)
                .font(.system(size: 11))
            VStack(alignment: .leading, spacing: 2) {
                Text(note.title)
                    .font(.system(size: 11, weight: .semibold))
                Text(note.detail)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(tint.opacity(0.12))
    }

    private var tint: Color {
        switch note.severity {
        case .info: return .accentColor
        case .warning: return .orange
        case .error: return .red
        }
    }
}
