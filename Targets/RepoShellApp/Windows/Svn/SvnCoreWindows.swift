import Cocoa
import SwiftUI
import RepoShellShared
import RepoShellVcs
import RepoShellServices

// MARK: - SVN Commit Window

struct SvnCommitWindowView: View {
    let repoPath: String
    let preselectedPaths: [String]

    @State private var branchLabel: String = ""
    @State private var items: [SvnDetailedStatusItem] = []
    @State private var selectedPaths: Set<String> = []
    @State private var changelists: [Changelist] = []
    @State private var activeChangelist: String = "__all__"
    @State private var pathFilter: String = ""
    @State private var showUntracked: Bool = true
    @State private var message: String = ""
    @State private var keepLocks: Bool = false
    @State private var keepChangelists: Bool = false
    @State private var isLoading: Bool = false
    @State private var recentMessages: [String] = []
    @State private var hiddenPatterns: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Text(L("Commit to:", "提交到："))
                    .foregroundColor(.secondary)
                Label(branchLabel.isEmpty ? "SVN" : branchLabel, systemImage: "server.rack")
                    .font(.headline)
                Spacer()
                Button(L("Manage Changelists…", "管理变更列表…")) {
                    AppContainer.shared.windowCoordinator.openChangelists(repoPath: repoPath)
                }
                Button(L("Hidden Files…", "隐藏文件…")) {
                    AppContainer.shared.windowCoordinator.openHiddenFiles(repoPath: repoPath)
                }
                Button {
                    refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help(L("Refresh status", "刷新状态"))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Divider()

            // Message box + options
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(L("Commit Message:", "提交信息："))
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Picker(L("Recent Messages", "最近提交信息"), selection: Binding(
                        get: { "" },
                        set: { if !$0.isEmpty { message = $0 } }
                    )) {
                        Text(L("Recent Messages…", "最近提交信息…")).tag("")
                        ForEach(recentMessages, id: \.self) { msg in
                            Text(msg.replacingOccurrences(of: "\n", with: " ")).lineLimit(1).tag(msg)
                        }
                    }
                    .frame(maxWidth: 260)
                }

                TextEditor(text: $message)
                    .font(.system(.body, design: .default))
                    .frame(height: 88)
                    .border(Color.secondary.opacity(0.25))

                HStack(spacing: 16) {
                    Toggle(L("Keep locks (--no-unlock)", "保留文件锁 (--no-unlock)"), isOn: $keepLocks)
                    Toggle(L("Keep changelists", "保留变更列表 (--keep-changelists)"), isOn: $keepChangelists)
                    Spacer()
                }
                .font(.caption)
            }
            .padding(12)

            Divider()

            // Filter bar
            HStack(spacing: 10) {
                Toggle(L("Select / Deselect All", "全选 / 取消全选"), isOn: Binding(
                    get: {
                        let visible = visibleItems
                        return !visible.isEmpty && visible.allSatisfy { selectedPaths.contains($0.item.relativePath) }
                    },
                    set: { checked in
                        let visible = Set(visibleItems.map(\.item.relativePath))
                        if checked {
                            selectedPaths.formUnion(visible)
                        } else {
                            selectedPaths.subtract(visible)
                        }
                    }
                ))

                Toggle(L("Show unversioned", "显示未版本控制"), isOn: $showUntracked)

                Picker(L("Changelist:", "变更列表："), selection: $activeChangelist) {
                    Text(L("All Changes", "全部更改")).tag("__all__")
                    ForEach(availableChangelistNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .frame(maxWidth: 220)

                Spacer()

                TextField(L("Filter paths…", "过滤路径…"), text: $pathFilter)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if isLoading && items.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visibleItems.isEmpty {
                EmptyStateBox(
                    systemImage: "checkmark.circle",
                    title: L("No Local Modifications", "工作副本没有本地更改"),
                    subtitle: L("Everything selected is clean or hidden by filters.", "当前筛选条件下没有需要提交的更改。")
                )
            } else {
                List(visibleItems) { entry in
                    HStack(spacing: 8) {
                        Toggle("", isOn: Binding(
                            get: { selectedPaths.contains(entry.item.relativePath) },
                            set: { on in
                                if on { selectedPaths.insert(entry.item.relativePath) }
                                else { selectedPaths.remove(entry.item.relativePath) }
                            }
                        ))
                        .labelsHidden()

                        StatusBadgeLabel(status: entry.item.status)
                            .frame(width: 90, alignment: .leading)

                        Text(entry.item.relativePath)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer()

                        if let rev = entry.revision, !rev.isEmpty {
                            Text("r\(rev)")
                                .font(.caption.monospacedDigit())
                                .foregroundColor(.secondary)
                        }
                        if let lock = entry.localLock {
                            Label(lock.owner, systemImage: "lock.fill")
                                .font(.caption2)
                                .foregroundColor(.orange)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        AppContainer.shared.windowCoordinator.openDiffWithRevision(
                            repoPath: repoPath,
                            filePath: entry.item.absolutePath,
                            revision: "BASE",
                            rightTitle: L("Working Copy", "工作副本")
                        )
                    }
                    .contextMenu {
                        Button(L("Diff", "对比")) {
                            AppContainer.shared.windowCoordinator.openDiffWithRevision(
                                repoPath: repoPath,
                                filePath: entry.item.absolutePath,
                                revision: "BASE",
                                rightTitle: L("Working Copy", "工作副本")
                            )
                        }
                        if entry.item.status != .untracked {
                            Button(L("Revert…", "复原…")) {
                                performRevert(paths: [entry.item.absolutePath])
                            }
                        }
                        Button(L("Add to Ignore List…", "添加到忽略清单…")) {
                            AppContainer.shared.windowCoordinator.dispatch(
                                action: .addToIgnore,
                                repoPath: repoPath,
                                targetDir: repoPath,
                                selectedPaths: [entry.item.absolutePath]
                            )
                        }
                    }
                }
            }

            Divider()

            // Footer
            HStack {
                Text(String(format: L("%d selected of %d files", "已选 %d / %d 项"), selectedPaths.count, visibleItems.count))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button(L("Cancel", "取消")) {
                    AppContainer.shared.windowCoordinator.closeWindow(key: "svn-commit-\(repoPath)")
                }
                .keyboardShortcut(.escape, modifiers: [])

                Button(L("Commit", "提交")) {
                    executeCommit()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(selectedPaths.isEmpty)
            }
            .padding(12)
        }
        .onAppear(perform: refresh)
    }

    private var availableChangelistNames: [String] {
        var names = Set(changelists.map(\.name))
        for item in items {
            if let cl = item.changelist, !cl.isEmpty { names.insert(cl) }
        }
        return Array(names).sorted()
    }

    private var visibleItems: [SvnDetailedStatusItem] {
        let lowerFilter = pathFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let storeMatchFiles: Set<String>? = {
            if activeChangelist == "__all__" { return nil }
            if let found = changelists.first(where: { $0.name == activeChangelist }) {
                return Set(found.files)
            }
            return nil
        }()

        return items.filter { entry in
            let st = entry.item.status
            if st == .ignored || st == .external { return false }
            if !showUntracked && st == .untracked { return false }
            if AppContainer.shared.hiddenFilesStore.matches(relativePath: entry.item.relativePath, rules: hiddenPatterns) { return false }
            if activeChangelist != "__all__" {
                let inNative = entry.changelist == activeChangelist
                let inStore = storeMatchFiles?.contains(entry.item.relativePath) ?? false
                if !inNative && !inStore { return false }
            }
            if !lowerFilter.isEmpty && !entry.item.relativePath.lowercased().contains(lowerFilter) {
                return false
            }
            return true
        }
    }

    private func refresh() {
        isLoading = true
        changelists = AppContainer.shared.changelistStore.load(for: repoPath)
        hiddenPatterns = AppContainer.shared.hiddenFilesStore.loadRules(for: repoPath)
        recentMessages = AppContainer.shared.recentHistoryStore.load().svnCommitMessages
        let prefs = AppContainer.shared.repositoryManager.currentConfigSnapshot().preferences
        showUntracked = prefs.commitShowUntracked

        Task {
            defer { isLoading = false }
            do {
                let info = try await AppContainer.shared.svnProvider.info(target: repoPath, workingDirectory: repoPath)
                branchLabel = info.formattedBranchName
                let detailed = try await AppContainer.shared.svnProvider.detailedStatus(
                    repoPath: repoPath,
                    checkRemote: false,
                    includeIgnored: false,
                    includeUntracked: true
                )
                let committable = detailed.items.filter {
                    let st = $0.item.status
                    return st != .normal && st != .ignored && st != .external
                }
                self.items = committable

                if !preselectedPaths.isEmpty {
                    let preSet = Set(preselectedPaths.map { PathUtils.normalize($0) })
                    let matched = committable.filter { entry in
                        preSet.contains { sel in
                            PathUtils.isPath(entry.item.absolutePath, insideOrEqualTo: sel)
                        }
                    }
                    self.selectedPaths = Set(matched.map(\.item.relativePath))
                } else {
                    self.selectedPaths = Set(committable.filter { $0.item.status != .untracked }.map(\.item.relativePath))
                }
            } catch {
                AlertHelper.showError(error)
            }
        }
    }

    private func performRevert(paths: [String]) {
        AppContainer.shared.windowCoordinator.runTaskWithProgress(
            title: L("SVN Revert", "SVN 复原"),
            repoPath: repoPath
        ) { onLine in
            let res = try await AppContainer.shared.svnProvider.revert(
                repoPath: repoPath,
                paths: paths,
                onOutputLine: { line, _ in onLine(line) }
            )
            await MainActor.run { refresh() }
            return res
        }
    }

    private func executeCommit() {
        let prefs = AppContainer.shared.repositoryManager.currentConfigSnapshot().preferences
        let trimmedMsg = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if prefs.checkEmptyCommitMessage && trimmedMsg.isEmpty {
            AlertHelper.showInfo(
                L("Commit Message Required", "请填写提交信息"),
                message: L("Commit message cannot be empty (configurable in General preferences).", "提交信息不能为空（可在通用偏好设置中关闭此检查）。")
            )
            return
        }

        let selectedEntries = items.filter { selectedPaths.contains($0.item.relativePath) }
        guard !selectedEntries.isEmpty else { return }

        if selectedEntries.contains(where: { $0.item.status == .unmerged }) {
            AlertHelper.showInfo(
                L("Conflicts Present", "存在未解决的冲突"),
                message: L("Please resolve conflicted files before committing.", "请先解决冲突文件后再提交。")
            )
            return
        }

        let autoAdd = selectedEntries.filter { $0.item.status == .untracked }.map(\.item.relativePath)
        let autoDelete = selectedEntries.filter { $0.item.status == .missing }.map(\.item.relativePath)
        let commitPaths = selectedEntries.map(\.item.relativePath)
        let nativeCl = (activeChangelist != "__all__" && selectedEntries.allSatisfy { $0.changelist == activeChangelist })
            ? activeChangelist
            : nil
        let msg = trimmedMsg
        let keepLocksVal = keepLocks
        let keepClVal = keepChangelists

        AppContainer.shared.recentHistoryStore.recordSvnCommitMessage(msg)
        AppContainer.shared.windowCoordinator.closeWindow(key: "svn-commit-\(repoPath)")

        AppContainer.shared.windowCoordinator.runTaskWithProgress(
            title: L("SVN Commit", "SVN 提交") + " — \(URL(fileURLWithPath: repoPath).lastPathComponent)",
            repoPath: repoPath
        ) { onLine in
            try await AppContainer.shared.runSvnInteractive(repoPath: repoPath) { env, auth in
                try await AppContainer.shared.svnProvider.svnCommit(
                    repoPath: repoPath,
                    paths: commitPaths,
                    message: msg,
                    changelist: nativeCl,
                    keepLocks: keepLocksVal,
                    keepChangelists: keepClVal,
                    autoAddPaths: autoAdd,
                    autoDeletePaths: autoDelete,
                    environment: env,
                    auth: auth,
                    onOutputLine: { line, _ in onLine(line) }
                )
            }
        }
    }
}

// MARK: - SVN Check for Modifications

struct SvnModificationsWindowView: View {
    let repoPath: String

    @State private var items: [SvnDetailedStatusItem] = []
    @State private var againstRev: String?
    @State private var selectedIDs: Set<String> = []
    @State private var checkRemote: Bool = false
    @State private var showUnversioned: Bool = true
    @State private var showIgnored: Bool = false
    @State private var showLocks: Bool = true
    @State private var filterText: String = ""
    @State private var isLoading: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    checkRemote = false
                    load(remote: false)
                } label: {
                    Label(L("Refresh Local", "刷新本地"), systemImage: "arrow.clockwise")
                }

                Button {
                    checkRemote = true
                    load(remote: true)
                } label: {
                    Label(L("Check Repository (-u)", "检查版本库 (-u)"), systemImage: "network")
                }
                .buttonStyle(.borderedProminent)

                if let rev = againstRev {
                    Text("HEAD: r\(rev)")
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                }

                Spacer()

                Toggle(L("Unversioned", "未版本控制"), isOn: $showUnversioned)
                Toggle(L("Ignored", "已忽略"), isOn: $showIgnored)
                    .onChange(of: showIgnored) { _ in load(remote: checkRemote) }
                Toggle(L("Locks", "锁信息"), isOn: $showLocks)

                TextField(L("Filter…", "过滤…"), text: $filterText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 170)
            }
            .padding(10)

            Divider()

            if isLoading && items.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredItems.isEmpty {
                EmptyStateBox(
                    systemImage: "doc.text.magnifyingglass",
                    title: L("Working Copy is Clean", "未检测到改动"),
                    subtitle: checkRemote
                        ? L("No local or incoming repository changes found.", "本地与远端均无待处理变更。")
                        : L("Click \"Check Repository (-u)\" to inspect incoming updates or server locks.", "可点击「检查版本库 (-u)」查看远端待更新项和锁定状态。")
                )
            } else {
                List(filteredItems, selection: $selectedIDs) { entry in
                    HStack(spacing: 10) {
                        StatusBadgeLabel(status: entry.item.status)
                            .frame(width: 90, alignment: .leading)

                        Text(entry.item.relativePath)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if checkRemote, let rem = entry.remoteItemStatus, rem != "none" {
                            Text("Remote: \(rem)")
                                .font(.caption)
                                .foregroundColor(.blue)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.12))
                                .cornerRadius(4)
                        }

                        if showLocks, let lock = entry.localLock ?? entry.remoteLock {
                            Label(lock.owner, systemImage: entry.localLock != nil ? "lock.fill" : "lock")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }

                        if let rev = entry.revision {
                            Text("r\(rev)")
                                .font(.caption.monospacedDigit())
                                .foregroundColor(.secondary)
                                .frame(width: 56, alignment: .trailing)
                        }

                        if let author = entry.commitAuthor {
                            Text(author)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(width: 90, alignment: .trailing)
                                .lineLimit(1)
                        }
                    }
                    .tag(entry.id)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        AppContainer.shared.windowCoordinator.openDiffWithRevision(
                            repoPath: repoPath,
                            filePath: entry.item.absolutePath,
                            revision: "BASE",
                            rightTitle: L("Working Copy", "工作副本")
                        )
                    }
                    .contextMenu {
                        let selPaths = resolvedActionPaths(fallback: entry.item.absolutePath)
                        Button(L("Diff", "对比")) {
                            AppContainer.shared.windowCoordinator.openDiffWithRevision(
                                repoPath: repoPath,
                                filePath: entry.item.absolutePath,
                                revision: "BASE",
                                rightTitle: L("Working Copy", "工作副本")
                            )
                        }
                        Button(L("SVN Commit…", "SVN 提交…")) {
                            AppContainer.shared.windowCoordinator.dispatch(action: .svnCommit, repoPath: repoPath, targetDir: repoPath, selectedPaths: selPaths)
                        }
                        Button(L("SVN Update…", "SVN 更新…")) {
                            AppContainer.shared.windowCoordinator.dispatch(action: .svnUpdate, repoPath: repoPath, targetDir: repoPath, selectedPaths: selPaths)
                        }
                        Button(L("Revert…", "复原…")) {
                            AppContainer.shared.windowCoordinator.dispatch(action: .revert, repoPath: repoPath, targetDir: repoPath, selectedPaths: selPaths)
                        }
                        Divider()
                        Button(L("Get Lock…", "获取锁…")) {
                            AppContainer.shared.windowCoordinator.dispatch(action: .svnLock, repoPath: repoPath, targetDir: repoPath, selectedPaths: selPaths)
                        }
                        Button(L("Release Lock…", "释放锁…")) {
                            AppContainer.shared.windowCoordinator.dispatch(action: .svnUnlock, repoPath: repoPath, targetDir: repoPath, selectedPaths: selPaths)
                        }
                        Button(L("Show Log", "显示日志")) {
                            AppContainer.shared.windowCoordinator.dispatch(action: .showLog, repoPath: repoPath, targetDir: repoPath, selectedPaths: [entry.item.absolutePath])
                        }
                    }
                }
            }

            Divider()

            HStack {
                Text(summaryText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button(L("Commit…", "提交…")) {
                    let targets = filteredItems.filter { selectedIDs.contains($0.id) }.map(\.item.absolutePath)
                    AppContainer.shared.windowCoordinator.dispatch(action: .svnCommit, repoPath: repoPath, targetDir: repoPath, selectedPaths: targets)
                }
                Button(L("Update", "更新")) {
                    let targets = filteredItems.filter { selectedIDs.contains($0.id) }.map(\.item.absolutePath)
                    AppContainer.shared.windowCoordinator.dispatch(action: .svnUpdate, repoPath: repoPath, targetDir: repoPath, selectedPaths: targets)
                }
            }
            .padding(10)
        }
        .onAppear { load(remote: false) }
    }

    private var filteredItems: [SvnDetailedStatusItem] {
        let lower = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return items.filter { entry in
            let st = entry.item.status
            if !showUnversioned && st == .untracked { return false }
            if !showIgnored && st == .ignored { return false }
            let hasRemote = checkRemote && (entry.remoteItemStatus ?? "none") != "none"
            if st == .normal && !hasRemote && entry.localLock == nil && entry.remoteLock == nil {
                return false
            }
            if !lower.isEmpty && !entry.item.relativePath.lowercased().contains(lower) {
                return false
            }
            return true
        }
    }

    private var summaryText: String {
        let list = filteredItems
        let mod = list.filter { $0.item.status == .modified }.count
        let add = list.filter { $0.item.status == .added }.count
        let del = list.filter { $0.item.status == .deleted }.count
        let mis = list.filter { $0.item.status == .missing }.count
        let con = list.filter { $0.item.status == .unmerged }.count
        let unc = list.filter { $0.item.status == .untracked }.count
        let lck = list.filter { $0.localLock != nil || $0.remoteLock != nil }.count
        return String(
            format: L(
                "Total: %d | Modified: %d | Added: %d | Deleted: %d | Missing: %d | Conflict: %d | Untracked: %d | Locked: %d",
                "共 %d 项 | 修改 %d | 新增 %d | 删除 %d | 丢失 %d | 冲突 %d | 未版本控制 %d | 已锁定 %d"
            ),
            list.count, mod, add, del, mis, con, unc, lck
        )
    }

    private func resolvedActionPaths(fallback: String) -> [String] {
        let chosen = filteredItems.filter { selectedIDs.contains($0.id) }.map(\.item.absolutePath)
        return chosen.isEmpty ? [fallback] : chosen
    }

    private func load(remote: Bool) {
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                let res: SvnDetailedStatusResult
                if remote {
                    res = try await AppContainer.shared.runSvnInteractive(repoPath: repoPath) { env, auth in
                        try await AppContainer.shared.svnProvider.detailedStatus(
                            repoPath: repoPath,
                            checkRemote: true,
                            includeIgnored: showIgnored,
                            includeUntracked: true,
                            environment: env,
                            auth: auth
                        )
                    }
                } else {
                    res = try await AppContainer.shared.svnProvider.detailedStatus(
                        repoPath: repoPath,
                        checkRemote: false,
                        includeIgnored: showIgnored,
                        includeUntracked: true
                    )
                }
                self.items = res.items
                self.againstRev = res.againstRevision
            } catch {
                AlertHelper.showError(error)
            }
        }
    }
}

// MARK: - SVN Show Log Window

struct SvnLogWindowView: View {
    let repoPath: String
    let initialPathFilter: String?

    @State private var commits: [VcsCommit] = []
    @State private var selectedCommitID: String?
    @State private var searchQuery: String = ""
    @State private var revisionRange: String = ""
    @State private var stopOnCopy: Bool = false
    @State private var useMergeHistory: Bool = false
    @State private var targetPathFilter: String
    @State private var isLoading: Bool = false
    @State private var editingCommit: VcsCommit?
    @State private var canLoadMore: Bool = true

    init(repoPath: String, initialPathFilter: String? = nil) {
        self.repoPath = repoPath
        self.initialPathFilter = initialPathFilter
        _targetPathFilter = State(initialValue: initialPathFilter ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField(L("Search author / message / path…", "搜索作者 / 提交信息 / 路径…"), text: $searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 200)
                    .onSubmit { loadInitial() }

                TextField(L("Rev range (e.g. HEAD:100)", "版本范围 (如 HEAD:100)"), text: $revisionRange)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 170)
                    .onSubmit { loadInitial() }

                Toggle(L("Stop on copy", "复制点停止"), isOn: $stopOnCopy)
                    .onChange(of: stopOnCopy) { _ in loadInitial() }
                Toggle(L("Merge history (-g)", "合并历史 (-g)"), isOn: $useMergeHistory)
                    .onChange(of: useMergeHistory) { _ in loadInitial() }

                Button {
                    loadInitial()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help(L("Refresh Log", "刷新日志"))
            }
            .padding(10)

            Divider()

            VSplitView {
                VStack(spacing: 0) {
                    if isLoading && commits.isEmpty {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if commits.isEmpty {
                        EmptyStateBox(
                            systemImage: "clock.arrow.circlepath",
                            title: L("No Log Entries", "暂无日志记录"),
                            subtitle: L("Adjust your search filter or check repository connection.", "请调整筛选条件或检查网络连接。")
                        )
                    } else {
                        List(commits, selection: $selectedCommitID) { commit in
                            HStack(spacing: 10) {
                                Text(commit.shortHash)
                                    .font(.caption.monospaced().weight(.semibold))
                                    .foregroundColor(.accentColor)
                                    .frame(width: 72, alignment: .leading)

                                Text(commit.author)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .frame(width: 100, alignment: .leading)
                                    .lineLimit(1)

                                Text(commit.subject)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                Text(commit.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .tag(commit.id)
                            .contextMenu {
                                Button(L("Update Working Copy to Revision %@", "更新工作副本至 r%@")
                                    .replacingOccurrences(of: "%@", with: commit.hash)) {
                                    updateToRevision(commit.hash)
                                }
                                Button(L("Revert Changes from Revision r\(commit.hash)…", "撤销此修订的更改 (r\(commit.hash))…")) {
                                    revertRevisionChanges(commit.hash)
                                }
                                Button(L("Edit Log Message…", "编辑日志信息…")) {
                                    editingCommit = commit
                                }
                                Divider()
                                Button(L("Compare with Working Copy", "与工作副本对比")) {
                                    AppContainer.shared.windowCoordinator.openCompareRevisions(
                                        repoPath: repoPath,
                                        rev1: commit.hash,
                                        rev2: "HEAD"
                                    )
                                }
                                Button(L("Compare with Previous Revision", "与前一修订对比")) {
                                    if let num = Int(commit.hash), num > 1 {
                                        AppContainer.shared.windowCoordinator.openCompareRevisions(
                                            repoPath: repoPath,
                                            rev1: String(num - 1),
                                            rev2: commit.hash
                                        )
                                    }
                                }
                                Button(L("Browse Repository at r\(commit.hash)", "在 r\(commit.hash) 浏览版本库")) {
                                    AppContainer.shared.windowCoordinator.openRepoBrowser(repoPath: repoPath, revision: commit.hash)
                                }
                                Button(L("Copy Revision Number", "拷贝版本号")) {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(commit.hash, forType: .string)
                                }
                            }
                        }
                    }

                    if canLoadMore && !commits.isEmpty {
                        Divider()
                        HStack {
                            Spacer()
                            Button(L("Load Next Page…", "加载下一页…")) {
                                loadNextPage()
                            }
                            .disabled(isLoading)
                            Spacer()
                        }
                        .padding(.vertical, 6)
                    }
                }
                .frame(minHeight: 240)

                // Detail bottom split
                if let commit = commits.first(where: { $0.id == selectedCommitID }) {
                    VSplitView {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("\(commit.shortHash) • \(commit.author)")
                                        .font(.headline)
                                    Spacer()
                                    Text(commit.date.formatted(date: .long, time: .standard))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Text(commit.body.isEmpty ? commit.subject : "\(commit.subject)\n\(commit.body)")
                                    .font(.body)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(10)
                        }
                        .frame(minHeight: 80)

                        List(commit.changedPaths) { ch in
                            HStack(spacing: 8) {
                                Text(ch.action)
                                    .font(.caption.monospaced().weight(.bold))
                                    .foregroundColor(colorForAction(ch.action))
                                    .frame(width: 20)
                                Text(ch.path)
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if let cp = ch.copyFromPath, !cp.isEmpty {
                                    Text("← \(cp)")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) {
                                diffChangedPath(ch, revision: commit.hash)
                            }
                            .contextMenu {
                                Button(L("Diff against previous revision", "与前一版本对比")) {
                                    diffChangedPath(ch, revision: commit.hash)
                                }
                                Button(L("Blame at r\(commit.hash)", "在 r\(commit.hash) 追溯")) {
                                    AppContainer.shared.windowCoordinator.openBlameResult(
                                        repoPath: repoPath,
                                        filePath: ch.path,
                                        revision: commit.hash,
                                        ignoreWhitespace: false,
                                        hideAuthorAndDate: false
                                    )
                                }
                            }
                        }
                        .frame(minHeight: 120)
                    }
                } else {
                    EmptyStateBox(
                        systemImage: "doc.plaintext",
                        title: L("Select a Revision", "选择一个版本查看详情"),
                        subtitle: nil
                    )
                }
            }
        }
        .onAppear { loadInitial() }
        .sheet(item: $editingCommit) { commit in
            SvnEditLogMessageSheet(repoPath: repoPath, commit: commit) { newMsg in
                if let idx = commits.firstIndex(where: { $0.id == commit.id }) {
                    let lines = newMsg.components(separatedBy: .newlines)
                    commits[idx].subject = lines.first ?? ""
                    commits[idx].body = lines.dropFirst().joined(separator: "\n")
                }
                editingCommit = nil
            } onCancel: {
                editingCommit = nil
            }
        }
    }

    private func pageSize() -> Int {
        max(20, AppContainer.shared.repositoryManager.currentConfigSnapshot().preferences.svnLogLimit)
    }

    private func colorForAction(_ act: String) -> Color {
        switch act {
        case "A": return .green
        case "D": return .red
        case "R": return .purple
        default: return .blue
        }
    }

    private func loadInitial() {
        isLoading = true
        let target = targetPathFilter.isEmpty ? "." : targetPathFilter
        let limit = pageSize()
        let revRange = revisionRange.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            defer { isLoading = false }
            do {
                let res = try await AppContainer.shared.runSvnInteractive(repoPath: repoPath) { env, auth in
                    try await AppContainer.shared.svnProvider.svnLog(
                        target: target,
                        repoPath: repoPath,
                        revisionRange: revRange.isEmpty ? nil : revRange,
                        limit: limit,
                        searchQuery: searchQuery.isEmpty ? nil : searchQuery,
                        stopOnCopy: stopOnCopy,
                        useMergeHistory: useMergeHistory,
                        environment: env,
                        auth: auth
                    )
                }
                self.commits = res
                self.canLoadMore = res.count >= limit
                if selectedCommitID == nil { selectedCommitID = res.first?.id }
            } catch {
                AlertHelper.showError(error)
            }
        }
    }

    private func loadNextPage() {
        guard let last = commits.last, let lastRev = Int(last.hash), lastRev > 1 else {
            canLoadMore = false
            return
        }
        isLoading = true
        let limit = pageSize()
        let target = targetPathFilter.isEmpty ? "." : targetPathFilter
        let range = "\(lastRev - 1):1"
        Task {
            defer { isLoading = false }
            do {
                let next = try await AppContainer.shared.runSvnInteractive(repoPath: repoPath) { env, auth in
                    try await AppContainer.shared.svnProvider.svnLog(
                        target: target,
                        repoPath: repoPath,
                        revisionRange: range,
                        limit: limit,
                        searchQuery: searchQuery.isEmpty ? nil : searchQuery,
                        stopOnCopy: stopOnCopy,
                        useMergeHistory: useMergeHistory,
                        environment: env,
                        auth: auth
                    )
                }
                let existingIDs = Set(commits.map(\.id))
                let appended = next.filter { !existingIDs.contains($0.id) }
                self.commits.append(contentsOf: appended)
                self.canLoadMore = next.count >= limit
            } catch {
                AlertHelper.showError(error)
            }
        }
    }

    private func updateToRevision(_ rev: String) {
        AppContainer.shared.windowCoordinator.runTaskWithProgress(
            title: L("Update to Revision r\(rev)", "更新至版本 r\(rev)"),
            repoPath: repoPath
        ) { onLine in
            try await AppContainer.shared.runSvnInteractive(repoPath: repoPath) { env, auth in
                try await AppContainer.shared.svnProvider.update(
                    repoPath: repoPath,
                    options: SvnUpdateOptions(revision: rev),
                    environment: env,
                    auth: auth,
                    onOutputLine: { line, _ in onLine(line) }
                )
            }
        }
    }

    private func revertRevisionChanges(_ rev: String) {
        guard AlertHelper.confirm(
            title: L("Revert Revision Changes", "撤销修订更改"),
            message: String(format: L("Reverse-merge changes from r%@ into the working copy?", "确定要将 r%@ 的更改反向合并回工作副本吗？"), rev)
        ) else { return }
        AppContainer.shared.windowCoordinator.runTaskWithProgress(
            title: L("Revert Changes from r\(rev)", "撤销修订 r\(rev)"),
            repoPath: repoPath
        ) { onLine in
            try await AppContainer.shared.runSvnInteractive(repoPath: repoPath) { env, auth in
                try await AppContainer.shared.svnProvider.revertRevisionChanges(
                    repoPath: repoPath,
                    revisions: [rev],
                    environment: env,
                    auth: auth,
                    onOutputLine: { line, _ in onLine(line) }
                )
            }
        }
    }

    private func diffChangedPath(_ ch: VcsChangedPath, revision: String) {
        guard let revNum = Int(revision), revNum > 1 else { return }
        Task {
            do {
                let info = try await AppContainer.shared.svnProvider.info(target: repoPath, workingDirectory: repoPath)
                let rootURL = info.repositoryRoot.hasSuffix("/") ? String(info.repositoryRoot.dropLast()) : info.repositoryRoot
                let relURLPath = ch.path.hasPrefix("/") ? ch.path : "/\(ch.path)"
                let fullURL = "\(rootURL)\(relURLPath)"
                AppContainer.shared.windowCoordinator.openDiffBetweenRevisions(
                    repoPath: repoPath,
                    filePath: fullURL,
                    leftRev: String(revNum - 1),
                    rightRev: revision
                )
            } catch {
                AlertHelper.showError(error)
            }
        }
    }
}

private struct SvnEditLogMessageSheet: View {
    let repoPath: String
    let commit: VcsCommit
    let onSaved: (String) -> Void
    let onCancel: () -> Void

    @State private var text: String
    @State private var isSaving = false

    init(repoPath: String, commit: VcsCommit, onSaved: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.repoPath = repoPath
        self.commit = commit
        self.onSaved = onSaved
        self.onCancel = onCancel
        let combined = commit.body.isEmpty ? commit.subject : "\(commit.subject)\n\(commit.body)"
        _text = State(initialValue: combined)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Edit Revision Log Message (r\(commit.hash))", "编辑修订日志信息 (r\(commit.hash))"))
                .font(.headline)
            Text(L(
                "Note: Server pre-revprop-change hook must allow editing svn:log.",
                "提示：需要 SVN 服务器端 pre-revprop-change 钩子允许修改 svn:log 属性。"
            ))
            .font(.caption)
            .foregroundColor(.secondary)

            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 130)
                .border(Color.secondary.opacity(0.25))

            HStack {
                Spacer()
                Button(L("Cancel", "取消"), action: onCancel)
                    .keyboardShortcut(.escape, modifiers: [])
                Button(L("Save", "保存")) {
                    isSaving = true
                    Task {
                        defer { isSaving = false }
                        do {
                            _ = try await AppContainer.shared.runSvnInteractive(repoPath: repoPath) { env, auth in
                                try await AppContainer.shared.svnProvider.editRevisionLog(
                                    repoPath: repoPath,
                                    revision: commit.hash,
                                    newMessage: text,
                                    environment: env,
                                    auth: auth
                                )
                            }
                            onSaved(text)
                        } catch {
                            AlertHelper.showError(error)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding()
        .frame(width: 480, height: 280)
    }
}
