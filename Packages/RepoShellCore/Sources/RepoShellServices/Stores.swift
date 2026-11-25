import Foundation
import RepoShellShared

public final class ChangelistStore: @unchecked Sendable {
    private let storage: SharedStorage

    public init(storage: SharedStorage = .shared) {
        self.storage = storage
    }

    public func load(for repoPath: String) -> [Changelist] {
        storage.read([Changelist].self, from: storage.changelistFileURL(for: repoPath)) ?? []
    }

    public func save(_ lists: [Changelist], for repoPath: String) throws {
        try storage.write(lists, to: storage.changelistFileURL(for: repoPath))
    }

    public func create(name: String, for repoPath: String) throws -> [Changelist] {
        var lists = load(for: repoPath)
        if !lists.contains(where: { $0.name == name }) {
            lists.append(Changelist(name: name))
            try save(lists, for: repoPath)
        }
        return lists
    }

    public func delete(id: UUID, for repoPath: String) throws -> [Changelist] {
        var lists = load(for: repoPath)
        lists.removeAll { $0.id == id }
        try save(lists, for: repoPath)
        return lists
    }

    public func moveFiles(_ relativePaths: [String], toChangelistID id: UUID?, for repoPath: String) throws -> [Changelist] {
        var lists = load(for: repoPath)
        let pathSet = Set(relativePaths)
        for idx in lists.indices {
            lists[idx].files.removeAll { pathSet.contains($0) }
            if lists[idx].id == id {
                for p in relativePaths where !lists[idx].files.contains(p) {
                    lists[idx].files.append(p)
                }
            }
        }
        try save(lists, for: repoPath)
        return lists
    }
}

public final class HiddenFilesStore: @unchecked Sendable {
    private let storage: SharedStorage

    public init(storage: SharedStorage = .shared) {
        self.storage = storage
    }

    public func loadRules(for repoPath: String) -> [String] {
        storage.read([String].self, from: storage.hiddenFilesFileURL(for: repoPath)) ?? []
    }

    public func saveRules(_ rules: [String], for repoPath: String) throws {
        try storage.write(rules, to: storage.hiddenFilesFileURL(for: repoPath))
    }

    public func addRules(_ newRules: [String], for repoPath: String) throws -> [String] {
        var rules = loadRules(for: repoPath)
        for r in newRules {
            let trimmed = r.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !rules.contains(trimmed) {
                rules.append(trimmed)
            }
        }
        try saveRules(rules, for: repoPath)
        return rules
    }

    public func matches(relativePath: String, rules: [String]) -> Bool {
        for rule in rules {
            if rule == relativePath {
                return true
            }
            if rule.hasPrefix("*.") {
                let ext = String(rule.dropFirst(1))
                if relativePath.hasSuffix(ext) {
                    return true
                }
            } else if fnmatch(rule, relativePath, 0) == 0 {
                return true
            }
        }
        return false
    }
}

public final class RecentHistoryStore: @unchecked Sendable {
    private let storage: SharedStorage
    private let maxCount: Int

    public init(storage: SharedStorage = .shared, maxCount: Int = 30) {
        self.storage = storage
        self.maxCount = maxCount
    }

    public func load() -> RecentHistoryData {
        storage.read(RecentHistoryData.self, from: storage.historyURL) ?? RecentHistoryData()
    }

    public func recordCommitMessage(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var data = load()
        data.commitMessages.removeAll { $0 == trimmed }
        data.commitMessages.insert(trimmed, at: 0)
        if data.commitMessages.count > maxCount {
            data.commitMessages = Array(data.commitMessages.prefix(maxCount))
        }
        try? storage.write(data, to: storage.historyURL)
    }

    public func recordRemoteURL(_ url: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var data = load()
        data.remoteURLs.removeAll { $0 == trimmed }
        data.remoteURLs.insert(trimmed, at: 0)
        if data.remoteURLs.count > maxCount {
            data.remoteURLs = Array(data.remoteURLs.prefix(maxCount))
        }
        try? storage.write(data, to: storage.historyURL)
    }

    public func clearCommitMessages() {
        var data = load()
        data.commitMessages = []
        try? storage.write(data, to: storage.historyURL)
    }

    public func clearRemoteURLs() {
        var data = load()
        data.remoteURLs = []
        try? storage.write(data, to: storage.historyURL)
    }
}
