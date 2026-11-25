import Foundation
import RepoShellShared

public final class FinderTagService: @unchecked Sendable {
    private let storage: SharedStorage
    private let lock = NSLock()
    /// Tracks tags applied by RepoShell per repo path so clearing never touches user-authored tags.
    private var appliedTagsByRepo: [String: [String: String]] = [:]

    public init(storage: SharedStorage = .shared) {
        self.storage = storage
    }

    public static func isCloudDrivePath(_ path: String, indicators: [String]) -> Bool {
        let norm = PathUtils.normalize(path)
        return indicators.contains { marker in
            !marker.isEmpty && norm.localizedCaseInsensitiveContains(marker)
        }
    }

    public static func finderTagName(for status: VcsFileStatus) -> String? {
        switch status {
        case .modified, .typeChanged:
            return "Orange"
        case .added, .renamed, .copied, .replaced:
            return "Green"
        case .deleted, .missing, .unmerged, .obstructed:
            return "Red"
        case .untracked:
            return "Gray"
        case .locked, .external:
            return "Blue"
        case .normal, .ignored, .readOnly:
            return nil
        }
    }

    public func applyTagsIfNeeded(for snapshot: RepoStatusSnapshot, preferences: AppPreferences) {
        let isCloud = Self.isCloudDrivePath(snapshot.repoPath, indicators: preferences.cloudDriveIndicators)
        let shouldApply = (isCloud && preferences.useFinderTagsForCloudDrives)
            || (!isCloud && preferences.useFinderTagsForLocalRepos)

        if !shouldApply {
            clearManagedTags(forRepo: snapshot.repoPath)
            return
        }

        var nextApplied: [String: String] = [:]
        for (relPath, status) in snapshot.fileStatuses {
            guard let tagName = Self.finderTagName(for: status) else { continue }
            let absPath = relPath.isEmpty
                ? snapshot.repoPath
                : PathUtils.normalize("\(snapshot.repoPath)/\(relPath)")
            nextApplied[absPath] = tagName
        }

        lock.lock()
        let previousApplied = appliedTagsByRepo[snapshot.repoPath] ?? [:]
        appliedTagsByRepo[snapshot.repoPath] = nextApplied
        lock.unlock()

        // Remove tags on paths that returned to normal or changed status
        for (path, oldTag) in previousApplied {
            if nextApplied[path] != oldTag {
                removeTag(oldTag, at: path)
            }
        }

        // Apply new tags
        for (path, newTag) in nextApplied {
            if previousApplied[path] != newTag {
                addTag(newTag, at: path)
            }
        }
    }

    public func clearManagedTags(forRepo repoPath: String) {
        let norm = PathUtils.normalize(repoPath)
        lock.lock()
        let previous = appliedTagsByRepo.removeValue(forKey: norm) ?? [:]
        lock.unlock()
        for (path, oldTag) in previous {
            removeTag(oldTag, at: path)
        }
    }

    private func addTag(_ tag: String, at path: String) {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return }
        let values = try? url.resourceValues(forKeys: [.tagNamesKey])
        var tags = values?.tagNames ?? []
        if !tags.contains(tag) {
            tags.append(tag)
            try? (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
        }
    }

    private func removeTag(_ tag: String, at path: String) {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return }
        let values = try? url.resourceValues(forKeys: [.tagNamesKey])
        guard var tags = values?.tagNames, tags.contains(tag) else { return }
        tags.removeAll { $0 == tag }
        try? (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
    }
}
