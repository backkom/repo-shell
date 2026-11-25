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
            HStack {
                Text(L("Commit to:", "提交至：") + " ")
                    .foregroundColor(.secondary)
                Label(branchName.isEmpty ? "HEAD" : branchName, systemImage: "arrow.triangle.branch")
                    .font(.headline)
                Spacer()
                Button(L("Manage Changelists…", "管理变更列表…")) {
                    AppContainer.shared.windowCoordinator.openChangelists(repoPath: repoPath)
                }
                Button(L("Hidden Files…", "隐藏文件…")) {
                    AppContainer.shared.windowCoordinator.openHiddenFiles(repoPath: repoPath)
                }
                Button {
                    Task { await reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help(L("Refresh", "刷新"))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            // Message Area
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(L("Message:", "提交信息："))
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Menu(L("Recent Messages", "最近信息")) {
                        if recentMessages.isEmpty {
                            Text(L("None", "无"))
                        } else {
                            ForEach(recentMessages, id: \.self) { msg in
                                Button(msg.prefix(60) + (msg.count > 60 ? "…" : "")) {
                                    message = msg
                                }
                            }
                        }
                    }
                    .frame(width: 150)
                }

                TextEditor(text: $message)
                    .font(.system(.body))
                    .frame(height: 96)
                    .border(Color.secondary.opacity(0.25))

                HStack(spacing: 16) {
                    Toggle(L("Amend last commit", "修订上一个提交"), isOn: $amend)
                        .onChange(of: amend) { isAmend in
                            if isAmend && message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                loadLastCommitMessage()
                            }
                        }
                    Toggle(L("Allow empty commit", "允许空的提交"), isOn: $allowEmpty)
                    Spacer()
                }
                .font(.subheadline)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            // Changes Filter Bar
            HStack(spacing: 10) {
                Toggle(L("Select / Deselect All", "全选 / 全不选"), isOn: Binding(
                    get: {
                        let visible = Set(filteredItems.map { $0.relativePath })
                        return !visible.isEmpty && visible.isSubset(of: selectedPaths)
                    },
                    set: { selectAll in
                        let visible = filteredItems.map { $0.relativePath }
                        if selectAll {
                            selectedPaths.formUnion(visible)
                        } else {
                            selectedPaths.subtract(visible)
                        }
                    }
                ))
                Toggle(L("Show untracked files", "显示未跟踪文件"), isOn: $showUntracked)

                Picker(L("Changelist:", "变更列表："), selection: $selectedChangelistID) {
                    Text(L("All Changes", "全部改动")).tag(UUID?.none)
                    ForEach(changelists) { cl in
                        Text("\(cl.name) (\(cl.files.count))").tag(UUID?.some(cl.id))
                    }
                }
                .frame(maxWidth: 200)

                Spacer()

                TextField(L("Filter paths…", "筛选路径…"), text: $filterText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 190)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            // File List
            if isLoading && items.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredItems.isEmpty {
                EmptyStateBox(systemImage: "checkmark.circle", title: L("No Changes to Commit", "没有待提交的改动"))
            } else {
                List {
                    ForEach(filteredItems) { item in
                        HStack(spacing: 8) {
                            Toggle("", isOn: Binding(
                                get: { selectedPaths.contains(item.relativePath) },
                                set: { checked in
                                    if checked {
                                        selectedPaths.insert(item.relativePath)
                                    } else {
                                        selectedPaths.remove(item.relativePath)
                                    }
                                }
                            ))
                            .labelsHidden()

                            StatusBadgeLabel(status: item.status)
                                .frame(width: 84, alignment: .leading)

                            Text(item.relativePath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            if let add = item.additions, let del = item.deletions {
                                Text("+\(add) -\(del)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundColor(.secondary)
                                    .frame(width: 75, alignment: .trailing)
                            }
                            Text(URL(fileURLWithPath: item.relativePath).pathExtension)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(width: 50, alignment: .trailing)
                            if let size = item.fileSize {
                                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .frame(width: 70, alignment: .trailing)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            diffItem(item)
                        }
                        .contextMenu {
                            fileContextMenu(for: item)
                        }
                    }
                }
                .listStyle(.inset)
            }

            Divider()

            // Footer
            let commitDisabled = isSubmitting || (selectedPaths.isEmpty && !allowEmpty && !amend && repoState != .merging)
            HStack {
                Text(String(format: L("%d selected of %d files", "%d 个文件已选择，共 %d 个文件"), selectedPaths.count, filteredItems.count))
                    .font(.caption)
                    .foregroundColor(.secondary)

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
        }
        .task { await reload() }
    }

    @ViewBuilder
    private func fileContextMenu(for item: VcsStatusItem) -> some View {
        Button(L("Diff with Base", "与 base 比较")) { diffItem(item) }
        Button(L("Show Log", "显示日志")) {
            AppContainer.shared.windowCoordinator.dispatch(action: .showLog, repoPath: repoPath, targetDir: repoPath, selectedPaths: [item.absolutePath])
        }
        Button(L("Blame…", "追溯…")) {
            AppContainer.shared.windowCoordinator.dispatch(action: .blame, repoPath: repoPath, targetDir: repoPath, selectedPaths: [item.absolutePath])
        }
        Divider()
        if item.status == .untracked {
            Button(L("Add", "添加")) {
                Task {
                    _ = try? await AppContainer.shared.gitProvider.add(repoPath: repoPath, paths: [item.absolutePath])
                    await reload()
                }
            }
        }
        Button(L("Revert…", "复原…")) {
            if AlertHelper.confirm(title: L("Revert File", "复原文件"), message: item.relativePath) {
                Task {
                    _ = try? await AppContainer.shared.gitProvider.revert(repoPath: repoPath, paths: [item.absolutePath])
                    await reload()
                }
            }
        }
        Button(L("Add to Ignore List…", "添加到忽略清单…")) {
            AppContainer.shared.windowCoordinator.dispatch(action: .addToIgnore, repoPath: repoPath, targetDir: repoPath, selectedPaths: [item.absolutePath])
        }
        Button(L("Hide Selected File", "隐藏所选文件")) {
            _ = try? AppContainer.shared.hiddenFilesStore.addRules([item.relativePath], for: repoPath)
            hiddenRules = AppContainer.shared.hiddenFilesStore.loadRules(for: repoPath)
        }
        Menu(L("Move to Changelist", "移动到变更列表")) {
            Button(L("No Changelist", "无变更列表")) {
                changelists = (try? AppContainer.shared.changelistStore.moveFiles([item.relativePath], toChangelistID: nil, for: repoPath)) ?? changelists
            }
            ForEach(changelists) { cl in
                Button(cl.name) {
                    changelists = (try? AppContainer.shared.changelistStore.moveFiles([item.relativePath], toChangelistID: cl.id, for: repoPath)) ?? changelists
                }
            }
        }
        Divider()
        Button(L("Open", "打开")) {
            NSWorkspace.shared.open(URL(fileURLWithPath: item.absolutePath))
        }
        Button(L("Reveal in Finder", "在访达中显示")) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.absolutePath)])
        }
    }

    private func diffItem(_ item: VcsStatusItem) {
        if item.status == .untracked {
            NSWorkspace.shared.open(URL(fileURLWithPath: item.absolutePath))
        } else {
            AppContainer.shared.windowCoordinator.openDiffWithRevision(
                repoPath: repoPath,
                filePath: item.absolutePath,
                revision: "HEAD",
                rightTitle: L("Working Tree", "工作区")
            )
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
            repoState = res.repoState
            items = res.items

            if selectedPaths.isEmpty {
                let preSet = preselectedPaths.compactMap { PathUtils.relativePath(of: $0, inside: repoPath) }
                if !preSet.isEmpty && !preSet.contains("") {
                    selectedPaths = Set(items.filter { item in
                        preSet.contains(where: { item.relativePath == $0 || item.relativePath.hasPrefix($0 + "/") })
                    }.map { $0.relativePath })
                } else {
                    selectedPaths = Set(items.filter { $0.status != .untracked }.map { $0.relativePath })
                }
            }
        } catch {
            AlertHelper.showError(error)
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
        let chosenAbsPaths = items
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
