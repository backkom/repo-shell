import Cocoa
import Combine
import RepoShellShared

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var configCancellable: AnyCancellable?
    private var actionObserver: NSObjectProtocol?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let container = AppContainer.shared
        container.startBackgroundServices()

        applyActivationPolicyAndMenuBar(showInMenuBar: container.repositoryManager.config.preferences.showInMenuBar)

        configCancellable = container.repositoryManager.$config
            .receive(on: DispatchQueue.main)
            .sink { [weak self] cfg in
                self?.applyActivationPolicyAndMenuBar(showInMenuBar: cfg.preferences.showInMenuBar)
                self?.rebuildStatusBarMenu()
            }

        setupMainMenuBar()

        actionObserver = DistributedNotificationCenter.default().addObserver(
            forName: AppConstants.DistributedNotification.actionTriggered.cfName,
            object: nil,
            queue: .main
        ) { note in
            guard let idStr = note.userInfo?["payloadId"] as? String,
                  let uuid = UUID(uuidString: idStr) else {
                return
            }
            Task { @MainActor in
                AppContainer.shared.windowCoordinator.handleActionPayload(id: uuid)
            }
        }

        let prefs = container.repositoryManager.config.preferences
        if !prefs.hasCompletedSetupWizard {
            container.windowCoordinator.openSetupWizard()
        } else if prefs.showPreferencesOnLaunch {
            container.windowCoordinator.openMainWindow(selectedTab: .repositories)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let obs = actionObserver {
            DistributedNotificationCenter.default().removeObserver(obs)
            actionObserver = nil
        }
        AppContainer.shared.stopBackgroundServices()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            AppContainer.shared.windowCoordinator.openMainWindow(selectedTab: .repositories)
        }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.isFileURL {
                Task {
                    _ = try? await AppContainer.shared.repositoryManager.addRepository(at: url.path)
                    AppContainer.shared.windowCoordinator.openMainWindow(selectedTab: .repositories)
                }
            } else {
                AppContainer.shared.windowCoordinator.handleURL(url)
            }
        }
    }

    // MARK: - Menu Bar & Dock Policy

    private func applyActivationPolicyAndMenuBar(showInMenuBar: Bool) {
        let targetPolicy: NSApplication.ActivationPolicy = showInMenuBar ? .accessory : .regular
        if NSApp.activationPolicy() != targetPolicy {
            NSApp.setActivationPolicy(targetPolicy)
        }

        if showInMenuBar && statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            if let button = item.button {
                let img = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: AppConstants.appName)
                img?.isTemplate = true
                button.image = img
                button.toolTip = AppConstants.appName
            }
            statusItem = item
            rebuildStatusBarMenu()
        } else if !showInMenuBar, let existing = statusItem {
            NSStatusBar.system.removeStatusItem(existing)
            statusItem = nil
        }
    }

    private func rebuildStatusBarMenu() {
        guard let item = statusItem else { return }
        let menu = NSMenu()
        let showItem = NSMenuItem(title: L("Show RepoShell", "显示 RepoShell"), action: #selector(openMainAction), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)
        menu.addItem(.separator())

        let repos = AppContainer.shared.repositoryManager.config.repositories
        if repos.isEmpty {
            let noneItem = NSMenuItem(title: L("No Repositories", "无版本库"), action: nil, keyEquivalent: "")
            noneItem.isEnabled = false
            menu.addItem(noneItem)
        } else {
            for repo in repos {
                let sub = NSMenu(title: repo.name)
                let quickActions: [(MenuAction, String)] = [
                    (.gitCommit, L("Commit…", "提交…")),
                    (.gitPull, L("Pull…", "拉取…")),
                    (.gitFetch, L("Fetch…", "获取…")),
                    (.gitPush, L("Push…", "推送…")),
                    (.showLog, L("Show Log", "显示日志")),
                    (.checkForModifications, L("Check for Modifications", "检测改动")),
                    (.repoBrowser, L("Repo-browser", "版本库浏览器")),
                    (.browseReferences, L("Browse References", "浏览引用")),
                    (.repoInfo, L("Repo Info", "版本库信息"))
                ]
                for (act, title) in quickActions {
                    let mi = NSMenuItem(title: title, action: #selector(runRepoStatusAction(_:)), keyEquivalent: "")
                    mi.target = self
                    mi.representedObject = (act, repo.path)
                    sub.addItem(mi)
                }
                let parent = NSMenuItem(title: repo.name, action: nil, keyEquivalent: "")
                parent.submenu = sub
                menu.addItem(parent)
            }
        }

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: L("Quit RepoShell", "退出 RepoShell"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)
        item.menu = menu
    }

    @objc private func openMainAction() {
        AppContainer.shared.windowCoordinator.openMainWindow(selectedTab: .repositories)
    }

    @objc private func runRepoStatusAction(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? (MenuAction, String) else { return }
        AppContainer.shared.windowCoordinator.dispatch(action: pair.0, repoPath: pair.1, targetDir: pair.1, selectedPaths: [pair.1])
    }

    // MARK: - Standard Application Menu

    private func setupMainMenuBar() {
        let mainMenu = NSMenu()

        // App Menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("About RepoShell", "关于 RepoShell"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let prefItem = NSMenuItem(title: L("Settings…", "偏好设置…"), action: #selector(openMainAction), keyEquivalent: ",")
        prefItem.target = self
        appMenu.addItem(prefItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("Hide RepoShell", "隐藏 RepoShell"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = NSMenuItem(title: L("Hide Others", "隐藏其他"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(withTitle: L("Show All", "显示全部"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("Quit RepoShell", "退出 RepoShell"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        // File Menu
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: L("File", "文件"))
        let cloneItem = NSMenuItem(title: L("Git Clone…", "Git 克隆…"), action: #selector(menuCloneAction), keyEquivalent: "n")
        cloneItem.target = self
        fileMenu.addItem(cloneItem)
        let initItem = NSMenuItem(title: L("Create Git Repository…", "创建 Git 版本库…"), action: #selector(menuInitAction), keyEquivalent: "")
        initItem.target = self
        fileMenu.addItem(initItem)
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: L("Close Window", "关闭窗口"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenuItem.submenu = fileMenu

        // Edit Menu (essential for Copy/Paste/Undo in text fields)
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: L("Edit", "编辑"))
        editMenu.addItem(withTitle: L("Undo", "撤销"), action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: L("Redo", "重做"), action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L("Cut", "剪切"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L("Copy", "拷贝"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L("Paste", "粘贴"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L("Select All", "全选"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        // Window Menu
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: L("Window", "窗口"))
        windowMenu.addItem(withTitle: L("Minimize", "最小化"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: L("Zoom", "缩放"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        let showMainItem = NSMenuItem(title: L("RepoShell Main Window", "RepoShell 主窗口"), action: #selector(openMainAction), keyEquivalent: "0")
        showMainItem.target = self
        windowMenu.addItem(showMainItem)
        windowMenuItem.submenu = windowMenu

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    @objc private func menuCloneAction() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        AppContainer.shared.windowCoordinator.dispatch(action: .gitClone, repoPath: nil, targetDir: home, selectedPaths: [])
    }

    @objc private func menuInitAction() {
        if let folder = AlertHelper.pickFolder(title: L("Choose folder to initialize Git repository", "选择要初始化 Git 版本库的文件夹")) {
            AppContainer.shared.windowCoordinator.dispatch(action: .gitInit, repoPath: nil, targetDir: folder.path, selectedPaths: [folder.path])
        }
    }
}
