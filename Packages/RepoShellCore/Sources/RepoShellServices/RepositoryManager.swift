import Foundation
import Combine
import RepoShellShared
import RepoShellVcs

public final class RepositoryManager: ObservableObject, @unchecked Sendable {
    @Published public private(set) var config: SharedConfig

    private let storage: SharedStorage
    private let gitProvider: GitProvider
    private let svnProvider: SvnProvider
    private let lock = NSLock()

    public init(
        storage: SharedStorage = .shared,
        gitProvider: GitProvider? = nil,
        svnProvider: SvnProvider? = nil
    ) {
        self.storage = storage
        let loaded = storage.loadConfig()
        self.config = loaded
        self.gitProvider = gitProvider ?? GitProvider(preferencesProvider: { storage.loadConfig().preferences })
        self.svnProvider = svnProvider ?? SvnProvider(preferencesProvider: { storage.loadConfig().preferences })
    }

    public func reload() {
        let loaded = storage.loadConfig()
        DispatchQueue.main.async {
            self.config = loaded
        }
    }

    public func updatePreferences(_ mutate: (inout AppPreferences) -> Void) {
        var next = currentConfigSnapshot()
        mutate(&next.preferences)
        persistAndNotify(next)
    }

    public func addRepository(at path: String, vcsType: VcsType? = nil, authConfig: RepoAuthConfig = RepoAuthConfig()) async throws -> RepositoryEntry {
        let norm = PathUtils.normalize(path)
        var detectedType = vcsType
        var rootPath = norm

        if detectedType == nil {
            if let gitRoot = await gitProvider.detectRepositoryRoot(for: norm) {
                detectedType = .git
                rootPath = gitRoot
            } else if let svnRoot = await svnProvider.detectRepositoryRoot(for: norm) {
                detectedType = .svn
                rootPath = svnRoot
            }
        } else if detectedType == .git {
            if let gitRoot = await gitProvider.detectRepositoryRoot(for: norm) {
                rootPath = gitRoot
            }
        } else if detectedType == .svn {
            if let svnRoot = await svnProvider.detectRepositoryRoot(for: norm) {
                rootPath = svnRoot
            }
        }

        guard let finalType = detectedType else {
            throw VcsError.invalidRepository(norm)
        }

        var next = currentConfigSnapshot()
        next.excludedPaths.removeAll { PathUtils.normalize($0) == rootPath }

        if let idx = next.repositories.firstIndex(where: { $0.path == rootPath }) {
            next.repositories[idx].isAutoDiscovered = false
            next.repositories[idx].parentRootPath = nil
            persistAndNotify(next)
            return next.repositories[idx]
        }

        let entry = RepositoryEntry(
            path: rootPath,
            vcsType: finalType,
            isAutoDiscovered: false,
            authConfig: authConfig
        )
        next.repositories.append(entry)
        next.repositories = RepositoryEntry.sortedForDisplay(next.repositories)
        persistAndNotify(next)
        return entry
    }

    public func toggleStar(id: UUID) {
        var next = currentConfigSnapshot()
        guard let idx = next.repositories.firstIndex(where: { $0.id == id }) else { return }
        next.repositories[idx].isStarred.toggle()
        next.repositories = RepositoryEntry.sortedForDisplay(next.repositories)
        persistAndNotify(next)
    }

    public func removeRepository(id: UUID) {
        var next = currentConfigSnapshot()
        if let removed = next.repositories.first(where: { $0.id == id }) {
            storage.removeStatusSnapshot(for: removed.path)
            if removed.isAutoDiscovered && !next.excludedPaths.contains(removed.path) {
                next.excludedPaths.append(removed.path)
            }
        }
        next.repositories.removeAll { $0.id == id }
        persistAndNotify(next)
    }

    public func excludeRepository(at path: String) {
        let norm = PathUtils.normalize(path)
        var next = currentConfigSnapshot()
        if !next.excludedPaths.contains(norm) {
            next.excludedPaths.append(norm)
        }
        next.repositories.removeAll { $0.path == norm }
        storage.removeStatusSnapshot(for: norm)
        persistAndNotify(next)
    }

    public func removeExclusion(path: String) {
        let norm = PathUtils.normalize(path)
        var next = currentConfigSnapshot()
        next.excludedPaths.removeAll { $0 == norm }
        persistAndNotify(next)
    }

    public func updateAuthConfig(for repoPath: String, authConfig: RepoAuthConfig) {
        let norm = PathUtils.normalize(repoPath)
        var next = currentConfigSnapshot()
        if let idx = next.repositories.firstIndex(where: { $0.path == norm }) {
            next.repositories[idx].authConfig = authConfig
            persistAndNotify(next)
        }
    }

    public func addWorkspaceRoot(at path: String, maxDepth: Int = 3) -> [RepositoryEntry] {
        let norm = PathUtils.normalize(path)
        var next = currentConfigSnapshot()
        if !next.workspaceRoots.contains(where: { $0.path == norm }) {
            next.workspaceRoots.append(WorkspaceScanRoot(path: norm, maxDepth: maxDepth, enabled: true))
        }
        let discovered = discoverRepositories(in: next.workspaceRoots, excludedPaths: next.excludedPaths, existing: next.repositories)
        next.repositories = discovered
        persistAndNotify(next)
        return discovered
    }

    public func removeWorkspaceRoot(id: UUID) {
        var next = currentConfigSnapshot()
        guard let root = next.workspaceRoots.first(where: { $0.id == id }) else { return }
        next.workspaceRoots.removeAll { $0.id == id }
        let removedAuto = next.repositories.filter { $0.isAutoDiscovered && $0.parentRootPath == root.path }
        for repo in removedAuto {
            storage.removeStatusSnapshot(for: repo.path)
        }
        next.repositories.removeAll { $0.isAutoDiscovered && $0.parentRootPath == root.path }
        persistAndNotify(next)
    }

    @discardableResult
    public func rescanWorkspaceRoots() -> [RepositoryEntry] {
        var next = currentConfigSnapshot()
        let discovered = discoverRepositories(in: next.workspaceRoots, excludedPaths: next.excludedPaths, existing: next.repositories)
        next.repositories = discovered
        persistAndNotify(next)
        return discovered
    }

    /// Pure discovery scan used by both production and unit tests.
    public func discoverRepositories(
        in roots: [WorkspaceScanRoot],
        excludedPaths: [String],
        existing: [RepositoryEntry]
    ) -> [RepositoryEntry] {
        let normalizedExcluded = Set(excludedPaths.map { PathUtils.normalize($0) })
        let manualRepos = existing.filter { !$0.isAutoDiscovered && !normalizedExcluded.contains($0.path) }
        var byPath: [String: RepositoryEntry] = Dictionary(uniqueKeysWithValues: manualRepos.map { ($0.path, $0) })

        // Preserve auth configs, starred flags, and UUIDs for previously discovered repos
        let previousByPath = Dictionary(existing.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })

        let fm = FileManager.default
        let skippedNames: Set<String> = [
            ".git", ".svn", "node_modules", "build", "DerivedData", ".build", ".swiftpm", "Pods", "target"
        ]

        func scan(dir: URL, rootPath: String, currentDepth: Int, maxDepth: Int) {
            let norm = PathUtils.normalize(dir.path)
            if normalizedExcluded.contains(norm) { return }

            let gitMarker = dir.appendingPathComponent(".git")
            if fm.fileExists(atPath: gitMarker.path) {
                if byPath[norm] == nil {
                    let prev = previousByPath[norm]
                    byPath[norm] = RepositoryEntry(
                        id: prev?.id ?? UUID(),
                        path: norm,
                        vcsType: .git,
                        isAutoDiscovered: true,
                        parentRootPath: rootPath,
                        authConfig: prev?.authConfig ?? RepoAuthConfig(),
                        isStarred: prev?.isStarred ?? false
                    )
                }
                return // Do not recurse inside a git repo unless configured manually as submodule
            }

            let svnMarker = dir.appendingPathComponent(".svn")
            if fm.fileExists(atPath: svnMarker.path) {
                if byPath[norm] == nil {
                    let prev = previousByPath[norm]
                    byPath[norm] = RepositoryEntry(
                        id: prev?.id ?? UUID(),
                        path: norm,
                        vcsType: .svn,
                        isAutoDiscovered: true,
                        parentRootPath: rootPath,
                        authConfig: prev?.authConfig ?? RepoAuthConfig(),
                        isStarred: prev?.isStarred ?? false
                    )
                }
                return
            }

            guard currentDepth < maxDepth else { return }
            guard let children = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else { return }

            for child in children {
                let name = child.lastPathComponent
                if skippedNames.contains(name) { continue }
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values?.isSymbolicLink == true { continue }
                if values?.isDirectory == true {
                    scan(dir: child, rootPath: rootPath, currentDepth: currentDepth + 1, maxDepth: maxDepth)
                }
            }
        }

        for root in roots where root.enabled {
            let rootURL = URL(fileURLWithPath: root.path)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: rootURL.path, isDirectory: &isDir), isDir.boolValue {
                scan(dir: rootURL, rootPath: root.path, currentDepth: 0, maxDepth: root.maxDepth)
            }
        }

        return RepositoryEntry.sortedForDisplay(Array(byPath.values))
    }

    public func currentConfigSnapshot() -> SharedConfig {
        lock.lock()
        defer { lock.unlock() }
        return storage.loadConfig()
    }

    private func persistAndNotify(_ next: SharedConfig) {
        lock.lock()
        try? storage.saveConfig(next)
        lock.unlock()

        if Thread.isMainThread {
            self.config = next
        } else {
            DispatchQueue.main.async {
                self.config = next
            }
        }
        AppConstants.postDistributed(.configDidUpdate)
    }
}
