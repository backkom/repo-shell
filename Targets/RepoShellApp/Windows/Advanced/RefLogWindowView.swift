import SwiftUI
import RepoShellShared
import RepoShellVcs

struct RefLogWindowView: View {
    let repoPath: String

    @State private var selectedRef: String = "HEAD"
    @State private var references: [GitReference] = []
    @State private var entries: [GitRefLogEntry] = []
    @State private var selection: Set<String> = []
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(L("Reference:", "引用：")).foregroundColor(.secondary)
                Picker("", selection: $selectedRef) {
                    Text("HEAD").tag("HEAD")
                    ForEach(references.filter { $0.kind == .localBranch }) { ref in
                        Text(ref.shortName).tag(ref.shortName)
                    }
                }
                .frame(maxWidth: 220)
                .onChange(of: selectedRef) { _ in Task { await reload() } }

                Spacer()
                Button(L("Refresh", "刷新")) { Task { await reload() } }
            }
            .padding()

            Divider()

            TableColumnHeaderBar(
                columns: [
                    TableColumnSpec(L("Selector", "选择器"), width: 85),
                    TableColumnSpec("SHA", width: 68),
                    TableColumnSpec(L("Action", "操作"), width: 110),
                    TableColumnSpec(L("Message", "描述")),
                    TableColumnSpec(L("Date", "日期"), width: 135, alignment: .trailing)
                ],
                horizontalPadding: 12,
                spacing: 10
            )

            if isLoading && entries.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if entries.isEmpty {
                EmptyStateBox(systemImage: "list.bullet.rectangle", title: L("No RefLog Entries", "无操作日志"))
            } else {
                List(entries, selection: $selection) { entry in
                    RefLogRowView(entry: entry)
                        .equatable()
                        .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 12))
                        .tag(entry.id)
                        .contextMenu {
                        let picked = entries.filter { selection.contains($0.id) }
                        if picked.count == 2 {
                            Button(L("Compare Two Versions", "比较两个版本")) {
                                AppContainer.shared.windowCoordinator.openCompareRevisions(repoPath: repoPath, rev1: picked[1].hash, rev2: picked[0].hash)
                            }
                            Divider()
                        }
                        Button(L("Compare with Working Tree", "与工作目录进行对比")) {
                            AppContainer.shared.windowCoordinator.openCompareRevisions(repoPath: repoPath, rev1: entry.hash, rev2: "HEAD")
                        }
                        Button(L("Browse Repository at This Commit", "浏览版本库")) {
                            AppContainer.shared.windowCoordinator.openRepoBrowser(repoPath: repoPath, revision: entry.hash)
                        }
                        Button(L("Show Branches This Commit Is On", "显示包含此提交的分支")) {
                            Task {
                                let branches = (try? await AppContainer.shared.gitProvider.branchesContaining(repoPath: repoPath, commitHash: entry.hash)) ?? []
                                AlertHelper.showInfo(
                                    L("Branches Containing \(entry.shortHash)", "包含 \(entry.shortHash) 的分支"),
                                    message: branches.isEmpty ? L("None (dangling or unreachable)", "无（悬空提交）") : branches.joined(separator: "\n")
                                )
                            }
                        }
                        Divider()
                        Button(L("Checkout This Version…", "切换至/签出此版本…")) {
                            Task {
                                _ = try? await AppContainer.shared.gitProvider.checkout(repoPath: repoPath, target: entry.hash)
                                AppContainer.shared.triggerRefresh(repoPath: repoPath)
                            }
                        }
                        Button(L("Reset Current Branch to This…", "重置当前分支至此版本…")) {
                            AppContainer.shared.windowCoordinator.presentWindow(
                                key: "reset-\(repoPath)-\(entry.shortHash)",
                                title: L("Reset", "重置"),
                                size: NSSize(width: 520, height: 360),
                                view: ResetWindowView(repoPath: repoPath, initialTarget: entry.hash)
                            )
                        }
                        Button(L("Create Branch Here…", "在此版本创建分支…")) {
                            AppContainer.shared.windowCoordinator.presentWindow(
                                key: "create-branch-\(repoPath)-\(entry.shortHash)",
                                title: L("Create Branch", "创建分支"),
                                size: NSSize(width: 480, height: 310),
                                view: CreateBranchWindowView(repoPath: repoPath, initialStartPoint: entry.hash)
                            )
                        }
                        Button(L("Create Tag Here…", "在此版本创建标签…")) {
                            AppContainer.shared.windowCoordinator.presentWindow(
                                key: "create-tag-\(repoPath)-\(entry.shortHash)",
                                title: L("Create Tag", "创建标签"),
                                size: NSSize(width: 480, height: 330),
                                view: CreateTagWindowView(repoPath: repoPath, initialTarget: entry.hash)
                            )
                        }
                        Divider()
                        Button(L("Cherry-Pick This Commit…", "摘取此提交…")) {
                            let c = VcsCommit(hash: entry.hash, shortHash: entry.shortHash, author: "", authorEmail: "", date: entry.date, subject: entry.message)
                            AppContainer.shared.windowCoordinator.openCherryPickWithCommits(repoPath: repoPath, commits: [c])
                        }
                        Button(L("Revert Changes by This Commit", "撤销此提交所做的修改")) {
                            Task {
                                _ = try? await AppContainer.shared.gitProvider.revertCommit(repoPath: repoPath, commitHash: entry.hash)
                                AppContainer.shared.triggerRefresh(repoPath: repoPath)
                            }
                        }
                        Button(L("Format Patch…", "导出补丁 (Format Patch)…")) {
                            if let folder = AlertHelper.pickFolder(title: L("Choose Patch Output Folder", "选择补丁输出目录")) {
                                Task {
                                    _ = try? await AppContainer.shared.gitProvider.formatPatch(repoPath: repoPath, commitHash: entry.hash, outputDirectory: folder.path)
                                }
                            }
                        }
                        Button(L("Copy SHA", "拷贝 SHA")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(entry.hash, forType: .string)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .task {
            references = (try? await AppContainer.shared.gitProvider.listReferences(repoPath: repoPath)) ?? []
            await reload()
        }
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        entries = (try? await AppContainer.shared.gitProvider.reflog(repoPath: repoPath, ref: selectedRef, limit: 200)) ?? []
    }
}

private struct RefLogRowView: View, Equatable {
    let entry: GitRefLogEntry

    var body: some View {
        HStack(spacing: 10) {
            Text(entry.selector)
                .font(.caption.monospaced())
                .foregroundColor(.accentColor)
                .frame(width: 85, alignment: .leading)
            Text(entry.shortHash)
                .font(.caption.monospaced())
                .foregroundColor(.secondary)
                .frame(width: 68, alignment: .leading)
            Text(entry.actionSummary)
                .font(.caption.weight(.semibold))
                .frame(width: 110, alignment: .leading)
                .lineLimit(1)
            Text(entry.message)
                .font(.system(size: 12.5))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(SharedDateFormatters.abbreviatedDateTime.string(from: entry.date))
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 135, alignment: .trailing)
        }
    }
}
