import SwiftUI
import RepoShellShared
import RepoShellVcs

struct CherryPickWindowView: View {
    let repoPath: String

    @State private var items: [GitCherryPickItem]
    @State private var commitSHAInput: String = ""
    @State private var noCommit: Bool = false
    @State private var recordOrigin: Bool = true
    @State private var repoState: VcsRepoState = .normal
    @State private var isBusy = false

    init(repoPath: String, initialItems: [GitCherryPickItem] = []) {
        self.repoPath = repoPath
        _items = State(initialValue: initialItems)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField(L("Commit SHA or revision to add…", "输入提交 SHA 或版本添加到队列…"), text: $commitSHAInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addCommitFromInput)
                Button(L("Add", "添加"), action: addCommitFromInput)
                    .disabled(commitSHAInput.trimmingCharacters(in: .whitespaces).isEmpty)
                Button(L("Pick from Log…", "从日志选择…")) {
                    AppContainer.shared.windowCoordinator.dispatch(action: .showLog, repoPath: repoPath, targetDir: repoPath, selectedPaths: [])
                }
            }
            .padding()

            if repoState == .cherryPicking {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    Text(L("Cherry-pick paused due to conflict. Resolve conflicts, then Continue, Skip, or Abort.", "摘取因冲突暂停，请解决冲突后点击“继续”、“跳过”或“中止”。"))
                        .font(.subheadline)
                    Spacer()
                    Button(L("Resolve…", "解决…")) {
                        AppContainer.shared.windowCoordinator.dispatch(action: .resolveConflicts, repoPath: repoPath, targetDir: repoPath, selectedPaths: [])
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.14))
            }

            Divider()

            if items.isEmpty {
                EmptyStateBox(
                    systemImage: "wand.and.stars",
                    title: L("No Commits Queued", "暂无待摘取提交"),
                    subtitle: L("Enter a commit SHA above or select commits from Show Log → Cherry-Pick.", "请在上方输入提交哈希，或在“显示日志”中右键选择提交进行摘取。")
                )
            } else {
                List {
                    ForEach(items) { item in
                        HStack(spacing: 10) {
                            Text("\(item.order)")
                                .font(.caption.monospacedDigit())
                                .foregroundColor(.secondary)
                                .frame(width: 24)
                            Text(item.shortHash)
                                .font(.caption.monospaced())
                                .frame(width: 68, alignment: .leading)
                            Text(item.message)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(item.author)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(width: 90, alignment: .leading)
                            Button {
                                items.removeAll { $0.id == item.id }
                                reindex()
                            } label: {
                                Image(systemName: "trash").foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .listStyle(.inset)
            }

            Divider()

            HStack(spacing: 14) {
                Toggle(L("Do not auto-commit (-n)", "不要自动创建提交 (-n)"), isOn: $noCommit)
                Toggle(L("Append \"cherry picked from ...\" (-x)", "记录来源信息 (-x)"), isOn: $recordOrigin)
                Spacer()

                if repoState == .cherryPicking {
                    Button(L("Abort", "中止")) {
                        runControl(.abort)
                    }
                    Button(L("Skip", "跳过")) {
                        runControl(.skip)
                    }
                    Button(L("Continue", "继续")) {
                        runControl(.continue)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button(L("Cancel", "取消")) {
                        AppContainer.shared.windowCoordinator.closeWindow(key: "cherrypick-\(repoPath)")
                    }
                    .keyboardShortcut(.escape, modifiers: [])

                    Button(L("Cherry-Pick", "开始摘取")) {
                        startCherryPick()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isBusy || items.isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding()
        }
        .onAppear {
            repoState = AppContainer.shared.gitProvider.detectRepoState(repoPath: repoPath)
        }
    }

    private func addCommitFromInput() {
        let rev = commitSHAInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rev.isEmpty else { return }
        commitSHAInput = ""
        Task {
            if let found = try? await AppContainer.shared.gitProvider.log(repoPath: repoPath, query: VcsLogQuery(revisionRange: rev, limit: 1)),
               let first = found.first {
                appendCommit(first)
            } else {
                let item = GitCherryPickItem(order: items.count + 1, hash: rev, shortHash: String(rev.prefix(7)), author: "", date: Date(), message: rev)
                items.append(item)
            }
        }
    }

    private func appendCommit(_ c: VcsCommit) {
        guard !items.contains(where: { $0.hash == c.hash }) else { return }
        items.append(GitCherryPickItem(order: items.count + 1, hash: c.hash, shortHash: c.shortHash, author: c.author, date: c.date, message: c.subject))
    }

    private func reindex() {
        for i in items.indices {
            items[i].order = i + 1
        }
    }

    private func startCherryPick() {
        isBusy = true
        let hashes = items.map { $0.hash }
        let nc = noCommit
        let rx = recordOrigin
        Task {
            defer { isBusy = false }
            do {
                _ = try await AppContainer.shared.gitProvider.cherryPick(repoPath: repoPath, commits: hashes, noCommit: nc, recordOrigin: rx)
                AppContainer.shared.triggerRefresh(repoPath: repoPath)
                repoState = AppContainer.shared.gitProvider.detectRepoState(repoPath: repoPath)
                AlertHelper.showInfo(L("Cherry-Pick Completed", "摘取完成"), message: L("Selected commits applied.", "所选提交已成功应用。"))
            } catch {
                repoState = AppContainer.shared.gitProvider.detectRepoState(repoPath: repoPath)
                AlertHelper.showError(error)
            }
        }
    }

    private func runControl(_ action: CherryPickControlAction) {
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                _ = try await AppContainer.shared.gitProvider.cherryPickControl(repoPath: repoPath, action: action)
                AppContainer.shared.triggerRefresh(repoPath: repoPath)
                repoState = AppContainer.shared.gitProvider.detectRepoState(repoPath: repoPath)
            } catch {
                repoState = AppContainer.shared.gitProvider.detectRepoState(repoPath: repoPath)
                AlertHelper.showError(error)
            }
        }
    }
}
