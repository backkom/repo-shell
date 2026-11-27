import Cocoa
import FinderSync
import Network
import RepoShellShared
import RepoShellVcs
import RepoShellServices

@MainActor
final class AppContainer: ObservableObject {
    static let shared = AppContainer()

    let storage: SharedStorage
    let repositoryManager: RepositoryManager
    let gitProvider: GitProvider
    let svnProvider: SvnProvider
    let finderTagService: FinderTagService
    let statusEngine: StatusEngine
    let quickActionManager: QuickActionManager
    let authManager: AuthManager
    let diffToolManager: DiffToolManager
    let changelistStore: ChangelistStore
    let hiddenFilesStore: HiddenFilesStore
    let recentHistoryStore: RecentHistoryStore
    let windowCoordinator: WindowCoordinator
    let updateController: AppUpdateController
    @Published private(set) var isFinderExtensionEnabled: Bool?
    @Published private(set) var statusSnapshots: [String: RepoStatusSnapshot] = [:]
    private(set) var askpassServer: AskpassIPCServer?
    private var extensionStatusCheckTask: Task<Bool, Never>?
    private var extensionStatusGeneration = 0
    private var statusObserver: NSObjectProtocol?
    private var distributedStatusObserver: NSObjectProtocol?

    private init() {
        let storage = SharedStorage.shared
        self.storage = storage
        self.gitProvider = GitProvider(preferencesProvider: { storage.loadConfig().preferences })
        self.svnProvider = SvnProvider(preferencesProvider: { storage.loadConfig().preferences })
        self.repositoryManager = RepositoryManager(
            storage: storage,
            gitProvider: gitProvider,
            svnProvider: svnProvider
        )
        self.finderTagService = FinderTagService(storage: storage)
        self.statusEngine = StatusEngine(
            storage: storage,
            repositoryManager: repositoryManager,
            gitProvider: gitProvider,
            svnProvider: svnProvider,
            finderTagService: finderTagService
        )
        self.quickActionManager = QuickActionManager(
            runnerScriptPath: QuickActionManager.defaultRunnerScriptPath()
        )
        self.authManager = AuthManager(storage: storage)
        self.diffToolManager = DiffToolManager(storage: storage)
        self.changelistStore = ChangelistStore(storage: storage)
        self.hiddenFilesStore = HiddenFilesStore(storage: storage)
        self.recentHistoryStore = RecentHistoryStore(storage: storage)
        self.windowCoordinator = WindowCoordinator()
        self.updateController = AppUpdateController(storage: storage)
        self.isFinderExtensionEnabled = FIFinderSyncController.isExtensionEnabled ? true : nil

        var initialSnapshots: [String: RepoStatusSnapshot] = [:]
        for repo in repositoryManager.config.repositories {
            let norm = PathUtils.normalize(repo.path)
            if let snap = storage.loadStatusSnapshot(for: norm) {
                initialSnapshots[norm] = snap
            }
        }
        self.statusSnapshots = initialSnapshots

        self.statusObserver = NotificationCenter.default.addObserver(
            forName: AppConstants.DistributedNotification.statusDidUpdate.cfName,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let repoPath = note.userInfo?["repoPath"] as? String
            Task { @MainActor in
                self?.reloadStatusSnapshot(for: repoPath)
            }
        }
    }

    func startBackgroundServices() {
        statusEngine.start()
        updateController.start()
        if distributedStatusObserver == nil {
            distributedStatusObserver = DistributedNotificationCenter.default().addObserver(
                forName: AppConstants.DistributedNotification.statusDidUpdate.cfName,
                object: nil,
                queue: .main
            ) { [weak self] note in
                let repoPath = note.userInfo?["repoPath"] as? String
                Task { @MainActor in
                    self?.reloadStatusSnapshot(for: repoPath)
                }
            }
        }
        let server = AskpassIPCServer(storage: storage) { [weak self] request in
            guard let self = self else {
                return AskpassIPCResponse(approved: false)
            }
            return await self.windowCoordinator.promptAskpass(request: request)
        }
        server.start()
        askpassServer = server
    }

    func stopBackgroundServices() {
        updateController.stop()
        statusEngine.stop()
        if let obs = distributedStatusObserver {
            DistributedNotificationCenter.default().removeObserver(obs)
            distributedStatusObserver = nil
        }
        askpassServer?.stop()
        askpassServer = nil
    }

    func statusSnapshot(for repoPath: String) -> RepoStatusSnapshot? {
        let norm = PathUtils.normalize(repoPath)
        return statusSnapshots[norm] ?? storage.loadStatusSnapshot(for: norm)
    }

    func reloadStatusSnapshot(for repoPath: String?) {
        if let repoPath {
            let norm = PathUtils.normalize(repoPath)
            if let snap = storage.loadStatusSnapshot(for: norm) {
                statusSnapshots[norm] = snap
            } else {
                statusSnapshots.removeValue(forKey: norm)
            }
        } else {
            var next: [String: RepoStatusSnapshot] = [:]
            for repo in repositoryManager.config.repositories {
                let norm = PathUtils.normalize(repo.path)
                if let snap = storage.loadStatusSnapshot(for: norm) {
                    next[norm] = snap
                }
            }
            statusSnapshots = next
        }
    }

    func localized(_ key: String) -> String {
        Localization(language: repositoryManager.config.preferences.language).string(key)
    }

    func authEnv(for repoPath: String?) -> [String: String] {
        authManager.environment(for: repoPath)
    }

    func svnEnv(for repoPath: String?) -> [String: String] {
        authManager.svnEnvironment(for: repoPath)
    }

    func runSvnInteractive<T>(
        repoPath: String?,
        targetURL: String? = nil,
        _ operation: @escaping @Sendable ([String: String], SvnAuthOverrides) async throws -> T
    ) async throws -> T {
        let env = authManager.svnEnvironment(for: repoPath)
        var effectiveURL = targetURL
        if effectiveURL == nil, let repoPath {
            effectiveURL = (try? await svnProvider.info(target: repoPath, workingDirectory: repoPath))?.url
        }
        var auth = authManager.svnAuthOverrides(for: repoPath, targetURL: effectiveURL)

        var attempts = 0
        while true {
            do {
                return try await operation(env, auth)
            } catch let error as VcsError {
                guard case .commandFailed(_, _, let stderr, let stdout) = error else {
                    throw error
                }
                attempts += 1
                if attempts > 4 {
                    throw error
                }
                switch SvnErrorClassifier.classify(stderr: stderr, stdout: stdout) {
                case .sslCertificateUntrusted(let detail, let suggestedHost):
                    let hostKey = suggestedHost
                        ?? effectiveURL.flatMap { URL(string: $0)?.host }
                        ?? ""
                    let choice = promptSslCertificateDecision(detail: detail, host: hostKey)
                    switch choice {
                    case .acceptPermanently:
                        if !hostKey.isEmpty {
                            authManager.trustSvnHostPermanently(hostKey)
                        }
                        auth.trustServerCertFailures = SvnAuthOverrides.allCertFailures
                        continue
                    case .acceptTemporarily:
                        auth.trustServerCertFailures = SvnAuthOverrides.allCertFailures
                        continue
                    case .reject:
                        throw error
                    }

                case .authenticationRequired(let realm, let detail):
                    let host = SvnErrorClassifier.extractHost(from: detail)
                        ?? effectiveURL.flatMap { URL(string: $0)?.host }
                        ?? ""
                    let req = AskpassIPCRequest(
                        kind: .credential,
                        prompt: realm ?? detail,
                        repoPath: repoPath ?? "",
                        remoteHost: host,
                        protocolName: "svn",
                        defaultUsername: auth.username ?? ""
                    )
                    let resp = await windowCoordinator.promptAskpass(request: req)
                    guard resp.approved else {
                        throw VcsError.cancelled
                    }
                    auth.username = resp.username
                    auth.password = resp.secret
                    if resp.saveToKeychain {
                        if let repoPath {
                            let cfg = RepoAuthConfig(mode: .userPassword, username: resp.username)
                            repositoryManager.updateAuthConfig(for: repoPath, authConfig: cfg)
                            authManager.saveCredentials(repoPath: repoPath, authConfig: cfg, secret: resp.secret)
                        } else if let key = effectiveURL ?? realm {
                            authManager.saveSvnUrlCredentials(
                                hostOrUrl: key,
                                username: resp.username,
                                password: resp.secret
                            )
                        }
                    }
                    continue

                default:
                    throw error
                }
            }
        }
    }

    private enum SslTrustChoice {
        case acceptPermanently
        case acceptTemporarily
        case reject
    }

    private func promptSslCertificateDecision(detail: String, host: String) -> SslTrustChoice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Untrusted SSL Certificate", "未受信任的 SSL 证书")
        let hostLine = host.isEmpty ? "" : "Host: \(host)\n\n"
        alert.informativeText = "\(hostLine)\(detail)"
        alert.addButton(withTitle: L("Accept Permanently", "永久接受"))
        alert.addButton(withTitle: L("Accept Temporarily", "临时接受"))
        alert.addButton(withTitle: L("Reject", "拒绝"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .acceptPermanently
        case .alertSecondButtonReturn: return .acceptTemporarily
        default: return .reject
        }
    }

    func triggerRefresh(repoPath: String?) {
        if let path = repoPath {
            statusEngine.scheduleRefresh(forRepo: path, delay: 0.05)
        } else {
            statusEngine.refreshAllRepositories()
        }
    }

    @discardableResult
    func refreshFinderExtensionStatus() async -> Bool {
        if let existing = extensionStatusCheckTask {
            return await existing.value
        }
        let generation = extensionStatusGeneration
        let task = Task { @MainActor in
            defer {
                if self.extensionStatusGeneration == generation {
                    self.extensionStatusCheckTask = nil
                }
            }
            let enabled = await FinderExtensionHelper.isEnabled()
            if !Task.isCancelled,
               self.extensionStatusGeneration == generation,
               self.isFinderExtensionEnabled != enabled {
                self.isFinderExtensionEnabled = enabled
            }
            return enabled
        }
        extensionStatusCheckTask = task
        return await task.value
    }

    @discardableResult
    func enableFinderExtensionNow() async -> Bool {
        extensionStatusGeneration += 1
        extensionStatusCheckTask?.cancel()
        extensionStatusCheckTask = nil
        let enabled = await FinderExtensionHelper.enableNow()
        if isFinderExtensionEnabled != enabled {
            isFinderExtensionEnabled = enabled
        }
        return enabled
    }
}

enum FinderExtensionHelper {
    private static let pluginkitURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
    private static let lsregisterURL = URL(
        fileURLWithPath: "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    )

    static var appexURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/PlugIns/RepoShellFinderSync.appex", isDirectory: true)
    }

    static func isEnabled() async -> Bool {
        let apiEnabled = await MainActor.run { FIFinderSyncController.isExtensionEnabled }
        if apiEnabled {
            return true
        }
        let output = try? await ProcessRunner.run(
            executableURL: pluginkitURL,
            arguments: ["-m", "-p", "com.apple.FinderSync"]
        )
        return output?.stdoutString
            .components(separatedBy: .newlines)
            .contains(where: {
                $0.contains(AppConstants.finderSyncBundleID)
                    && $0.trimmingCharacters(in: .whitespaces).hasPrefix("+")
            }) ?? false
    }

    @MainActor
    static func openManagementInterface() {
        Task {
            await repairRegistrationIfNeeded(force: false)
        }
        FIFinderSyncController.showExtensionManagementInterface()
    }

    /// Removes stale PlugInKit/LaunchServices entries whose bundles no longer exist on disk
    /// (which can shadow lower-version builds) and ensures the running bundle is registered.
    static func repairRegistrationIfNeeded(force: Bool = false) async {
        let fm = FileManager.default
        let allOutput = try? await ProcessRunner.run(
            executableURL: pluginkitURL,
            arguments: ["-m", "-v", "-A", "-D", "-i", AppConstants.finderSyncBundleID]
        )

        var removedDeadRegistration = false
        let registeredPaths = (allOutput?.stdoutString ?? "")
            .components(separatedBy: .newlines)
            .compactMap { line -> String? in
                let cols = line.components(separatedBy: "\t")
                guard cols.count >= 4 else { return nil }
                let path = cols[3].trimmingCharacters(in: .whitespacesAndNewlines)
                return path.hasPrefix("/") ? path : nil
            }

        for regPath in registeredPaths where !fm.fileExists(atPath: regPath) {
            removedDeadRegistration = true
            _ = try? await ProcessRunner.run(executableURL: pluginkitURL, arguments: ["-r", regPath])
            if fm.fileExists(atPath: lsregisterURL.path) {
                _ = try? await ProcessRunner.run(executableURL: lsregisterURL, arguments: ["-u", regPath])
                if let range = regPath.range(of: "/Contents/PlugIns/") {
                    let appPath = String(regPath[..<range.lowerBound])
                    _ = try? await ProcessRunner.run(executableURL: lsregisterURL, arguments: ["-u", appPath])
                }
            }
        }

        let activeOutput = try? await ProcessRunner.run(
            executableURL: pluginkitURL,
            arguments: ["-m", "-p", "com.apple.FinderSync"]
        )
        let isDiscoverable = activeOutput?.stdoutString
            .components(separatedBy: .newlines)
            .contains(where: { $0.contains(AppConstants.finderSyncBundleID) }) ?? false

        guard force || removedDeadRegistration || !isDiscoverable else {
            return
        }

        let appexPath = appexURL.path
        if fm.fileExists(atPath: appexPath) {
            if fm.fileExists(atPath: lsregisterURL.path) {
                _ = try? await ProcessRunner.run(
                    executableURL: lsregisterURL,
                    arguments: ["-f", Bundle.main.bundleURL.path]
                )
            }
            _ = try? await ProcessRunner.run(executableURL: pluginkitURL, arguments: ["-a", appexPath])
        }

        // LaunchServices can retain deleted higher-version app bundles that pluginkit -m -A hides
        // while still shadowing the running bundle during default discovery.
        let postOutput = try? await ProcessRunner.run(
            executableURL: pluginkitURL,
            arguments: ["-m", "-p", "com.apple.FinderSync"]
        )
        let discoverableNow = postOutput?.stdoutString
            .components(separatedBy: .newlines)
            .contains(where: { $0.contains(AppConstants.finderSyncBundleID) }) ?? false
        if !discoverableNow, fm.fileExists(atPath: lsregisterURL.path) {
            await unregisterMissingBundlesFromLaunchServices(fileManager: fm)
            if fm.fileExists(atPath: appexPath) {
                _ = try? await ProcessRunner.run(
                    executableURL: lsregisterURL,
                    arguments: ["-f", Bundle.main.bundleURL.path]
                )
                _ = try? await ProcessRunner.run(executableURL: pluginkitURL, arguments: ["-a", appexPath])
            }
        }
    }

    private static func unregisterMissingBundlesFromLaunchServices(fileManager fm: FileManager) async {
        guard let dump = try? await ProcessRunner.run(
            executableURL: lsregisterURL,
            arguments: ["-dump"]
        ) else {
            return
        }
        var missingPaths = Set<String>()
        for line in dump.stdoutString.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("path:") else { continue }
            guard trimmed.contains("RepoShell.app") || trimmed.contains("RepoShellFinderSync.appex") else { continue }
            let rawValue = trimmed.dropFirst("path:".count).trimmingCharacters(in: .whitespaces)
            guard rawValue.hasPrefix("/") else { continue }
            let cleanPath: String
            if let suffixRange = rawValue.range(of: " (0x") {
                cleanPath = String(rawValue[..<suffixRange.lowerBound])
            } else {
                cleanPath = rawValue
            }
            if !fm.fileExists(atPath: cleanPath) {
                missingPaths.insert(cleanPath)
            }
        }
        for path in missingPaths {
            _ = try? await ProcessRunner.run(executableURL: lsregisterURL, arguments: ["-u", path])
            if path.hasSuffix(".appex") {
                _ = try? await ProcessRunner.run(executableURL: pluginkitURL, arguments: ["-r", path])
            }
        }
    }

    static func enableNow() async -> Bool {
        await repairRegistrationIfNeeded(force: true)
        _ = try? await ProcessRunner.run(
            executableURL: pluginkitURL,
            arguments: ["-e", "use", "-i", AppConstants.finderSyncBundleID]
        )
        return await isEnabled()
    }
}

@MainActor
enum LocalNetworkAuthorizationHelper {
    private static var activeBrowser: NWBrowser?

    static func requestPermissionIfNeeded() {
        guard activeBrowser == nil else { return }
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_http._tcp", domain: "local."), using: params)
        activeBrowser = browser
        browser.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled:
                Task { @MainActor in
                    activeBrowser = nil
                }
            default:
                break
            }
        }
        browser.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            activeBrowser?.cancel()
            activeBrowser = nil
        }
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
            NSWorkspace.shared.open(url)
        }
    }
}

func L(_ en: String, _ zh: String) -> String {
    let lang = SharedStorage.shared.loadConfig().preferences.language
    let isZh: Bool
    switch lang {
    case .zhHans: isZh = true
    case .en: isZh = false
    case .system:
        isZh = (Locale.preferredLanguages.first ?? "en").hasPrefix("zh")
    }
    return isZh ? zh : en
}
