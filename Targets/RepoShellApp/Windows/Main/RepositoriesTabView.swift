import SwiftUI
import UniformTypeIdentifiers
import RepoShellShared

enum RepoVcsSubtab: String, CaseIterable {
    case git
    case svn
}

struct RepositoriesTabView: View {
    @ObservedObject private var repoManager = AppContainer.shared.repositoryManager
    @State private var selectedVcsTab: RepoVcsSubtab = .git
    @State private var selectedRepoID: UUID?
    @State private var showAddMenu = false
    @State private var showWorkspacePanel = false
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedVcsTab) {
                Label("Git (\(gitRepositories.count))", systemImage: "arrow.triangle.branch")
                    .tag(RepoVcsSubtab.git)
                Label("SVN (\(svnRepositories.count))", systemImage: "server.rack")
                    .tag(RepoVcsSubtab.svn)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .onChange(of: selectedVcsTab) { _ in
                selectedRepoID = nil
            }

            Divider()

            // Monitored Repositories List
            List(selection: $selectedRepoID) {
                Section(header: HStack {
                    Text(selectedVcsTab == .git
                         ? L("Git Repositories", "Git 版本库")
                         : L("SVN Working Copies", "SVN 工作副本"))
                    Spacer()
                    Text("\(filteredRepositories.count)")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }) {
                    if filteredRepositories.isEmpty {
                        Text(selectedVcsTab == .git
                             ? L("Drop Git repositories here or click + below to add.", "可将 Git 版本库拖放到此处，或点击下方 + 按钮添加。")
                             : L("Drop SVN working copies here or click + below to add or checkout.", "可将 SVN 工作副本拖放到此处，或点击下方 + 按钮添加或签出。"))
                            .foregroundColor(.secondary)
                            .padding(.vertical, 16)
                    } else {
                        ForEach(filteredRepositories) { repo in
                            RepositoryRowView(repo: repo)
                                .tag(repo.id)
                                .contextMenu {
                                    repoContextMenu(for: repo)
                                }
                        }
                    }
                }

                Section(header: HStack {
                    Text(L("Workspace Auto-Discovery Folders", "工作区自动扫描目录"))
                    Spacer()
                    Button(L("Add Folder…", "添加目录…")) {
                        if let url = AlertHelper.pickFolder(title: L("Select Workspace Parent Folder", "选择工作区父目录")) {
                            _ = repoManager.addWorkspaceRoot(at: url.path, maxDepth: 3)
                            AppContainer.shared.statusEngine.rebuildWatchersAndRefreshAll()
                        }
                    }
                    .buttonStyle(.link)
                    Button(L("Rescan", "重新扫描")) {
                        _ = repoManager.rescanWorkspaceRoots()
                        AppContainer.shared.statusEngine.rebuildWatchersAndRefreshAll()
                    }
                    .buttonStyle(.link)
                }) {
                    if repoManager.config.workspaceRoots.isEmpty {
                        Text(L("No workspace folders configured.", "未配置自动扫描父目录。"))
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(repoManager.config.workspaceRoots) { root in
                            HStack {
                                Image(systemName: "folder.fill")
                                    .foregroundColor(.accentColor)
                                VStack(alignment: .leading) {
                                    Text(URL(fileURLWithPath: root.path).lastPathComponent)
                                        .fontWeight(.medium)
                                    Text(root.path)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Text(L("Depth: \(root.maxDepth)", "深度: \(root.maxDepth)"))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Button {
                                    repoManager.removeWorkspaceRoot(id: root.id)
                                    AppContainer.shared.statusEngine.rebuildWatchersAndRefreshAll()
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                if !repoManager.config.excludedPaths.isEmpty {
                    Section(header: Text(L("Excluded Paths", "已排除路径"))) {
                        ForEach(repoManager.config.excludedPaths, id: \.self) { path in
                            HStack {
                                Image(systemName: "eye.slash")
                                    .foregroundColor(.secondary)
                                Text(path)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Button(L("Remove", "移除")) {
                                    repoManager.removeExclusion(path: path)
                                    _ = repoManager.rescanWorkspaceRoots()
                                    AppContainer.shared.statusEngine.rebuildWatchersAndRefreshAll()
                                }
                                .buttonStyle(.link)
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor, lineWidth: isDropTargeted ? 2 : 0)
                    .padding(4)
            )
            .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers: providers)
            }

            Divider()

            // Bottom Action Bar
            HStack(spacing: 8) {
                Menu {
                    Button(L("Add Existing Git / SVN Repository…", "添加现有 Git / SVN 版本库…")) {
                        if let url = AlertHelper.pickFolder(title: L("Select Git or SVN Repository", "选择 Git 或 SVN 版本库")) {
                            Task {
                                do {
                                    let entry = try await repoManager.addRepository(at: url.path)
                                    selectedVcsTab = (entry.vcsType == .svn ? .svn : .git)
                                    selectedRepoID = entry.id
                                    AppContainer.shared.triggerRefresh(repoPath: entry.path)
                                } catch {
                                    AlertHelper.showError(error)
                                }
                            }
                        }
                    }
                    Button(L("Add Workspace Parent Folder…", "添加工作区扫描目录…")) {
                        if let url = AlertHelper.pickFolder(title: L("Select Workspace Parent Folder", "选择工作区父目录")) {
                            _ = repoManager.addWorkspaceRoot(at: url.path, maxDepth: 3)
                            AppContainer.shared.statusEngine.rebuildWatchersAndRefreshAll()
                        }
                    }
                    Divider()
                    Button(L("Clone Existing Git Repository…", "克隆现有 Git 版本库…")) {
                        let home = FileManager.default.homeDirectoryForCurrentUser.path
                        AppContainer.shared.windowCoordinator.dispatch(action: .gitClone, repoPath: nil, targetDir: home, selectedPaths: [])
                    }
                    Button(L("Create New Git Repository…", "创建新的 Git 版本库…")) {
                        if let url = AlertHelper.pickFolder(title: L("Choose Folder for New Repository", "选择新建版本库目录")) {
                            AppContainer.shared.windowCoordinator.dispatch(action: .gitInit, repoPath: nil, targetDir: url.path, selectedPaths: [url.path])
                        }
                    }
                    Divider()
                    Button(L("SVN Checkout…", "SVN 签出…")) {
                        let home = FileManager.default.homeDirectoryForCurrentUser.path
                        AppContainer.shared.windowCoordinator.dispatch(action: .svnCheckout, repoPath: nil, targetDir: home, selectedPaths: [])
                    }
                    Button(L("Create New SVN Repository…", "创建新的 SVN 版本库…")) {
                        if let url = AlertHelper.pickFolder(title: L("Choose Folder for New SVN Repository", "选择新建 SVN 版本库目录")) {
                            AppContainer.shared.windowCoordinator.dispatch(action: .svnCreateRepo, repoPath: nil, targetDir: url.path, selectedPaths: [url.path])
                        }
                    }
                    Button(L("SVN Import…", "SVN 导入…")) {
                        if let url = AlertHelper.pickFolder(title: L("Select Folder to Import to SVN", "选择要导入到 SVN 的目录")) {
                            AppContainer.shared.windowCoordinator.dispatch(action: .svnImport, repoPath: nil, targetDir: url.path, selectedPaths: [url.path])
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 22, height: 22)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 34)
                .help(L("Add Repository or Workspace", "添加版本库或工作区"))

                Button {
                    if let id = selectedRepoID {
                        repoManager.removeRepository(id: id)
                        selectedRepoID = nil
                    }
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 22, height: 22)
                }
                .disabled(selectedRepoID == nil)
                .help(L("Remove Selected Repository", "移除选中版本库"))

                Button {
                    if let repo = selectedRepo {
                        AppContainer.shared.windowCoordinator.openAuthConfig(for: repo.path)
                    }
                } label: {
                    Image(systemName: "key.fill")
                        .frame(width: 22, height: 22)
                }
                .disabled(selectedRepoID == nil)
                .help(L("Configure Authentication", "配置身份验证"))

                Spacer()

                if let repo = selectedRepo {
                    if repo.vcsType == .svn {
                        Button(L("Update…", "更新…")) {
                            openAction(.svnUpdate, repo: repo)
                        }
                        Button(L("Commit…", "提交…")) {
                            openAction(.svnCommit, repo: repo)
                        }
                    } else {
                        Button(L("Commit…", "提交…")) {
                            openAction(.gitCommit, repo: repo)
                        }
                    }
                    Button(L("Show Log", "显示日志")) {
                        openAction(.showLog, repo: repo)
                    }
                    Button(L("Modifications", "检测改动")) {
                        openAction(.checkForModifications, repo: repo)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private var gitRepositories: [RepositoryEntry] {
        repoManager.config.repositories.filter { $0.vcsType == .git }
    }

    private var svnRepositories: [RepositoryEntry] {
        repoManager.config.repositories.filter { $0.vcsType == .svn }
    }

    private var filteredRepositories: [RepositoryEntry] {
        selectedVcsTab == .git ? gitRepositories : svnRepositories
    }

    private var selectedRepo: RepositoryEntry? {
        filteredRepositories.first { $0.id == selectedRepoID }
    }

    private func openAction(_ action: MenuAction, repo: RepositoryEntry) {
        AppContainer.shared.windowCoordinator.dispatch(
            action: action,
            repoPath: repo.path,
            targetDir: repo.path,
            selectedPaths: [repo.path]
        )
    }

    @ViewBuilder
    private func repoContextMenu(for repo: RepositoryEntry) -> some View {
        if repo.vcsType == .svn {
            Button(L("SVN Update…", "SVN 更新…")) { openAction(.svnUpdate, repo: repo) }
            Button(L("Update to Revision…", "更新至指定版本…")) { openAction(.svnUpdateToRevision, repo: repo) }
            Button(L("SVN Commit…", "SVN 提交…")) { openAction(.svnCommit, repo: repo) }
            Divider()
            Button(L("Show Log", "显示日志")) { openAction(.showLog, repo: repo) }
            Button(L("Check for Modifications", "检测改动")) { openAction(.checkForModifications, repo: repo) }
            Button(L("Repo-browser", "版本库浏览器")) { openAction(.repoBrowser, repo: repo) }
            Divider()
            Button(L("Branch / Tag…", "分支 / 标签…")) { openAction(.svnBranchTag, repo: repo) }
            Button(L("Switch…", "切换 (Switch)…")) { openAction(.svnSwitch, repo: repo) }
            Button(L("SVN Merge…", "SVN 合并…")) { openAction(.svnMerge, repo: repo) }
            Button(L("Compare Revisions…", "比较版本…")) { openAction(.compareRevisions, repo: repo) }
            Button(L("Export…", "导出…")) { openAction(.export, repo: repo) }
            Divider()
            Button(L("Get Lock…", "获取锁…")) { openAction(.svnLock, repo: repo) }
            Button(L("Release Lock…", "释放锁…")) { openAction(.svnUnlock, repo: repo) }
            Button(L("Properties…", "属性…")) { openAction(.svnProperties, repo: repo) }
            Button(L("Revert…", "复原…")) { openAction(.revert, repo: repo) }
            Divider()
            Button(L("Create Patch…", "创建补丁…")) { openAction(.svnCreatePatch, repo: repo) }
            Button(L("Apply Patch…", "应用补丁…")) { openAction(.svnApplyPatch, repo: repo) }
            Button(L("Relocate…", "重定位…")) { openAction(.svnRelocate, repo: repo) }
            Divider()
            Button(L("SVN Info", "SVN 信息")) { openAction(.svnInfo, repo: repo) }
            Button(L("Configure Authentication…", "配置身份验证…")) {
                AppContainer.shared.windowCoordinator.openAuthConfig(for: repo.path)
            }
            Button(L("Clean up…", "清理 (Clean up)…")) { openAction(.svnCleanup, repo: repo) }
            Button(L("Upgrade Working Copy…", "升级工作副本…")) { openAction(.svnUpgrade, repo: repo) }
            Divider()
            Button(L("Reveal in Finder", "在访达中显示")) {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: repo.path)
            }
            Button(L("Copy Path", "拷贝路径")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(repo.path, forType: .string)
            }
            Divider()
            Button(L("Remove", "移除")) {
                repoManager.removeRepository(id: repo.id)
            }
        } else {
            Button(L("Git Commit…", "Git 提交…")) { openAction(.gitCommit, repo: repo) }
            Button(L("Git Pull…", "Git 拉取…")) { openAction(.gitPull, repo: repo) }
            Button(L("Git Fetch…", "Git 获取…")) { openAction(.gitFetch, repo: repo) }
            Button(L("Git Push…", "Git 推送…")) { openAction(.gitPush, repo: repo) }
            Divider()
            Button(L("Show Log", "显示日志")) { openAction(.showLog, repo: repo) }
            Button(L("Check for Modifications", "检测改动")) { openAction(.checkForModifications, repo: repo) }
            Button(L("Repo-browser", "版本库浏览器")) { openAction(.repoBrowser, repo: repo) }
            Button(L("Browse References", "浏览引用")) { openAction(.browseReferences, repo: repo) }
            Button(L("Show RefLog", "显示操作日志 (RefLog)")) { openAction(.showRefLog, repo: repo) }
            Divider()
            Button(L("Checkout / Switch…", "签出 / 切换…")) { openAction(.checkout, repo: repo) }
            Button(L("Stash Save…", "储藏…")) { openAction(.stashPush, repo: repo) }
            Button(L("Stash List", "储藏列表")) { openAction(.stashList, repo: repo) }
            Button(L("Manage Submodules…", "管理子模块…")) { openAction(.submoduleManage, repo: repo) }
            Button(L("Revert…", "复原…")) { openAction(.revert, repo: repo) }
            Divider()
            Button(L("Repo Info", "版本库信息")) { openAction(.repoInfo, repo: repo) }
            Button(L("Configure Authentication…", "配置身份验证…")) {
                AppContainer.shared.windowCoordinator.openAuthConfig(for: repo.path)
            }
            Button(L("Cleanup (git gc)", "清理 (git gc)")) { openAction(.cleanup, repo: repo) }
            Divider()
            Button(L("Reveal in Finder", "在访达中显示")) {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: repo.path)
            }
            Button(L("Copy Path", "拷贝路径")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(repo.path, forType: .string)
            }
            Divider()
            Button(L("Remove", "移除")) {
                repoManager.removeRepository(id: repo.id)
            }
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    Task { @MainActor in
                        if let entry = try? await repoManager.addRepository(at: url.path) {
                            selectedVcsTab = (entry.vcsType == .svn ? .svn : .git)
                            selectedRepoID = entry.id
                            AppContainer.shared.triggerRefresh(repoPath: entry.path)
                        }
                    }
                }
            }
        }
        return handled
    }
}

private struct RepositoryRowView: View {
    let repo: RepositoryEntry

    var body: some View {
        let snap = AppContainer.shared.storage.loadStatusSnapshot(for: repo.path)
        HStack(spacing: 10) {
            Image(systemName: repo.vcsType == .git ? "arrow.triangle.branch" : "server.rack")
                .foregroundColor(.accentColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(repo.name)
                        .fontWeight(.medium)
                    Text(repo.vcsType.displayName)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.12))
                        .cornerRadius(3)
                    if let branch = snap?.branchName, !branch.isEmpty {
                        Text(branch)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    if repo.isAutoDiscovered {
                        Text(L("Auto", "自动发现"))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                Text(repo.path)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}
