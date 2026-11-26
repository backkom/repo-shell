import Cocoa
import FinderSync
import RepoShellShared

@objc(FinderSync)
final class FinderSync: FIFinderSync {
    private let storage = SharedStorage.shared
    private let stateLock = NSLock()

    private var config = SharedConfig()
    private var snapshotsByRepo: [String: RepoStatusSnapshot] = [:]
    private var diffLaterState: DiffLaterState?
    private var updateState: AppUpdateState?
    private var menuActionsByTag: [Int: MenuActionBox] = [:]

    private var configObserver: NSObjectProtocol?
    private var statusObserver: NSObjectProtocol?
    private var diffLaterObserver: NSObjectProtocol?
    private var updateObserver: NSObjectProtocol?

    override init() {
        super.init()

        BadgeAssets.registerBadges(on: FIFinderSyncController.default())
        reloadAllState()

        let dnc = DistributedNotificationCenter.default()
        configObserver = dnc.addObserver(
            forName: AppConstants.DistributedNotification.configDidUpdate.cfName,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reloadAllState()
        }

        statusObserver = dnc.addObserver(
            forName: AppConstants.DistributedNotification.statusDidUpdate.cfName,
            object: nil,
            queue: .main
        ) { [weak self] note in
            if let repoPath = note.userInfo?["repoPath"] as? String {
                self?.reloadSnapshot(for: repoPath)
            } else {
                self?.reloadAllState()
            }
        }

        diffLaterObserver = dnc.addObserver(
            forName: AppConstants.DistributedNotification.diffLaterDidUpdate.cfName,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            let diffLater = self.storage.loadDiffLater()
            self.stateLock.withLock {
                self.diffLaterState = diffLater
            }
        }

        updateObserver = dnc.addObserver(
            forName: AppConstants.DistributedNotification.updateStateDidUpdate.cfName,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            let loadedUpdate = self.storage.loadUpdateState()
            self.stateLock.withLock {
                self.updateState = loadedUpdate
            }
        }
    }

    deinit {
        let dnc = DistributedNotificationCenter.default()
        if let o = configObserver { dnc.removeObserver(o) }
        if let o = statusObserver { dnc.removeObserver(o) }
        if let o = diffLaterObserver { dnc.removeObserver(o) }
        if let o = updateObserver { dnc.removeObserver(o) }
    }

    // MARK: - FIFinderSync Overrides

    override func beginObservingDirectory(at url: URL) {
        let path = PathUtils.normalize(url.path)
        let cfg = currentConfig()
        if let repo = cfg.matchingRepository(for: path) {
            AppConstants.postDistributed(.requestRefresh, userInfo: ["repoPath": repo.path])
        }
    }

    override func requestBadgeIdentifier(for url: URL) {
        let normPath = PathUtils.normalize(url.path)
        let (cfg, snapshot) = stateForPath(normPath)
        guard let repo = cfg.matchingRepository(for: normPath) else {
            return
        }
        guard let snap = snapshot else {
            FIFinderSyncController.default().setBadgeIdentifier("normal", for: url)
            return
        }
        let status = snap.status(forAbsolutePath: normPath)
        FIFinderSyncController.default().setBadgeIdentifier(status.badgeIdentifier, for: url)
        _ = repo
    }

    override var toolbarItemName: String {
        AppConstants.appName
    }

    override var toolbarItemToolTip: String {
        "RepoShell: Git & SVN operations"
    }

    override var toolbarItemImage: NSImage {
        BadgeAssets.toolbarIconImage()
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        let controller = FIFinderSyncController.default()
        let targetedURL = controller.targetedURL()
        let selectedURLs = controller.selectedItemURLs() ?? []

        let targetDirPath: String
        if let t = targetedURL {
            targetDirPath = PathUtils.normalize(t.path)
        } else if let first = selectedURLs.first {
            targetDirPath = PathUtils.normalize(first.deletingLastPathComponent().path)
        } else {
            return nil
        }

        let selectedPaths = selectedURLs.map { PathUtils.normalize($0.path) }
        let lookupPath = selectedPaths.first ?? targetDirPath

        let latestCfg = storage.loadConfig()
        let latestUpdate = storage.loadUpdateState()
        let (cfg, matchedRepo, snapshot, diffLater, availableUpdateVersion) = stateLock.withLock {
            self.config = latestCfg
            self.updateState = latestUpdate
            let repo = latestCfg.matchingRepository(for: lookupPath) ?? latestCfg.matchingRepository(for: targetDirPath)
            let snap = repo.flatMap { snapshotsByRepo[$0.path] ?? storage.loadStatusSnapshot(for: $0.path) }
            if let repo = repo, let snap = snap, snapshotsByRepo[repo.path] == nil {
                snapshotsByRepo[repo.path] = snap
            }
            let availVer: String? = (latestUpdate?.isNewer(than: AppConstants.currentVersion) == true) ? latestUpdate?.latestVersion : nil
            return (latestCfg, repo, snap, diffLaterState, availVer)
        }

        var containsGit = false
        var containsSvn = false
        if matchedRepo == nil {
            let checkDir = selectedPaths.count == 1 ? selectedPaths[0] : targetDirPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: checkDir, isDirectory: &isDir), isDir.boolValue {
                let dirURL = URL(fileURLWithPath: checkDir)
                containsGit = FileManager.default.fileExists(atPath: dirURL.appendingPathComponent(".git").path)
                containsSvn = FileManager.default.fileExists(atPath: dirURL.appendingPathComponent(".svn").path)
            }
        }

        let context = MenuResolutionContext(
            targetDirectoryPath: targetDirPath,
            selectedPaths: selectedPaths,
            matchedRepo: matchedRepo,
            snapshot: snapshot,
            diffLaterState: diffLater,
            directoryContainsGitFolder: containsGit,
            directoryContainsSvnFolder: containsSvn,
            isDirectoryCleanRepoCandidate: !containsGit && !containsSvn,
            language: cfg.preferences.language,
            availableUpdateVersion: availableUpdateVersion
        )

        let isToolbar = (menuKind == .toolbarItemMenu)
        let resolved = MenuVisibilityResolver.resolveMenu(for: context, forToolbar: isToolbar)
        guard !resolved.isEmpty else { return nil }

        // Cascade in context menus when configured; keep toolbar dropdown flat
        let shouldCascade = !isToolbar && cfg.preferences.cascadeMenu
        let topActions: [MenuAction]
        if isToolbar {
            topActions = []
        } else if matchedRepo?.vcsType == .svn {
            topActions = cfg.preferences.svnTopLevelMenuActions
        } else {
            topActions = cfg.preferences.topLevelMenuActions
        }

        let built = MenuBuilder.buildMenu(
            resolvedItems: resolved,
            cascade: shouldCascade,
            topLevelActions: topActions,
            showIcons: cfg.preferences.showMenuIcons,
            showUpdateDot: availableUpdateVersion != nil,
            targetDirectoryPath: targetDirPath,
            selectedPaths: selectedPaths,
            repoPath: matchedRepo?.path,
            target: self,
            selector: #selector(handleMenuAction(_:))
        )
        stateLock.withLock {
            self.menuActionsByTag = built.actionsByTag
        }
        return built.menu
    }

    @objc private func handleMenuAction(_ sender: NSMenuItem) {
        let box = stateLock.withLock {
            self.menuActionsByTag[sender.tag]
        }
        guard let box = box else { return }

        if box.action == .refresh {
            if let repoPath = box.repoPath {
                AppConstants.postDistributed(.requestRefresh, userInfo: ["repoPath": repoPath])
            } else {
                AppConstants.postDistributed(.requestRefresh)
            }
            return
        }

        let payload = ActionPayload(
            actionRawValue: box.action.rawValue,
            targetDirectoryPath: box.targetDirectoryPath,
            selectedPaths: box.selectedPaths,
            repoPath: box.repoPath
        )

        guard (try? storage.saveActionPayload(payload)) != nil else {
            return
        }

        AppConstants.postDistributed(.actionTriggered, userInfo: ["payloadId": payload.id.uuidString])

        if let url = URL(string: "\(AppConstants.urlScheme)://action?payloadId=\(payload.id.uuidString)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - State Synchronization

    private func reloadAllState() {
        let cfg = storage.loadConfig()
        var loadedSnaps: [String: RepoStatusSnapshot] = [:]
        for repo in cfg.repositories {
            if let snap = storage.loadStatusSnapshot(for: repo.path) {
                loadedSnaps[repo.path] = snap
            }
        }
        let diffLater = storage.loadDiffLater()
        let loadedUpdate = storage.loadUpdateState()

        stateLock.withLock {
            self.config = cfg
            self.snapshotsByRepo = loadedSnaps
            self.diffLaterState = diffLater
            self.updateState = loadedUpdate
        }

        // Observe "/" without overlapping child entries so Finder invokes menu(for:) everywhere
        // while requestBadgeIdentifier does O(N) in-memory prefix matching for monitored repos only.
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    private func reloadSnapshot(for repoPath: String) {
        let norm = PathUtils.normalize(repoPath)
        guard let snap = storage.loadStatusSnapshot(for: norm) else { return }

        let oldKeys: Set<String> = stateLock.withLock {
            let prev = snapshotsByRepo[norm]?.fileStatuses.keys.map { $0 } ?? []
            self.snapshotsByRepo[norm] = snap
            return Set(prev)
        }

        let controller = FIFinderSyncController.default()
        let repoURL = URL(fileURLWithPath: norm)
        let rootStatus = snap.status(forAbsolutePath: norm)
        controller.setBadgeIdentifier(rootStatus.badgeIdentifier, for: repoURL)

        // Reset files/folders that returned to normal
        for oldRel in oldKeys where snap.fileStatuses[oldRel] == nil && !oldRel.isEmpty {
            controller.setBadgeIdentifier("normal", for: repoURL.appendingPathComponent(oldRel))
        }

        for (relPath, status) in snap.fileStatuses where !relPath.isEmpty {
            let itemURL = repoURL.appendingPathComponent(relPath)
            controller.setBadgeIdentifier(status.badgeIdentifier, for: itemURL)
        }
    }

    private func currentConfig() -> SharedConfig {
        stateLock.withLock { config }
    }

    private func stateForPath(_ path: String) -> (SharedConfig, RepoStatusSnapshot?) {
        stateLock.withLock {
            let repo = config.matchingRepository(for: path)
            let snap = repo.flatMap { snapshotsByRepo[$0.path] }
            return (config, snap)
        }
    }

    private func snapshotBundle(forPath path: String) -> (SharedConfig, RepoStatusSnapshot?, DiffLaterState?) {
        stateLock.withLock {
            let repo = config.matchingRepository(for: path)
            let snap = repo.flatMap { snapshotsByRepo[$0.path] }
            return (config, snap, diffLaterState)
        }
    }
}
