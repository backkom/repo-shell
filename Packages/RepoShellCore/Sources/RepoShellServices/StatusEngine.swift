import Foundation
import CoreServices
import RepoShellShared
import RepoShellVcs

public final class StatusEngine: @unchecked Sendable {
    private let storage: SharedStorage
    private let repositoryManager: RepositoryManager
    private let gitProvider: GitProvider
    private let svnProvider: SvnProvider
    private let finderTagService: FinderTagService

    private let stateLock = NSLock()
    private var eventStream: FSEventStreamRef?
    private var watchedPaths: [String] = []
    private var debounceTimers: [String: DispatchWorkItem] = [:]
    private var inFlightRepos: Set<String> = []
    private var configObserver: NSObjectProtocol?
    private var refreshObserver: NSObjectProtocol?

    private let workQueue = DispatchQueue(label: "com.leaf.reposhell.statusengine", qos: .utility)

    public init(
        storage: SharedStorage = .shared,
        repositoryManager: RepositoryManager,
        gitProvider: GitProvider? = nil,
        svnProvider: SvnProvider? = nil,
        finderTagService: FinderTagService? = nil
    ) {
        self.storage = storage
        self.repositoryManager = repositoryManager
        self.gitProvider = gitProvider ?? GitProvider(preferencesProvider: { storage.loadConfig().preferences })
        self.svnProvider = svnProvider ?? SvnProvider(preferencesProvider: { storage.loadConfig().preferences })
        self.finderTagService = finderTagService ?? FinderTagService(storage: storage)
    }

    deinit {
        stop()
    }

    public func start() {
        configObserver = DistributedNotificationCenter.default().addObserver(
            forName: AppConstants.DistributedNotification.configDidUpdate.cfName,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.rebuildWatchersAndRefreshAll()
        }

        refreshObserver = DistributedNotificationCenter.default().addObserver(
            forName: AppConstants.DistributedNotification.requestRefresh.cfName,
            object: nil,
            queue: nil
        ) { [weak self] note in
            if let path = note.userInfo?["repoPath"] as? String {
                self?.scheduleRefresh(forRepo: path, delay: 0.05)
            } else {
                self?.refreshAllRepositories()
            }
        }

        rebuildWatchersAndRefreshAll()
    }

    public func stop() {
        if let obs = configObserver {
            DistributedNotificationCenter.default().removeObserver(obs)
            configObserver = nil
        }
        if let obs = refreshObserver {
            DistributedNotificationCenter.default().removeObserver(obs)
            refreshObserver = nil
        }
        stopStream()
    }

    public func rebuildWatchersAndRefreshAll() {
        let cfg = storage.loadConfig()
        let paths = cfg.repositories.map { $0.path }.sorted()
        restartFSEventStream(paths: paths)
        refreshAllRepositories()
    }

    public func refreshAllRepositories() {
        let cfg = storage.loadConfig()
        for repo in cfg.repositories {
            scheduleRefresh(forRepo: repo.path, delay: 0.05)
        }
    }

    public func refreshRepositoryNow(at repoPath: String) async {
        let norm = PathUtils.normalize(repoPath)
        let cfg = storage.loadConfig()
        let prefs = cfg.preferences

        guard tryBeginRefresh(repoPath: norm) else {
            return
        }
        defer {
            endRefresh(repoPath: norm)
        }

        let matchedRepo = cfg.repositories.first(where: { PathUtils.normalize($0.path) == norm })
            ?? cfg.matchingRepository(for: norm)
        let vcsType: VcsType = matchedRepo?.vcsType
            ?? (FileManager.default.fileExists(atPath: URL(fileURLWithPath: norm).appendingPathComponent(".svn").path) ? .svn : .git)

        let options = VcsStatusOptions(includeIgnored: true, includeUntracked: true, includeLineStats: false)
        let statusResult: VcsStatusResult?
        switch vcsType {
        case .svn:
            // Local working copy scan only; never pass -u in background StatusEngine.
            statusResult = try? await svnProvider.status(repoPath: norm, options: options)
        case .git:
            statusResult = try? await gitProvider.status(repoPath: norm, options: options)
        }

        guard let statusRes = statusResult else {
            return
        }

        let folderMap = GitParsers.buildFolderStatuses(from: statusRes.items)
        let snapshot = RepoStatusSnapshot(
            repoPath: norm,
            vcsType: vcsType,
            branchName: statusRes.branchName,
            repoState: statusRes.repoState,
            updatedAt: Date(),
            fileStatuses: folderMap
        )

        try? storage.saveStatusSnapshot(snapshot)
        finderTagService.applyTagsIfNeeded(for: snapshot, preferences: prefs)
        AppConstants.postDistributed(.statusDidUpdate, userInfo: ["repoPath": norm])
    }

    public func scheduleRefresh(forRepo repoPath: String, delay: TimeInterval = 0.35) {
        let norm = PathUtils.normalize(repoPath)
        stateLock.lock()
        debounceTimers[norm]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            Task.detached(priority: .utility) {
                await self.refreshRepositoryNow(at: norm)
            }
        }
        debounceTimers[norm] = item
        stateLock.unlock()

        workQueue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    // MARK: - FSEvents

    private func stopStream() {
        stateLock.lock()
        let stream = eventStream
        eventStream = nil
        stateLock.unlock()

        if let stream = stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    private func restartFSEventStream(paths: [String]) {
        stateLock.lock()
        let unchanged = (paths == watchedPaths && eventStream != nil)
        stateLock.unlock()
        if unchanged { return }

        stopStream()

        stateLock.lock()
        watchedPaths = paths
        stateLock.unlock()

        guard !paths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, _, _ in
            guard let info = info else { return }
            let engine = Unmanaged<StatusEngine>.fromOpaque(info).takeUnretainedValue()
            let cfPaths = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            var changedPaths: [String] = []
            changedPaths.reserveCapacity(numEvents)
            for i in 0..<numEvents {
                changedPaths.append(String(cString: cfPaths[i]))
            }
            engine.handleFSEvents(paths: changedPaths)
        }

        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.35,
            flags
        ) else {
            return
        }

        FSEventStreamSetDispatchQueue(stream, workQueue)
        FSEventStreamStart(stream)

        stateLock.lock()
        eventStream = stream
        stateLock.unlock()
    }

    private func tryBeginRefresh(repoPath: String) -> Bool {
        stateLock.withLock {
            if inFlightRepos.contains(repoPath) {
                return false
            }
            inFlightRepos.insert(repoPath)
            return true
        }
    }

    private func endRefresh(repoPath: String) {
        _ = stateLock.withLock {
            inFlightRepos.remove(repoPath)
        }
    }

    private func handleFSEvents(paths: [String]) {
        let cfg = storage.loadConfig()
        var affectedRepos: Set<String> = []

        for rawPath in paths {
            // Ignore transient Git index.lock/object packing churn and SVN SQLite WAL/tmp churn
            if rawPath.hasSuffix(".git/index.lock")
                || rawPath.contains("/.git/objects/")
                || rawPath.hasSuffix(".svn/wc.db-journal")
                || rawPath.hasSuffix(".svn/wc.db-wal")
                || rawPath.hasSuffix(".svn/wc.db-shm")
                || rawPath.contains("/.svn/tmp/") {
                continue
            }
            if let repo = cfg.matchingRepository(for: rawPath) {
                affectedRepos.insert(repo.path)
            }
        }

        for repoPath in affectedRepos {
            scheduleRefresh(forRepo: repoPath, delay: 0.35)
        }
    }
}
