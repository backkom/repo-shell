import SwiftUI
import RepoShellShared
import RepoShellVcs

struct SwitchCheckoutWindowView: View {
    let repoPath: String

    @State private var targetRef: String = ""
    @State private var createNewBranch = false
    @State private var newBranchName = ""
    @State private var force = false
    @State private var mergeLocal = false
    @State private var overwriteBranch = false
    @State private var track = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(header: Text(L("Switch / Checkout Target", "签出目标"))) {
                    RefSelectionPicker(repoPath: repoPath, selectedRef: $targetRef, allowHEAD: false)
                }
                Section(header: Text(L("Options", "选项"))) {
                    Toggle(L("Create new branch", "创建新分支"), isOn: $createNewBranch)
                    if createNewBranch {
                        TextField(L("New branch name:", "新分支名称："), text: $newBranchName)
                        Toggle(L("Overwrite existing branch (-B)", "覆盖现有分支 (-B)"), isOn: $overwriteBranch)
                        Toggle(L("Set upstream tracking (--track)", "配置 upstream 跟踪"), isOn: $track)
                    }
                    Toggle(L("Force checkout (-f, discards local changes)", "强制执行（丢弃本地未提交修改）"), isOn: $force)
                    Toggle(L("Merge local changes (-m)", "将本地修改合并至新分支"), isOn: $mergeLocal)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button(L("Cancel", "取消")) {
                    AppContainer.shared.windowCoordinator.closeWindow(key: "checkout-\(repoPath)")
                }
                .keyboardShortcut(.escape, modifiers: [])
                Button(L("Checkout", "签出")) {
                    let target = targetRef
                    let branch = createNewBranch ? newBranchName.trimmingCharacters(in: .whitespaces) : nil
                    AppContainer.shared.windowCoordinator.closeWindow(key: "checkout-\(repoPath)")
                    AppContainer.shared.windowCoordinator.runTaskWithProgress(title: L("Git Checkout", "Git 签出"), repoPath: repoPath) { _ in
                        try await AppContainer.shared.gitProvider.checkout(
                            repoPath: repoPath,
                            target: target,
                            createBranchName: branch,
                            force: force,
                            mergeLocalChanges: mergeLocal,
                            overwriteBranch: overwriteBranch,
                            track: track
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(targetRef.isEmpty || (createNewBranch && newBranchName.trimmingCharacters(in: .whitespaces).isEmpty))
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()
        }
    }
}

struct CreateBranchWindowView: View {
    let repoPath: String
    var initialStartPoint: String = "HEAD"

    @State private var branchName: String = ""
    @State private var startPoint: String
    @State private var force = false
    @State private var checkoutAfter = true
    @State private var track = false

    init(repoPath: String, initialStartPoint: String = "HEAD") {
        self.repoPath = repoPath
        self.initialStartPoint = initialStartPoint
        _startPoint = State(initialValue: initialStartPoint)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField(L("Branch Name:", "分支名称："), text: $branchName)
                Section(header: Text(L("Start Point:", "起点："))) {
                    RefSelectionPicker(repoPath: repoPath, selectedRef: $startPoint, allowHEAD: true)
                }
                Toggle(L("Switch to new branch after creation", "创建后立即签出"), isOn: $checkoutAfter)
                Toggle(L("Overwrite if exists", "覆盖同名分支"), isOn: $force)
                Toggle(L("Configure upstream tracking (--track)", "配置跟踪"), isOn: $track)
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button(L("Cancel", "取消")) {
                    AppContainer.shared.windowCoordinator.closeWindow(key: "create-branch-\(repoPath)")
                }
                .keyboardShortcut(.escape, modifiers: [])
                Button(L("Create Branch", "创建分支")) {
                    let name = branchName.trimmingCharacters(in: .whitespaces)
                    let sp = startPoint.isEmpty ? "HEAD" : startPoint
                    Task {
                        do {
                            _ = try await AppContainer.shared.gitProvider.createBranch(
                                repoPath: repoPath,
                                name: name,
                                startPoint: sp,
                                force: force,
                                checkoutAfter: checkoutAfter,
                                track: track
                            )
                            AppContainer.shared.triggerRefresh(repoPath: repoPath)
                            AppContainer.shared.windowCoordinator.closeWindow(key: "create-branch-\(repoPath)")
                        } catch {
                            AlertHelper.showError(error)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(branchName.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()
        }
    }
}

struct CreateTagWindowView: View {
    let repoPath: String
    var initialTarget: String = "HEAD"

    @State private var tagName: String = ""
    @State private var targetRef: String
    @State private var message: String = ""
    @State private var force = false

    init(repoPath: String, initialTarget: String = "HEAD") {
        self.repoPath = repoPath
        self.initialTarget = initialTarget
        _targetRef = State(initialValue: initialTarget)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField(L("Tag Name:", "标签名称："), text: $tagName)
                Section(header: Text(L("Target Revision:", "目标版本："))) {
                    RefSelectionPicker(repoPath: repoPath, selectedRef: $targetRef, allowHEAD: true)
                }
                TextField(L("Message (optional, creates annotated tag):", "附注消息（可选）："), text: $message)
                Toggle(L("Overwrite existing tag (-f)", "覆盖现有标签"), isOn: $force)
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button(L("Cancel", "取消")) {
                    AppContainer.shared.windowCoordinator.closeWindow(key: "create-tag-\(repoPath)")
                }
                .keyboardShortcut(.escape, modifiers: [])
                Button(L("Create Tag", "创建标签")) {
                    let name = tagName.trimmingCharacters(in: .whitespaces)
                    let target = targetRef.isEmpty ? "HEAD" : targetRef
                    let msg = message.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task {
                        do {
                            _ = try await AppContainer.shared.gitProvider.createTag(
                                repoPath: repoPath,
                                name: name,
                                target: target,
                                message: msg.isEmpty ? nil : msg,
                                force: force
                            )
                            AppContainer.shared.triggerRefresh(repoPath: repoPath)
                            AppContainer.shared.windowCoordinator.closeWindow(key: "create-tag-\(repoPath)")
                        } catch {
                            AlertHelper.showError(error)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(tagName.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()
        }
    }
}

struct MergeWindowView: View {
    let repoPath: String

    @State private var sourceRef: String = ""
    @State private var noFastForward = false
    @State private var squash = false
    @State private var noCommit = false
    @State private var includeLog = false
    @State private var logCountText = "20"
    @State private var customMessage = ""

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(header: Text(L("Merge From:", "合并来源："))) {
                    RefSelectionPicker(repoPath: repoPath, selectedRef: $sourceRef, allowHEAD: false)
                }
                Section(header: Text(L("Options", "选项"))) {
                    Toggle(L("Create a merge commit even if fast-forward (--no-ff)", "不允许快进（始终创建合并提交）"), isOn: $noFastForward)
                    Toggle(L("Squash commits (--squash)", "挤压 (--squash)"), isOn: $squash)
                    Toggle(L("Do not commit (--no-commit)", "合并后不自动创建提交"), isOn: $noCommit)
                    HStack {
                        Toggle(L("Include log messages (--log)", "包含被合并提交消息"), isOn: $includeLog)
                        if includeLog {
                            TextField("20", text: $logCountText)
                                .frame(width: 50)
                        }
                    }
                    TextField(L("Custom merge message (optional):", "合并提交消息（可选）："), text: $customMessage)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button(L("Cancel", "取消")) {
                    AppContainer.shared.windowCoordinator.closeWindow(key: "merge-\(repoPath)")
                }
                .keyboardShortcut(.escape, modifiers: [])
                Button(L("Merge", "合并")) {
                    let opts = GitMergeOptions(
                        sourceRef: sourceRef,
                        noFastForward: noFastForward,
                        squash: squash,
                        noCommit: noCommit,
                        logCount: includeLog ? (Int(logCountText) ?? 20) : nil,
                        message: customMessage.isEmpty ? nil : customMessage
                    )
                    AppContainer.shared.windowCoordinator.closeWindow(key: "merge-\(repoPath)")
                    AppContainer.shared.windowCoordinator.runTaskWithProgress(title: L("Git Merge", "Git 合并"), repoPath: repoPath) { _ in
                        try await AppContainer.shared.gitProvider.merge(repoPath: repoPath, options: opts)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(sourceRef.isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()
        }
    }
}

struct ResetWindowView: View {
    let repoPath: String
    var initialTarget: String = "HEAD"

    @State private var targetRef: String
    @State private var mode: GitResetMode = .mixed

    init(repoPath: String, initialTarget: String = "HEAD") {
        self.repoPath = repoPath
        self.initialTarget = initialTarget
        _targetRef = State(initialValue: initialTarget)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(header: Text(L("Reset Current Branch To:", "重置当前分支至："))) {
                    RefSelectionPicker(repoPath: repoPath, selectedRef: $targetRef, allowHEAD: true)
                }
                Section(header: Text(L("Reset Type:", "重置类型："))) {
                    Picker("", selection: $mode) {
                        Text(L("Soft: keep working tree and index", "软 (Soft)：不改变工作目录及索引")).tag(GitResetMode.soft)
                        Text(L("Mixed: keep working tree, reset index", "混合 (Mixed)：保持工作目录不变，重置索引")).tag(GitResetMode.mixed)
                        Text(L("Hard: reset working tree & index (DISCARDS ALL CHANGES)", "硬 (Hard)：重置工作目录及索引（丢弃所有本地改动）")).tag(GitResetMode.hard)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button(L("Cancel", "取消")) {
                    AppContainer.shared.windowCoordinator.closeWindow(key: "reset-\(repoPath)")
                }
                .keyboardShortcut(.escape, modifiers: [])
                Button(L("Reset", "重置")) {
                    if mode == .hard && !AlertHelper.confirm(
                        title: L("Hard Reset Warning", "硬重置警告"),
                        message: L("Hard reset will permanently discard uncommitted changes. Continue?", "硬重置将永久丢弃所有未提交的本地修改，确定继续？")
                    ) {
                        return
                    }
                    let target = targetRef.isEmpty ? "HEAD" : targetRef
                    let m = mode
                    AppContainer.shared.windowCoordinator.closeWindow(key: "reset-\(repoPath)")
                    AppContainer.shared.windowCoordinator.runTaskWithProgress(title: L("Git Reset", "Git 重置"), repoPath: repoPath) { _ in
                        try await AppContainer.shared.gitProvider.reset(repoPath: repoPath, target: target, mode: m)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()
        }
    }
}

struct ReferencesWindowView: View {
    let repoPath: String

    @State private var references: [GitReference] = []
    @State private var filterKind: GitReferenceKind? = nil
    @State private var searchText: String = ""
    @State private var selection: Set<String> = []
    @State private var renameTarget: GitReference?
    @State private var renameText: String = ""

    private var filtered: [GitReference] {
        let byKind = filterKind == nil ? references : references.filter { $0.kind == filterKind }
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return byKind }
        return byKind.filter {
            $0.shortName.localizedCaseInsensitiveContains(q)
            || $0.lastCommitSubject.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("", selection: $filterKind) {
                    Text(L("All", "全部")).tag(GitReferenceKind?.none)
                    Text(L("Local Branches", "本地分支")).tag(GitReferenceKind?.some(.localBranch))
                    Text(L("Remote Branches", "远程分支")).tag(GitReferenceKind?.some(.remoteBranch))
                    Text(L("Tags", "标签")).tag(GitReferenceKind?.some(.tag))
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 380)

                SearchInputField(
                    placeholder: L("Filter refs…", "筛选引用…"),
                    text: $searchText,
                    width: 170
                )

                Spacer()
                if selection.count == 2 {
                    Button(L("Compare References", "比较引用")) {
                        let arr = Array(selection)
                        if let r1 = references.first(where: { $0.id == arr[0] }),
                           let r2 = references.first(where: { $0.id == arr[1] }) {
                            AppContainer.shared.windowCoordinator.openCompareRevisions(repoPath: repoPath, rev1: r1.shortName, rev2: r2.shortName)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button(L("Refresh", "刷新")) { Task { await reload() } }
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            TableColumnHeaderBar(
                columns: [
                    TableColumnSpec(L("Reference", "引用")),
                    TableColumnSpec(L("Last Commit", "最新提交"), width: 240, alignment: .trailing),
                    TableColumnSpec("SHA", width: 64, alignment: .trailing)
                ],
                horizontalPadding: 12,
                spacing: 8
            )

            List(filtered, selection: $selection) { ref in
                HStack(spacing: 8) {
                    Image(systemName: icon(for: ref.kind))
                        .foregroundColor(ref.isCurrent ? .green : .secondary)
                    Text(ref.shortName)
                        .font(.system(size: 12.5, weight: ref.isCurrent ? .semibold : .regular))
                    if ref.isCurrent {
                        Text("HEAD")
                            .font(.system(size: 9.5, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.green.opacity(0.16))
                            .foregroundColor(.green)
                            .cornerRadius(3)
                    }
                    if let upstream = ref.upstream {
                        Text("→ \(upstream)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    if let ab = ref.aheadBehind, !ab.isEmpty {
                        Text(ab)
                            .font(.caption2.monospacedDigit())
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.12))
                            .foregroundColor(.accentColor)
                            .cornerRadius(3)
                    }
                    Spacer()
                    Text(ref.lastCommitSubject)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .frame(width: 240, alignment: .trailing)
                    Text(String(ref.objectHash.prefix(7)))
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                        .frame(width: 64, alignment: .trailing)
                }
                .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 12))
                .tag(ref.id)
                .contextMenu {
                    Button(L("Checkout", "签出")) {
                        Task {
                            _ = try? await AppContainer.shared.gitProvider.checkout(repoPath: repoPath, target: ref.shortName)
                            AppContainer.shared.triggerRefresh(repoPath: repoPath)
                            await reload()
                        }
                    }
                    Button(L("Show Log", "显示日志")) {
                        AppContainer.shared.windowCoordinator.dispatch(action: .showLog, repoPath: repoPath, targetDir: repoPath, selectedPaths: [])
                    }
                    Button(L("Repo-browser", "版本库浏览器")) {
                        AppContainer.shared.windowCoordinator.openRepoBrowser(repoPath: repoPath, revision: ref.shortName)
                    }
                    Divider()
                    if ref.kind == .localBranch {
                        Button(L("Rename Branch…", "重命名分支…")) {
                            renameText = ref.shortName
                            renameTarget = ref
                        }
                        if !ref.isCurrent {
                            Button(L("Delete Branch", "删除分支")) {
                                if AlertHelper.confirm(title: L("Delete Branch", "删除分支"), message: ref.shortName) {
                                    Task {
                                        do {
                                            _ = try await AppContainer.shared.gitProvider.deleteBranch(repoPath: repoPath, name: ref.shortName, force: false)
                                            await reload()
                                        } catch {
                                            AlertHelper.showError(error)
                                        }
                                    }
                                }
                            }
                        }
                    } else if ref.kind == .tag {
                        Button(L("Delete Tag", "删除标签")) {
                            Task {
                                _ = try? await AppContainer.shared.gitProvider.deleteTag(repoPath: repoPath, name: ref.shortName)
                                await reload()
                            }
                        }
                    } else if ref.kind == .remoteBranch {
                        Button(L("Delete Remote Branch", "删除远程分支")) {
                            let parts = ref.shortName.split(separator: "/", maxSplits: 1).map(String.init)
                            if parts.count == 2 && AlertHelper.confirm(title: L("Delete Remote Branch", "删除远程分支"), message: ref.shortName) {
                                Task {
                                    let env = AppContainer.shared.authEnv(for: repoPath)
                                    _ = try? await AppContainer.shared.gitProvider.deleteRemoteBranch(repoPath: repoPath, remote: parts[0], branchName: parts[1], extraEnv: env)
                                    await reload()
                                }
                            }
                        }
                    }
                    Button(L("Copy Reference Name", "拷贝引用名称")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(ref.shortName, forType: .string)
                    }
                }
            }
            .listStyle(.inset)
        }
        .sheet(item: $renameTarget) { ref in
            VStack(spacing: 12) {
                Text(L("Rename Branch", "重命名分支") + " (\(ref.shortName))").font(.headline)
                TextField(L("New branch name", "新分支名称"), text: $renameText)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button(L("Cancel", "取消")) { renameTarget = nil }
                    Button(L("Rename", "重命名")) {
                        let next = renameText.trimmingCharacters(in: .whitespaces)
                        Task {
                            _ = try? await AppContainer.shared.gitProvider.renameBranch(repoPath: repoPath, oldName: ref.shortName, newName: next)
                            renameTarget = nil
                            AppContainer.shared.triggerRefresh(repoPath: repoPath)
                            await reload()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(20)
            .frame(width: 340)
        }
        .task { await reload() }
    }

    private func icon(for kind: GitReferenceKind) -> String {
        switch kind {
        case .localBranch: return "arrow.triangle.branch"
        case .remoteBranch: return "cloud"
        case .tag: return "tag"
        }
    }

    private func reload() async {
        references = (try? await AppContainer.shared.gitProvider.listReferences(repoPath: repoPath)) ?? []
    }
}
