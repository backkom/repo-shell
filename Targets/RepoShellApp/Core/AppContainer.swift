import Cocoa
import FinderSync
import RepoShellShared
import RepoShellVcs
import RepoShellServices

@MainActor
final class AppContainer: ObservableObject {
    static let shared = AppContainer()

    let storage: SharedStorage
    let repositoryManager: RepositoryManager
    let gitProvider: GitProvider
    let finderTagService: FinderTagService
    let statusEngine: StatusEngine
    let quickActionManager: QuickActionManager
    let authManager: AuthManager
    let diffToolManager: DiffToolManager
    let changelistStore: ChangelistStore
    let hiddenFilesStore: HiddenFilesStore
    let recentHistoryStore: RecentHistoryStore
    let windowCoordinator: WindowCoordinator
    private(set) var askpassServer: AskpassIPCServer?

    private init() {
        let storage = SharedStorage.shared
        self.storage = storage
        self.repositoryManager = RepositoryManager(storage: storage)
        self.gitProvider = GitProvider(preferencesProvider: { storage.loadConfig().preferences })
        self.finderTagService = FinderTagService(storage: storage)
        self.statusEngine = StatusEngine(
            storage: storage,
            repositoryManager: repositoryManager,
            gitProvider: gitProvider,
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
    }

    func startBackgroundServices() {
        statusEngine.start()
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
        statusEngine.stop()
        askpassServer?.stop()
        askpassServer = nil
    }

    func localized(_ key: String) -> String {
        Localization(language: repositoryManager.config.preferences.language).string(key)
    }

    func authEnv(for repoPath: String?) -> [String: String] {
        authManager.environment(for: repoPath)
    }

    func triggerRefresh(repoPath: String?) {
        if let path = repoPath {
            statusEngine.scheduleRefresh(forRepo: path, delay: 0.05)
        } else {
            statusEngine.refreshAllRepositories()
        }
    }
}

enum FinderExtensionHelper {
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
            executableURL: URL(fileURLWithPath: "/usr/bin/pluginkit"),
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
        FIFinderSyncController.showExtensionManagementInterface()
    }

    static func enableNow() async -> Bool {
        let pluginkitURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        let path = appexURL.path
        if FileManager.default.fileExists(atPath: path) {
            _ = try? await ProcessRunner.run(executableURL: pluginkitURL, arguments: ["-a", path])
        }
        _ = try? await ProcessRunner.run(
            executableURL: pluginkitURL,
            arguments: ["-e", "use", "-i", AppConstants.finderSyncBundleID]
        )
        return await isEnabled()
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
