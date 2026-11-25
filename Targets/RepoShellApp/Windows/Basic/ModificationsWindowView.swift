import SwiftUI
import RepoShellShared
import RepoShellVcs

struct ModificationsWindowView: View {
    let repoPath: String

    @State private var items: [VcsStatusItem] = []
    @State private var branchName: String = ""
    @State private var filterText: String = ""
    @State private var showModified: Bool = true
    @State private var showStaged: Bool = true
    @State private var showUntracked: Bool = true
    @State private var showIgnored: Bool = false
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

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label(branchName.isEmpty ? "HEAD" : branchName, systemImage: "arrow.triangle.branch")
                    .font(.headline)
                Spacer()
                TextField(L("Filter paths…", "筛选项目…"), text: $filterText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                Button(L("Refresh", "刷新")) {
                    Task { await reload() }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

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
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)

            Divider()

            if isLoading && items.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredItems.isEmpty {
                EmptyStateBox(systemImage: "checkmark.seal", title: L("Working Directory is Clean", "工作目录无改动"))
            } else {
                List(filteredItems, selection: $selection) { item in
                    HStack(spacing: 10) {
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
                        }
                        if let size = item.fileSize {
                            Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(width: 68, alignment: .trailing)
                        }
                    }
                    .tag(item.relativePath)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        AppContainer.shared.windowCoordinator.openDiffWithRevision(
                            repoPath: repoPath,
                            filePath: item.absolutePath,
                            revision: "HEAD",
                            rightTitle: L("Working Tree", "工作区")
                        )
                    }
                    .contextMenu {
                        Button(L("Diff with Base", "与 base 对比")) {
                            AppContainer.shared.windowCoordinator.openDiffWithRevision(
                                repoPath: repoPath,
                                filePath: item.absolutePath,
                                revision: "HEAD",
                                rightTitle: L("Working Tree", "工作区")
                            )
                        }
                        Button(L("Add", "添加")) {
                            Task {
                                _ = try? await AppContainer.shared.gitProvider.add(repoPath: repoPath, paths: [item.absolutePath])
                                await reload()
                            }
                        }
                        Button(L("Revert…", "复原…")) {
                            if AlertHelper.confirm(title: L("Revert", "复原"), message: item.relativePath) {
                                Task {
                                    _ = try? await AppContainer.shared.gitProvider.revert(repoPath: repoPath, paths: [item.absolutePath])
                                    await reload()
                                }
                            }
                        }
                        Button(L("Rename…", "重命名…")) {
                            AppContainer.shared.windowCoordinator.dispatch(action: .rename, repoPath: repoPath, targetDir: repoPath, selectedPaths: [item.absolutePath])
                        }
                        Button(L("Delete", "删除")) {
                            if AlertHelper.confirm(title: L("Delete", "删除"), message: item.relativePath) {
                                Task {
                                    _ = try? await AppContainer.shared.gitProvider.remove(repoPath: repoPath, paths: [item.absolutePath], keepLocal: false)
                                    await reload()
                                }
                            }
                        }
                        Divider()
                        Button(L("Show Log", "显示日志")) {
                            AppContainer.shared.windowCoordinator.dispatch(action: .showLog, repoPath: repoPath, targetDir: repoPath, selectedPaths: [item.absolutePath])
                        }
                        Button(L("Blame…", "追溯…")) {
                            AppContainer.shared.windowCoordinator.dispatch(action: .blame, repoPath: repoPath, targetDir: repoPath, selectedPaths: [item.absolutePath])
                        }
                        Button(L("Reveal in Finder", "在访达中显示")) {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.absolutePath)])
                        }
                    }
                }
                .listStyle(.inset)
            }

            Divider()

            HStack {
                Text(summaryText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button(L("Close", "关闭")) {
                    AppContainer.shared.windowCoordinator.closeWindow(key: "modifications-\(repoPath)")
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .task { await reload() }
    }

    private var summaryText: String {
        let totalAdd = items.compactMap { $0.additions }.reduce(0, +)
        let totalDel = items.compactMap { $0.deletions }.reduce(0, +)
        let mod = items.filter { $0.status == .modified || $0.status == .typeChanged }.count
        let add = items.filter { $0.status == .added || $0.status == .renamed }.count
        let del = items.filter { $0.status == .deleted || $0.status == .missing }.count
        let conf = items.filter { $0.status == .unmerged }.count
        let unt = items.filter { $0.status == .untracked }.count
        let ign = items.filter { $0.status == .ignored }.count
        return L(
            "Lines: +\(totalAdd) -\(totalDel) | Modified=\(mod), Added=\(add), Deleted=\(del), Conflict=\(conf), Untracked=\(unt), Ignored=\(ign)",
            "行数：+\(totalAdd) -\(totalDel) | 已修改=\(mod)，已添加=\(add)，已删除=\(del)，冲突=\(conf)，未跟踪=\(unt)，已忽略=\(ign)"
        )
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
            items = res.items
        } catch {
            AlertHelper.showError(error)
        }
    }
}
