import Foundation

public final class SharedStorage: @unchecked Sendable {
    public static let shared = SharedStorage()

    public let baseDirectoryURL: URL
    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "com.leaf.reposhell.sharedstorage", attributes: .concurrent)

    private let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return enc
    }()

    private let decoder: JSONDecoder = {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }()

    public init(baseDirectoryURL: URL = AppConstants.groupContainerURL) {
        self.baseDirectoryURL = baseDirectoryURL
        ensureDirectories()
    }

    public var configURL: URL {
        baseDirectoryURL.appendingPathComponent("config.json", isDirectory: false)
    }

    public var diffLaterURL: URL {
        baseDirectoryURL.appendingPathComponent("diff-later.json", isDirectory: false)
    }

    public var askpassSocketURL: URL {
        baseDirectoryURL.appendingPathComponent("askpass.sock", isDirectory: false)
    }

    public var cacheDirectoryURL: URL {
        baseDirectoryURL.appendingPathComponent("cache", isDirectory: true)
    }

    public var pendingActionsDirectoryURL: URL {
        baseDirectoryURL.appendingPathComponent("pending-actions", isDirectory: true)
    }

    public var changelistsDirectoryURL: URL {
        baseDirectoryURL.appendingPathComponent("changelists", isDirectory: true)
    }

    public var hiddenFilesDirectoryURL: URL {
        baseDirectoryURL.appendingPathComponent("hidden-files", isDirectory: true)
    }

    public var historyURL: URL {
        baseDirectoryURL.appendingPathComponent("history.json", isDirectory: false)
    }

    public var updateStateURL: URL {
        baseDirectoryURL.appendingPathComponent("update-state.json", isDirectory: false)
    }

    public func cacheFileURL(for repoPath: String) -> URL {
        let hash = PathUtils.repoHash(for: repoPath)
        return cacheDirectoryURL.appendingPathComponent("\(hash).json", isDirectory: false)
    }

    public func changelistFileURL(for repoPath: String) -> URL {
        let hash = PathUtils.repoHash(for: repoPath)
        return changelistsDirectoryURL.appendingPathComponent("\(hash).json", isDirectory: false)
    }

    public func hiddenFilesFileURL(for repoPath: String) -> URL {
        let hash = PathUtils.repoHash(for: repoPath)
        return hiddenFilesDirectoryURL.appendingPathComponent("\(hash).json", isDirectory: false)
    }

    public func pendingActionFileURL(for id: UUID) -> URL {
        pendingActionsDirectoryURL.appendingPathComponent("\(id.uuidString).json", isDirectory: false)
    }

    private func ensureDirectories() {
        let dirs = [
            baseDirectoryURL,
            cacheDirectoryURL,
            pendingActionsDirectoryURL,
            changelistsDirectoryURL,
            hiddenFilesDirectoryURL
        ]
        for dir in dirs {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    // MARK: - Config

    public func loadConfig() -> SharedConfig {
        queue.sync {
            guard let data = try? Data(contentsOf: configURL),
                  let config = try? decoder.decode(SharedConfig.self, from: data) else {
                return SharedConfig()
            }
            return config
        }
    }

    public func saveConfig(_ config: SharedConfig) throws {
        try queue.sync(flags: .barrier) {
            try writeAtomic(config, to: configURL)
        }
    }

    // MARK: - Status Cache

    public func loadStatusSnapshot(for repoPath: String) -> RepoStatusSnapshot? {
        let url = cacheFileURL(for: repoPath)
        return queue.sync {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(RepoStatusSnapshot.self, from: data)
        }
    }

    public func saveStatusSnapshot(_ snapshot: RepoStatusSnapshot) throws {
        let url = cacheFileURL(for: snapshot.repoPath)
        try queue.sync(flags: .barrier) {
            try writeAtomic(snapshot, to: url)
        }
    }

    public func removeStatusSnapshot(for repoPath: String) {
        let url = cacheFileURL(for: repoPath)
        queue.sync(flags: .barrier) {
            try? fileManager.removeItem(at: url)
        }
    }

    // MARK: - Pending Action Payloads

    public func saveActionPayload(_ payload: ActionPayload) throws -> URL {
        let url = pendingActionFileURL(for: payload.id)
        try queue.sync(flags: .barrier) {
            try writeAtomic(payload, to: url)
        }
        return url
    }

    public func loadAndConsumeActionPayload(id: UUID) -> ActionPayload? {
        let url = pendingActionFileURL(for: id)
        return queue.sync(flags: .barrier) {
            guard let data = try? Data(contentsOf: url),
                  let payload = try? decoder.decode(ActionPayload.self, from: data) else {
                return nil
            }
            try? fileManager.removeItem(at: url)
            return payload
        }
    }

    // MARK: - Diff Later

    public func loadDiffLater() -> DiffLaterState? {
        queue.sync {
            guard let data = try? Data(contentsOf: diffLaterURL) else { return nil }
            return try? decoder.decode(DiffLaterState.self, from: data)
        }
    }

    public func saveDiffLater(_ state: DiffLaterState?) throws {
        try queue.sync(flags: .barrier) {
            if let state = state {
                try writeAtomic(state, to: diffLaterURL)
            } else if fileManager.fileExists(atPath: diffLaterURL.path) {
                try fileManager.removeItem(at: diffLaterURL)
            }
        }
    }

    // MARK: - Update State

    public func loadUpdateState() -> AppUpdateState? {
        queue.sync {
            guard let data = try? Data(contentsOf: updateStateURL) else { return nil }
            return try? decoder.decode(AppUpdateState.self, from: data)
        }
    }

    public func saveUpdateState(_ state: AppUpdateState?) throws {
        try queue.sync(flags: .barrier) {
            if let state = state {
                try writeAtomic(state, to: updateStateURL)
            } else if fileManager.fileExists(atPath: updateStateURL.path) {
                try fileManager.removeItem(at: updateStateURL)
            }
        }
    }

    // MARK: - Generic Codable Helpers

    public func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        queue.sync {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(type, from: data)
        }
    }

    public func write<T: Encodable>(_ value: T, to url: URL) throws {
        try queue.sync(flags: .barrier) {
            try writeAtomic(value, to: url)
        }
    }

    private func writeAtomic<T: Encodable>(_ value: T, to destination: URL) throws {
        ensureDirectories()
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let data = try encoder.encode(value)
        let tempURL = parent.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: tempURL, options: .atomic)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: tempURL)
        } else {
            try fileManager.moveItem(at: tempURL, to: destination)
        }
    }
}
