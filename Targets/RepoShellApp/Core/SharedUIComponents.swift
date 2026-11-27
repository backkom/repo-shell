import Cocoa
import SwiftUI
import UniformTypeIdentifiers
import RepoShellShared
import RepoShellVcs

// MARK: - Shared Native File Icon Cache

@MainActor
enum SharedFileIconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(forPath path: String, isDirectory: Bool) -> NSImage {
        let ext = isDirectory ? "" : URL(fileURLWithPath: path).pathExtension.lowercased()
        let key = isDirectory ? "__dir__" : (ext.isEmpty ? "__file__" : ext)
        if let hit = cache[key] {
            return hit
        }
        let img: NSImage
        if isDirectory {
            img = NSWorkspace.shared.icon(for: .folder)
        } else if !ext.isEmpty, let ut = UTType(filenameExtension: ext) {
            img = NSWorkspace.shared.icon(for: ut)
        } else {
            img = NSWorkspace.shared.icon(for: .data)
        }
        img.size = NSSize(width: 16, height: 16)
        cache[key] = img
        return img
    }
}

struct FileTypeIconView: View {
    let path: String
    var isDirectory: Bool = false
    var size: CGFloat = 15

    var body: some View {
        Image(nsImage: SharedFileIconCache.icon(forPath: path, isDirectory: isDirectory))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

// MARK: - Search Input Field

struct SearchInputField: View {
    let placeholder: String
    @Binding var text: String
    var width: CGFloat? = nil
    var onSubmit: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onSubmit {
                    onSubmit?()
                }
            if !text.isEmpty {
                Button {
                    text = ""
                    onSubmit?()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help(L("Clear", "清除"))
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .frame(width: width)
        .background(Color(nsColor: .textBackgroundColor))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }
}

// MARK: - Reusable Table Column Header Bar

struct TableColumnSpec: Identifiable {
    let id: String
    let title: String
    var width: CGFloat? = nil
    var alignment: Alignment = .leading

    init(_ title: String, width: CGFloat? = nil, alignment: Alignment = .leading) {
        self.id = title + (width.map { "_\($0)" } ?? "_flex")
        self.title = title
        self.width = width
        self.alignment = alignment
    }
}

struct TableColumnHeaderBar: View {
    let columns: [TableColumnSpec]
    var horizontalPadding: CGFloat = 12
    var spacing: CGFloat = 8

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: spacing) {
                ForEach(Array(columns.enumerated()), id: \.element.id) { idx, col in
                    if idx > 0 {
                        Rectangle()
                            .fill(Color(nsColor: .separatorColor).opacity(0.6))
                            .frame(width: 1, height: 12)
                    }
                    Group {
                        if let w = col.width {
                            Text(col.title)
                                .frame(width: w, alignment: col.alignment)
                        } else {
                            Text(col.title)
                                .frame(maxWidth: .infinity, alignment: col.alignment)
                        }
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                }
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, 5)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.85))

            Divider()
        }
    }
}

// MARK: - Action & Diff Badges

struct VcsActionBadge: View {
    let action: String

    var body: some View {
        Text(action)
            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
            .frame(width: 20, height: 17)
            .background(color.opacity(0.16))
            .foregroundColor(color)
            .cornerRadius(3.5)
    }

    private var color: Color {
        switch action {
        case "A": return .green
        case "D": return .red
        case "R", "C": return .purple
        case "U": return .pink
        default: return .orange
        }
    }
}

struct DiffLineStatsBadge: View {
    let additions: Int
    let deletions: Int

    var body: some View {
        HStack(spacing: 4) {
            Text("+\(additions)")
                .foregroundColor(additions > 0 ? Color(red: 0.14, green: 0.58, blue: 0.24) : .secondary)
            Text("-\(deletions)")
                .foregroundColor(deletions > 0 ? Color(red: 0.80, green: 0.18, blue: 0.18) : .secondary)
        }
        .font(.system(size: 11, design: .monospaced).monospacedDigit())
    }
}

// MARK: - Git Commit Graph Engine & Renderer

struct CommitGraphSegment: Hashable {
    let fromLane: Int
    let toLane: Int
    let colorIndex: Int
}

struct CommitGraphNodeLayout: Equatable {
    let lane: Int
    let colorIndex: Int
    let isMerge: Bool
    let incomingSegments: [CommitGraphSegment]
    let outgoingSegments: [CommitGraphSegment]
    let maxLanes: Int
}

enum CommitGraphLayoutEngine {
    static func computeLayouts(for commits: [VcsCommit]) -> [String: CommitGraphNodeLayout] {
        var result: [String: CommitGraphNodeLayout] = [:]
        var activeHashes: [String?] = []
        var activeColors: [Int] = []
        var nextColorSeed = 0

        for commit in commits {
            // 1. Find lanes currently waiting for this commit
            var matchingIndices: [Int] = []
            for (idx, h) in activeHashes.enumerated() where h == commit.hash {
                matchingIndices.append(idx)
            }

            let commitLane: Int
            let commitColor: Int
            if let first = matchingIndices.first {
                commitLane = first
                commitColor = activeColors[first]
            } else {
                // Allocate first free lane or append
                if let emptyIdx = activeHashes.firstIndex(where: { $0 == nil }) {
                    commitLane = emptyIdx
                } else {
                    commitLane = activeHashes.count
                    activeHashes.append(nil)
                    activeColors.append(0)
                }
                commitColor = nextColorSeed
                nextColorSeed += 1
                activeColors[commitLane] = commitColor
            }

            // Incoming segments from previous row's active lanes into this row
            var incoming: [CommitGraphSegment] = []
            for (idx, h) in activeHashes.enumerated() where h != nil {
                if matchingIndices.contains(idx) {
                    incoming.append(CommitGraphSegment(fromLane: idx, toLane: commitLane, colorIndex: activeColors[idx]))
                } else {
                    incoming.append(CommitGraphSegment(fromLane: idx, toLane: idx, colorIndex: activeColors[idx]))
                }
            }

            // Collapse extra matching lanes
            for idx in matchingIndices.dropFirst() {
                activeHashes[idx] = nil
            }
            activeHashes[commitLane] = nil

            // 2. Assign parents to outgoing lanes
            var outgoing: [CommitGraphSegment] = []
            for (idx, h) in activeHashes.enumerated() where h != nil {
                outgoing.append(CommitGraphSegment(fromLane: idx, toLane: idx, colorIndex: activeColors[idx]))
            }

            for (pIdx, parentHash) in commit.parents.enumerated() {
                if let existingLane = activeHashes.firstIndex(where: { $0 == parentHash }) {
                    let segColor = pIdx == 0 ? commitColor : activeColors[existingLane]
                    outgoing.append(CommitGraphSegment(fromLane: commitLane, toLane: existingLane, colorIndex: segColor))
                } else if pIdx == 0 && activeHashes[commitLane] == nil {
                    activeHashes[commitLane] = parentHash
                    activeColors[commitLane] = commitColor
                    outgoing.append(CommitGraphSegment(fromLane: commitLane, toLane: commitLane, colorIndex: commitColor))
                } else {
                    let targetLane: Int
                    if let freeIdx = activeHashes.firstIndex(where: { $0 == nil }) {
                        targetLane = freeIdx
                    } else {
                        targetLane = activeHashes.count
                        activeHashes.append(nil)
                        activeColors.append(0)
                    }
                    let newColor = nextColorSeed
                    nextColorSeed += 1
                    activeHashes[targetLane] = parentHash
                    activeColors[targetLane] = newColor
                    outgoing.append(CommitGraphSegment(fromLane: commitLane, toLane: targetLane, colorIndex: newColor))
                }
            }

            // Trim trailing nils
            while let last = activeHashes.last, last == nil {
                activeHashes.removeLast()
                activeColors.removeLast()
            }

            let maxLaneInRow = max(
                commitLane + 1,
                activeHashes.count,
                (incoming.map { max($0.fromLane, $0.toLane) }.max() ?? 0) + 1,
                (outgoing.map { max($0.fromLane, $0.toLane) }.max() ?? 0) + 1
            )

            result[commit.id] = CommitGraphNodeLayout(
                lane: commitLane,
                colorIndex: commitColor,
                isMerge: commit.parents.count > 1,
                incomingSegments: incoming,
                outgoingSegments: outgoing,
                maxLanes: maxLaneInRow
            )
        }
        return result
    }
}

struct CommitGraphCellView: View {
    let layout: CommitGraphNodeLayout

    private static let palette: [Color] = [
        Color(red: 0.16, green: 0.52, blue: 0.96),
        Color(red: 0.20, green: 0.68, blue: 0.36),
        Color(red: 0.92, green: 0.50, blue: 0.12),
        Color(red: 0.62, green: 0.34, blue: 0.88),
        Color(red: 0.88, green: 0.24, blue: 0.42),
        Color(red: 0.12, green: 0.68, blue: 0.68),
        Color(red: 0.78, green: 0.56, blue: 0.08),
    ]

    var body: some View {
        Canvas { context, size in
            let laneStep: CGFloat = 12
            let leftPad: CGFloat = 9
            let midY = size.height / 2

            func xFor(_ lane: Int) -> CGFloat {
                leftPad + CGFloat(min(lane, 8)) * laneStep
            }

            func colorFor(_ idx: Int) -> Color {
                Self.palette[abs(idx) % Self.palette.count]
            }

            // Incoming segments (top -> midY)
            for seg in layout.incomingSegments {
                let x1 = xFor(seg.fromLane)
                let x2 = xFor(seg.toLane)
                var path = Path()
                path.move(to: CGPoint(x: x1, y: 0))
                if seg.fromLane == seg.toLane {
                    path.addLine(to: CGPoint(x: x2, y: midY))
                } else {
                    path.addCurve(
                        to: CGPoint(x: x2, y: midY),
                        control1: CGPoint(x: x1, y: midY * 0.55),
                        control2: CGPoint(x: x2, y: midY * 0.45)
                    )
                }
                context.stroke(path, with: .color(colorFor(seg.colorIndex).opacity(0.85)), lineWidth: 1.75)
            }

            // Outgoing segments (midY -> bottom)
            for seg in layout.outgoingSegments {
                let x1 = xFor(seg.fromLane)
                let x2 = xFor(seg.toLane)
                var path = Path()
                path.move(to: CGPoint(x: x1, y: midY))
                if seg.fromLane == seg.toLane {
                    path.addLine(to: CGPoint(x: x2, y: size.height))
                } else {
                    path.addCurve(
                        to: CGPoint(x: x2, y: size.height),
                        control1: CGPoint(x: x1, y: midY + (size.height - midY) * 0.55),
                        control2: CGPoint(x: x2, y: midY + (size.height - midY) * 0.45)
                    )
                }
                context.stroke(path, with: .color(colorFor(seg.colorIndex).opacity(0.85)), lineWidth: 1.75)
            }

            // Node circle
            let cx = xFor(layout.lane)
            let radius: CGFloat = layout.isMerge ? 4.3 : 3.6
            let nodeRect = CGRect(x: cx - radius, y: midY - radius, width: radius * 2, height: radius * 2)
            let nodeColor = colorFor(layout.colorIndex)
            context.fill(Path(ellipseIn: nodeRect), with: .color(nodeColor))
            context.stroke(Path(ellipseIn: nodeRect), with: .color(Color(nsColor: .controlBackgroundColor)), lineWidth: 1.2)
        }
    }
}

// MARK: - Shared Cached Date Formatters

@MainActor
enum SharedDateFormatters {
    static let abbreviatedDateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    static let numericDateOnly: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        return f
    }()
}

// MARK: - List Row Double Click

@MainActor
private final class ListRowDoubleClickRegistry {
    static let shared = ListRowDoubleClickRegistry()

    private final class WeakBox {
        weak var view: ListRowDoubleClickNSView?
        init(_ view: ListRowDoubleClickNSView) { self.view = view }
    }

    private var entries: [ObjectIdentifier: WeakBox] = [:]
    private var monitor: Any?

    func register(_ view: ListRowDoubleClickNSView) {
        entries[ObjectIdentifier(view)] = WeakBox(view)
        ensureMonitor()
    }

    func unregister(_ view: ListRowDoubleClickNSView) {
        entries.removeValue(forKey: ObjectIdentifier(view))
        pruneAndUpdateMonitor()
    }

    private func pruneAndUpdateMonitor() {
        entries = entries.filter { $0.value.view != nil }
        if entries.isEmpty, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func ensureMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleMouseDown(event)
            }
            return event
        }
    }

    private func handleMouseDown(_ event: NSEvent) {
        guard event.clickCount == 2,
              event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty,
              let eventWindow = event.window else {
            return
        }
        pruneAndUpdateMonitor()
        let views = entries.values.compactMap(\.view)
        for view in views {
            guard view.window === eventWindow,
                  !view.isHiddenOrHasHiddenAncestor else {
                continue
            }
            let localPoint = view.convert(event.locationInWindow, from: nil)
            guard view.visibleRect.contains(localPoint) else {
                continue
            }
            let action = view.onDoubleClick
            DispatchQueue.main.async {
                action()
            }
            break
        }
    }
}

private final class ListRowDoubleClickNSView: NSView {
    var onDoubleClick: () -> Void = {}

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            ListRowDoubleClickRegistry.shared.register(self)
        } else {
            ListRowDoubleClickRegistry.shared.unregister(self)
        }
    }
}

private struct ListRowDoubleClickRepresentable: NSViewRepresentable {
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> ListRowDoubleClickNSView {
        let view = ListRowDoubleClickNSView()
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ nsView: ListRowDoubleClickNSView, context: Context) {
        nsView.onDoubleClick = onDoubleClick
    }

    static func dismantleNSView(_ nsView: ListRowDoubleClickNSView, coordinator: ()) {
        ListRowDoubleClickRegistry.shared.unregister(nsView)
    }
}

extension View {
    /// Detects double-clicks inside a `List(selection:)` row without installing a SwiftUI
    /// `TapGesture` that intercepts single-click selection on macOS.
    func onListRowDoubleClick(perform action: @escaping () -> Void) -> some View {
        background(ListRowDoubleClickRepresentable(onDoubleClick: action))
    }
}

// MARK: - Native NSTableView Log Commit List

enum LogTableLayoutStyle: Equatable {
    case git
    case svn
}

final class ClosureMenuItem: NSMenuItem {
    private var handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invokeHandler), keyEquivalent: "")
        self.target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func invokeHandler() {
        handler()
    }
}

private final class CommitGraphNSView: NSView {
    private static let palette: [NSColor] = [
        NSColor(srgbRed: 0.16, green: 0.52, blue: 0.96, alpha: 1),
        NSColor(srgbRed: 0.20, green: 0.68, blue: 0.36, alpha: 1),
        NSColor(srgbRed: 0.92, green: 0.50, blue: 0.12, alpha: 1),
        NSColor(srgbRed: 0.62, green: 0.34, blue: 0.88, alpha: 1),
        NSColor(srgbRed: 0.88, green: 0.24, blue: 0.42, alpha: 1),
        NSColor(srgbRed: 0.12, green: 0.68, blue: 0.68, alpha: 1),
        NSColor(srgbRed: 0.78, green: 0.56, blue: 0.08, alpha: 1),
    ]

    var layout: CommitGraphNodeLayout? {
        didSet {
            if oldValue != layout {
                needsDisplay = true
            }
        }
    }

    var isEmphasized: Bool = false {
        didSet {
            if oldValue != isEmphasized {
                needsDisplay = true
            }
        }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let layout else { return }
        let laneStep: CGFloat = 12
        let leftPad: CGFloat = 9
        let midY = bounds.height / 2
        let height = bounds.height

        func xFor(_ lane: Int) -> CGFloat {
            leftPad + CGFloat(min(lane, 8)) * laneStep
        }

        func colorFor(_ idx: Int) -> NSColor {
            Self.palette[abs(idx) % Self.palette.count]
        }

        for seg in layout.incomingSegments {
            let x1 = xFor(seg.fromLane)
            let x2 = xFor(seg.toLane)
            let path = NSBezierPath()
            path.lineWidth = 1.75
            path.move(to: NSPoint(x: x1, y: 0))
            if seg.fromLane == seg.toLane {
                path.line(to: NSPoint(x: x2, y: midY))
            } else {
                path.curve(
                    to: NSPoint(x: x2, y: midY),
                    controlPoint1: NSPoint(x: x1, y: midY * 0.55),
                    controlPoint2: NSPoint(x: x2, y: midY * 0.45)
                )
            }
            let c = isEmphasized ? NSColor.white.withAlphaComponent(0.9) : colorFor(seg.colorIndex).withAlphaComponent(0.85)
            c.setStroke()
            path.stroke()
        }

        for seg in layout.outgoingSegments {
            let x1 = xFor(seg.fromLane)
            let x2 = xFor(seg.toLane)
            let path = NSBezierPath()
            path.lineWidth = 1.75
            path.move(to: NSPoint(x: x1, y: midY))
            if seg.fromLane == seg.toLane {
                path.line(to: NSPoint(x: x2, y: height))
            } else {
                path.curve(
                    to: NSPoint(x: x2, y: height),
                    controlPoint1: NSPoint(x: x1, y: midY + (height - midY) * 0.55),
                    controlPoint2: NSPoint(x: x2, y: midY + (height - midY) * 0.45)
                )
            }
            let c = isEmphasized ? NSColor.white.withAlphaComponent(0.9) : colorFor(seg.colorIndex).withAlphaComponent(0.85)
            c.setStroke()
            path.stroke()
        }

        let cx = xFor(layout.lane)
        let radius: CGFloat = layout.isMerge ? 4.3 : 3.6
        let nodeRect = NSRect(x: cx - radius, y: midY - radius, width: radius * 2, height: radius * 2)
        let nodePath = NSBezierPath(ovalIn: nodeRect)
        colorFor(layout.colorIndex).setFill()
        nodePath.fill()

        nodePath.lineWidth = 1.2
        (isEmphasized ? NSColor.white : NSColor.controlBackgroundColor).setStroke()
        nodePath.stroke()
    }
}

private final class RefPillNSView: NSView {
    let label = NSTextField(labelWithString: "")
    private var baseColor: NSColor = .systemGreen
    var isEmphasized: Bool = false {
        didSet { updateAppearance() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 3.5

        label.font = .systemFont(ofSize: 10.5, weight: .semibold)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.usesSingleLineMode = true
        addSubview(label)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(text: String) {
        label.stringValue = text
        if text.contains("tag:") {
            baseColor = .systemOrange
        } else if text.contains("origin/") || text.contains("/") {
            baseColor = .systemPurple
        } else {
            baseColor = .systemGreen
        }
        updateAppearance()
    }

    private func updateAppearance() {
        if isEmphasized {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.24).cgColor
            label.textColor = .selectedControlTextColor
        } else {
            layer?.backgroundColor = baseColor.withAlphaComponent(0.16).cgColor
            label.textColor = baseColor
        }
    }

    override var intrinsicContentSize: NSSize {
        let textSize = label.intrinsicContentSize
        return NSSize(width: ceil(textSize.width) + 10, height: 16)
    }

    override func layout() {
        super.layout()
        let textHeight = label.intrinsicContentSize.height
        label.frame = NSRect(
            x: 5,
            y: floor((bounds.height - textHeight) / 2),
            width: max(0, bounds.width - 10),
            height: textHeight
        )
    }
}

private final class LogCommitCellView: NSTableCellView {
    private let graphView = CommitGraphNSView()
    private let shaField = NSTextField(labelWithString: "")
    private let subjectField = NSTextField(labelWithString: "")
    private let authorField = NSTextField(labelWithString: "")
    private let dateField = NSTextField(labelWithString: "")
    private let noteIconView = NSImageView()
    private var refPills: [RefPillNSView] = []
    private var visibleRefCount = 0

    private var layoutStyle: LogTableLayoutStyle = .git
    private var showsGraph = true
    private var graphWidth: CGFloat = 36
    private var shaWidth: CGFloat = 62
    private var authorWidth: CGFloat = 112
    private var dateWidth: CGFloat = 136
    private var horizontalPadding: CGFloat = 10
    private var columnSpacing: CGFloat = 8
    private var hasNote = false

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyColors() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        shaField.maximumNumberOfLines = 1
        shaField.usesSingleLineMode = true
        shaField.lineBreakMode = .byTruncatingTail

        subjectField.font = .systemFont(ofSize: 12.5)
        subjectField.maximumNumberOfLines = 1
        subjectField.usesSingleLineMode = true
        subjectField.lineBreakMode = .byTruncatingTail

        authorField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        authorField.maximumNumberOfLines = 1
        authorField.usesSingleLineMode = true
        authorField.lineBreakMode = .byTruncatingTail

        dateField.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        dateField.alignment = .right
        dateField.maximumNumberOfLines = 1
        dateField.usesSingleLineMode = true
        dateField.lineBreakMode = .byTruncatingTail

        noteIconView.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: nil)
        noteIconView.contentTintColor = .systemOrange
        noteIconView.imageScaling = .scaleProportionallyDown

        addSubview(graphView)
        addSubview(shaField)
        addSubview(subjectField)
        addSubview(noteIconView)
        addSubview(authorField)
        addSubview(dateField)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        commit: VcsCommit,
        layout: CommitGraphNodeLayout?,
        formattedDate: String,
        layoutStyle: LogTableLayoutStyle,
        showsGraph: Bool,
        graphWidth: CGFloat,
        shaWidth: CGFloat,
        authorWidth: CGFloat,
        dateWidth: CGFloat,
        horizontalPadding: CGFloat,
        columnSpacing: CGFloat
    ) {
        self.layoutStyle = layoutStyle
        self.showsGraph = showsGraph && (layout != nil)
        self.graphWidth = graphWidth
        self.shaWidth = shaWidth
        self.authorWidth = authorWidth
        self.dateWidth = dateWidth
        self.horizontalPadding = horizontalPadding
        self.columnSpacing = columnSpacing
        self.hasNote = (layoutStyle == .git && commit.note != nil)

        graphView.isHidden = !self.showsGraph
        graphView.layout = self.showsGraph ? layout : nil

        shaField.font = .monospacedSystemFont(
            ofSize: NSFont.smallSystemFontSize,
            weight: layoutStyle == .svn ? .semibold : .regular
        )
        shaField.stringValue = commit.shortHash
        subjectField.stringValue = commit.subject
        authorField.stringValue = commit.author
        dateField.stringValue = formattedDate
        noteIconView.isHidden = !self.hasNote

        let refs = (layoutStyle == .git) ? commit.refs : []
        visibleRefCount = refs.count
        while refPills.count < refs.count {
            let pill = RefPillNSView(frame: .zero)
            addSubview(pill)
            refPills.append(pill)
        }
        for (idx, pill) in refPills.enumerated() {
            if idx < refs.count {
                pill.isHidden = false
                pill.configure(text: refs[idx])
            } else {
                pill.isHidden = true
            }
        }

        applyColors()
        needsLayout = true
    }

    private func applyColors() {
        let emphasized = (backgroundStyle == .emphasized)
        graphView.isEmphasized = emphasized
        if emphasized {
            shaField.textColor = .selectedControlTextColor
            subjectField.textColor = .selectedControlTextColor
            authorField.textColor = .selectedControlTextColor
            dateField.textColor = .selectedControlTextColor
            noteIconView.contentTintColor = .selectedControlTextColor
        } else {
            shaField.textColor = (layoutStyle == .svn) ? .controlAccentColor : .secondaryLabelColor
            subjectField.textColor = .labelColor
            authorField.textColor = .secondaryLabelColor
            dateField.textColor = .secondaryLabelColor
            noteIconView.contentTintColor = .systemOrange
        }
        for idx in 0..<visibleRefCount {
            refPills[idx].isEmphasized = emphasized
        }
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let w = bounds.width
        guard w > 0, h > 0 else { return }

        var leftX = horizontalPadding
        let rightX = w - horizontalPadding

        let shaH = shaField.intrinsicContentSize.height
        let subjectH = subjectField.intrinsicContentSize.height
        let authorH = authorField.intrinsicContentSize.height
        let dateH = dateField.intrinsicContentSize.height

        let dateX = max(leftX, rightX - dateWidth)
        dateField.frame = NSRect(x: dateX, y: floor((h - dateH) / 2), width: dateWidth, height: dateH)

        switch layoutStyle {
        case .git:
            if showsGraph {
                graphView.frame = NSRect(x: leftX, y: 0, width: graphWidth, height: h)
                leftX += graphWidth + columnSpacing
            }
            shaField.frame = NSRect(x: leftX, y: floor((h - shaH) / 2), width: shaWidth, height: shaH)
            leftX += shaWidth + columnSpacing

            let authorX = max(leftX, dateX - columnSpacing - authorWidth)
            authorField.frame = NSRect(x: authorX, y: floor((h - authorH) / 2), width: authorWidth, height: authorH)

            var messageRight = authorX - columnSpacing
            if hasNote {
                let noteSize: CGFloat = 13
                let noteX = max(leftX, messageRight - noteSize)
                noteIconView.frame = NSRect(x: noteX, y: floor((h - noteSize) / 2), width: noteSize, height: noteSize)
                messageRight = noteX - columnSpacing
            }

            for idx in 0..<visibleRefCount {
                let pill = refPills[idx]
                let size = pill.intrinsicContentSize
                let pillWidth = min(size.width, max(0, messageRight - leftX))
                if pillWidth <= 0 {
                    pill.isHidden = true
                    continue
                }
                pill.isHidden = false
                pill.frame = NSRect(x: leftX, y: floor((h - size.height) / 2), width: pillWidth, height: size.height)
                leftX += pillWidth + 5
            }

            let subjectWidth = max(0, messageRight - leftX)
            subjectField.frame = NSRect(x: leftX, y: floor((h - subjectH) / 2), width: subjectWidth, height: subjectH)

        case .svn:
            shaField.frame = NSRect(x: leftX, y: floor((h - shaH) / 2), width: shaWidth, height: shaH)
            leftX += shaWidth + columnSpacing

            authorField.frame = NSRect(x: leftX, y: floor((h - authorH) / 2), width: authorWidth, height: authorH)
            leftX += authorWidth + columnSpacing

            let messageRight = max(leftX, dateX - columnSpacing)
            subjectField.frame = NSRect(x: leftX, y: floor((h - subjectH) / 2), width: messageRight - leftX, height: subjectH)
        }
    }
}

struct LogCommitsTableView: NSViewRepresentable {
    let commits: [VcsCommit]
    @Binding var selectedCommitIDs: Set<String>
    var graphLayouts: [String: CommitGraphNodeLayout] = [:]
    var layoutStyle: LogTableLayoutStyle = .git
    var showsGraph: Bool = true
    var graphWidth: CGFloat = 36
    var allowsMultipleSelection: Bool = true
    var shaWidth: CGFloat = 62
    var authorWidth: CGFloat = 112
    var dateWidth: CGFloat = 136
    var horizontalPadding: CGFloat = 10
    var columnSpacing: CGFloat = 8
    let onPopulateContextMenu: (_ clickedCommit: VcsCommit, _ selectedCommits: [VcsCommit], _ menu: NSMenu) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .controlBackgroundColor

        let table = NSTableView()
        table.style = .plain
        table.headerView = nil
        table.usesAlternatingRowBackgroundColors = false
        table.allowsMultipleSelection = allowsMultipleSelection
        table.allowsEmptySelection = false
        table.allowsColumnReordering = false
        table.allowsColumnResizing = false
        table.rowHeight = 26
        table.intercellSpacing = .zero
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.focusRingType = .none

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("commit"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)

        let coord = context.coordinator
        table.delegate = coord
        table.dataSource = coord

        let menu = NSMenu()
        menu.delegate = coord
        table.menu = menu

        coord.tableView = table
        coord.syncData(forceReload: true)

        scrollView.documentView = table
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let coord = context.coordinator
        coord.parent = self
        coord.syncData(forceReload: false)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: LogCommitsTableView
        weak var tableView: NSTableView?

        private var sourceCommits: [VcsCommit] = []
        private var formattedDates: [String] = []
        private var sourceGraphLayouts: [String: CommitGraphNodeLayout] = [:]
        private var lastShowsGraph: Bool = true
        private var lastGraphWidth: CGFloat = 36
        private var lastTableSelectedIDs: Set<String> = []
        private var pendingAsyncSelectionSync = false
        private var selectionSyncGeneration = 0
        private var isUpdatingSelectionProgrammatically = false

        init(parent: LogCommitsTableView) {
            self.parent = parent
        }

        func syncData(forceReload: Bool) {
            guard let table = tableView else { return }
            let commitsChanged = forceReload || (parent.commits != sourceCommits)
            let layoutChanged = (parent.showsGraph != lastShowsGraph)
                || (parent.graphWidth != lastGraphWidth)
                || (parent.showsGraph && parent.graphLayouts != sourceGraphLayouts)

            if commitsChanged || layoutChanged {
                sourceCommits = parent.commits
                if commitsChanged {
                    formattedDates = parent.commits.map {
                        SharedDateFormatters.abbreviatedDateTime.string(from: $0.date)
                    }
                }
                sourceGraphLayouts = parent.graphLayouts
                lastShowsGraph = parent.showsGraph
                lastGraphWidth = parent.graphWidth

                pendingAsyncSelectionSync = false
                selectionSyncGeneration &+= 1
                table.reloadData()
                restoreSelection(on: table)
            } else if !pendingAsyncSelectionSync, parent.selectedCommitIDs != lastTableSelectedIDs {
                restoreSelection(on: table)
            }
        }

        private func restoreSelection(on table: NSTableView) {
            let target = parent.selectedCommitIDs
            var indexes = IndexSet()
            if !target.isEmpty {
                for (idx, commit) in sourceCommits.enumerated() where target.contains(commit.id) {
                    indexes.insert(idx)
                }
            }
            isUpdatingSelectionProgrammatically = true
            table.selectRowIndexes(indexes, byExtendingSelection: false)
            isUpdatingSelectionProgrammatically = false
            lastTableSelectedIDs = target
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            sourceCommits.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row >= 0, row < sourceCommits.count else { return nil }
            let id = NSUserInterfaceItemIdentifier("LogCommitCell")
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? LogCommitCellView) ?? {
                let v = LogCommitCellView(frame: .zero)
                v.identifier = id
                return v
            }()
            let commit = sourceCommits[row]
            let layout = parent.showsGraph ? sourceGraphLayouts[commit.id] : nil
            cell.configure(
                commit: commit,
                layout: layout,
                formattedDate: formattedDates[row],
                layoutStyle: parent.layoutStyle,
                showsGraph: parent.showsGraph,
                graphWidth: parent.graphWidth,
                shaWidth: parent.shaWidth,
                authorWidth: parent.authorWidth,
                dateWidth: parent.dateWidth,
                horizontalPadding: parent.horizontalPadding,
                columnSpacing: parent.columnSpacing
            )
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isUpdatingSelectionProgrammatically, let table = tableView else { return }
            let selected = Set(table.selectedRowIndexes.compactMap { idx -> String? in
                guard idx >= 0, idx < sourceCommits.count else { return nil }
                return sourceCommits[idx].id
            })
            lastTableSelectedIDs = selected
            selectionSyncGeneration &+= 1
            let gen = selectionSyncGeneration
            pendingAsyncSelectionSync = true
            DispatchQueue.main.async { [weak self] in
                guard let self, self.selectionSyncGeneration == gen else { return }
                self.pendingAsyncSelectionSync = false
                if self.parent.selectedCommitIDs != selected {
                    self.parent.selectedCommitIDs = selected
                }
            }
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table = tableView else { return }
            let clicked = table.clickedRow
            guard clicked >= 0, clicked < sourceCommits.count else { return }

            if !table.selectedRowIndexes.contains(clicked) {
                table.selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false)
            }
            let selectedCommits = table.selectedRowIndexes.compactMap { idx -> VcsCommit? in
                guard idx >= 0, idx < sourceCommits.count else { return nil }
                return sourceCommits[idx]
            }
            parent.onPopulateContextMenu(sourceCommits[clicked], selectedCommits, menu)
        }
    }
}
