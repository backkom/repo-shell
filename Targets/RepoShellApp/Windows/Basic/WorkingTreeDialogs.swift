import SwiftUI
import RepoShellShared
import RepoShellVcs

// MARK: - Resolve Conflicts

struct ResolveWindowView: View {
    let repoPath: String
    @State private var conflicted: [VcsStatusItem] = []
    @State private var selected: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("Conflicted Files", "冲突文件"))
                    .font(.headline)
                Spacer()
                Button(L("Refresh", "刷新")) { Task { await reload() } }
            }
            .padding()

            Divider()

            if conflicted.isEmpty {
                EmptyStateBox(systemImage: "checkmark.circle", title: L("No Conflicts Remaining", "当前无未解决冲突"))
            } else {
                List(conflicted) { item in
                    HStack {
                        Toggle("", isOn: Binding(
                            get: { selected.contains(item.relativePath) },
                            set: { on in
                                if on { selected.insert(item.relativePath) } else { selected.remove(item.relativePath) }
                            }
                        )).labelsHidden()
                        StatusBadgeLabel(status: item.status)
                        Text(item.relativePath)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        launchExternalMerge(for: item)
                    }
                    .contextMenu {
                        Button(L("Resolve using \"ours\"", "使用“ours”解决冲突")) {
                            resolve([item], strategy: .ours)
                        }
                        Button(L("Resolve using \"theirs\"", "使用“theirs”解决冲突")) {
                            resolve([item], strategy: .theirs)
                        }
                        Button(L("Mark as Resolved", "标记为已解决")) {
                            resolve([item], strategy: .markResolved)
                        }
                        Button(L("Open Merge Tool", "使用合并工具打开")) {
                            launchExternalMerge(for: item)
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
                Button(L("Use Ours", "使用 Ours")) {
                    resolve(selectedItems, strategy: .ours)
                }.disabled(selected.isEmpty)
                Button(L("Use Theirs", "使用 Theirs")) {
                    resolve(selectedItems, strategy: .theirs)
                }.disabled(selected.isEmpty)
                Button(L("Mark Resolved", "标记为已解决")) {
                    resolve(selectedItems, strategy: .markResolved)
                }.disabled(selected.isEmpty)
                Spacer()
                Button(L("Close", "关闭")) {
                    AppContainer.shared.windowCoordinator.closeWindow(key: "resolve-\(repoPath)")
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding()
        }
        .task { await reload() }
    }

    private var selectedItems: [VcsStatusItem] {
        conflicted.filter { selected.contains($0.relativePath) }
    }

    private func reload() async {
        if let res = try? await AppContainer.shared.gitProvider.status(repoPath: repoPath) {
            conflicted = res.items.filter { $0.status == .unmerged }
            selected = Set(conflicted.map { $0.relativePath })
        }
    }

    private func resolve(_ targets: [VcsStatusItem], strategy: ConflictResolutionStrategy) {
        Task {
            for item in targets {
                _ = try? await AppContainer.shared.gitProvider.resolveConflict(repoPath: repoPath, path: item.absolutePath, strategy: strategy)
            }
            AppContainer.shared.triggerRefresh(repoPath: repoPath)
            await reload()
        }
    }

    private func launchExternalMerge(for item: VcsStatusItem) {
        Task {
            let tmpDir = FileManager.default.temporaryDirectory
            let baseTmp = tmpDir.appendingPathComponent("base_\(UUID().uuidString.prefix(6))_\(URL(fileURLWithPath: item.relativePath).lastPathComponent)")
            let oursTmp = tmpDir.appendingPathComponent("ours_\(UUID().uuidString.prefix(6))_\(URL(fileURLWithPath: item.relativePath).lastPathComponent)")
            let theirsTmp = tmpDir.appendingPathComponent("theirs_\(UUID().uuidString.prefix(6))_\(URL(fileURLWithPath: item.relativePath).lastPathComponent)")

            _ = try? await AppContainer.shared.gitProvider.extractFile(repoPath: repoPath, path: item.relativePath, revision: ":1", to: baseTmp.path)
            _ = try? await AppContainer.shared.gitProvider.extractFile(repoPath: repoPath, path: item.relativePath, revision: ":2", to: oursTmp.path)
            _ = try? await AppContainer.shared.gitProvider.extractFile(repoPath: repoPath, path: item.relativePath, revision: ":3", to: theirsTmp.path)

            let prefs = AppContainer.shared.repositoryManager.currentConfigSnapshot().preferences
            let launched = (try? AppContainer.shared.diffToolManager.launchMerge(
                basePath: baseTmp.path,
                localPath: oursTmp.path,
                remotePath: theirsTmp.path,
                mergedPath: item.absolutePath,
                preferences: prefs
            )) ?? false

            if !launched {
                AlertHelper.showInfo(L("No Merge Tool Configured", "未配置合并工具"), message: L("Please configure a Merge Tool in General Preferences.", "请在通用设置中配置合并工具。"))
            }
        }
    }
}

// MARK: - Revert Working Files

struct RevertWindowView: View {
    let repoPath: String
    let preselectedPaths: [String]

    @State private var items: [VcsStatusItem] = []
    @State private var selected: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Toggle(L("Select / Deselect All", "全选 / 全不选"), isOn: Binding(
                    get: { !items.isEmpty && selected.count == items.count },
                    set: { all in selected = all ? Set(items.map { $0.relativePath }) : [] }
                ))
                Spacer()
                Button(L("Refresh", "刷新")) { Task { await reload() } }
            }
            .padding()

            Divider()

            if items.isEmpty {
                EmptyStateBox(systemImage: "arrow.uturn.backward", title: L("No Modified Files to Revert", "没有可复原的修改文件"))
            } else {
                List(items) { item in
                    HStack {
                        Toggle("", isOn: Binding(
                            get: { selected.contains(item.relativePath) },
                            set: { on in
                                if on { selected.insert(item.relativePath) } else { selected.remove(item.relativePath) }
                            }
                        )).labelsHidden()
                        StatusBadgeLabel(status: item.status)
                        Text(item.relativePath)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        AppContainer.shared.windowCoordinator.openDiffWithRevision(
                            repoPath: repoPath,
                            filePath: item.absolutePath,
                            revision: "HEAD",
                            rightTitle: L("Working Tree", "工作区")
                        )
                    }
                }
                .listStyle(.inset)
            }

            Divider()
            HStack {
                Text(String(format: L("%d selected of %d files", "已选择 %d / %d 个文件"), selected.count, items.count))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button(L("Cancel", "取消")) {
                    AppContainer.shared.windowCoordinator.closeWindow(key: "revert-\(repoPath)")
                }
                .keyboardShortcut(.escape, modifiers: [])
                Button(L("Revert", "复原")) {
                    let absPaths = items.filter { selected.contains($0.relativePath) }.map { $0.absolutePath }
                    Task {
                        do {
                            _ = try await AppContainer.shared.gitProvider.revert(repoPath: repoPath, paths: absPaths)
                            AppContainer.shared.triggerRefresh(repoPath: repoPath)
                            AppContainer.shared.windowCoordinator.closeWindow(key: "revert-\(repoPath)")
                        } catch {
                            AlertHelper.showError(error)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()
        }
        .task { await reload() }
    }

    private func reload() async {
        if let res = try? await AppContainer.shared.gitProvider.status(repoPath: repoPath, options: VcsStatusOptions(includeIgnored: false, includeUntracked: true)) {
            items = res.items.filter { $0.status != .normal && $0.status != .ignored }
            let preRels = preselectedPaths.compactMap { PathUtils.relativePath(of: $0, inside: repoPath) }
            if !preRels.isEmpty && !preRels.contains("") {
                selected = Set(items.filter { item in
                    preRels.contains(where: { item.relativePath == $0 || item.relativePath.hasPrefix($0 + "/") })
                }.map { $0.relativePath })
            } else {
                selected = Set(items.filter { $0.status != .untracked }.map { $0.relativePath })
            }
        }
    }
}

// MARK: - Stash Save & Stash List

struct StashSaveWindowView: View {
    let repoPath: String
    let preselectedPaths: [String]

    @State private var message: String = ""
    @State private var includeUntracked = false
    @State private var includeAll = false
    @State private var items: [VcsStatusItem] = []
    @State private var selected: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Stash Message:", "储藏信息：")).font(.subheadline.weight(.medium))
                TextField(L("Optional description…", "可选描述…"), text: $message)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 14) {
                    Toggle(L("Include untracked files (-u)", "包含未跟踪文件 (-u)"), isOn: $includeUntracked)
                    Toggle(L("Save entire working tree incl. ignored (-a)", "保存整个工作目录含忽略文件 (-a)"), isOn: $includeAll)
                }
            }
            .padding()

            Divider()

            List(items) { item in
                HStack {
                    Toggle("", isOn: Binding(
                        get: { selected.contains(item.relativePath) },
                        set: { on in if on { selected.insert(item.relativePath) } else { selected.remove(item.relativePath) } }
                    )).labelsHidden()
                    StatusBadgeLabel(status: item.status)
                    Text(item.relativePath)
                }
            }
            .listStyle(.inset)

            Divider()
            HStack {
                Spacer()
                Button(L("Cancel", "取消")) {
                    AppContainer.shared.windowCoordinator.closeWindow(key: "stash-save-\(repoPath)")
                }
                .keyboardShortcut(.escape, modifiers: [])
                Button(L("Stash Push", "储藏推入")) {
                    let paths = selected.count == items.count ? [] : items.filter { selected.contains($0.relativePath) }.map { $0.absolutePath }
                    Task {
                        do {
                            _ = try await AppContainer.shared.gitProvider.stashSave(
                                repoPath: repoPath,
                                message: message,
                                includeUntracked: includeUntracked,
                                includeAll: includeAll,
                                paths: paths
                            )
                            AppContainer.shared.triggerRefresh(repoPath: repoPath)
                            AppContainer.shared.windowCoordinator.closeWindow(key: "stash-save-\(repoPath)")
                        } catch {
                            AlertHelper.showError(error)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()
        }
        .task {
            if let res = try? await AppContainer.shared.gitProvider.status(repoPath: repoPath, options: VcsStatusOptions(includeIgnored: false, includeUntracked: true)) {
                items = res.items
                selected = Set(items.map { $0.relativePath })
            }
        }
    }
}

struct StashListWindowView: View {
    let repoPath: String
    @State private var stashes: [GitStashEntry] = []
    @State private var selectedRef: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("Stash List", "储藏列表")).font(.headline)
                Spacer()
                Button(L("New Stash…", "新建储藏…")) {
                    AppContainer.shared.windowCoordinator.dispatch(action: .stashPush, repoPath: repoPath, targetDir: repoPath, selectedPaths: [])
                }
                Button(L("Clear All", "删除全部")) {
                    if AlertHelper.confirm(title: L("Clear All Stashes", "删除全部储藏"), message: L("Remove all stash entries permanently?", "确定清空所有储藏吗？")) {
                        Task {
                            _ = try? await AppContainer.shared.gitProvider.stashClear(repoPath: repoPath)
                            await reload()
                        }
                    }
                }
                .disabled(stashes.isEmpty)
                Button(L("Refresh", "刷新")) { Task { await reload() } }
            }
            .padding()

            Divider()

            TableColumnHeaderBar(
                columns: [
                    TableColumnSpec(L("Stash", "储藏"), width: 90),
                    TableColumnSpec("SHA", width: 64),
                    TableColumnSpec(L("Branch", "分支"), width: 100),
                    TableColumnSpec(L("Message", "信息")),
                    TableColumnSpec(L("Date", "日期"), width: 136, alignment: .trailing)
                ],
                horizontalPadding: 12,
                spacing: 8
            )

            if stashes.isEmpty {
                EmptyStateBox(systemImage: "tray", title: L("No Stashes", "无储藏"))
            } else {
                List(stashes, selection: $selectedRef) { s in
                    HStack(spacing: 8) {
                        Text(s.refName).font(.caption.monospaced()).frame(width: 90, alignment: .leading)
                        Text(s.shortHash).font(.caption.monospaced()).foregroundColor(.secondary).frame(width: 64, alignment: .leading)
                        Text(s.branchName).font(.caption).foregroundColor(.accentColor).frame(width: 100, alignment: .leading)
                        Text(s.message).font(.system(size: 12.5)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        Text(s.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                            .frame(width: 136, alignment: .trailing)
                    }
                    .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 12))
                    .tag(s.refName)
                    .contextMenu {
                        Button(L("Apply Stash", "应用储藏")) { apply(s.refName, pop: false) }
                        Button(L("Pop Stash", "应用并删除 (Pop)")) { apply(s.refName, pop: true) }
                        Button(L("Branch from Stash…", "从储藏创建分支…")) {
                            Task {
                                _ = try? await AppContainer.shared.gitProvider.stashBranch(repoPath: repoPath, branchName: "stash-branch-\(s.shortHash)", stashRef: s.refName)
                                AppContainer.shared.triggerRefresh(repoPath: repoPath)
                                await reload()
                            }
                        }
                        Divider()
                        Button(L("Drop Stash", "删除储藏")) { drop(s.refName) }
                    }
                }
                .listStyle(.inset)
            }

            Divider()
            HStack {
                if let ref = selectedRef {
                    Button(L("Apply", "应用")) { apply(ref, pop: false) }
                    Button(L("Pop", "弹出 (Pop)")) { apply(ref, pop: true) }
                    Button(L("Drop", "删除")) { drop(ref) }
                }
                Spacer()
                Button(L("Close", "关闭")) {
                    AppContainer.shared.windowCoordinator.closeWindow(key: "stash-list-\(repoPath)")
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding()
        }
        .task { await reload() }
    }

    private func reload() async {
        stashes = (try? await AppContainer.shared.gitProvider.listStashes(repoPath: repoPath)) ?? []
    }

    private func apply(_ ref: String, pop: Bool) {
        Task {
            do {
                _ = try await AppContainer.shared.gitProvider.stashApply(repoPath: repoPath, stashRef: ref, pop: pop)
                AppContainer.shared.triggerRefresh(repoPath: repoPath)
                await reload()
            } catch {
                AlertHelper.showError(error)
            }
        }
    }

    private func drop(_ ref: String) {
        Task {
            _ = try? await AppContainer.shared.gitProvider.stashDrop(repoPath: repoPath, stashRef: ref)
            await reload()
        }
    }
}

// MARK: - Repo Info & Remotes

struct RepoInfoWindowView: View {
    let repoPath: String

    @State private var summary: GitRepoSummary?
    @State private var gitignoreText: String = ""
    @State private var gitConfigText: String = ""
    @State private var selectedTab: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                Text(L("Summary", "概要")).tag(0)
                Text(L("Remotes", "远程版本库")).tag(1)
                Text(".gitignore").tag(2)
                Text(".git/config").tag(3)
            }
            .pickerStyle(.segmented)
            .padding()

            Divider()

            Group {
                switch selectedTab {
                case 0:
                    Form {
                        if let s = summary {
                            LabeledContent(L("Path", "路径"), value: s.repoPath)
                            LabeledContent(L("Current Branch", "当前分支"), value: s.currentBranch)
                            LabeledContent("HEAD", value: s.headHash)
                            LabeledContent(L("Upstream", "上游分支"), value: s.upstreamBranch ?? L("None", "无"))
                            LabeledContent(L("Commits", "提交数"), value: "\(s.totalCommits)")
                            LabeledContent(L("State", "状态"), value: s.repoState.rawValue)
                            LabeledContent(L("Submodules", "子模块"), value: "\(s.submodules.count)")
                        } else {
                            ProgressView()
                        }
                    }
                    .formStyle(.grouped)
                case 1:
                    RemotesWindowView(repoPath: repoPath)
                case 2:
                    VStack(alignment: .trailing) {
                        TextEditor(text: $gitignoreText)
                            .font(.system(.body, design: .monospaced))
                            .border(Color.secondary.opacity(0.25))
                        Button(L("Save .gitignore", "保存 .gitignore")) {
                            let url = URL(fileURLWithPath: repoPath).appendingPathComponent(".gitignore")
                            try? gitignoreText.write(to: url, atomically: true, encoding: .utf8)
                            AppContainer.shared.triggerRefresh(repoPath: repoPath)
                        }
                    }
                    .padding()
                default:
                    VStack(alignment: .trailing) {
                        TextEditor(text: $gitConfigText)
                            .font(.system(.body, design: .monospaced))
                            .border(Color.secondary.opacity(0.25))
                        Button(L("Save .git/config", "保存 .git/config")) {
                            let url = AppContainer.shared.gitProvider.resolveGitDirectory(repoPath: repoPath).appendingPathComponent("config")
                            try? gitConfigText.write(to: url, atomically: true, encoding: .utf8)
                        }
                    }
                    .padding()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            summary = try? await AppContainer.shared.gitProvider.repoSummary(repoPath: repoPath)
            let gi = URL(fileURLWithPath: repoPath).appendingPathComponent(".gitignore")
            gitignoreText = (try? String(contentsOf: gi, encoding: .utf8)) ?? ""
            let gc = AppContainer.shared.gitProvider.resolveGitDirectory(repoPath: repoPath).appendingPathComponent("config")
            gitConfigText = (try? String(contentsOf: gc, encoding: .utf8)) ?? ""
        }
    }
}

struct RemotesWindowView: View {
    let repoPath: String

    @State private var remotes: [GitRemote] = []
    @State private var newName: String = ""
    @State private var newURL: String = ""

    var body: some View {
        VStack(spacing: 10) {
            List(remotes) { r in
                HStack {
                    Text(r.name).fontWeight(.semibold).frame(width: 100, alignment: .leading)
                    Text(r.fetchURL).font(.caption).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button(L("Remove", "移除")) {
                        Task {
                            _ = try? await AppContainer.shared.gitProvider.removeRemote(repoPath: repoPath, name: r.name)
                            await reload()
                        }
                    }
                }
            }
            .listStyle(.inset)

            HStack {
                TextField(L("Name (e.g. origin)", "名称"), text: $newName)
                    .frame(width: 130)
                TextField(L("Remote URL", "远程 URL"), text: $newURL)
                Button(L("Add / Update", "添加 / 更新")) {
                    let n = newName.trimmingCharacters(in: .whitespaces)
                    let u = newURL.trimmingCharacters(in: .whitespaces)
                    guard !n.isEmpty, !u.isEmpty else { return }
                    Task {
                        if remotes.contains(where: { $0.name == n }) {
                            _ = try? await AppContainer.shared.gitProvider.setRemoteURL(repoPath: repoPath, name: n, url: u)
                        } else {
                            _ = try? await AppContainer.shared.gitProvider.addRemote(repoPath: repoPath, name: n, url: u)
                        }
                        newName = ""
                        newURL = ""
                        await reload()
                    }
                }
            }
            .padding([.horizontal, .bottom])
        }
        .task { await reload() }
    }

    private func reload() async {
        remotes = (try? await AppContainer.shared.gitProvider.listRemotes(repoPath: repoPath)) ?? []
    }
}

// MARK: - Export, Ignore, Rename, TaskProgress

struct ExportWindowView: View {
    let repoPath: String

    @State private var revision: String = "HEAD"
    @State private var asZip: Bool = true
    @State private var destPath: String = ""

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(header: Text(L("Revision:", "版本："))) {
                    RefSelectionPicker(repoPath: repoPath, selectedRef: $revision, allowHEAD: true)
                }
                Toggle(L("Export as Zip archive", "导出为 Zip 文件"), isOn: $asZip)
                HStack {
                    TextField(L("Destination:", "目标路径："), text: $destPath)
                    Button(L("Browse…", "浏览…")) {
                        if asZip {
                            let panel = NSSavePanel()
                            panel.nameFieldStringValue = "\(URL(fileURLWithPath: repoPath).lastPathComponent).zip"
                            if panel.runModal() == .OK, let url = panel.url {
                                destPath = url.path
                            }
                        } else if let url = AlertHelper.pickFolder(title: L("Choose Export Folder", "选择导出目录")) {
                            destPath = url.path
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button(L("Cancel", "取消")) {
                    AppContainer.shared.windowCoordinator.closeWindow(key: "export-\(repoPath)")
                }
                .keyboardShortcut(.escape, modifiers: [])
                Button(L("Export", "导出")) {
                    let rev = revision.isEmpty ? "HEAD" : revision
                    let dest = destPath
                    let zip = asZip
                    AppContainer.shared.windowCoordinator.closeWindow(key: "export-\(repoPath)")
                    AppContainer.shared.windowCoordinator.runTaskWithProgress(title: L("Export", "导出"), repoPath: repoPath) { _ in
                        try await AppContainer.shared.gitProvider.export(repoPath: repoPath, revision: rev, destinationPath: dest, asZip: zip)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(destPath.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()
        }
    }
}

struct IgnoreWindowView: View {
    let repoPath: String
    let targetPaths: [String]

    enum IgnorePatternMode: Int {
        case byName
        case byExtension
    }

    @State private var mode: IgnorePatternMode = .byName

    private var patterns: [String] {
        var result: [String] = []
        for path in targetPaths {
            let url = URL(fileURLWithPath: path)
            if mode == .byExtension && !url.pathExtension.isEmpty {
                result.append("*.\(url.pathExtension)")
            } else if let rel = PathUtils.relativePath(of: path, inside: repoPath), !rel.isEmpty {
                result.append(rel)
            } else {
                result.append(url.lastPathComponent)
            }
        }
        return Array(Set(result)).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(L("Ignore By:", "忽略方式："), selection: $mode) {
                Text(L("By File Name / Path", "通过文件名 / 路径")).tag(IgnorePatternMode.byName)
                Text(L("By Extension (*.ext)", "通过后缀名 (*.ext)")).tag(IgnorePatternMode.byExtension)
            }
            .pickerStyle(.radioGroup)

            Text(L("Patterns to append to .gitignore:", "将添加到 .gitignore 的规则："))
                .font(.caption)
                .foregroundColor(.secondary)
            Text(patterns.joined(separator: "\n"))
                .font(.system(.caption, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08))
                .cornerRadius(6)

            Spacer()
            HStack {
                Spacer()
                Button(L("Cancel", "取消")) {
                    AppContainer.shared.windowCoordinator.closeWindow(key: "ignore-\(repoPath)")
                }
                Button(L("OK", "确定")) {
                    try? AppContainer.shared.gitProvider.appendToGitIgnore(repoPath: repoPath, patterns: patterns)
                    AppContainer.shared.triggerRefresh(repoPath: repoPath)
                    AppContainer.shared.windowCoordinator.closeWindow(key: "ignore-\(repoPath)")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }
}

struct RenameWindowView: View {
    let repoPath: String
    let sourcePath: String

    @State private var newName: String

    init(repoPath: String, sourcePath: String) {
        self.repoPath = repoPath
        self.sourcePath = sourcePath
        _newName = State(initialValue: URL(fileURLWithPath: sourcePath).lastPathComponent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Rename:", "重命名：") + " \(URL(fileURLWithPath: sourcePath).lastPathComponent)")
                .font(.headline)
            TextField(L("New name:", "新名称："), text: $newName)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button(L("Cancel", "取消")) {
                    AppContainer.shared.windowCoordinator.closeWindow(key: "rename-\(sourcePath)")
                }
                Button(L("Rename", "重命名")) {
                    let parent = URL(fileURLWithPath: sourcePath).deletingLastPathComponent()
                    let dest = parent.appendingPathComponent(newName).path
                    Task {
                        do {
                            _ = try await AppContainer.shared.gitProvider.rename(repoPath: repoPath, from: sourcePath, to: dest)
                            AppContainer.shared.triggerRefresh(repoPath: repoPath)
                            AppContainer.shared.windowCoordinator.closeWindow(key: "rename-\(sourcePath)")
                        } catch {
                            AlertHelper.showError(error)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
    }
}

@MainActor
final class TaskProgressModel: ObservableObject {
    let title: String
    let repoPath: String?
    let operation: @Sendable (@escaping @Sendable (String) -> Void) async throws -> VcsCommandResult

    @Published var isRunning = false
    @Published var succeeded: Bool?
    @Published var outputLines: [String] = []
    @Published var autoClose = false
    private var task: Task<Void, Never>?

    init(
        title: String,
        repoPath: String?,
        operation: @escaping @Sendable (@escaping @Sendable (String) -> Void) async throws -> VcsCommandResult
    ) {
        self.title = title
        self.repoPath = repoPath
        self.operation = operation
    }

    func start() {
        isRunning = true
        succeeded = nil
        outputLines = []
        task = Task {
            let tracker = StreamTracker()
            do {
                let res = try await operation { line in
                    tracker.markStreamed()
                    Task { @MainActor in
                        self.outputLines.append(line)
                    }
                }
                if !tracker.didStream {
                    if !res.stdout.isEmpty { outputLines.append(res.stdout) }
                    if !res.stderr.isEmpty { outputLines.append(res.stderr) }
                }
                outputLines.append(L("Completed successfully.", "操作已完成。"))
                succeeded = true
                isRunning = false
                if let repo = repoPath {
                    AppContainer.shared.triggerRefresh(repoPath: repo)
                }
            } catch let err as VcsError {
                if case .commandFailed(let cmd, let code, let stderr, _) = err {
                    if !tracker.didStream && !stderr.isEmpty {
                        outputLines.append(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                    outputLines.append("Command failed (\(code)): \(cmd)")
                } else {
                    outputLines.append(err.localizedDescription)
                }
                succeeded = false
                isRunning = false
            } catch {
                outputLines.append(error.localizedDescription)
                succeeded = false
                isRunning = false
            }
        }
    }

    var isLocalNetworkError: Bool {
        let joined = outputLines.joined(separator: "\n")
        return joined.contains("Couldn't connect to server")
            || joined.contains("No route to host")
            || joined.contains("Failed to connect to")
            || SvnErrorClassifier.isTransientLocalNetworkError(joined)
    }

    func cancel() {
        task?.cancel()
        isRunning = false
    }
}

private final class StreamTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var streamed = false
    func markStreamed() { lock.withLock { streamed = true } }
    var didStream: Bool { lock.withLock { streamed } }
}

struct TaskProgressWindowView: View {
    @ObservedObject var model: TaskProgressModel
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if model.isRunning {
                    ProgressView().controlSize(.small)
                    Text(L("Operation in progress…", "操作进行中…"))
                } else if model.succeeded == true {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    Text(L("Succeeded", "成功"))
                } else if model.succeeded == false {
                    Image(systemName: "xmark.octagon.fill").foregroundColor(.red)
                    Text(L("Failed", "失败"))
                }
                Spacer()
            }
            .font(.headline)

            ScrollView {
                Text(model.outputLines.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .background(Color.black.opacity(0.06))
            .cornerRadius(6)

            if model.succeeded == false && model.isLocalNetworkError {
                HStack(spacing: 8) {
                    Image(systemName: "network.slash")
                        .foregroundColor(.orange)
                    Text(L(
                        "If connecting to a LAN server, allow RepoShell in System Settings → Privacy & Security → Local Network. If already enabled after an update, toggle it off/on or click Retry.",
                        "如果目标为局域网服务器，请在「系统设置 → 隐私与安全性 → 本地网络」中允许 RepoShell 访问；若更新后已开启仍提示失败，请先关闭再重新开启或点击重试。"
                    ))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    Spacer()
                    Button(L("Local Network Settings", "打开本地网络设置")) {
                        LocalNetworkAuthorizationHelper.requestPermissionIfNeeded()
                        LocalNetworkAuthorizationHelper.openSettings()
                    }
                    .font(.caption)
                }
                .padding(8)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(6)
            }

            HStack {
                Toggle(L("Close automatically when done", "自动关闭此窗口"), isOn: $model.autoClose)
                Spacer()
                if model.isRunning {
                    Button(L("Cancel", "取消")) { model.cancel() }
                } else {
                    if model.succeeded == false {
                        Button(L("Retry", "重试")) { model.start() }
                    }
                    Button(L("OK", "确定")) { onClose() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding()
        .onChange(of: model.succeeded) { ok in
            if ok == true && model.autoClose {
                onClose()
            }
        }
    }
}
