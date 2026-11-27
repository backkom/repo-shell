import SwiftUI
import RepoShellShared
import RepoShellVcs

struct LogWindowView: View {
    let repoPath: String
    let initialPathFilter: String?

    @State private var commits: [VcsCommit] = []
    @State private var commitIndexByID: [String: VcsCommit] = [:]
    @State private var graphLayouts: [String: CommitGraphNodeLayout] = [:]
    @State private var graphMaxLanes: Int = 1
    @State private var selectedCommitIDs: Set<String> = []
    @State private var displayedCommitID: String?
    @State private var detailUpdateTask: Task<Void, Never>?
    @State private var searchQuery: String = ""
    @State private var pathFilter: String
    @State private var selectedRevisionScope: String = "--all"
    @State private var references: [GitReference] = []
    @State private var showGraph: Bool = true
    @State private var noMerges: Bool = false
    @State private var followRenames: Bool = false
    @State private var limit: Int = 200
    @State private var isLoading: Bool = false

    init(repoPath: String, initialPathFilter: String? = nil) {
        self.repoPath = repoPath
        self.initialPathFilter = initialPathFilter
        let rel = initialPathFilter.flatMap { PathUtils.relativePath(of: $0, inside: repoPath) } ?? ""
        _pathFilter = State(initialValue: rel)
    }

    private var targetSelectedCommitID: String? {
        if selectedCommitIDs.isEmpty {
            return commits.first?.id
        }
        if selectedCommitIDs.count == 1, let only = selectedCommitIDs.first {
            return commitIndexByID[only] != nil ? only : commits.first?.id
        }
        return commits.first(where: { selectedCommitIDs.contains($0.id) })?.id ?? commits.first?.id
    }

    private var activeCommit: VcsCommit? {
        if let displayedCommitID, let match = commitIndexByID[displayedCommitID] {
            return match
        }
        return commits.first
    }

    private var isDetailPending: Bool {
        targetSelectedCommitID != displayedCommitID
    }

    private var graphColumnWidth: CGFloat {
        let clamped = min(max(graphMaxLanes, 1), 8)
        return max(36, CGFloat(clamped) * 12 + 10)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Filter Toolbar
            HStack(spacing: 8) {
                Picker(L("Scope:", "范围："), selection: $selectedRevisionScope) {
                    Text(L("All Branches", "全部分支")).tag("--all")
                    Text("HEAD").tag("HEAD")
                    ForEach(references.filter { $0.kind != .tag }) { ref in
                        Text(ref.shortName).tag(ref.shortName)
                    }
                }
                .frame(maxWidth: 175)
                .onChange(of: selectedRevisionScope) { _ in
                    Task { await reload() }
                }

                SearchInputField(
                    placeholder: L("Search message / author / SHA…", "搜索提交信息 / 作者 / 哈希…"),
                    text: $searchQuery,
                    onSubmit: { Task { await reload() } }
                )

                SearchInputField(
                    placeholder: L("Filter path…", "筛选路径…"),
                    text: $pathFilter,
                    width: 165,
                    onSubmit: { Task { await reload() } }
                )

                Toggle(L("Graph", "分支图"), isOn: $showGraph)
                    .toggleStyle(.checkbox)

                Toggle(L("No merges", "不显示合并"), isOn: $noMerges)
                    .toggleStyle(.checkbox)
                    .onChange(of: noMerges) { _ in Task { await reload() } }

                if !pathFilter.isEmpty {
                    Toggle(L("Follow", "跟随重命名"), isOn: $followRenames)
                        .toggleStyle(.checkbox)
                        .onChange(of: followRenames) { _ in Task { await reload() } }
                }

                Button {
                    Task { await reload() }
                } label: {
                    if isLoading {
                        ProgressView().controlSize(.small).frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .help(L("Refresh", "刷新"))
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            VSplitView {
                // Top Pane: Commit History Table
                VStack(spacing: 0) {
                    TableColumnHeaderBar(
                        columns: headerColumns,
                        horizontalPadding: 10,
                        spacing: 8
                    )

                    if isLoading && commits.isEmpty {
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color(nsColor: .controlBackgroundColor))
                    } else if commits.isEmpty {
                        EmptyStateBox(systemImage: "clock", title: L("No Commits Found", "无提交记录"))
                            .background(Color(nsColor: .controlBackgroundColor))
                    } else {
                        LogCommitsTableView(
                            commits: commits,
                            selectedCommitIDs: $selectedCommitIDs,
                            graphLayouts: graphLayouts,
                            layoutStyle: .git,
                            showsGraph: showGraph,
                            graphWidth: graphColumnWidth,
                            allowsMultipleSelection: true,
                            shaWidth: 62,
                            authorWidth: 112,
                            dateWidth: 136,
                            horizontalPadding: 10,
                            columnSpacing: 8,
                            onPopulateContextMenu: { clickedCommit, selectedCommits, menu in
                                populateContextMenu(menu, commit: clickedCommit, selectedCommits: selectedCommits)
                            }
                        )
                        .onChange(of: selectedCommitIDs) { _ in
                            scheduleDetailRefresh()
                        }
                    }
                }
                .frame(minHeight: 220)

                // Middle & Bottom Panes: Commit Details & Changed Paths (decoupled from row highlight)
                if let commit = activeCommit {
                    LogCommitDetailSection(
                        repoPath: repoPath,
                        commit: commit,
                        headCommitHash: commits.first?.hash,
                        onReload: {
                            Task { await reload() }
                        },
                        onDiffChangedPath: { changed in
                            diffChangedPath(changed, commit: commit)
                        },
                        onSaveFileAtCommit: { path in
                            saveFileAtCommit(path: path, commitHash: commit.hash)
                        }
                    )
                    .equatable()
                }
            }

            Divider()

            HStack {
                Text(L("Showing \(commits.count) commits", "共显示 \(commits.count) 条提交"))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                if let active = activeCommit {
                    Text("·")
                        .foregroundColor(.secondary)
                    Text(String(format: L("%d files changed in %@", "所选提交改动 %d 个文件"), active.changedPaths.count, active.shortHash))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if isDetailPending {
                    ProgressView()
                        .controlSize(.mini)
                        .padding(.leading, 4)
                }
                Spacer()
                Button(L("Load More", "加载更多")) {
                    limit += 200
                    Task { await reload() }
                }
                Button(L("Close", "关闭")) {
                    AppContainer.shared.windowCoordinator.closeWindow(key: "log-\(repoPath)-\(initialPathFilter ?? "")")
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .task {
            if let refs = try? await AppContainer.shared.gitProvider.listReferences(repoPath: repoPath) {
                references = refs
            }
            await reload()
        }
        .onDisappear {
            detailUpdateTask?.cancel()
            detailUpdateTask = nil
        }
    }

    private var headerColumns: [TableColumnSpec] {
        var cols: [TableColumnSpec] = []
        if showGraph {
            cols.append(TableColumnSpec(L("Graph", "图谱"), width: graphColumnWidth, alignment: .leading))
        }
        cols.append(TableColumnSpec("SHA", width: 62, alignment: .leading))
        cols.append(TableColumnSpec(L("Message", "提交信息")))
        cols.append(TableColumnSpec(L("Author", "作者"), width: 112, alignment: .leading))
        cols.append(TableColumnSpec(L("Date", "日期"), width: 136, alignment: .trailing))
        return cols
    }

    private func populateContextMenu(_ menu: NSMenu, commit: VcsCommit, selectedCommits: [VcsCommit]) {
        if selectedCommits.count == 2 {
            menu.addItem(ClosureMenuItem(title: L("Compare Two Revisions", "对比两个版本")) {
                AppContainer.shared.windowCoordinator.openCompareRevisions(
                    repoPath: repoPath,
                    rev1: selectedCommits[1].hash,
                    rev2: selectedCommits[0].hash
                )
            })
            menu.addItem(.separator())
        }

        if let parent = commit.parents.first {
            menu.addItem(ClosureMenuItem(title: L("Compare with Previous Version", "与前一版本进行对比")) {
                AppContainer.shared.windowCoordinator.openCompareRevisions(repoPath: repoPath, rev1: parent, rev2: commit.hash)
            })
        }
        menu.addItem(ClosureMenuItem(title: L("Compare with Working Tree", "与工作目录进行对比")) {
            AppContainer.shared.windowCoordinator.openCompareRevisions(repoPath: repoPath, rev1: commit.hash, rev2: "HEAD")
        })
        menu.addItem(ClosureMenuItem(title: L("Browse Repository at This Commit", "浏览此提交版本库")) {
            AppContainer.shared.windowCoordinator.openRepoBrowser(repoPath: repoPath, revision: commit.hash)
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: L("Checkout This Commit…", "切换到/签出此提交…")) {
            Task {
                _ = try? await AppContainer.shared.gitProvider.checkout(repoPath: repoPath, target: commit.hash)
                AppContainer.shared.triggerRefresh(repoPath: repoPath)
            }
        })
        menu.addItem(ClosureMenuItem(title: L("Create Branch Here…", "在此创建分支…")) {
            AppContainer.shared.windowCoordinator.presentWindow(
                key: "create-branch-\(repoPath)-\(commit.shortHash)",
                title: L("Create Branch", "创建分支"),
                size: NSSize(width: 480, height: 310),
                view: CreateBranchWindowView(repoPath: repoPath, initialStartPoint: commit.hash)
            )
        })
        menu.addItem(ClosureMenuItem(title: L("Create Tag Here…", "在此创建标签…")) {
            AppContainer.shared.windowCoordinator.presentWindow(
                key: "create-tag-\(repoPath)-\(commit.shortHash)",
                title: L("Create Tag", "创建标签"),
                size: NSSize(width: 480, height: 330),
                view: CreateTagWindowView(repoPath: repoPath, initialTarget: commit.hash)
            )
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: L("Cherry-Pick Selected Commits…", "摘取所选提交…")) {
            let list = selectedCommits.isEmpty ? [commit] : selectedCommits.reversed()
            AppContainer.shared.windowCoordinator.openCherryPickWithCommits(repoPath: repoPath, commits: Array(list))
        })
        menu.addItem(ClosureMenuItem(title: L("Merge into Current Branch…", "合并到当前分支…")) {
            Task {
                _ = try? await AppContainer.shared.gitProvider.merge(repoPath: repoPath, options: GitMergeOptions(sourceRef: commit.hash))
                AppContainer.shared.triggerRefresh(repoPath: repoPath)
                await reload()
            }
        })
        menu.addItem(ClosureMenuItem(title: L("Rebase Current Branch onto This", "将当前分支变基到该版本")) {
            Task {
                _ = try? await AppContainer.shared.gitProvider.runGit(repoPath: repoPath, arguments: ["rebase", commit.hash])
                AppContainer.shared.triggerRefresh(repoPath: repoPath)
                await reload()
            }
        })
        menu.addItem(ClosureMenuItem(title: L("Reset Current Branch to This…", "将当前分支重置到该版本…")) {
            AppContainer.shared.windowCoordinator.presentWindow(
                key: "reset-\(repoPath)-\(commit.shortHash)",
                title: L("Reset", "重置"),
                size: NSSize(width: 520, height: 360),
                view: ResetWindowView(repoPath: repoPath, initialTarget: commit.hash)
            )
        })
        menu.addItem(ClosureMenuItem(title: L("Revert Changes by This Commit", "撤销此提交所做的修改")) {
            Task {
                do {
                    _ = try await AppContainer.shared.gitProvider.revertCommit(repoPath: repoPath, commitHash: commit.hash)
                    AppContainer.shared.triggerRefresh(repoPath: repoPath)
                    await reload()
                } catch {
                    AlertHelper.showError(error)
                }
            }
        })
        if selectedCommits.count >= 2, let oldestParent = selectedCommits.last?.parents.first {
            menu.addItem(ClosureMenuItem(title: L("Squash into One Commit", "压扁成一个提交")) {
                let combined = selectedCommits.reversed().map { $0.subject }.joined(separator: "\n\n")
                Task {
                    do {
                        _ = try await AppContainer.shared.gitProvider.squashCommits(repoPath: repoPath, baseParentHash: oldestParent, message: combined)
                        AppContainer.shared.triggerRefresh(repoPath: repoPath)
                        await reload()
                    } catch {
                        AlertHelper.showError(error)
                    }
                }
            })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: L("Export This Version…", "导出此版本…")) {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "\(URL(fileURLWithPath: repoPath).lastPathComponent)-\(commit.shortHash).zip"
            if panel.runModal() == .OK, let dest = panel.url {
                Task {
                    _ = try? await AppContainer.shared.gitProvider.export(repoPath: repoPath, revision: commit.hash, destinationPath: dest.path, asZip: true)
                }
            }
        })
        menu.addItem(ClosureMenuItem(title: L("Copy Full SHA", "拷贝完整哈希")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(commit.hash, forType: .string)
        })
        menu.addItem(ClosureMenuItem(title: L("Copy Short SHA", "拷贝短哈希")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(commit.shortHash, forType: .string)
        })
    }

    private func diffChangedPath(_ changed: VcsChangedPath, commit: VcsCommit) {
        let abs = PathUtils.normalize("\(repoPath)/\(changed.path)")
        if let parent = commit.parents.first {
            AppContainer.shared.windowCoordinator.openDiffBetweenRevisions(repoPath: repoPath, filePath: abs, leftRev: parent, rightRev: commit.hash)
        } else {
            AppContainer.shared.windowCoordinator.openDiffWithRevision(repoPath: repoPath, filePath: abs, revision: commit.hash, rightTitle: commit.shortHash)
        }
    }

    private func saveFileAtCommit(path: String, commitHash: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = URL(fileURLWithPath: path).lastPathComponent
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                try? await AppContainer.shared.gitProvider.extractFile(repoPath: repoPath, path: path, revision: commitHash, to: url.path)
            }
        }
    }

    private func scheduleDetailRefresh() {
        let targetID = targetSelectedCommitID
        detailUpdateTask?.cancel()
        guard targetID != displayedCommitID else {
            detailUpdateTask = nil
            return
        }
        detailUpdateTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 30_000_000)
            guard !Task.isCancelled else { return }
            displayedCommitID = targetID
            detailUpdateTask = nil
        }
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        let query = VcsLogQuery(
            revisionRange: selectedRevisionScope == "--all" ? nil : selectedRevisionScope,
            pathFilter: pathFilter.isEmpty ? nil : pathFilter,
            searchQuery: searchQuery.isEmpty ? nil : searchQuery,
            noMerges: noMerges,
            followRenames: followRenames,
            limit: limit,
            skip: 0
        )
        do {
            let loaded = try await AppContainer.shared.gitProvider.log(repoPath: repoPath, query: query)
            let layouts = CommitGraphLayoutEngine.computeLayouts(for: loaded)
            let index = Dictionary(loaded.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            detailUpdateTask?.cancel()
            detailUpdateTask = nil
            commits = loaded
            commitIndexByID = index
            graphLayouts = layouts
            graphMaxLanes = layouts.values.map(\.maxLanes).max() ?? 1
            if selectedCommitIDs.isEmpty || selectedCommitIDs.allSatisfy({ index[$0] == nil }) {
                selectedCommitIDs = loaded.first.map { [$0.id] } ?? []
            }
            displayedCommitID = targetSelectedCommitID
        } catch {
            AlertHelper.showError(error)
        }
    }
}

private struct LogCommitDetailSection: View, Equatable {
    let repoPath: String
    let commit: VcsCommit
    let headCommitHash: String?
    let onReload: () -> Void
    let onDiffChangedPath: (VcsChangedPath) -> Void
    let onSaveFileAtCommit: (String) -> Void

    @State private var selectedPathID: String?

    static func == (lhs: LogCommitDetailSection, rhs: LogCommitDetailSection) -> Bool {
        lhs.repoPath == rhs.repoPath
            && lhs.commit == rhs.commit
            && lhs.headCommitHash == rhs.headCommitHash
    }

    var body: some View {
        Group {
            // Middle Pane: Full Message, Metadata & Notes
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text(commit.shortHash)
                        .font(.caption.monospaced().weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.12))
                        .foregroundColor(.accentColor)
                        .cornerRadius(4)
                        .textSelection(.enabled)

                    Text(commit.author)
                        .font(.system(size: 12, weight: .semibold))
                    if !commit.authorEmail.isEmpty {
                        Text("<\(commit.authorEmail)>")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    Text("·")
                        .foregroundColor(.secondary)
                    Text(SharedDateFormatters.abbreviatedDateTime.string(from: commit.date))
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if !commit.parents.isEmpty {
                        Text("·")
                            .foregroundColor(.secondary)
                        Text(L("Parents:", "父提交:") + " " + commit.parents.map { String($0.prefix(7)) }.joined(separator: ", "))
                            .font(.caption.monospaced())
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Button(L("Copy SHA", "拷贝哈希")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(commit.hash, forType: .string)
                    }
                    .controlSize(.small)

                    Button(L("Edit Notes", "编辑备注")) {
                        AppContainer.shared.windowCoordinator.openEditNotes(
                            repoPath: repoPath,
                            commitHash: commit.hash,
                            currentNote: commit.note ?? ""
                        )
                    }
                    .controlSize(.small)

                    if commit.hash == headCommitHash {
                        Button(L("Edit Commit Message…", "编辑日志信息…")) {
                            let fullMsg = commit.body.isEmpty ? commit.subject : "\(commit.subject)\n\n\(commit.body)"
                            AppContainer.shared.windowCoordinator.openEditCommitMessage(
                                repoPath: repoPath,
                                initialMessage: fullMsg
                            ) {
                                onReload()
                            }
                        }
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.65))

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(commit.subject)
                            .font(.system(size: 13, weight: .semibold))
                            .textSelection(.enabled)

                        if !commit.body.isEmpty {
                            Text(commit.body)
                                .font(.system(size: 12.5))
                                .foregroundColor(.primary.opacity(0.9))
                                .textSelection(.enabled)
                        }

                        if let note = commit.note, !note.isEmpty {
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "note.text")
                                    .foregroundColor(.orange)
                                Text(L("Note: ", "备注：") + note)
                                    .font(.subheadline)
                                    .textSelection(.enabled)
                            }
                            .padding(8)
                            .background(Color.orange.opacity(0.1))
                            .cornerRadius(6)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(nsColor: .textBackgroundColor))
            }
            .frame(minHeight: 110, idealHeight: 135)

            // Bottom Pane: Changed Paths in Selected Commit
            VStack(spacing: 0) {
                TableColumnHeaderBar(
                    columns: [
                        TableColumnSpec("", width: 24, alignment: .center),
                        TableColumnSpec(L("Path", "路径")),
                        TableColumnSpec(L("Changes", "变更"), width: 92, alignment: .trailing)
                    ],
                    horizontalPadding: 10,
                    spacing: 8
                )

                if commit.changedPaths.isEmpty {
                    EmptyStateBox(systemImage: "doc", title: L("No Changed Files in Commit", "此提交无文件改动"))
                        .background(Color(nsColor: .controlBackgroundColor))
                } else {
                    List(commit.changedPaths, selection: $selectedPathID) { changed in
                        HStack(spacing: 8) {
                            VcsActionBadge(action: changed.action)
                                .frame(width: 24)
                            FileTypeIconView(path: changed.path)
                            Text(changed.path)
                                .font(.system(size: 12.5))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if let copyFrom = changed.copyFromPath {
                                Text("← \(copyFrom)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            if let add = changed.additions, let del = changed.deletions {
                                DiffLineStatsBadge(additions: add, deletions: del)
                                    .frame(width: 92, alignment: .trailing)
                            }
                        }
                        .tag(changed.id)
                        .contentShape(Rectangle())
                        .onListRowDoubleClick {
                            onDiffChangedPath(changed)
                        }
                        .listRowInsets(EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10))
                        .contextMenu {
                            Button(L("Diff with Previous Version", "与前一版本进行对比")) {
                                onDiffChangedPath(changed)
                            }
                            Button(L("Diff with Working Tree", "与工作目录进行对比")) {
                                let abs = PathUtils.normalize("\(repoPath)/\(changed.path)")
                                AppContainer.shared.windowCoordinator.openDiffWithRevision(
                                    repoPath: repoPath,
                                    filePath: abs,
                                    revision: commit.hash,
                                    rightTitle: L("Working Tree", "工作区")
                                )
                            }
                            Button(L("Show Log for This File", "显示此文件日志")) {
                                let abs = PathUtils.normalize("\(repoPath)/\(changed.path)")
                                AppContainer.shared.windowCoordinator.dispatch(action: .showLog, repoPath: repoPath, targetDir: repoPath, selectedPaths: [abs])
                            }
                            Button(L("Blame…", "追溯…")) {
                                let abs = PathUtils.normalize("\(repoPath)/\(changed.path)")
                                AppContainer.shared.windowCoordinator.openBlameResult(
                                    repoPath: repoPath,
                                    filePath: abs,
                                    revision: commit.hash,
                                    ignoreWhitespace: false,
                                    hideAuthorAndDate: false
                                )
                            }
                            Divider()
                            Button(L("Save Revision As…", "保存版本至…")) {
                                onSaveFileAtCommit(changed.path)
                            }
                            Button(L("Revert to This Version", "复原至此版本")) {
                                let abs = PathUtils.normalize("\(repoPath)/\(changed.path)")
                                Task {
                                    try? await AppContainer.shared.gitProvider.extractFile(repoPath: repoPath, path: changed.path, revision: commit.hash, to: abs)
                                    AppContainer.shared.triggerRefresh(repoPath: repoPath)
                                }
                            }
                            Button(L("Copy Path", "拷贝路径")) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(changed.path, forType: .string)
                            }
                        }
                    }
                    .listStyle(.inset)
                    .environment(\.defaultMinListRowHeight, 22)
                }
            }
            .frame(minHeight: 130)
        .onChange(of: commit.id) { _ in
                selectedPathID = nil
            }
        }
    }
}
