import Cocoa
import SwiftUI
import RepoShellShared
import RepoShellVcs
import RepoShellServices

@MainActor
final class WindowCoordinator {
    private var controllers: [String: HostedWindowController] = [:]

    func openMainWindow(selectedTab: MainTab = .repositories) {
        let key = "main-window"
        if let existing = controllers[key] {
            existing.showAndFocus()
            return
        }
        let view = MainWindowView(initialTab: selectedTab)
        let ctrl = HostedWindowController(
            title: AppConstants.appName,
            size: NSSize(width: 760, height: 540),
            minSize: NSSize(width: 660, height: 460),
            autosaveName: "RepoShellMainWindow",
            rootView: view
        ) { [weak self] in
            self?.controllers.removeValue(forKey: key)
        }
        controllers[key] = ctrl
        ctrl.showAndFocus()
    }

    func openSetupWizard() {
        let key = "setup-wizard"
        if let existing = controllers[key] {
            existing.showAndFocus()
            return
        }
        let view = SetupWizardView { [weak self] in
            self?.controllers[key]?.close()
            self?.openMainWindow(selectedTab: .repositories)
        }
        let ctrl = HostedWindowController(
            title: L("RepoShell Setup Wizard", "RepoShell 设置向导"),
            size: NSSize(width: 600, height: 440),
            minSize: NSSize(width: 540, height: 400),
            rootView: view
        ) { [weak self] in
            self?.controllers.removeValue(forKey: key)
        }
        controllers[key] = ctrl
        ctrl.showAndFocus()
    }

    func handleActionPayload(id: UUID) {
        guard let payload = AppContainer.shared.storage.loadAndConsumeActionPayload(id: id),
              let action = MenuAction(rawValue: payload.actionRawValue) else {
            return
        }
        dispatch(
            action: action,
            repoPath: payload.repoPath,
            targetDir: payload.targetDirectoryPath,
            selectedPaths: payload.selectedPaths
        )
    }

    func handleURL(_ url: URL) {
        guard url.scheme?.lowercased() == AppConstants.urlScheme else { return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []

        if url.host == "action",
           let idStr = queryItems.first(where: { $0.name == "payloadId" })?.value,
           let uuid = UUID(uuidString: idStr) {
            handleActionPayload(id: uuid)
            return
        }

        if url.host == "quickaction",
           let actRaw = queryItems.first(where: { $0.name == "action" })?.value,
           let action = MenuAction(rawValue: actRaw) {
            let baseDir = queryItems.first(where: { $0.name == "baseDir" })?.value ?? ""
            let paths = queryItems.filter { $0.name == "path" }.compactMap { $0.value }
            let config = AppContainer.shared.repositoryManager.currentConfigSnapshot()
            let lookup = paths.first ?? baseDir
            let matchedRepo = config.matchingRepository(for: lookup)
            dispatch(
                action: action,
                repoPath: matchedRepo?.path,
                targetDir: baseDir,
                selectedPaths: paths
            )
        }
    }

    func dispatch(action: MenuAction, repoPath: String?, targetDir: String, selectedPaths: [String]) {
        let container = AppContainer.shared

        switch action {
        case .showApp:
            openMainWindow(selectedTab: .repositories)

        case .addRepository:
            let candidate = selectedPaths.first ?? targetDir
            Task {
                do {
                    let entry = try await container.repositoryManager.addRepository(at: candidate)
                    container.triggerRefresh(repoPath: entry.path)
                    openMainWindow(selectedTab: .repositories)
                } catch {
                    AlertHelper.showError(error)
                }
            }

        case .excludeRepository:
            if let repo = repoPath ?? selectedPaths.first {
                if AlertHelper.confirm(
                    title: L("Exclude Repository", "排除版本库"),
                    message: String(format: L("Exclude \"%@\" from RepoShell monitoring?", "确定要将“%@”排除出 RepoShell 监控吗？"), repo)
                ) {
                    container.repositoryManager.excludeRepository(at: repo)
                }
            }

        case .refresh:
            container.triggerRefresh(repoPath: repoPath)

        case .gitClone:
            presentWindow(
                key: "clone-\(targetDir)",
                title: L("Git Clone", "Git 克隆"),
                size: NSSize(width: 540, height: 340),
                view: CloneWindowView(initialParentDir: targetDir)
            )

        case .gitInit:
            let dir = selectedPaths.first ?? targetDir
            presentWindow(
                key: "init-\(dir)",
                title: L("Create Git Repository", "创建 Git 版本库"),
                size: NSSize(width: 480, height: 220),
                view: CreateRepoWindowView(initialPath: dir)
            )

        case .gitCommit:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths) else { return }
            presentWindow(
                key: "commit-\(repo)",
                title: L("Git Commit", "Git 提交") + " — \(URL(fileURLWithPath: repo).lastPathComponent)",
                size: NSSize(width: 820, height: 600),
                autosave: "CommitWindow",
                view: CommitWindowView(repoPath: repo, preselectedPaths: selectedPaths)
            )

        case .gitPull:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths) else { return }
            presentWindow(
                key: "pull-\(repo)",
                title: L("Git Pull", "Git 拉取") + " — \(URL(fileURLWithPath: repo).lastPathComponent)",
                size: NSSize(width: 520, height: 390),
                view: PullWindowView(repoPath: repo)
            )

        case .gitFetch:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths) else { return }
            presentWindow(
                key: "fetch-\(repo)",
                title: L("Git Fetch", "Git 获取") + " — \(URL(fileURLWithPath: repo).lastPathComponent)",
                size: NSSize(width: 480, height: 290),
                view: FetchWindowView(repoPath: repo)
            )

        case .gitPush:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths) else { return }
            presentWindow(
                key: "push-\(repo)",
                title: L("Git Push", "Git 推送") + " — \(URL(fileURLWithPath: repo).lastPathComponent)",
                size: NSSize(width: 620, height: 480),
                view: PushWindowView(repoPath: repo)
            )

        case .showLog:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths) else { return }
            let filterPath = selectedPaths.count == 1 && PathUtils.normalize(selectedPaths[0]) != repo ? selectedPaths[0] : nil
            presentWindow(
                key: "log-\(repo)-\(filterPath ?? "")",
                title: L("Show Log", "显示日志") + " — \(URL(fileURLWithPath: repo).lastPathComponent)",
                size: NSSize(width: 960, height: 680),
                autosave: "LogWindow",
                view: LogWindowView(repoPath: repo, initialPathFilter: filterPath)
            )

        case .checkForModifications:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths) else { return }
            presentWindow(
                key: "modifications-\(repo)",
                title: L("Check for Modifications", "检测改动") + " — \(URL(fileURLWithPath: repo).lastPathComponent)",
                size: NSSize(width: 840, height: 560),
                autosave: "ModificationsWindow",
                view: ModificationsWindowView(repoPath: repo)
            )

        case .browseReferences:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths) else { return }
            presentWindow(
                key: "refs-\(repo)",
                title: L("Browse References", "浏览引用") + " — \(URL(fileURLWithPath: repo).lastPathComponent)",
                size: NSSize(width: 780, height: 520),
                view: ReferencesWindowView(repoPath: repo)
            )

        case .stashPush:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths) else { return }
            presentWindow(
                key: "stash-save-\(repo)",
                title: L("Stash Save", "储藏") + " — \(URL(fileURLWithPath: repo).lastPathComponent)",
                size: NSSize(width: 640, height: 470),
                view: StashSaveWindowView(repoPath: repo, preselectedPaths: selectedPaths)
            )

        case .stashList:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths) else { return }
            presentWindow(
                key: "stash-list-\(repo)",
                title: L("Stash List", "储藏列表") + " — \(URL(fileURLWithPath: repo).lastPathComponent)",
                size: NSSize(width: 740, height: 460),
                view: StashListWindowView(repoPath: repo)
            )

        case .repoBrowser:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths) else { return }
            presentWindow(
                key: "browser-\(repo)",
                title: L("Repo-browser", "版本库浏览器") + " — \(URL(fileURLWithPath: repo).lastPathComponent)",
                size: NSSize(width: 820, height: 560),
                view: RepoBrowserWindowView(repoPath: repo)
            )

        case .resolveConflicts:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths) else { return }
            presentWindow(
                key: "resolve-\(repo)",
                title: L("Resolve Conflicts", "解决冲突") + " — \(URL(fileURLWithPath: repo).lastPathComponent)",
                size: NSSize(width: 680, height: 460),
                view: ResolveWindowView(repoPath: repo)
            )

        case .revert:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths) else { return }
            presentWindow(
                key: "revert-\(repo)",
                title: L("Revert", "复原") + " — \(URL(fileURLWithPath: repo).lastPathComponent)",
                size: NSSize(width: 680, height: 460),
                view: RevertWindowView(repoPath: repo, preselectedPaths: selectedPaths)
            )

        case .checkout:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths) else { return }
            presentWindow(
                key: "checkout-\(repo)",
                title: L("Checkout / Switch", "签出 / 切换") + " — \(URL(fileURLWithPath: repo).lastPathComponent)",
                size: NSSize(width: 500, height: 370),
                view: SwitchCheckoutWindowView(repoPath: repo)
            )

        case .createBranch:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths) else { return }
            presentWindow(
                key: "create-branch-\(repo)",
                title: L("Create Branch", "创建分支") + " — \(URL(fileURLWithPath: repo).lastPathComponent)",
                size: NSSize(width: 480, height: 310),
                view: CreateBranchWindowView(repoPath: repo)
            )

        case .createTag:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths) else { return }
            presentWindow(
                key: "create-tag-\(repo)",
                title: L("Create Tag", "创建标签") + " — \(URL(fileURLWithPath: repo).lastPathComponent)",
                size: NSSize(width: 480, height: 330),
                view: CreateTagWindowView(repoPath: repo)
            )

        case .merge:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths) else { return }
            presentWindow(
                key: "merge-\(repo)",
                title: L("Merge", "合并") + " — \(URL(fileURLWithPath: repo).lastPathComponent)",
                size: NSSize(width: 520, height: 420),
                view: MergeWindowView(repoPath: repo)
            )

        case .abortMerge:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths) else { return }
            if AlertHelper.confirm(
                title: L("Abort Merge", "放弃合并"),
                message: L("Abort the current merge and reset working tree?", "确定要放弃当前合并并恢复工作目录吗？")
            ) {
                runTaskWithProgress(title: L("Abort Merge", "放弃合并"), repoPath: repo) { _ in
                    try await container.gitProvider.abortMerge(repoPath: repo)
                }
            }

        case .reset:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths) else { return }
            presentWindow(
                key: "reset-\(repo)",
                title: L("Reset", "重置") + " — \(URL(fileURLWithPath: repo).lastPathComponent)",
                size: NSSize(width: 520, height: 360),
                view: ResetWindowView(repoPath: repo)
            )

        case .export:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths) else { return }
            presentWindow(
                key: "export-\(repo)",
                title: L("Export", "导出") + " — \(URL(fileURLWithPath: repo).lastPathComponent)",
                size: NSSize(width: 500, height: 300),
                view: ExportWindowView(repoPath: repo)
            )

        case .diff:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths),
                  let file = selectedPaths.first else { return }
            openDiffWithRevision(repoPath: repo, filePath: file, revision: "HEAD", rightTitle: L("Working Tree", "工作区"))

        case .diffPrevious:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths),
                  let file = selectedPaths.first else { return }
            openDiffPreviousVersion(repoPath: repo, filePath: file)

        case .diffLater:
            guard let file = selectedPaths.first else { return }
            try? container.diffToolManager.saveDiffLater(filePath: file)

        case .diffWithLater:
            guard let file = selectedPaths.first,
                  let later = container.diffToolManager.loadDiffLater() else { return }
            launchDiffFiles(leftPath: later.filePath, rightPath: file, leftTitle: later.fileName, rightTitle: URL(fileURLWithPath: file).lastPathComponent)

        case .add:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths) else { return }
            runTaskWithProgress(title: L("Git Add", "添加文件"), repoPath: repo) { _ in
                try await container.gitProvider.add(repoPath: repo, paths: selectedPaths)
            }

        case .delete:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths) else { return }
            if AlertHelper.confirm(
                title: L("Delete Files", "删除文件"),
                message: L("Remove selected files from Git and working directory?", "确定要从 Git 和工作区删除所选文件吗？")
            ) {
                runTaskWithProgress(title: L("Delete", "删除"), repoPath: repo) { _ in
                    try await container.gitProvider.remove(repoPath: repo, paths: selectedPaths, keepLocal: false)
                }
            }

        case .deleteKeepLocal:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths) else { return }
            runTaskWithProgress(title: L("Delete (Keep Local)", "删除（保留本地拷贝）"), repoPath: repo) { _ in
                try await container.gitProvider.remove(repoPath: repo, paths: selectedPaths, keepLocal: true)
            }

        case .rename:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths),
                  let file = selectedPaths.first else { return }
            presentWindow(
                key: "rename-\(file)",
                title: L("Rename", "重命名"),
                size: NSSize(width: 460, height: 180),
                view: RenameWindowView(repoPath: repo, sourcePath: file)
            )

        case .addToIgnore:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths) else { return }
            presentWindow(
                key: "ignore-\(repo)",
                title: L("Add to Ignore List", "添加到忽略清单"),
                size: NSSize(width: 480, height: 240),
                view: IgnoreWindowView(repoPath: repo, targetPaths: selectedPaths)
            )

        case .repoInfo:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths) else { return }
            presentWindow(
                key: "info-\(repo)",
                title: L("Repo Info", "版本库信息") + " — \(URL(fileURLWithPath: repo).lastPathComponent)",
                size: NSSize(width: 680, height: 500),
                view: RepoInfoWindowView(repoPath: repo)
            )

        case .cleanup:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths) else { return }
            runTaskWithProgress(title: L("Cleanup (git gc)", "清理 (git gc)"), repoPath: repo) { _ in
                try await container.gitProvider.cleanup(repoPath: repo)
            }

        case .rebase:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths) else { return }
            presentWindow(
                key: "rebase-\(repo)",
                title: L("Interactive Rebase", "交互式变基 (Rebase)") + " — \(URL(fileURLWithPath: repo).lastPathComponent)",
                size: NSSize(width: 820, height: 560),
                view: RebaseWindowView(repoPath: repo)
            )

        case .cherryPick:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths) else { return }
            presentWindow(
                key: "cherrypick-\(repo)",
                title: L("Cherry-Pick", "摘取 (Cherry-Pick)") + " — \(URL(fileURLWithPath: repo).lastPathComponent)",
                size: NSSize(width: 760, height: 500),
                view: CherryPickWindowView(repoPath: repo)
            )

        case .showRefLog:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths) else { return }
            presentWindow(
                key: "reflog-\(repo)",
                title: L("RefLog", "操作日志 (RefLog)") + " — \(URL(fileURLWithPath: repo).lastPathComponent)",
                size: NSSize(width: 860, height: 560),
                view: RefLogWindowView(repoPath: repo)
            )

        case .compareRevisions:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths) else { return }
            presentWindow(
                key: "compare-\(repo)",
                title: L("Compare Revisions", "比较版本") + " — \(URL(fileURLWithPath: repo).lastPathComponent)",
                size: NSSize(width: 780, height: 540),
                view: CompareRevisionsWindowView(repoPath: repo)
            )

        case .blame:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths),
                  let file = selectedPaths.first else { return }
            presentWindow(
                key: "blame-dlg-\(file)",
                title: L("Git Blame", "Git 追溯"),
                size: NSSize(width: 460, height: 240),
                view: BlameDialogView(repoPath: repo, filePath: file)
            )

        case .submoduleAdd:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths) else { return }
            presentWindow(
                key: "sub-add-\(repo)",
                title: L("Add Submodule", "新增子模块"),
                size: NSSize(width: 500, height: 260),
                view: AddSubmoduleWindowView(repoPath: repo)
            )

        case .submoduleUpdate:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths) else { return }
            presentWindow(
                key: "sub-update-\(repo)",
                title: L("Update Submodules", "更新子模块"),
                size: NSSize(width: 580, height: 420),
                view: UpdateSubmoduleWindowView(repoPath: repo)
            )

        case .submoduleManage:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths) else { return }
            presentWindow(
                key: "sub-manage-\(repo)",
                title: L("Submodules", "管理子模块") + " — \(URL(fileURLWithPath: repo).lastPathComponent)",
                size: NSSize(width: 680, height: 440),
                view: SubmodulesWindowView(repoPath: repo)
            )

        default:
            AlertHelper.showInfo(L("Coming in V2", "V2 即将支持"), message: L("SVN operations will be enabled in V2.", "SVN 操作将在 V2 版本启用。"))
        }
    }

    // MARK: - Helper Presentation Methods

    func presentWindow<V: View>(key: String, title: String, size: NSSize, autosave: String? = nil, view: V) {
        if let existing = controllers[key] {
            existing.showAndFocus()
            return
        }
        let ctrl = HostedWindowController(
            title: title,
            size: size,
            autosaveName: autosave,
            rootView: view
        ) { [weak self] in
            self?.controllers.removeValue(forKey: key)
        }
        controllers[key] = ctrl
        ctrl.showAndFocus()
    }

    func closeWindow(key: String) {
        controllers[key]?.close()
    }

    func openAuthConfig(for repoPath: String) {
        presentWindow(
            key: "auth-\(repoPath)",
            title: L("Authentication", "配置身份验证") + " — \(URL(fileURLWithPath: repoPath).lastPathComponent)",
            size: NSSize(width: 500, height: 340),
            view: AuthenticationConfigView(repoPath: repoPath)
        )
    }

    func openChangelists(repoPath: String) {
        presentWindow(
            key: "changelists-\(repoPath)",
            title: L("Manage Changelists", "管理变更列表"),
            size: NSSize(width: 480, height: 360),
            view: ChangelistsWindowView(repoPath: repoPath)
        )
    }

    func openHiddenFiles(repoPath: String) {
        presentWindow(
            key: "hidden-files-\(repoPath)",
            title: L("Hidden Files", "隐藏文件规则"),
            size: NSSize(width: 520, height: 380),
            view: HiddenFilesWindowView(repoPath: repoPath)
        )
    }

    func openEditNotes(repoPath: String, commitHash: String, currentNote: String) {
        presentWindow(
            key: "notes-\(commitHash)",
            title: L("Edit Commit Notes", "编辑备注"),
            size: NSSize(width: 500, height: 320),
            view: EditNotesWindowView(repoPath: repoPath, commitHash: commitHash, initialNote: currentNote)
        )
    }

    func openEditCommitMessage(repoPath: String, initialMessage: String, onSaved: @escaping () -> Void) {
        presentWindow(
            key: "edit-msg-\(repoPath)",
            title: L("Edit Commit Message", "编辑日志信息"),
            size: NSSize(width: 500, height: 300),
            view: EditCommitMessageWindowView(repoPath: repoPath, initialMessage: initialMessage, onSaved: onSaved)
        )
    }

    func openBlameResult(repoPath: String, filePath: String, revision: String, ignoreWhitespace: Bool, hideAuthorAndDate: Bool) {
        presentWindow(
            key: "blame-res-\(filePath)-\(revision)",
            title: L("Blame", "追溯") + ": \(URL(fileURLWithPath: filePath).lastPathComponent) (\(revision))",
            size: NSSize(width: 920, height: 620),
            view: BlameResultWindowView(
                repoPath: repoPath,
                filePath: filePath,
                revision: revision,
                ignoreWhitespace: ignoreWhitespace,
                hideAuthorAndDate: hideAuthorAndDate
            )
        )
    }

    func openCherryPickWithCommits(repoPath: String, commits: [VcsCommit]) {
        let items = commits.enumerated().map { idx, c in
            GitCherryPickItem(order: idx + 1, hash: c.hash, shortHash: c.shortHash, author: c.author, date: c.date, message: c.subject)
        }
        presentWindow(
            key: "cherrypick-\(repoPath)-\(UUID().uuidString)",
            title: L("Cherry-Pick", "摘取 (Cherry-Pick)") + " — \(URL(fileURLWithPath: repoPath).lastPathComponent)",
            size: NSSize(width: 760, height: 500),
            view: CherryPickWindowView(repoPath: repoPath, initialItems: items)
        )
    }

    func openCompareRevisions(repoPath: String, rev1: String, rev2: String) {
        presentWindow(
            key: "compare-\(repoPath)-\(rev1)-\(rev2)",
            title: L("Compare Revisions", "比较版本") + " — \(rev1.prefix(7)) ↔ \(rev2.prefix(7))",
            size: NSSize(width: 780, height: 540),
            view: CompareRevisionsWindowView(repoPath: repoPath, initialRev1: rev1, initialRev2: rev2)
        )
    }

    func openRepoBrowser(repoPath: String, revision: String) {
        presentWindow(
            key: "browser-\(repoPath)-\(revision)",
            title: L("Repo-browser", "版本库浏览器") + " (\(revision))",
            size: NSSize(width: 820, height: 560),
            view: RepoBrowserWindowView(repoPath: repoPath, initialRevision: revision)
        )
    }

    func openRemotes(repoPath: String) {
        presentWindow(
            key: "remotes-\(repoPath)",
            title: L("Manage Remotes", "管理远程") + " — \(URL(fileURLWithPath: repoPath).lastPathComponent)",
            size: NSSize(width: 580, height: 380),
            view: RemotesWindowView(repoPath: repoPath)
        )
    }

    func openImageDiff(leftPath: String, rightPath: String, leftTitle: String, rightTitle: String) {
        presentWindow(
            key: "imgdiff-\(UUID().uuidString)",
            title: L("Image Comparison", "图片对比") + " — \(URL(fileURLWithPath: rightPath).lastPathComponent)",
            size: NSSize(width: 860, height: 600),
            view: ImageDiffWindowView(leftPath: leftPath, rightPath: rightPath, leftTitle: leftTitle, rightTitle: rightTitle)
        )
    }

    // MARK: - Diff & Task Helpers

    func openDiffWithRevision(repoPath: String, filePath: String, revision: String, rightTitle: String) {
        Task {
            let ext = URL(fileURLWithPath: filePath).pathExtension
            let name = URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent
            let tempFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(name)_\(revision.prefix(7))_\(UUID().uuidString.prefix(6)).\(ext)")
            do {
                try await AppContainer.shared.gitProvider.extractFile(repoPath: repoPath, path: filePath, revision: revision, to: tempFile.path)
                launchDiffFiles(leftPath: tempFile.path, rightPath: filePath, leftTitle: revision, rightTitle: rightTitle)
            } catch {
                AlertHelper.showError(error)
            }
        }
    }

    func openDiffBetweenRevisions(repoPath: String, filePath: String, leftRev: String, rightRev: String) {
        Task {
            let ext = URL(fileURLWithPath: filePath).pathExtension
            let name = URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent
            let tempLeft = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(name)_\(leftRev.prefix(7))_\(UUID().uuidString.prefix(6)).\(ext)")
            let tempRight = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(name)_\(rightRev.prefix(7))_\(UUID().uuidString.prefix(6)).\(ext)")
            do {
                try await AppContainer.shared.gitProvider.extractFile(repoPath: repoPath, path: filePath, revision: leftRev, to: tempLeft.path)
                try await AppContainer.shared.gitProvider.extractFile(repoPath: repoPath, path: filePath, revision: rightRev, to: tempRight.path)
                launchDiffFiles(leftPath: tempLeft.path, rightPath: tempRight.path, leftTitle: leftRev, rightTitle: rightRev)
            } catch {
                AlertHelper.showError(error)
            }
        }
    }

    func openDiffPreviousVersion(repoPath: String, filePath: String) {
        openDiffBetweenRevisions(repoPath: repoPath, filePath: filePath, leftRev: "HEAD~1", rightRev: "HEAD")
    }

    func launchDiffFiles(leftPath: String, rightPath: String, leftTitle: String, rightTitle: String) {
        let prefs = AppContainer.shared.repositoryManager.currentConfigSnapshot().preferences
        do {
            let outcome = try AppContainer.shared.diffToolManager.launchDiff(
                leftPath: leftPath,
                rightPath: rightPath,
                leftTitle: leftTitle,
                rightTitle: rightTitle,
                preferences: prefs
            )
            switch outcome {
            case .launchedExternal:
                break
            case .openBuiltInImageDiff(let l, let r, let lt, let rt):
                openImageDiff(leftPath: l, rightPath: r, leftTitle: lt, rightTitle: rt)
            case .noToolConfigured:
                AlertHelper.showInfo(
                    L("No Diff Tool Configured", "未配置对比工具"),
                    message: L("Please select an external diff tool in RepoShell General Preferences.", "请在 RepoShell 通用偏好设置中选择外部对比工具。")
                )
            }
        } catch {
            AlertHelper.showError(error)
        }
    }

    func runTaskWithProgress(
        title: String,
        repoPath: String?,
        operation: @escaping @Sendable (@escaping @Sendable (String) -> Void) async throws -> VcsCommandResult
    ) {
        let model = TaskProgressModel(title: title, repoPath: repoPath, operation: operation)
        let key = "task-\(UUID().uuidString)"
        let ctrl = HostedWindowController(
            title: title,
            size: NSSize(width: 580, height: 320),
            rootView: TaskProgressWindowView(model: model) { [weak self] in
                self?.controllers[key]?.close()
            }
        ) { [weak self] in
            self?.controllers.removeValue(forKey: key)
        }
        controllers[key] = ctrl
        ctrl.showAndFocus()
        model.start()
    }

    func promptAskpass(request: AskpassIPCRequest) async -> AskpassIPCResponse {
        await withCheckedContinuation { continuation in
            let key = "askpass-\(request.requestId.uuidString)"
            var completed = false
            let finish: (AskpassIPCResponse) -> Void = { [weak self] resp in
                guard !completed else { return }
                completed = true
                self?.controllers[key]?.close()
                continuation.resume(returning: resp)
            }

            let view = AskpassPromptView(request: request, onComplete: finish)
            let ctrl = HostedWindowController(
                title: L("Authentication", "身份验证"),
                size: NSSize(width: 440, height: 240),
                rootView: view
            ) { [weak self] in
                self?.controllers.removeValue(forKey: key)
                if !completed {
                    completed = true
                    continuation.resume(returning: AskpassIPCResponse(approved: false))
                }
            }
            controllers[key] = ctrl
            ctrl.showAndFocus()
        }
    }

    private func resolveRepo(_ repoPath: String?, targetDir: String, selectedPaths: [String]) -> String? {
        if let repoPath = repoPath { return repoPath }
        let cfg = AppContainer.shared.repositoryManager.currentConfigSnapshot()
        if let first = selectedPaths.first, let matched = cfg.matchingRepository(for: first) {
            return matched.path
        }
        return cfg.matchingRepository(for: targetDir)?.path
    }
}
