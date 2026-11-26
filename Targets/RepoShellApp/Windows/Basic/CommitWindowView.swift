import SwiftUI
import RepoShellShared
import RepoShellVcs

enum CommitActionMode: String, CaseIterable {
    case commit
    case commitAndPush
    case commitAndPushDialog

    static let defaultsKey = "reposhell.commit.primaryAction"

    static func loadSaved() -> CommitActionMode {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
              let mode = CommitActionMode(rawValue: raw) else {
            return .commit
        }
        return mode
    }

    func saveAsDefault() {
        UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey)
    }

    var title: String {
        switch self {
        case .commit:
            return L("Commit", "提交")
        case .commitAndPush:
            return L("Commit & Push", "提交并推送")
        case .commitAndPushDialog:
            return L("Commit & Push…", "提交并打开推送窗口…")
        }
    }
}

struct CommitWindowView: View {
    let repoPath: String
    let preselectedPaths: [String]

    @State private var branchName: String = ""
    @State private var upstreamBranch: String?
    @State private var aheadCount: Int = 0
    @State private var behindCount: Int = 0
    @State private var repoState: VcsRepoState = .normal
    @State private var message: String = ""
    @State private var amend: Bool = false
    @State private var allowEmpty: Bool = false
    @State private var primaryActionMode: CommitActionMode = CommitActionMode.loadSaved()
    @State private var showUntracked: Bool = true
    @State private var filterText: String = ""
    @State private var selectedChangelistID: UUID? = nil

    @State private var items: [VcsStatusItem] = []
    @State private var selectedPaths: Set<String> = []
    @State private var highlightedPaths: Set<String> = []
    @State private var changelists: [Changelist] = []
    @State private var hiddenRules: [String] = []
    @State private var recentMessages: [String] = []
    @State private var isLoading: Bool = false
    @State private var isSubmitting: Bool = false

    private var filteredItems: [VcsStatusItem] {
        items.filter { item in
            if item.status == .ignored { return false }
            if !showUntracked && item.status == .untracked { return false }
            if AppContainer.shared.hiddenFilesStore.matches(relativePath: item.relativePath, rules: hiddenRules) {
                return false
            }
            if let clID = selectedChangelistID,
               let cl = changelists.first(where: { $0.id == clID }) {
                if !cl.files.contains(item.relativePath) { return false }
            }
            if !filterText.isEmpty && !item.relativePath.localizedCaseInsensitiveContains(filterText) {
                return false
            }
            return true
        }
    }

    private var commitRows: [CommitFileRow] {
        filteredItems.map { item in
            let detail: String
            if let add = item.additions, let del = item.deletions {
                detail = "+\(add) -\(del)"
            } else if let size = item.fileSize {
                detail = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            } else {
                detail = ""
            }
            return CommitFileRow(
                relativePath: item.relativePath,
                absolutePath: item.absolutePath,
                extensionText: item.isDirectory ? "" : URL(fileURLWithPath: item.relativePath).pathExtension,
                status: item.status,
                statusDisplayText: AppContainer.shared.localized(item.status.localizedLabelKey),
                isDirectory: item.isDirectory,
                detailText: detail,
                tooltipText: item.relativePath
            )
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if repoState == .merging {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(L("Merge in progress. Resolve conflicts before committing or Abort Merge.", "合并进行中，请先解决冲突后再提交，或选择“放弃合并”。"))
                        .font(.subheadline)
                    Spacer()
                    Button(L("Resolve…", "解决…")) {
                        AppContainer.shared.windowCoordinator.dispatch(action: .resolveConflicts, repoPath: repoPath, targetDir: repoPath, selectedPaths: [])
                    }
                    Button(L("Abort Merge", "放弃合并")) {
                        AppContainer.shared.windowCoordinator.dispatch(action: .abortMerge, repoPath: repoPath, targetDir: repoPath, selectedPaths: [])
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.12))
            }

            // Header bar
            HStack(spacing: 8) {
                Text(L("Commit to:", "提交至："))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Label(branchName.isEmpty ? "HEAD" : branchName, systemImage: "arrow.triangle.branch")
                    .font(.subheadline.weight(.semibold))
                if let up = upstreamBranch, !up.isEmpty {
                    Text("→ \(up)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if aheadCount > 0 || behindCount > 0 {
                        Text("↑\(aheadCount) ↓\(behindCount)")
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.12))
                            .foregroundColor(.accentColor)
                            .cornerRadius(4)
                    }
                }
                Spacer()
                Button(L("Manage Changelists…", "变更列表…")) {
                    AppContainer.shared.windowCoordinator.openChangelists(repoPath: repoPath)
                }
                .controlSize(.small)
                Button(L("Hidden Files…", "隐藏规则…")) {
                    AppContainer.shared.windowCoordinator.openHiddenFiles(repoPath: repoPath)
                }
                .controlSize(.small)
                Button {
                    Task { await reload() }
                } label: {
                    if isLoading {
                        ProgressView().controlSize(.small)
                            .frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .controlSize(.small)
                .help(L("Refresh", "刷新"))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            VSplitView {
                // Message Area
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(L("Message:", "提交信息："))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)

                        let firstLineCount = message.split(separator: "\n", omittingEmptySubsequences: false).first?.count ?? 0
                        if !message.isEmpty {
                            Text(String(format: L("Subject: %d chars", "首行 %d 字符"), firstLineCount))
                                .font(.caption2.monospacedDigit())
                                .foregroundColor(firstLineCount > 72 ? .orange : .secondary)
                        }

                        Spacer()

                        Button(L("Sign-off", "签名")) {
                            insertSignOff()
                        }
                        .controlSize(.small)
                        .help(L("Append Signed-off-by line", "添加 Signed-off-by 签名行"))

                        Menu(L("Recent Messages", "最近信息")) {
                            if recentMessages.isEmpty {
                                Text(L("None", "无"))
                            } else {
                                ForEach(recentMessages, id: \.self) { msg in
                                    Button(msg.replacingOccurrences(of: "\n", with: " ").prefix(72) + (msg.count > 72 ? "…" : "")) {
                                        message = msg
                                    }
                                }
                            }
                        }
                        .menuStyle(.borderedButton)
                        .controlSize(.small)
                        .fixedSize()
                    }

                    ZStack(alignment: .topLeading) {
                        if message.isEmpty {
                            Text(L("Enter commit message… (⌘↩ to commit)", "输入提交说明…（⌘↩ 提交）"))
                                .font(.system(size: 13))
                                .foregroundColor(Color(nsColor: .placeholderTextColor))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 7)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $message)
                            .font(.system(size: 13))
                            .scrollContentBackground(.hidden)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 4)
                    }
                    .frame(minHeight: 74, maxHeight: .infinity)
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(5)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(minHeight: 112, idealHeight: 136)

                // Changes Pane
                VStack(spacing: 6) {
                    HStack(spacing: 8) {
                        Text(L("Changes made (double-click on file for diff):", "变更列表（双击文件进行对比，空格切换勾选）："))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)

                        Spacer()

                        Picker("", selection: $selectedChangelistID) {
                            Text(L("All Changes", "全部改动")).tag(UUID?.none)
                            ForEach(changelists) { cl in
                                Text("\(cl.name) (\(cl.files.count))").tag(UUID?.some(cl.id))
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(maxWidth: 170)

                        SearchInputField(
                            placeholder: L("Filter paths…", "筛选路径…"),
                            text: $filterText,
                            width: 190
                        )
                    }

                    // Native AppKit File Table
                    Group {
                        if isLoading && items.isEmpty {
                            ProgressView()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(Color(nsColor: .controlBackgroundColor))
                                .border(Color(nsColor: .separatorColor), width: 1)
                        } else if filteredItems.isEmpty {
                            EmptyStateBox(systemImage: "checkmark.circle", title: L("No Changes to Commit", "没有待提交的改动"))
                                .background(Color(nsColor: .controlBackgroundColor))
                                .border(Color(nsColor: .separatorColor), width: 1)
                        } else {
                            CommitFilesTableView(
                                rows: commitRows,
                                checkedPaths: $selectedPaths,
                                highlightedPaths: $highlightedPaths,
                                detailColumnTitle: L("Changes", "变更"),
                                vcsType: .git,
                                changelists: changelists,
                                onDoubleClick: { row in
                                    openDiffOrFile(row)
                                },
                                onContextAction: handleContextAction
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    // Table Footer Strip
                    let visible = filteredItems
                    let checkedVisibleCount = visible.filter { selectedPaths.contains($0.relativePath) }.count
                    HStack(spacing: 14) {
                        Toggle(L("Select / deselect all", "全选 / 全不选"), isOn: Binding(
                            get: {
                                let set = Set(visible.map(\.relativePath))
                                return !set.isEmpty && set.isSubset(of: selectedPaths)
                            },
                            set: { selectAll in
                                let set = visible.map(\.relativePath)
                                if selectAll {
                                    selectedPaths.formUnion(set)
                                } else {
                                    selectedPaths.subtract(set)
                                }
                            }
                        ))

                        Toggle(L("Show untracked files", "显示未跟踪文件"), isOn: $showUntracked)

                        Spacer()

                        if highlightedPaths.count > 1 {
                            Text(String(format: L("%d highlighted", "已选中 %d 行"), highlightedPaths.count))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        let checkedItems = visible.filter { selectedPaths.contains($0.relativePath) }
                        let checkedAdd = checkedItems.compactMap(\.additions).reduce(0, +)
                        let checkedDel = checkedItems.compactMap(\.deletions).reduce(0, +)
                        if checkedAdd > 0 || checkedDel > 0 {
                            DiffLineStatsBadge(additions: checkedAdd, deletions: checkedDel)
                        }

                        Text(String(format: L("%d selected, %d files total", "已勾选 %d 项，共 %d 个文件"), checkedVisibleCount, visible.count))
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 10)
                .frame(minHeight: 220)
            }

            Divider()

            // Footer
            let visibleCheckedCount = filteredItems.filter { selectedPaths.contains($0.relativePath) }.count
            let commitDisabled = isSubmitting || (visibleCheckedCount == 0 && !allowEmpty && !amend && repoState != .merging)
            HStack(spacing: 16) {
                Toggle(L("Amend last commit", "修订上一个提交"), isOn: $amend)
                    .onChange(of: amend) { isAmend in
                        if isAmend && message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            loadLastCommitMessage()
                        }
                    }
                Toggle(L("Allow empty commit", "允许空的提交"), isOn: $allowEmpty)

                // Hidden keyboard shortcut triggers so Cmd+Return and Shift+Cmd+Return work cleanly with Menu split button
                Group {
                    Button("") {
                        performCommit(mode: primaryActionMode)
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(commitDisabled)

                    Button("") {
                        selectAndPerform(.commitAndPush)
                    }
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                    .disabled(commitDisabled)
                }
                .frame(width: 0, height: 0)
                .opacity(0)

                Spacer()
                Button(L("Cancel", "取消")) {
                    AppContainer.shared.windowCoordinator.closeWindow(key: "commit-\(repoPath)")
                }
                .keyboardShortcut(.escape, modifiers: [])

                Menu {
                    ForEach(CommitActionMode.allCases, id: \.self) { mode in
                        Button {
                            selectAndPerform(mode)
                        } label: {
                            HStack {
                                Text(mode.title)
                                if mode == primaryActionMode {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Text(primaryActionMode.title)
                        .frame(minWidth: 100)
                } primaryAction: {
                    performCommit(mode: primaryActionMode)
                }
                .menuStyle(.button)
                .buttonStyle(.borderedProminent)
                .fixedSize()
                .disabled(commitDisabled)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .task { await reload() }
    }

    private func openDiffOrFile(_ row: CommitFileRow) {
        if row.status == .untracked {
            NSWorkspace.shared.open(URL(fileURLWithPath: row.absolutePath))
        } else {
            AppContainer.shared.windowCoordinator.openDiffWithRevision(
                repoPath: repoPath,
                filePath: row.absolutePath,
                revision: "HEAD",
                rightTitle: L("Working Tree", "工作区")
            )
        }
    }

    private func handleContextAction(_ action: CommitFileContextAction) {
        switch action {
        case .diff(let row):
            openDiffOrFile(row)
        case .diffPrevious(let row):
            AppContainer.shared.windowCoordinator.openDiffPreviousVersion(repoPath: repoPath, filePath: row.absolutePath)
        case .showLog(let row):
            AppContainer.shared.windowCoordinator.dispatch(action: .showLog, repoPath: repoPath, targetDir: repoPath, selectedPaths: [row.absolutePath])
        case .blame(let row):
            AppContainer.shared.windowCoordinator.dispatch(action: .blame, repoPath: repoPath, targetDir: repoPath, selectedPaths: [row.absolutePath])
        case .add(let rows):
            let targets = rows.map(\.absolutePath)
            Task {
                _ = try? await AppContainer.shared.gitProvider.add(repoPath: repoPath, paths: targets)
                await reload()
            }
        case .revert(let rows):
            let targets = rows.map(\.absolutePath)
            guard !targets.isEmpty, AlertHelper.confirm(
                title: L("Revert File", "复原文件"),
                message: rows.count == 1 ? rows[0].relativePath : String(format: L("Revert %d selected items?", "确定要复原所选 %d 项吗？"), rows.count)
            ) else { return }
            Task {
                _ = try? await AppContainer.shared.gitProvider.revert(repoPath: repoPath, paths: targets)
                await reload()
            }
        case .delete(let rows):
            let targets = rows.map(\.absolutePath)
            guard !targets.isEmpty, AlertHelper.confirm(
                title: L("Delete Files", "删除文件"),
                message: rows.count == 1 ? rows[0].relativePath : String(format: L("Remove %d selected files from Git and disk?", "确定从 Git 和工作区删除所选 %d 个文件吗？"), rows.count)
            ) else { return }
            Task {
                _ = try? await AppContainer.shared.gitProvider.remove(repoPath: repoPath, paths: targets, keepLocal: false)
                await reload()
            }
        case .addToIgnore(let rows):
            AppContainer.shared.windowCoordinator.dispatch(action: .addToIgnore, repoPath: repoPath, targetDir: repoPath, selectedPaths: rows.map(\.absolutePath))
        case .hideFiles(let rows):
            _ = try? AppContainer.shared.hiddenFilesStore.addRules(rows.map(\.relativePath), for: repoPath)
            hiddenRules = AppContainer.shared.hiddenFilesStore.loadRules(for: repoPath)
        case .moveToChangelist(let rows, let clID):
            changelists = (try? AppContainer.shared.changelistStore.moveFiles(rows.map(\.relativePath), toChangelistID: clID, for: repoPath)) ?? changelists
        case .openFile(let row):
            NSWorkspace.shared.open(URL(fileURLWithPath: row.absolutePath))
        case .revealInFinder(let rows):
            NSWorkspace.shared.activateFileViewerSelecting(rows.map { URL(fileURLWithPath: $0.absolutePath) })
        case .copyPaths(let rows):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(rows.map(\.relativePath).joined(separator: "\n"), forType: .string)
        }
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }

        changelists = AppContainer.shared.changelistStore.load(for: repoPath)
        hiddenRules = AppContainer.shared.hiddenFilesStore.loadRules(for: repoPath)
        recentMessages = AppContainer.shared.recentHistoryStore.load().commitMessages

        let prefs = AppContainer.shared.repositoryManager.currentConfigSnapshot().preferences
        showUntracked = prefs.commitShowUntracked

        do {
            let res = try await AppContainer.shared.gitProvider.status(
                repoPath: repoPath,
                options: VcsStatusOptions(includeIgnored: false, includeUntracked: true, includeLineStats: true)
            )
            branchName = res.branchName
            upstreamBranch = res.upstreamBranch
            aheadCount = res.aheadCount
            behindCount = res.behindCount
            repoState = res.repoState
            items = res.items

            if selectedPaths.isEmpty {
                let normRepo = PathUtils.normalize(repoPath)
                let preSet = Set(preselectedPaths.map { PathUtils.normalize($0) })
                if preSet.isEmpty || preSet.contains(normRepo) {
                    selectedPaths = Set(items.filter { $0.status != .untracked }.map(\.relativePath))
                } else {
                    selectedPaths = Set(items.filter { item in
                        preSet.contains(item.absolutePath)
                        || (item.status != .untracked && preSet.contains { PathUtils.isPath(item.absolutePath, insideOrEqualTo: $0) })
                    }.map(\.relativePath))
                }
            }
        } catch {
            AlertHelper.showError(error)
        }
    }

    private func insertSignOff() {
        Task {
            let gp = AppContainer.shared.gitProvider
            let name = await gp.getGlobalConfigValue(key: "user.name")
            let email = await gp.getGlobalConfigValue(key: "user.email")
            let displayName = name.isEmpty ? NSFullUserName() : name
            let signOff = email.isEmpty
                ? "Signed-off-by: \(displayName)"
                : "Signed-off-by: \(displayName) <\(email)>"
            if message.contains(signOff) { return }
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            message = trimmed.isEmpty ? signOff : "\(trimmed)\n\n\(signOff)"
        }
    }

    private func loadLastCommitMessage() {
        Task {
            if let commits = try? await AppContainer.shared.gitProvider.log(repoPath: repoPath, query: VcsLogQuery(limit: 1)),
               let head = commits.first {
                message = head.body.isEmpty ? head.subject : "\(head.subject)\n\n\(head.body)"
            }
        }
    }

    private func selectAndPerform(_ mode: CommitActionMode) {
        primaryActionMode = mode
        mode.saveAsDefault()
        performCommit(mode: mode)
    }

    private func performCommit(mode: CommitActionMode) {
        let prefs = AppContainer.shared.repositoryManager.currentConfigSnapshot().preferences
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if prefs.checkEmptyCommitMessage && trimmed.isEmpty {
            AlertHelper.showInfo(L("Empty Commit Message", "提交信息为空"), message: L("Please enter a commit message.", "请输入提交信息。"))
            return
        }

        isSubmitting = true
        let chosenAbsPaths = filteredItems
            .filter { selectedPaths.contains($0.relativePath) }
            .map { $0.absolutePath }
        let isAmend = amend
        let isAllowEmpty = allowEmpty
        let msg = trimmed
        let currentBranch = branchName
        let currentUpstream = upstreamBranch

        AppContainer.shared.recentHistoryStore.recordCommitMessage(msg)

        Task {
            defer { isSubmitting = false }
            do {
                _ = try await AppContainer.shared.gitProvider.commit(
                    repoPath: repoPath,
                    options: VcsCommitOptions(
                        message: msg,
                        paths: repoState == .merging ? [] : chosenAbsPaths,
                        amend: isAmend,
                        allowEmpty: isAllowEmpty,
                        stageSelectedPaths: repoState != .merging
                    )
                )
                AppContainer.shared.triggerRefresh(repoPath: repoPath)
                AppContainer.shared.windowCoordinator.closeWindow(key: "commit-\(repoPath)")

                switch mode {
                case .commit:
                    break
                case .commitAndPushDialog:
                    AppContainer.shared.windowCoordinator.dispatch(action: .gitPush, repoPath: repoPath, targetDir: repoPath, selectedPaths: [])
                case .commitAndPush:
                    await performDirectPush(branchName: currentBranch, upstreamBranch: currentUpstream)
                }
            } catch {
                AlertHelper.showError(error)
            }
        }
    }

    private func performDirectPush(branchName: String, upstreamBranch: String?) async {
        guard !branchName.isEmpty, !branchName.hasPrefix("HEAD (") else {
            AppContainer.shared.windowCoordinator.dispatch(action: .gitPush, repoPath: repoPath, targetDir: repoPath, selectedPaths: [])
            return
        }

        let remotes = (try? await AppContainer.shared.gitProvider.listRemotes(repoPath: repoPath)) ?? []
        var targetRemote: String?
        var targetRemoteBranch: String = branchName
        var shouldSetUpstream = false

        if let upstream = upstreamBranch, !upstream.isEmpty {
            if let matchedRemote = remotes.first(where: { upstream.hasPrefix($0.name + "/") }) {
                targetRemote = matchedRemote.name
                targetRemoteBranch = String(upstream.dropFirst(matchedRemote.name.count + 1))
            } else if let slash = upstream.firstIndex(of: "/") {
                targetRemote = String(upstream[..<slash])
                targetRemoteBranch = String(upstream[upstream.index(after: slash)...])
            }
        } else if remotes.count == 1 {
            targetRemote = remotes[0].name
            targetRemoteBranch = branchName
            shouldSetUpstream = true
        }

        guard let remote = targetRemote, !remote.isEmpty else {
            AppContainer.shared.windowCoordinator.dispatch(action: .gitPush, repoPath: repoPath, targetDir: repoPath, selectedPaths: [])
            return
        }

        let opts = GitPushOptions(
            remote: remote,
            branchMappings: [GitPushBranchMapping(localBranch: branchName, remoteBranch: targetRemoteBranch, isSelected: true)],
            setUpstream: shouldSetUpstream
        )
        let env = AppContainer.shared.authEnv(for: repoPath)
        AppContainer.shared.windowCoordinator.runTaskWithProgress(
            title: L("Git Push", "Git 推送"),
            repoPath: repoPath
        ) { log in
            try await AppContainer.shared.gitProvider.push(repoPath: repoPath, options: opts, extraEnv: env) { line, _ in
                log(line)
            }
        }
    }
}
