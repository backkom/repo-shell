import SwiftUI
import RepoShellShared
import RepoShellVcs

struct CompareRevisionsWindowView: View {
    let repoPath: String

    @State private var rev1: String
    @State private var rev2: String
    @State private var diffs: [VcsChangedPath] = []
    @State private var selection: Set<String> = []
    @State private var isLoading = false

    init(repoPath: String, initialRev1: String = "HEAD~1", initialRev2: String = "HEAD") {
        self.repoPath = repoPath
        _rev1 = State(initialValue: initialRev1)
        _rev2 = State(initialValue: initialRev2)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Revision 1:", "版本 1：")).font(.caption).foregroundColor(.secondary)
                    RefSelectionPicker(repoPath: repoPath, selectedRef: $rev1, allowHEAD: true)
                }
                Button {
                    let tmp = rev1
                    rev1 = rev2
                    rev2 = tmp
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                }
                .padding(.top, 20)

                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Revision 2:", "版本 2：")).font(.caption).foregroundColor(.secondary)
                    RefSelectionPicker(repoPath: repoPath, selectedRef: $rev2, allowHEAD: true)
                }

                Button(L("Compare", "比较")) {
                    Task { await reload() }
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 18)
            }
            .padding()

            Divider()

            if isLoading && diffs.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if diffs.isEmpty {
                EmptyStateBox(systemImage: "doc.on.doc", title: L("No Differences Found", "两个版本间无差异"))
            } else {
                List(diffs, selection: $selection) { item in
                    HStack(spacing: 10) {
                        Text(item.action)
                            .font(.caption.monospaced().bold())
                            .frame(width: 24)
                        Text(item.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let add = item.additions, let del = item.deletions {
                            Text("+\(add) -\(del)")
                                .font(.caption.monospacedDigit())
                                .foregroundColor(.secondary)
                        }
                    }
                    .tag(item.path)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        let abs = PathUtils.normalize("\(repoPath)/\(item.path)")
                        AppContainer.shared.windowCoordinator.openDiffBetweenRevisions(repoPath: repoPath, filePath: abs, leftRev: rev1, rightRev: rev2)
                    }
                    .contextMenu {
                        Button(L("Diff", "比较")) {
                            let abs = PathUtils.normalize("\(repoPath)/\(item.path)")
                            AppContainer.shared.windowCoordinator.openDiffBetweenRevisions(repoPath: repoPath, filePath: abs, leftRev: rev1, rightRev: rev2)
                        }
                        Button(L("Show Log", "显示日志")) {
                            let abs = PathUtils.normalize("\(repoPath)/\(item.path)")
                            AppContainer.shared.windowCoordinator.dispatch(action: .showLog, repoPath: repoPath, targetDir: repoPath, selectedPaths: [abs])
                        }
                        Button(L("Copy Path", "拷贝路径到剪贴板")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(item.path, forType: .string)
                        }
                    }
                }
                .listStyle(.inset)
            }

            Divider()
            HStack {
                Text(L("\(diffs.count) changed files", "共 \(diffs.count) 个差异文件"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button(L("Export Selected Files…", "导出所选文件到…")) {
                    exportSelected()
                }
                .disabled(selection.isEmpty)
                Button(L("Close", "关闭")) {
                    AppContainer.shared.windowCoordinator.closeWindow(key: "compare-\(repoPath)")
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding()
        }
        .task { await reload() }
    }

    private func reload() async {
        guard !rev1.isEmpty, !rev2.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        diffs = (try? await AppContainer.shared.gitProvider.diffRevisions(repoPath: repoPath, rev1: rev1, rev2: rev2)) ?? []
    }

    private func exportSelected() {
        guard let destFolder = AlertHelper.pickFolder(title: L("Export Selected Changed Files To", "选择导出目录")) else { return }
        let selectedFiles = diffs.filter { selection.contains($0.path) }
        Task {
            for file in selectedFiles {
                let target = destFolder.appendingPathComponent(file.path)
                try? await AppContainer.shared.gitProvider.extractFile(repoPath: repoPath, path: file.path, revision: rev2, to: target.path)
            }
        }
    }
}
