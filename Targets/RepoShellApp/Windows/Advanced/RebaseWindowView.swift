import SwiftUI
import RepoShellShared
import RepoShellVcs

struct RebaseWindowView: View {
    let repoPath: String

    @State private var references: [GitReference] = []
    @State private var currentBranch: String = ""
    @State private var upstreamRef: String = ""
    @State private var todoItems: [GitRebaseTodoItem] = []
    @State private var selectedItemID: String?
    @State private var repoState: VcsRepoState = .normal
    @State private var statusMessage: String = ""
    @State private var isBusy = false

    var body: some View {
        VStack(spacing: 0) {
            // Top bar
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Text(L("Branch:", "分支：")).foregroundColor(.secondary)
                    Text(currentBranch.isEmpty ? "HEAD" : currentBranch).fontWeight(.semibold)
                }

                Text(L("Upstream:", "上游：")).foregroundColor(.secondary)
                Picker("", selection: $upstreamRef) {
                    ForEach(references.filter { $0.shortName != currentBranch }) { ref in
                        Text(ref.shortName).tag(ref.shortName)
                    }
                }
                .frame(maxWidth: 220)
                .onChange(of: upstreamRef) { _ in Task { await loadTodo() } }

                Spacer()

                Button(L("Refresh", "刷新")) { Task { await loadStateAndTodo() } }
            }
            .padding()

            if repoState == .rebasing {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    Text(L("Rebase in progress. Resolve any conflicts, then Continue, Skip, or Abort.", "变基进行中。如有冲突请先解决，再点击“继续”、“跳过”或“中止”。"))
                        .font(.subheadline)
                    Spacer()
                    Button(L("Resolve Conflicts…", "解决冲突…")) {
                        AppContainer.shared.windowCoordinator.dispatch(action: .resolveConflicts, repoPath: repoPath, targetDir: repoPath, selectedPaths: [])
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.14))
            }

            Divider()

            if todoItems.isEmpty {
                EmptyStateBox(
                    systemImage: "arrow.up.and.down.text.horizontal",
                    title: repoState == .rebasing
                        ? L("Rebase Currently Paused", "变基已暂停，等待继续或中止")
                        : L("No Commits to Rebase", "当前分支相对于所选上游无待变基提交")
                )
            } else {
                List($todoItems, selection: $selectedItemID) { $item in
                    HStack(spacing: 10) {
                        Text("\(item.index)")
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                            .frame(width: 24)

                        Picker("", selection: $item.action) {
                            ForEach(GitRebaseAction.allCases, id: \.self) { act in
                                Text(act.displayTitle).tag(act)
                            }
                        }
                        .frame(width: 95)

                        Text(item.shortHash)
                            .font(.caption.monospaced())
                            .foregroundColor(.secondary)
                            .frame(width: 68)

                        Text(item.message)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text(item.author)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 90, alignment: .leading)
                            .lineLimit(1)

                        Text(item.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 130, alignment: .trailing)
                    }
                    .tag(item.id)
                }
                .listStyle(.inset)
            }

            if !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
                    .padding(.top, 6)
            }

            Divider()

            HStack(spacing: 8) {
                Button {
                    moveSelected(offset: -1)
                } label: {
                    Image(systemName: "arrow.up")
                }
                .disabled(!canMoveSelected(offset: -1))
                .help(L("Move Up", "上移"))

                Button {
                    moveSelected(offset: 1)
                } label: {
                    Image(systemName: "arrow.down")
                }
                .disabled(!canMoveSelected(offset: 1))
                .help(L("Move Down", "下移"))

                Spacer()

                if repoState == .rebasing {
                    Button(L("Abort", "中止")) {
                        runControl { try await AppContainer.shared.gitProvider.rebaseAbort(repoPath: repoPath) }
                    }
                    Button(L("Skip", "跳过")) {
                        runControl { try await AppContainer.shared.gitProvider.rebaseSkip(repoPath: repoPath) }
                    }
                    Button(L("Continue", "继续")) {
                        runControl { try await AppContainer.shared.gitProvider.rebaseContinue(repoPath: repoPath) }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button(L("Cancel", "取消")) {
                        AppContainer.shared.windowCoordinator.closeWindow(key: "rebase-\(repoPath)")
                    }
                    .keyboardShortcut(.escape, modifiers: [])

                    Button(L("Start Rebase", "开始变基")) {
                        startRebase()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isBusy || todoItems.isEmpty || upstreamRef.isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding()
        }
        .task { await loadStateAndTodo() }
    }

    private func moveSelected(offset: Int) {
        guard let id = selectedItemID,
              let idx = todoItems.firstIndex(where: { $0.id == id }) else { return }
        let target = idx + offset
        guard target >= 0 && target < todoItems.count else { return }
        todoItems.swapAt(idx, target)
        for i in todoItems.indices {
            todoItems[i].index = i + 1
        }
    }

    private func canMoveSelected(offset: Int) -> Bool {
        guard let id = selectedItemID,
              let idx = todoItems.firstIndex(where: { $0.id == id }) else { return false }
        let target = idx + offset
        return target >= 0 && target < todoItems.count
    }

    private func loadStateAndTodo() async {
        let gp = AppContainer.shared.gitProvider
        repoState = gp.detectRepoState(repoPath: repoPath)
        if let st = try? await gp.status(repoPath: repoPath, options: VcsStatusOptions(includeIgnored: false, includeUntracked: false)) {
            currentBranch = st.branchName
        }
        if let refs = try? await gp.listReferences(repoPath: repoPath) {
            references = refs
            if upstreamRef.isEmpty {
                let candidate = refs.first(where: { $0.kind == .remoteBranch }) ?? refs.first(where: { $0.shortName != currentBranch })
                upstreamRef = candidate?.shortName ?? ""
            }
        }
        await loadTodo()
    }

    private func loadTodo() async {
        guard !upstreamRef.isEmpty else { return }
        todoItems = (try? await AppContainer.shared.gitProvider.loadRebaseTodo(repoPath: repoPath, upstream: upstreamRef)) ?? []
    }

    private func startRebase() {
        isBusy = true
        let up = upstreamRef
        let items = todoItems
        Task {
            defer { isBusy = false }
            do {
                _ = try await AppContainer.shared.gitProvider.startInteractiveRebase(repoPath: repoPath, upstream: up, todoItems: items)
                AppContainer.shared.triggerRefresh(repoPath: repoPath)
                statusMessage = L("Rebase completed successfully.", "变基已完成。")
                await loadStateAndTodo()
            } catch {
                await loadStateAndTodo()
                AlertHelper.showError(error)
            }
        }
    }

    private func runControl(_ block: @escaping () async throws -> VcsCommandResult) {
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                _ = try await block()
                AppContainer.shared.triggerRefresh(repoPath: repoPath)
                await loadStateAndTodo()
            } catch {
                await loadStateAndTodo()
                AlertHelper.showError(error)
            }
        }
    }
}
