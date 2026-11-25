import SwiftUI
import RepoShellShared

struct ChangelistsWindowView: View {
    let repoPath: String

    @State private var lists: [Changelist] = []
    @State private var newName: String = ""

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                TextField(L("New changelist name…", "新变更列表名称…"), text: $newName)
                    .textFieldStyle(.roundedBorder)
                Button(L("Create", "创建")) {
                    let trimmed = newName.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    lists = (try? AppContainer.shared.changelistStore.create(name: trimmed, for: repoPath)) ?? lists
                    newName = ""
                }
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding([.top, .horizontal])

            if lists.isEmpty {
                EmptyStateBox(systemImage: "list.bullet", title: L("No Changelists", "无变更列表"))
            } else {
                List(lists) { cl in
                    HStack {
                        Text(cl.name).fontWeight(.medium)
                        Spacer()
                        Text("\(cl.files.count) files").font(.caption).foregroundColor(.secondary)
                        Button {
                            lists = (try? AppContainer.shared.changelistStore.delete(id: cl.id, for: repoPath)) ?? lists
                        } label: {
                            Image(systemName: "trash").foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.inset)
            }

            HStack {
                Text(String(format: L("%d changelists", "%d 个变更列表"), lists.count))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button(L("Close", "关闭")) {
                    AppContainer.shared.windowCoordinator.closeWindow(key: "changelists-\(repoPath)")
                }
            }
            .padding([.horizontal, .bottom])
        }
        .onAppear {
            lists = AppContainer.shared.changelistStore.load(for: repoPath)
        }
    }
}

struct HiddenFilesWindowView: View {
    let repoPath: String

    @State private var rules: [String] = []
    @State private var newRule: String = ""

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                TextField(L("Pattern (e.g. *.lock or path/to/file)…", "规则（如 *.lock 或相对路径）…"), text: $newRule)
                    .textFieldStyle(.roundedBorder)
                Button(L("Add", "添加")) {
                    rules = (try? AppContainer.shared.hiddenFilesStore.addRules([newRule], for: repoPath)) ?? rules
                    newRule = ""
                }
                .disabled(newRule.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding([.top, .horizontal])

            if rules.isEmpty {
                EmptyStateBox(systemImage: "eye.slash", title: L("No Hidden File Rules", "无文件隐藏规则"))
            } else {
                List(rules, id: \.self) { rule in
                    HStack {
                        Text(rule).font(.system(.body, design: .monospaced))
                        Spacer()
                        Button {
                            rules.removeAll { $0 == rule }
                            try? AppContainer.shared.hiddenFilesStore.saveRules(rules, for: repoPath)
                        } label: {
                            Image(systemName: "trash").foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.inset)
            }

            HStack {
                Text(String(format: L("%d rules", "总共 %d 条规则"), rules.count))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button(L("Close", "关闭")) {
                    AppContainer.shared.windowCoordinator.closeWindow(key: "hidden-files-\(repoPath)")
                }
            }
            .padding([.horizontal, .bottom])
        }
        .onAppear {
            rules = AppContainer.shared.hiddenFilesStore.loadRules(for: repoPath)
        }
    }
}

struct EditNotesWindowView: View {
    let repoPath: String
    let commitHash: String
    @State private var noteText: String

    init(repoPath: String, commitHash: String, initialNote: String) {
        self.repoPath = repoPath
        self.commitHash = commitHash
        _noteText = State(initialValue: initialNote)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Commit:", "提交：") + " \(String(commitHash.prefix(12)))")
                .font(.caption.monospaced())
                .foregroundColor(.secondary)
            TextEditor(text: $noteText)
                .border(Color.secondary.opacity(0.25))
            HStack {
                Spacer()
                Button(L("Cancel", "取消")) {
                    AppContainer.shared.windowCoordinator.closeWindow(key: "notes-\(commitHash)")
                }
                .keyboardShortcut(.escape, modifiers: [])
                Button(L("Save", "保存")) {
                    Task {
                        do {
                            _ = try await AppContainer.shared.gitProvider.editNote(repoPath: repoPath, commitHash: commitHash, note: noteText)
                            AppContainer.shared.windowCoordinator.closeWindow(key: "notes-\(commitHash)")
                        } catch {
                            AlertHelper.showError(error)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding()
    }
}

struct EditCommitMessageWindowView: View {
    let repoPath: String
    let onSaved: () -> Void
    @State private var message: String

    init(repoPath: String, initialMessage: String, onSaved: @escaping () -> Void) {
        self.repoPath = repoPath
        self.onSaved = onSaved
        _message = State(initialValue: initialMessage)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Edit HEAD Commit Message (git commit --amend)", "编辑最新提交日志信息"))
                .font(.headline)
            TextEditor(text: $message)
                .border(Color.secondary.opacity(0.25))
            HStack {
                Spacer()
                Button(L("Cancel", "取消")) {
                    AppContainer.shared.windowCoordinator.closeWindow(key: "edit-msg-\(repoPath)")
                }
                .keyboardShortcut(.escape, modifiers: [])
                Button(L("Save", "保存")) {
                    Task {
                        do {
                            _ = try await AppContainer.shared.gitProvider.editHeadCommitMessage(repoPath: repoPath, newMessage: message)
                            onSaved()
                            AppContainer.shared.windowCoordinator.closeWindow(key: "edit-msg-\(repoPath)")
                        } catch {
                            AlertHelper.showError(error)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding()
    }
}
