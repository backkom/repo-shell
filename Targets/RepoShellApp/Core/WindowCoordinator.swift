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
            if vcsType(for: repo) == .svn {
                dispatch(action: .svnCommit, repoPath: repo, targetDir: targetDir, selectedPaths: selectedPaths)
                return
            }
            presentWindow(
                key: "commit-\(repo)",
                title: L("Git Commit", "Git 提交") + " — \(URL(fileURLWithPath: repo).lastPathComponent)",
                size: NSSize(width: 820, height: 600),
                autosave: "CommitWindow",
                view: CommitWindowView(repoPath: repo, preselectedPaths: selectedPaths)
            )

        case .gitPull:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths) else { return }
            if vcsType(for: repo) == .svn {
                dispatch(action: .svnUpdate, repoPath: repo, targetDir: targetDir, selectedPaths: selectedPaths)
                return
            }
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
            if vcsType(for: repo) == .svn {
                openSvnLog(repoPath: repo, target: filterPath)
            } else {
                presentWindow(
                    key: "log-\(repo)-\(filterPath ?? "")",
                    title: L("Show Log", "显示日志") + " — \(URL(fileURLWithPath: repo).lastPathComponent)",
                    size: NSSize(width: 960, height: 680),
                    autosave: "LogWindow",
                    view: LogWindowView(repoPath: repo, initialPathFilter: filterPath)
                )
            }

        case .checkForModifications:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths) else { return }
            if vcsType(for: repo) == .svn {
                presentWindow(
                    key: "svn-modifications-\(repo)",
                    title: L("Check for Modifications", "检测改动") + " — \(URL(fileURLWithPath: repo).lastPathComponent)",
                    size: NSSize(width: 860, height: 560),
                    autosave: "SvnModificationsWindow",
                    view: SvnModificationsWindowView(repoPath: repo)
                )
            } else {
                presentWindow(
                    key: "modifications-\(repo)",
                    title: L("Check for Modifications", "检测改动") + " — \(URL(fileURLWithPath: repo).lastPathComponent)",
                    size: NSSize(width: 840, height: 560),
                    autosave: "ModificationsWindow",
                    view: ModificationsWindowView(repoPath: repo)
                )
            }

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
            openRepoBrowser(repoPath: repo, revision: "HEAD")

        case .resolveConflicts:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths) else { return }
            if vcsType(for: repo) == .svn {
                presentWindow(
                    key: "svn-resolve-\(repo)",
                    title: L("Resolve Conflicts", "解决冲突") + " — \(URL(fileURLWithPath: repo).lastPathComponent)",
                    size: NSSize(width: 680, height: 460),
                    view: SvnResolveConflictsWindowView(repoPath: repo, preselectedPaths: selectedPaths)
                )
            } else {
                presentWindow(
                    key: "resolve-\(repo)",
                    title: L("Resolve Conflicts", "解决冲突") + " — \(URL(fileURLWithPath: repo).lastPathComponent)",
                    size: NSSize(width: 680, height: 460),
                    view: ResolveWindowView(repoPath: repo)
                )
            }

        case .revert:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths) else { return }
            if vcsType(for: repo) == .svn {
                presentWindow(
                    key: "svn-revert-\(repo)",
                    title: L("SVN Revert", "SVN 复原") + " — \(URL(fileURLWithPath: repo).lastPathComponent)",
                    size: NSSize(width: 660, height: 440),
                    view: SvnRevertWindowView(repoPath: repo, preselectedPaths: selectedPaths)
                )
            } else {
                presentWindow(
                    key: "revert-\(repo)",
                    title: L("Revert", "复原") + " — \(URL(fileURLWithPath: repo).lastPathComponent)",
                    size: NSSize(width: 680, height: 460),
                    view: RevertWindowView(repoPath: repo, preselectedPaths: selectedPaths)
                )
            }

        case .checkout:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths) else { return }
            if vcsType(for: repo) == .svn {
                dispatch(action: .svnSwitch, repoPath: repo, targetDir: targetDir, selectedPaths: selectedPaths)
                return
            }
            presentWindow(
                key: "checkout-\(repo)",
                title: L("Checkout / Switch", "签出 / 切换") + " — \(URL(fileURLWithPath: repo).lastPathComponent)",
                size: NSSize(width: 500, height: 370),
                view: SwitchCheckoutWindowView(repoPath: repo)
            )

        case .createBranch:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths) else { return }
            if vcsType(for: repo) == .svn {
                dispatch(action: .svnBranchTag, repoPath: repo, targetDir: targetDir, selectedPaths: selectedPaths)
                return
            }
            presentWindow(
                key: "create-branch-\(repo)",
                title: L("Create Branch", "创建分支") + " — \(URL(fileURLWithPath: repo).lastPathComponent)",
                size: NSSize(width: 480, height: 310),
                view: CreateBranchWindowView(repoPath: repo)
            )

        case .createTag:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths) else { return }
            if vcsType(for: repo) == .svn {
                dispatch(action: .svnBranchTag, repoPath: repo, targetDir: targetDir, selectedPaths: selectedPaths)
                return
            }
            presentWindow(
                key: "create-tag-\(repo)",
                title: L("Create Tag", "创建标签") + " — \(URL(fileURLWithPath: repo).lastPathComponent)",
                size: NSSize(width: 480, height: 330),
                view: CreateTagWindowView(repoPath: repo)
            )

        case .merge:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths) else { return }
            if vcsType(for: repo) == .svn {
                dispatch(action: .svnMerge, repoPath: repo, targetDir: targetDir, selectedPaths: selectedPaths)
                return
            }
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
            if vcsType(for: repo) == .svn {
                let source = selectedPaths.first ?? repo
                openSvnExport(source: source, repoPath: repo, revision: "WORKING")
            } else {
                presentWindow(
                    key: "export-\(repo)",
                    title: L("Export", "导出") + " — \(URL(fileURLWithPath: repo).lastPathComponent)",
                    size: NSSize(width: 500, height: 300),
                    view: ExportWindowView(repoPath: repo)
                )
            }

        case .diff:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths) else { return }
            if vcsType(for: repo) == .svn {
                let target = selectedPaths.first ?? targetDir
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: target, isDirectory: &isDir), isDir.boolValue {
                    Task {
                        do {
                            let diff = try await container.svnProvider.diffText(repoPath: repo, paths: selectedPaths)
                            if diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                AlertHelper.showInfo(L("No Differences", "无差异"), message: L("No textual changes found in selected folder.", "所选目录没有文本差异。"))
                            } else {
                                let tmp = FileManager.default.temporaryDirectory
                                    .appendingPathComponent("svn-diff-\(UUID().uuidString.prefix(6)).diff")
                                try diff.write(to: tmp, atomically: true, encoding: .utf8)
                                NSWorkspace.shared.open(tmp)
                            }
                        } catch {
                            AlertHelper.showError(error)
                        }
                    }
                } else {
                    openDiffWithRevision(repoPath: repo, filePath: target, revision: "BASE", rightTitle: L("Working Copy", "工作副本"))
                }
            } else if let file = selectedPaths.first {
                openDiffWithRevision(repoPath: repo, filePath: file, revision: "HEAD", rightTitle: L("Working Tree", "工作区"))
            }

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
            let isSvn = vcsType(for: repo) == .svn
            runTaskWithProgress(title: isSvn ? L("SVN Add", "SVN 添加") : L("Git Add", "添加文件"), repoPath: repo) { _ in
                if isSvn {
                    return try await container.svnProvider.add(repoPath: repo, paths: selectedPaths)
                }
                return try await container.gitProvider.add(repoPath: repo, paths: selectedPaths)
            }

        case .delete:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths) else { return }
            let isSvn = vcsType(for: repo) == .svn
            if AlertHelper.confirm(
                title: L("Delete Files", "删除文件"),
                message: isSvn
                    ? L("Schedule selected items for SVN deletion and remove local copies?", "确定从 SVN 版本控制和本地工作副本删除所选文件吗？")
                    : L("Remove selected files from Git and working directory?", "确定要从 Git 和工作区删除所选文件吗？")
            ) {
                runTaskWithProgress(title: L("Delete", "删除"), repoPath: repo) { _ in
                    if isSvn {
                        return try await container.svnProvider.remove(repoPath: repo, paths: selectedPaths, keepLocal: false)
                    }
                    return try await container.gitProvider.remove(repoPath: repo, paths: selectedPaths, keepLocal: false)
                }
            }

        case .deleteKeepLocal:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths) else { return }
            let isSvn = vcsType(for: repo) == .svn
            runTaskWithProgress(title: L("Delete (Keep Local)", "删除（保留本地拷贝）"), repoPath: repo) { _ in
                if isSvn {
                    return try await container.svnProvider.remove(repoPath: repo, paths: selectedPaths, keepLocal: true)
                }
                return try await container.gitProvider.remove(repoPath: repo, paths: selectedPaths, keepLocal: true)
            }

        case .rename:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths),
                  let file = selectedPaths.first else { return }
            if vcsType(for: repo) == .svn {
                presentWindow(
                    key: "svn-move-\(file)",
                    title: L("SVN Rename", "SVN 重命名"),
                    size: NSSize(width: 480, height: 220),
                    view: SvnMoveRenameWindowView(repoPath: repo, sourcePath: file, isMove: false)
                )
            } else {
                presentWindow(
                    key: "rename-\(file)",
                    title: L("Rename", "重命名"),
                    size: NSSize(width: 460, height: 180),
                    view: RenameWindowView(repoPath: repo, sourcePath: file)
                )
            }

        case .addToIgnore:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths) else { return }
            if vcsType(for: repo) == .svn {
                presentWindow(
                    key: "svn-ignore-\(repo)",
                    title: L("Add to Ignore List", "添加到忽略清单"),
                    size: NSSize(width: 500, height: 260),
                    view: SvnAddToIgnoreWindowView(repoPath: repo, targetPaths: selectedPaths)
                )
            } else {
                presentWindow(
                    key: "ignore-\(repo)",
                    title: L("Add to Ignore List", "添加到忽略清单"),
                    size: NSSize(width: 480, height: 240),
                    view: IgnoreWindowView(repoPath: repo, targetPaths: selectedPaths)
                )
            }

        case .repoInfo:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths) else { return }
            if vcsType(for: repo) == .svn {
                dispatch(action: .svnInfo, repoPath: repo, targetDir: targetDir, selectedPaths: selectedPaths)
                return
            }
            presentWindow(
                key: "info-\(repo)",
                title: L("Repo Info", "版本库信息") + " — \(URL(fileURLWithPath: repo).lastPathComponent)",
                size: NSSize(width: 680, height: 500),
                view: RepoInfoWindowView(repoPath: repo)
            )

        case .cleanup:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths) else { return }
            if vcsType(for: repo) == .svn {
                dispatch(action: .svnCleanup, repoPath: repo, targetDir: targetDir, selectedPaths: selectedPaths)
                return
            }
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
            openCompareRevisions(repoPath: repo, rev1: vcsType(for: repo) == .svn ? "1" : "HEAD~1", rev2: "HEAD")

        case .blame:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths),
                  let file = selectedPaths.first else { return }
            if vcsType(for: repo) == .svn {
                presentWindow(
                    key: "blame-dlg-\(file)",
                    title: L("SVN Blame", "SVN 追溯"),
                    size: NSSize(width: 460, height: 240),
                    view: SvnBlameDialogView(repoPath: repo, filePath: file)
                )
            } else {
                presentWindow(
                    key: "blame-dlg-\(file)",
                    title: L("Git Blame", "Git 追溯"),
                    size: NSSize(width: 460, height: 240),
                    view: BlameDialogView(repoPath: repo, filePath: file)
                )
            }

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

        // MARK: - V2 SVN Explicit Actions

        case .svnCommit:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths) else { return }
            presentWindow(
                key: "svn-commit-\(repo)",
                title: L("SVN Commit", "SVN 提交") + " — \(URL(fileURLWithPath: repo).lastPathComponent)",
                size: NSSize(width: 820, height: 600),
                autosave: "SvnCommitWindow",
                view: SvnCommitWindowView(repoPath: repo, preselectedPaths: selectedPaths)
            )

        case .svnCheckout:
            openSvnCheckout(parentDir: targetDir)

        case .svnCreateRepo:
            let dir = selectedPaths.first ?? targetDir
            presentWindow(
                key: "svn-create-\(dir)",
                title: L("Create SVN Repository", "创建 SVN 版本库"),
                size: NSSize(width: 500, height: 240),
                view: SvnCreateRepoWindowView(initialPath: dir)
            )

        case .svnImport:
            let dir = selectedPaths.first ?? targetDir
            presentWindow(
                key: "svn-import-\(dir)",
                title: L("SVN Import", "SVN 导入"),
                size: NSSize(width: 540, height: 320),
                view: SvnImportWindowView(initialLocalPath: dir)
            )

        case .svnUpdate:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths) else { return }
            let updateTargets = selectedPaths.isEmpty ? [targetDir] : selectedPaths
            runTaskWithProgress(
                title: L("SVN Update", "SVN 更新") + " — \(URL(fileURLWithPath: repo).lastPathComponent)",
                repoPath: repo
            ) { onLine in
                try await container.runSvnInteractive(repoPath: repo) { env, auth in
                    try await container.svnProvider.update(
                        repoPath: repo,
                        options: SvnUpdateOptions(paths: updateTargets),
                        environment: env,
                        auth: auth,
                        onOutputLine: { line, _ in onLine(line) }
                    )
                }
            }

        case .svnUpdateToRevision:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths) else { return }
            presentWindow(
                key: "svn-uprev-\(repo)",
                title: L("Update to Revision", "更新至指定版本") + " — \(URL(fileURLWithPath: repo).lastPathComponent)",
                size: NSSize(width: 520, height: 390),
                view: SvnUpdateToRevisionWindowView(repoPath: repo, selectedPaths: selectedPaths)
            )

        case .svnBranchTag:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths) else { return }
            presentWindow(
                key: "svn-branch-\(repo)",
                title: L("SVN Branch / Tag", "SVN 分支 / 标签") + " — \(URL(fileURLWithPath: repo).lastPathComponent)",
                size: NSSize(width: 560, height: 420),
                view: SvnBranchTagWindowView(repoPath: repo)
            )

        case .svnSwitch:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths) else { return }
            presentWindow(
                key: "svn-switch-\(repo)",
                title: L("SVN Switch", "SVN 切换") + " — \(URL(fileURLWithPath: repo).lastPathComponent)",
                size: NSSize(width: 540, height: 350),
                view: SvnSwitchWindowView(repoPath: repo)
            )

        case .svnMerge:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths) else { return }
            presentWindow(
                key: "svn-merge-\(repo)",
                title: L("SVN Merge", "SVN 合并") + " — \(URL(fileURLWithPath: repo).lastPathComponent)",
                size: NSSize(width: 600, height: 500),
                view: SvnMergeWindowView(repoPath: repo)
            )

        case .svnMove:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths),
                  let src = selectedPaths.first else { return }
            presentWindow(
                key: "svn-move-\(src)",
                title: L("SVN Move", "SVN 移动"),
                size: NSSize(width: 480, height: 220),
                view: SvnMoveRenameWindowView(repoPath: repo, sourcePath: src, isMove: true)
            )

        case .svnCleanup:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths) else { return }
            presentWindow(
                key: "svn-cleanup-\(repo)",
                title: L("SVN Clean up", "SVN 清理") + " — \(URL(fileURLWithPath: repo).lastPathComponent)",
                size: NSSize(width: 520, height: 310),
                view: SvnCleanupWindowView(repoPath: repo, targetPaths: selectedPaths)
            )

        case .svnInfo:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths) else { return }
            let target = selectedPaths.first ?? repo
            presentWindow(
                key: "svn-info-\(target)",
                title: L("SVN Info", "SVN 信息") + " — \(URL(fileURLWithPath: target).lastPathComponent)",
                size: NSSize(width: 620, height: 470),
                view: SvnInfoWindowView(repoPath: repo, targetPath: target)
            )

        case .svnUpgrade:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths) else { return }
            if AlertHelper.confirm(
                title: L("Upgrade Working Copy", "升级工作副本"),
                message: L("Upgrade working copy metadata format to match your installed Subversion version?", "确定要升级此工作副本格式以匹配当前 Subversion 版本吗？")
            ) {
                runTaskWithProgress(title: L("SVN Upgrade", "SVN 升级工作副本"), repoPath: repo) { onLine in
                    try await container.svnProvider.upgradeWorkingCopy(
                        repoPath: repo,
                        onOutputLine: { line, _ in onLine(line) }
                    )
                }
            }

        case .svnLock:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths) else { return }
            let targets = selectedPaths.isEmpty ? [targetDir] : selectedPaths
            presentWindow(
                key: "svn-lock-\(repo)",
                title: L("Get Lock", "获取锁") + " — \(URL(fileURLWithPath: repo).lastPathComponent)",
                size: NSSize(width: 480, height: 230),
                view: SvnLockUnlockWindowView(repoPath: repo, targetPaths: targets, isUnlock: false)
            )

        case .svnUnlock:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths) else { return }
            let targets = selectedPaths.isEmpty ? [targetDir] : selectedPaths
            presentWindow(
                key: "svn-unlock-\(repo)",
                title: L("Release Lock", "释放锁") + " — \(URL(fileURLWithPath: repo).lastPathComponent)",
                size: NSSize(width: 480, height: 210),
                view: SvnLockUnlockWindowView(repoPath: repo, targetPaths: targets, isUnlock: true)
            )

        case .svnProperties:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths) else { return }
            let target = selectedPaths.first ?? repo
            presentWindow(
                key: "svn-props-\(target)",
                title: L("SVN Properties", "SVN 属性") + " — \(URL(fileURLWithPath: target).lastPathComponent)",
                size: NSSize(width: 680, height: 460),
                view: SvnPropertiesWindowView(repoPath: repo, target: target)
            )

        case .svnRelocate:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths) else { return }
            presentWindow(
                key: "svn-relocate-\(repo)",
                title: L("SVN Relocate", "SVN 重定位") + " — \(URL(fileURLWithPath: repo).lastPathComponent)",
                size: NSSize(width: 520, height: 220),
                view: SvnRelocateWindowView(repoPath: repo)
            )

        case .svnCreatePatch:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths) else { return }
            presentWindow(
                key: "svn-mkpatch-\(repo)",
                title: L("Create Patch", "创建补丁") + " — \(URL(fileURLWithPath: repo).lastPathComponent)",
                size: NSSize(width: 520, height: 230),
                view: SvnCreatePatchWindowView(repoPath: repo, targetPaths: selectedPaths)
            )

        case .svnApplyPatch:
            guard let repo = resolveRepo(repoPath, targetDir: targetDir, selectedPaths: selectedPaths) else { return }
            presentWindow(
                key: "svn-appatch-\(repo)",
                title: L("Apply Patch", "应用补丁") + " — \(URL(fileURLWithPath: repo).lastPathComponent)",
                size: NSSize(width: 520, height: 270),
                view: SvnApplyPatchWindowView(repoPath: repo)
            )
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

    func openBlameResult(
        repoPath: String,
        filePath: String,
        revision: String,
        ignoreWhitespace: Bool,
        hideAuthorAndDate: Bool,
        vcsType: VcsType? = nil
    ) {
        let resolvedType = vcsType ?? self.vcsType(for: repoPath)
        presentWindow(
            key: "blame-res-\(filePath)-\(revision)",
            title: L("Blame", "追溯") + ": \(URL(fileURLWithPath: filePath).lastPathComponent) (\(revision))",
            size: NSSize(width: 920, height: 620),
            view: BlameResultWindowView(
                repoPath: repoPath,
                filePath: filePath,
                revision: revision,
                ignoreWhitespace: ignoreWhitespace,
                hideAuthorAndDate: hideAuthorAndDate,
                vcsType: resolvedType
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
        if vcsType(for: repoPath) == .svn {
            presentWindow(
                key: "svn-compare-\(repoPath)-\(rev1)-\(rev2)",
                title: L("Compare Revisions", "比较版本") + " — r\(rev1) ↔ r\(rev2)",
                size: NSSize(width: 780, height: 540),
                view: SvnCompareRevisionsWindowView(repoPath: repoPath, initialRev1: rev1, initialRev2: rev2)
            )
        } else {
            presentWindow(
                key: "compare-\(repoPath)-\(rev1)-\(rev2)",
                title: L("Compare Revisions", "比较版本") + " — \(rev1.prefix(7)) ↔ \(rev2.prefix(7))",
                size: NSSize(width: 780, height: 540),
                view: CompareRevisionsWindowView(repoPath: repoPath, initialRev1: rev1, initialRev2: rev2)
            )
        }
    }

    func openRepoBrowser(repoPath: String, revision: String) {
        if vcsType(for: repoPath) == .svn {
            presentWindow(
                key: "svn-browser-\(repoPath)-\(revision)",
                title: L("Repo-browser", "版本库浏览器") + " (\(revision))",
                size: NSSize(width: 860, height: 580),
                view: SvnRepoBrowserWindowView(repoPath: repoPath, initialRevision: revision)
            )
        } else {
            presentWindow(
                key: "browser-\(repoPath)-\(revision)",
                title: L("Repo-browser", "版本库浏览器") + " (\(revision))",
                size: NSSize(width: 820, height: 560),
                view: RepoBrowserWindowView(repoPath: repoPath, initialRevision: revision)
            )
        }
    }

    func openSvnLog(repoPath: String?, target: String?) {
        let base = repoPath ?? target ?? ""
        presentWindow(
            key: "svn-log-\(base)-\(target ?? "")",
            title: L("Show Log", "显示日志") + (repoPath.map { " — \(URL(fileURLWithPath: $0).lastPathComponent)" } ?? ""),
            size: NSSize(width: 960, height: 680),
            autosave: "SvnLogWindow",
            view: SvnLogWindowView(repoPath: base, initialPathFilter: target)
        )
    }

    func openSvnCheckout(parentDir: String? = nil, initialURL: String = "") {
        let dir = parentDir ?? FileManager.default.homeDirectoryForCurrentUser.path
        presentWindow(
            key: "svn-checkout-\(dir)",
            title: L("SVN Checkout", "SVN 签出"),
            size: NSSize(width: 560, height: 420),
            view: SvnCheckoutWindowView(initialParentDir: dir, initialURL: initialURL)
        )
    }

    func openSvnExport(source: String, repoPath: String? = nil, revision: String = "WORKING") {
        presentWindow(
            key: "svn-export-\(source)",
            title: L("SVN Export", "SVN 导出"),
            size: NSSize(width: 520, height: 320),
            view: SvnExportWindowView(sourcePathOrURL: source, repoPath: repoPath, initialRevision: revision)
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
        let isSvn = vcsType(for: repoPath) == .svn
        Task {
            let ext = URL(fileURLWithPath: filePath).pathExtension
            let name = URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent
            let suffix = ext.isEmpty ? "" : ".\(ext)"
            let tempFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(name)_\(revision.prefix(7))_\(UUID().uuidString.prefix(6))\(suffix)")
            do {
                if isSvn {
                    try await AppContainer.shared.runSvnInteractive(repoPath: repoPath) { env, auth in
                        try await AppContainer.shared.svnProvider.extractFile(
                            repoPath: repoPath,
                            path: filePath,
                            revision: revision,
                            to: tempFile.path,
                            environment: env,
                            auth: auth
                        )
                    }
                } else {
                    try await AppContainer.shared.gitProvider.extractFile(repoPath: repoPath, path: filePath, revision: revision, to: tempFile.path)
                }
                launchDiffFiles(leftPath: tempFile.path, rightPath: filePath, leftTitle: revision, rightTitle: rightTitle)
            } catch {
                AlertHelper.showError(error)
            }
        }
    }

    func openDiffBetweenRevisions(repoPath: String, filePath: String, leftRev: String, rightRev: String) {
        let isSvn = vcsType(for: repoPath) == .svn
        Task {
            let ext = URL(fileURLWithPath: filePath).pathExtension
            let name = URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent
            let suffix = ext.isEmpty ? "" : ".\(ext)"
            let tempLeft = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(name)_\(leftRev.prefix(7))_\(UUID().uuidString.prefix(6))\(suffix)")
            let tempRight = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(name)_\(rightRev.prefix(7))_\(UUID().uuidString.prefix(6))\(suffix)")
            do {
                if isSvn {
                    try await AppContainer.shared.runSvnInteractive(repoPath: repoPath) { env, auth in
                        try await AppContainer.shared.svnProvider.extractFile(
                            repoPath: repoPath,
                            path: filePath,
                            revision: leftRev,
                            to: tempLeft.path,
                            environment: env,
                            auth: auth
                        )
                        try await AppContainer.shared.svnProvider.extractFile(
                            repoPath: repoPath,
                            path: filePath,
                            revision: rightRev,
                            to: tempRight.path,
                            environment: env,
                            auth: auth
                        )
                    }
                } else {
                    try await AppContainer.shared.gitProvider.extractFile(repoPath: repoPath, path: filePath, revision: leftRev, to: tempLeft.path)
                    try await AppContainer.shared.gitProvider.extractFile(repoPath: repoPath, path: filePath, revision: rightRev, to: tempRight.path)
                }
                launchDiffFiles(leftPath: tempLeft.path, rightPath: tempRight.path, leftTitle: leftRev, rightTitle: rightRev)
            } catch {
                AlertHelper.showError(error)
            }
        }
    }

    func openDiffPreviousVersion(repoPath: String, filePath: String) {
        if vcsType(for: repoPath) == .svn {
            Task {
                if let prevRev = try? await AppContainer.shared.svnProvider.previousRevision(of: filePath, repoPath: repoPath) {
                    openDiffBetweenRevisions(repoPath: repoPath, filePath: filePath, leftRev: prevRev, rightRev: "BASE")
                } else {
                    AlertHelper.showInfo(L("No Previous Version", "没有前一版本"), message: L("Could not determine an earlier SVN revision for this file.", "无法找到该文件的更早 SVN 修订版本。"))
                }
            }
        } else {
            openDiffBetweenRevisions(repoPath: repoPath, filePath: filePath, leftRev: "HEAD~1", rightRev: "HEAD")
        }
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

    private func vcsType(for repoPath: String) -> VcsType {
        let cfg = AppContainer.shared.repositoryManager.currentConfigSnapshot()
        if let matched = cfg.matchingRepository(for: repoPath) {
            return matched.vcsType
        }
        let svnMarker = URL(fileURLWithPath: PathUtils.normalize(repoPath)).appendingPathComponent(".svn").path
        let gitMarker = URL(fileURLWithPath: PathUtils.normalize(repoPath)).appendingPathComponent(".git").path
        if FileManager.default.fileExists(atPath: svnMarker) && !FileManager.default.fileExists(atPath: gitMarker) {
            return .svn
        }
        return .git
    }
}
