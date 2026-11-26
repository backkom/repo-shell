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
