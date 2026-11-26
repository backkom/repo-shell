import SwiftUI
import RepoShellShared
import RepoShellVcs

struct ModificationsWindowView: View {
    let repoPath: String

    @State private var items: [VcsStatusItem] = []
    @State private var branchName: String = ""
    @State private var upstreamBranch: String?
    @State private var aheadCount: Int = 0
    @State private var behindCount: Int = 0
    @State private var filterText: String = ""
    @State private var showModified: Bool = true
    @State private var showStaged: Bool = true
    @State private var showUntracked: Bool = true
    @State private var showIgnored: Bool = false
    @State private var dummyChecked: Set<String> = []
    @State private var selection: Set<String> = []
    @State private var isLoading = false

    private var filteredItems: [VcsStatusItem] {
        items.filter { item in
            if !showUntracked && item.status == .untracked { return false }
            if !showIgnored && item.status == .ignored { return false }
            if !showStaged && item.isStaged && item.workTreeStatusCode == " " { return false }
            if !showModified && !item.isStaged && item.status != .untracked && item.status != .ignored { return false }
            if !filterText.isEmpty && !item.relativePath.localizedCaseInsensitiveContains(filterText) {
                return false
            }
            return true
        }
    }

    private var tableRows: [CommitFileRow] {
        filteredItems.map { item in
            let detail: String
            if let add = item.additions, let del = item.deletions {
                detail = "+\(add) -\(del)"
            } else {
                detail = ""
            }
            let sizeStr = item.fileSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""
            return CommitFileRow(
                relativePath: item.relativePath,
                absolutePath: item.absolutePath,
                extensionText: item.isDirectory ? "" : URL(fileURLWithPath: item.relativePath).pathExtension,
                status: item.status,
                statusDisplayText: AppContainer.shared.localized(item.status.localizedLabelKey),
                isDirectory: item.isDirectory,
                detailText: detail,
                tooltipText: item.relativePath,
                stagedText: item.isStaged ? L("Staged", "已暂存") : "",
                sizeText: sizeStr
            )
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label(branchName.isEmpty ? "HEAD" : branchName, systemImage: "arrow.triangle.branch")
                    .font(.headline)

                if let up = upstreamBranch, !up.isEmpty {
                    Text("→ \(up)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if aheadCount > 0 || behindCount > 0 {
                        Text("↑\(aheadCount) ↓\(behindCount)")
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.12))
                            .foregroundColor(.accentColor)
                            .cornerRadius(4)
                    }
                }

                Spacer()

                SearchInputField(
                    placeholder: L("Filter paths…", "筛选项目…"),
                    text: $filterText,
                    width: 220
                )

                Button {
                    Task { await reload() }
                } label: {
                    if isLoading {
                        ProgressView().controlSize(.small).frame(width: 14, height: 14)
                    } else {
                        Label(L("Refresh", "刷新"), systemImage: "arrow.clockwise")
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color(nsColor: .windowBackgroundColor))

            HStack(spacing: 14) {
                Toggle(L("Modified", "已修改"), isOn: $showModified)
                Toggle(L("Staged", "已暂存"), isOn: $showStaged)
                Toggle(L("Untracked", "未跟踪"), isOn: $showUntracked)
                Toggle(L("Ignored", "已忽略"), isOn: $showIgnored)
                Spacer()
                Button(L("Commit…", "提交…")) {
                    let selectedAbs = items.filter { selection.contains($0.relativePath) }.map { $0.absolutePath }
                    AppContainer.shared.windowCoordinator.dispatch(action: .gitCommit, repoPath: repoPath, targetDir: repoPath, selectedPaths: selectedAbs)
                }
                Button(L("Stash…", "储藏…")) {
                    let selectedAbs = items.filter { selection.contains($0.relativePath) }.map { $0.absolutePath }
                    AppContainer.shared.windowCoordinator.dispatch(action: .stashPush, repoPath: repoPath, targetDir: repoPath, selectedPaths: selectedAbs)
                }
                if selection.count == 2 {
                    Button(L("Compare Two Files", "比较两个文件")) {
                        let arr = Array(selection)
                        let p1 = PathUtils.normalize("\(repoPath)/\(arr[0])")
                        let p2 = PathUtils.normalize("\(repoPath)/\(arr[1])")
                        AppContainer.shared.windowCoordinator.launchDiffFiles(leftPath: p1, rightPath: p2, leftTitle: arr[0], rightTitle: arr[1])
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            if isLoading && items.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredItems.isEmpty {
                EmptyStateBox(systemImage: "checkmark.seal", title: L("Working Directory is Clean", "工作目录无改动"))
            } else {
                CommitFilesTableView(
                    rows: tableRows,
                    checkedPaths: $dummyChecked,
                    highlightedPaths: $selection,
                    detailColumnTitle: L("Changes", "变更"),
                    vcsType: .git,
                    changelists: [],
                    showsCheckboxes: false,
                    showsStagedAndSizeColumns: true,
                    onDoubleClick: { row in
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
                    },
                    onContextAction: handleContextAction
                )
            }

            Divider()

            HStack(spacing: 10) {
                let totalAdd = filteredItems.compactMap { $0.additions }.reduce(0, +)
                let totalDel = filteredItems.compactMap { $0.deletions }.reduce(0, +)
                DiffLineStatsBadge(additions: totalAdd, deletions: totalDel)
                Text("·")
                    .foregroundColor(.secondary)
                Text(summaryText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                if !selection.isEmpty {
                    Text(String(format: L("%d selected", "已选中 %d 项"), selection.count))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Button(L("Close", "关闭")) {
                    AppContainer.shared.windowCoordinator.closeWindow(key: "modifications-\(repoPath)")
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .task { await reload() }
    }

    private var summaryText: String {
        let mod = items.filter { $0.status == .modified || $0.status == .typeChanged }.count
        let add = items.filter { $0.status == .added || $0.status == .renamed }.count
        let del = items.filter { $0.status == .deleted || $0.status == .missing }.count
        let conf = items.filter { $0.status == .unmerged }.count
        let unt = items.filter { $0.status == .untracked }.count
        let ign = items.filter { $0.status == .ignored }.count
        return L(
            "Modified=\(mod), Added=\(add), Deleted=\(del), Conflict=\(conf), Untracked=\(unt), Ignored=\(ign)",
            "已修改=\(mod)，已添加=\(add)，已删除=\(del)，冲突=\(conf)，未跟踪=\(unt)，已忽略=\(ign)"
        )
    }

    private func handleContextAction(_ action: CommitFileContextAction) {
        switch action {
        case .diff(let row):
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
        case .diffPrevious(let row):
            AppContainer.shared.windowCoordinator.openDiffPreviousVersion(repoPath: repoPath, filePath: row.absolutePath)
        case .showLog(let row):
            AppContainer.shared.windowCoordinator.dispatch(action: .showLog, repoPath: repoPath, targetDir: repoPath, selectedPaths: [row.absolutePath])
        case .blame(let row):
            AppContainer.shared.windowCoordinator.dispatch(action: .blame, repoPath: repoPath, targetDir: repoPath, selectedPaths: [row.absolutePath])
        case .add(let rows):
            Task {
                _ = try? await AppContainer.shared.gitProvider.add(repoPath: repoPath, paths: rows.map(\.absolutePath))
                await reload()
            }
        case .revert(let rows):
            let msg = rows.count == 1 ? rows[0].relativePath : String(format: L("Revert %d selected files?", "确定复原所选 %d 个文件？"), rows.count)
            if AlertHelper.confirm(title: L("Revert", "复原"), message: msg) {
                Task {
                    _ = try? await AppContainer.shared.gitProvider.revert(repoPath: repoPath, paths: rows.map(\.absolutePath))
                    await reload()
                }
            }
        case .delete(let rows):
            let msg = rows.count == 1 ? rows[0].relativePath : String(format: L("Delete %d selected files?", "确定删除所选 %d 个文件？"), rows.count)
            if AlertHelper.confirm(title: L("Delete", "删除"), message: msg) {
                Task {
                    _ = try? await AppContainer.shared.gitProvider.remove(repoPath: repoPath, paths: rows.map(\.absolutePath), keepLocal: false)
                    await reload()
                }
            }
        case .addToIgnore(let rows):
            AppContainer.shared.windowCoordinator.dispatch(action: .addToIgnore, repoPath: repoPath, targetDir: repoPath, selectedPaths: rows.map(\.absolutePath))
        case .hideFiles:
            break
        case .moveToChangelist:
            break
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
        do {
            let res = try await AppContainer.shared.gitProvider.status(
                repoPath: repoPath,
                options: VcsStatusOptions(includeIgnored: true, includeUntracked: true, includeLineStats: true)
            )
            branchName = res.branchName
            upstreamBranch = res.upstreamBranch
            aheadCount = res.aheadCount
            behindCount = res.behindCount
            items = res.items
        } catch {
            AlertHelper.showError(error)
        }
    }
}
