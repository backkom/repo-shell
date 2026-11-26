import Cocoa
import SwiftUI
import RepoShellShared
import RepoShellVcs
import RepoShellServices

// MARK: - SVN Checkout

struct SvnCheckoutWindowView: View {
    let initialParentDir: String
    var initialURL: String = ""

    @State private var url: String
    @State private var parentDir: String
    @State private var folderName: String = ""
    @State private var useHead: Bool = true
    @State private var revision: String = ""
    @State private var depth: SvnDepth = .infinity
    @State private var ignoreExternals: Bool = false
    @State private var force: Bool = false
    @State private var recentURLs: [String] = []

    init(initialParentDir: String, initialURL: String = "") {
        self.initialParentDir = initialParentDir
        self.initialURL = initialURL
        _url = State(initialValue: initialURL)
        _parentDir = State(initialValue: initialParentDir)
        _folderName = State(initialValue: Self.deriveFolderName(from: initialURL))
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(header: Text(L("Repository URL", "SVN 版本库地址"))) {
                    HStack {
                        TextField("https://svn.example.com/svn/project/trunk", text: $url)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: url) { newVal in
                                folderName = Self.deriveFolderName(from: newVal)
                            }
                        if !recentURLs.isEmpty {
                            Picker("", selection: $url) {
                                Text(L("History…", "历史…")).tag("")
                                ForEach(recentURLs, id: \.self) { u in
                                    Text(u).tag(u)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 110)
                        }
                    }
                }

                Section(header: Text(L("Destination", "签出位置"))) {
                    HStack {
                        TextField(L("Parent Directory", "父目录"), text: $parentDir)
                            .textFieldStyle(.roundedBorder)
                        Button(L("Browse…", "浏览…")) {
                            if let picked = AlertHelper.pickFolder(title: L("Select Destination Folder", "选择签出目录")) {
                                parentDir = picked.path
                            }
                        }
                    }
                    TextField(L("Working Copy Folder Name:", "工作副本目录名："), text: $folderName)
                        .textFieldStyle(.roundedBorder)
                }

                Section(header: Text(L("Options", "选项"))) {
                    HStack {
                        Toggle(L("HEAD Revision", "最新修订 (HEAD)"), isOn: $useHead)
                        if !useHead {
                            TextField(L("Revision", "版本号"), text: $revision)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 120)
                        }
                    }

                    Picker(L("Checkout Depth:", "签出深度："), selection: $depth) {
                        ForEach(SvnDepth.allCases, id: \.self) { d in
                            Text(d.displayTitle).tag(d)
                        }
                    }

                    Toggle(L("Omit externals (--ignore-externals)", "忽略外部定义 (--ignore-externals)"), isOn: $ignoreExternals)
                    Toggle(L("Force into existing directory (--force)", "允许覆盖已有目录 (--force)"), isOn: $force)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button(L("Cancel", "取消")) {
                    AppContainer.shared.windowCoordinator.closeWindow(key: "svn-checkout-\(initialParentDir)")
                }
                .keyboardShortcut(.escape, modifiers: [])

                Button(L("Checkout", "签出")) {
                    startCheckout()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || parentDir.isEmpty)
            }
            .padding()
        }
        .onAppear {
            recentURLs = AppContainer.shared.recentHistoryStore.load().svnRepoURLs
        }
    }

    private static func deriveFolderName(from urlStr: String) -> String {
        let trimmed = urlStr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let u = URL(string: trimmed) else { return "" }
        let last = u.lastPathComponent
        return last == "/" ? "" : last
    }

    private func startCheckout() {
        let cleanURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let leaf = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let dest = leaf.isEmpty ? parentDir : PathUtils.normalize("\(parentDir)/\(leaf)")
        let opts = SvnCheckoutOptions(
            url: cleanURL,
            destinationPath: dest,
            revision: useHead ? nil : revision,
            depth: depth,
            ignoreExternals: ignoreExternals,
            force: force
        )

        AppContainer.shared.recentHistoryStore.recordSvnRepoURL(cleanURL)
        AppContainer.shared.windowCoordinator.closeWindow(key: "svn-checkout-\(initialParentDir)")

        AppContainer.shared.windowCoordinator.runTaskWithProgress(
            title: L("SVN Checkout", "SVN 签出"),
            repoPath: nil
        ) { onLine in
            let res = try await AppContainer.shared.runSvnInteractive(repoPath: nil, targetURL: cleanURL) { env, auth in
                try await AppContainer.shared.svnProvider.checkout(
                    options: opts,
                    environment: env,
                    auth: auth,
                    onOutputLine: { line, _ in onLine(line) }
                )
            }
            if let entry = try? await AppContainer.shared.repositoryManager.addRepository(at: dest, vcsType: .svn) {
                await AppContainer.shared.triggerRefresh(repoPath: entry.path)
            }
            return res
        }
    }
}

// MARK: - Create SVN Repository

struct SvnCreateRepoWindowView: View {
    let initialPath: String

    @State private var folderPath: String
    @State private var fsType: String = "fsfs"
    @State private var createStandardLayout: Bool = false

    init(initialPath: String) {
        self.initialPath = initialPath
        _folderPath = State(initialValue: initialPath)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                HStack {
                    TextField(L("Repository Path:", "版本库路径："), text: $folderPath)
                        .textFieldStyle(.roundedBorder)
                    Button(L("Browse…", "浏览…")) {
                        if let url = AlertHelper.pickFolder(title: L("Select Folder for New SVN Repository", "选择新建 SVN 版本库目录")) {
                            folderPath = url.path
                        }
                    }
                }

                Picker(L("Filesystem Type:", "存储后端类型："), selection: $fsType) {
                    Text("FSFS (Recommended)").tag("fsfs")
                    Text("Berkeley DB (bdb)").tag("bdb")
                }

                Toggle(L("Create standard trunk / branches / tags directories", "自动创建 trunk / branches / tags 标准目录结构"), isOn: $createStandardLayout)
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button(L("Cancel", "取消")) {
                    AppContainer.shared.windowCoordinator.closeWindow(key: "svn-create-\(initialPath)")
                }
                .keyboardShortcut(.escape, modifiers: [])

                Button(L("Create", "创建")) {
                    let target = folderPath
                    let layout = createStandardLayout
                    let fs = fsType
                    AppContainer.shared.windowCoordinator.closeWindow(key: "svn-create-\(initialPath)")
                    Task {
                        do {
                            _ = try await AppContainer.shared.svnProvider.createRepository(at: target, fsType: fs)
                            let rawURL = URL(fileURLWithPath: PathUtils.normalize(target)).absoluteString
                            let repoURL = rawURL.hasSuffix("/") ? String(rawURL.dropLast()) : rawURL
                            if layout {
                                for sub in ["trunk", "branches", "tags"] {
                                    _ = try await AppContainer.shared.svnProvider.remoteMakeDirectory(
                                        url: "\(repoURL)/\(sub)",
                                        message: "Create initial \(sub) directory"
                                    )
                                }
                            }
                            AlertHelper.showInfo(
                                L("SVN Repository Created", "SVN 版本库创建成功"),
                                message: L("Local repository URL: ", "本地版本库 URL：") + repoURL
                            )
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
    }
}

// MARK: - Update to Revision

struct SvnUpdateToRevisionWindowView: View {
    let repoPath: String
    let selectedPaths: [String]

    @State private var useHead: Bool = true
    @State private var revision: String = ""
    @State private var useCustomDepth: Bool = false
    @State private var depth: SvnDepth = .infinity
    @State private var stickyDepth: Bool = false
    @State private var ignoreExternals: Bool = false
    @State private var force: Bool = false
    @State private var accept: SvnConflictAccept = .postpone

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(header: Text(L("Target Revision", "目标版本"))) {
                    Toggle(L("Update to HEAD (Latest)", "更新到最新版本 (HEAD)"), isOn: $useHead)
                    if !useHead {
                        TextField(L("Revision number:", "指定版本号："), text: $revision)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                Section(header: Text(L("Update Depth & Options", "更新深度与选项"))) {
                    Toggle(L("Override Update Depth", "自定义更新深度"), isOn: $useCustomDepth)
                    if useCustomDepth {
                        Picker(L("Depth:", "深度："), selection: $depth) {
                            ForEach(SvnDepth.allCases, id: \.self) { d in
                                Text(d.displayTitle).tag(d)
                            }
                        }
                        Toggle(L("Make depth sticky (--set-depth)", "持久保存此深度 (--set-depth)"), isOn: $stickyDepth)
                    }
                    Toggle(L("Ignore externals", "忽略外部定义"), isOn: $ignoreExternals)
                    Toggle(L("Force overwrite unversioned obstructions", "强制覆盖同名未跟踪文件 (--force)"), isOn: $force)
                    Picker(L("On Conflict:", "遇到冲突时："), selection: $accept) {
                        ForEach(SvnConflictAccept.allCases, id: \.self) { c in
                            Text(c.displayTitle).tag(c)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button(L("Cancel", "取消")) {
                    AppContainer.shared.windowCoordinator.closeWindow(key: "svn-uprev-\(repoPath)")
                }
                .keyboardShortcut(.escape, modifiers: [])
                Button(L("Update", "更新")) {
                    let opts = SvnUpdateOptions(
                        paths: selectedPaths,
                        revision: useHead ? nil : revision,
                        depth: useCustomDepth ? depth : nil,
                        setDepthSticky: stickyDepth,
                        ignoreExternals: ignoreExternals,
                        force: force,
                        accept: accept
                    )
                    AppContainer.shared.windowCoordinator.closeWindow(key: "svn-uprev-\(repoPath)")
                    AppContainer.shared.windowCoordinator.runTaskWithProgress(
                        title: L("SVN Update", "SVN 更新"),
                        repoPath: repoPath
                    ) { onLine in
                        try await AppContainer.shared.runSvnInteractive(repoPath: repoPath) { env, auth in
                            try await AppContainer.shared.svnProvider.update(
                                repoPath: repoPath,
                                options: opts,
                                environment: env,
                                auth: auth,
                                onOutputLine: { line, _ in onLine(line) }
                            )
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()
        }
    }
}

// MARK: - SVN Export

struct SvnExportWindowView: View {
    let sourcePathOrURL: String
    let repoPath: String?
    var initialRevision: String = "WORKING"

    @State private var revision: String
    @State private var destinationPath: String = ""
    @State private var asZip: Bool = false
    @State private var depth: SvnDepth = .infinity
    @State private var ignoreExternals: Bool = false

    init(sourcePathOrURL: String, repoPath: String?, initialRevision: String = "WORKING") {
        self.sourcePathOrURL = sourcePathOrURL
        self.repoPath = repoPath
        self.initialRevision = initialRevision
        _revision = State(initialValue: initialRevision)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Text(sourcePathOrURL)
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                TextField(L("Revision (WORKING, HEAD, or rev):", "版本（WORKING、HEAD 或版本号）："), text: $revision)
                    .textFieldStyle(.roundedBorder)
                Picker(L("Depth:", "深度："), selection: $depth) {
                    ForEach(SvnDepth.allCases, id: \.self) { d in
                        Text(d.displayTitle).tag(d)
                    }
                }
                Toggle(L("Omit externals (--ignore-externals)", "忽略外部定义"), isOn: $ignoreExternals)
                Toggle(L("Export as .zip Archive", "导出为 .zip 压缩包"), isOn: $asZip)
                HStack {
                    TextField(L("Destination:", "导出目标路径："), text: $destinationPath)
                        .textFieldStyle(.roundedBorder)
                    Button(L("Browse…", "浏览…")) {
                        if asZip {
                            if let url = AlertHelper.saveFile(title: L("Save Export Archive", "保存导出压缩包"), defaultName: "export.zip") {
                                destinationPath = url.path
                            }
                        } else if let url = AlertHelper.pickFolder(title: L("Select Export Destination Folder", "选择导出目标目录")) {
                            let leaf = URL(fileURLWithPath: sourcePathOrURL).lastPathComponent
                            destinationPath = url.appendingPathComponent(leaf.isEmpty ? "export" : leaf).path
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button(L("Cancel", "取消")) {
                    AppContainer.shared.windowCoordinator.closeWindow(key: "svn-export-\(sourcePathOrURL)")
                }
                .keyboardShortcut(.escape, modifiers: [])
                Button(L("Export", "导出")) {
                    let rev = revision
                    let dest = destinationPath
                    let zip = asZip
                    let d = depth
                    let ignExt = ignoreExternals
                    AppContainer.shared.windowCoordinator.closeWindow(key: "svn-export-\(sourcePathOrURL)")
                    AppContainer.shared.windowCoordinator.runTaskWithProgress(
                        title: L("SVN Export", "SVN 导出"),
                        repoPath: repoPath
                    ) { onLine in
                        if zip, let repoPath {
                            return try await AppContainer.shared.svnProvider.export(
                                repoPath: repoPath,
                                revision: rev,
                                destinationPath: dest,
                                asZip: true
                            )
                        }
                        return try await AppContainer.shared.runSvnInteractive(repoPath: repoPath) { env, auth in
                            try await AppContainer.shared.svnProvider.svnExport(
                                source: sourcePathOrURL,
                                destinationPath: dest,
                                revision: rev,
                                depth: d,
                                ignoreExternals: ignExt,
                                force: true,
                                workingDirectory: repoPath,
                                environment: env,
                                auth: auth,
                                onOutputLine: { line, _ in onLine(line) }
                            )
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(destinationPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()
        }
    }
}

// MARK: - SVN Clean up

struct SvnCleanupWindowView: View {
    let repoPath: String
    let targetPaths: [String]

    @State private var removeUnversioned = false
    @State private var removeIgnored = false
    @State private var vacuumPristines = false
    @State private var includeExternals = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(header: Text(L("Cleanup Actions", "清理选项"))) {
                    Text(L("Clean up working copy status and release stale write locks.", "清理工作副本状态并解除残留的写锁。"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Toggle(L("Delete unversioned files and folders (--remove-unversioned)", "删除未受版本控制的文件和目录"), isOn: $removeUnversioned)
                    Toggle(L("Delete ignored files and folders (--remove-ignored)", "删除已忽略的文件和目录"), isOn: $removeIgnored)
                    Toggle(L("Vacuum unused pristines (--vacuum-pristines)", "清理不再引用的原始副本缓存 (--vacuum-pristines)"), isOn: $vacuumPristines)
                    Toggle(L("Include externals (--include-externals)", "同时清理外部定义目录 (--include-externals)"), isOn: $includeExternals)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button(L("Cancel", "取消")) {
                    AppContainer.shared.windowCoordinator.closeWindow(key: "svn-cleanup-\(repoPath)")
                }
                .keyboardShortcut(.escape, modifiers: [])
                Button(L("Clean up", "执行清理")) {
                    let opts = SvnCleanupOptions(
                        paths: targetPaths,
                        removeUnversioned: removeUnversioned,
                        removeIgnored: removeIgnored,
                        vacuumPristines: vacuumPristines,
                        includeExternals: includeExternals
                    )
                    AppContainer.shared.windowCoordinator.closeWindow(key: "svn-cleanup-\(repoPath)")
                    AppContainer.shared.windowCoordinator.runTaskWithProgress(
                        title: L("SVN Clean up", "SVN 清理"),
                        repoPath: repoPath
                    ) { onLine in
                        try await AppContainer.shared.svnProvider.cleanup(
                            repoPath: repoPath,
                            options: opts,
                            onOutputLine: { line, _ in onLine(line) }
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()
        }
    }
}

// MARK: - SVN Resolve Conflicts

struct SvnResolveConflictsWindowView: View {
    let repoPath: String
    let preselectedPaths: [String]

    @State private var conflicts: [VcsStatusItem] = []
    @State private var selectedPath: String?
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("Conflicted Files", "冲突文件列表"))
                    .font(.headline)
                Spacer()
                Button(L("Refresh", "刷新")) { refresh() }
            }
            .padding(10)

            Divider()

            if isLoading && conflicts.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if conflicts.isEmpty {
                EmptyStateBox(
                    systemImage: "checkmark.seal",
                    title: L("No Conflicts", "无冲突文件"),
                    subtitle: L("All working copy conflicts have been resolved.", "当前没有未解决的 SVN 冲突。")
                )
            } else {
                List(conflicts, selection: $selectedPath) { item in
                    HStack {
                        StatusBadgeLabel(status: item.status)
                        Text(item.relativePath)
                            .font(.system(.body, design: .monospaced))
                        Spacer()
                    }
                    .tag(item.absolutePath)
                }
            }

            Divider()

            HStack(spacing: 8) {
                Button(L("Open Merge Tool…", "打开合并工具…")) {
                    openMergeTool()
                }
                .disabled(selectedPath == nil)

                Spacer()

                Menu(L("Resolve Using…", "按策略解决冲突…")) {
                    Button(SvnConflictAccept.mineFull.displayTitle) { resolveSelected(.mineFull) }
                    Button(SvnConflictAccept.theirsFull.displayTitle) { resolveSelected(.theirsFull) }
                    Button(SvnConflictAccept.mineConflict.displayTitle) { resolveSelected(.mineConflict) }
                    Button(SvnConflictAccept.theirsConflict.displayTitle) { resolveSelected(.theirsConflict) }
                    Button(SvnConflictAccept.base.displayTitle) { resolveSelected(.base) }
                    Divider()
                    Button(SvnConflictAccept.working.displayTitle) { resolveSelected(.working) }
                }
                .disabled(selectedPath == nil && conflicts.isEmpty)

                Button(L("Mark Resolved", "标记为已解决")) {
                    resolveSelected(.working)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedPath == nil && conflicts.isEmpty)
            }
            .padding(10)
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        isLoading = true
        Task {
            defer { isLoading = false }
            if let res = try? await AppContainer.shared.svnProvider.status(
                repoPath: repoPath,
                options: VcsStatusOptions(includeIgnored: false, includeUntracked: false)
            ) {
                let unmerged = res.items.filter { $0.status == .unmerged }
                self.conflicts = unmerged
                if selectedPath == nil {
                    selectedPath = unmerged.first?.absolutePath
                }
            }
        }
    }

    private func resolveSelected(_ accept: SvnConflictAccept) {
        let targets = selectedPath.map { [$0] } ?? conflicts.map(\.absolutePath)
        guard !targets.isEmpty else { return }
        Task {
            do {
                _ = try await AppContainer.shared.svnProvider.resolveConflict(repoPath: repoPath, paths: targets, accept: accept)
                AppContainer.shared.triggerRefresh(repoPath: repoPath)
                refresh()
            } catch {
                AlertHelper.showError(error)
            }
        }
    }

    private func openMergeTool() {
        guard let target = selectedPath else { return }
        Task {
            let dir = URL(fileURLWithPath: target).deletingLastPathComponent()
            let baseName = URL(fileURLWithPath: target).lastPathComponent
            let fm = FileManager.default
            let siblings = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []

            let mineFile = siblings.first(where: { $0 == "\(baseName).working" || $0 == "\(baseName).mine" })
                .map { dir.appendingPathComponent($0).path } ?? target

            let remoteCandidates = siblings.filter {
                $0.hasPrefix("\(baseName).merge-right.") || $0.hasPrefix("\(baseName).r")
            }.sorted()
            let remoteFile = remoteCandidates.last.map { dir.appendingPathComponent($0).path } ?? target

            let baseCandidates = siblings.filter {
                $0.hasPrefix("\(baseName).merge-left.") || $0.hasPrefix("\(baseName).r")
            }.sorted()
            var baseFile = baseCandidates.first.map { dir.appendingPathComponent($0).path }

            if baseFile == nil {
                let tempBase = fm.temporaryDirectory.appendingPathComponent("svn-base-\(UUID().uuidString.prefix(6))-\(baseName)")
                try? await AppContainer.shared.svnProvider.extractFile(repoPath: repoPath, path: target, revision: "BASE", to: tempBase.path)
                baseFile = tempBase.path
            }

            let prefs = AppContainer.shared.repositoryManager.currentConfigSnapshot().preferences
            do {
                let launched = try AppContainer.shared.diffToolManager.launchMerge(
                    basePath: baseFile ?? target,
                    localPath: mineFile,
                    remotePath: remoteFile,
                    mergedPath: target,
                    preferences: prefs
                )
                if !launched {
                    AlertHelper.showInfo(
                        L("No Merge Tool Configured", "未配置合并工具"),
                        message: L("Please choose a Merge Tool in RepoShell General Preferences.", "请在 RepoShell 通用偏好设置中选择外部合并工具。")
                    )
                }
            } catch {
                AlertHelper.showError(error)
            }
        }
    }
}

// MARK: - SVN Revert

struct SvnRevertWindowView: View {
    let repoPath: String
    let preselectedPaths: [String]

    @State private var items: [SvnDetailedStatusItem] = []
    @State private var selectedRelPaths: Set<String> = []
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Toggle(L("Select / Deselect All", "全选 / 取消全选"), isOn: Binding(
                    get: { !items.isEmpty && selectedRelPaths.count == items.count },
                    set: { on in selectedRelPaths = on ? Set(items.map(\.item.relativePath)) : [] }
                ))
                Spacer()
                Button(L("Refresh", "刷新")) { refresh() }
            }
            .padding(10)

            Divider()

            if isLoading && items.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                EmptyStateBox(
                    systemImage: "arrow.uturn.backward.circle",
                    title: L("Nothing to Revert", "没有可复原的修改"),
                    subtitle: nil
                )
            } else {
                List(items) { entry in
                    HStack {
                        Toggle("", isOn: Binding(
                            get: { selectedRelPaths.contains(entry.item.relativePath) },
                            set: { on in
                                if on { selectedRelPaths.insert(entry.item.relativePath) }
                                else { selectedRelPaths.remove(entry.item.relativePath) }
                            }
                        ))
                        .labelsHidden()
                        StatusBadgeLabel(status: entry.item.status)
                        Text(entry.item.relativePath)
                            .font(.system(.body, design: .monospaced))
                        Spacer()
                    }
                }
            }

            Divider()
            HStack {
                Spacer()
                Button(L("Cancel", "取消")) {
                    AppContainer.shared.windowCoordinator.closeWindow(key: "svn-revert-\(repoPath)")
                }
                .keyboardShortcut(.escape, modifiers: [])
                Button(L("Revert", "复原")) {
                    let chosen = Array(selectedRelPaths)
                    guard !chosen.isEmpty else { return }
                    guard AlertHelper.confirm(
                        title: L("Confirm SVN Revert", "确认 SVN 复原"),
                        message: L("Discard local changes to selected items?", "确定放弃所选项目的本地更改吗？此操作无法撤销。")
                    ) else { return }
                    AppContainer.shared.windowCoordinator.closeWindow(key: "svn-revert-\(repoPath)")
                    AppContainer.shared.windowCoordinator.runTaskWithProgress(
                        title: L("SVN Revert", "SVN 复原"),
                        repoPath: repoPath
                    ) { onLine in
                        try await AppContainer.shared.svnProvider.revert(
                            repoPath: repoPath,
                            paths: chosen,
                            onOutputLine: { line, _ in onLine(line) }
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedRelPaths.isEmpty)
            }
            .padding(10)
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        isLoading = true
        Task {
            defer { isLoading = false }
            if let detailed = try? await AppContainer.shared.svnProvider.detailedStatus(
                repoPath: repoPath,
                paths: preselectedPaths,
                checkRemote: false,
                includeIgnored: false,
                includeUntracked: false
            ) {
                let revertible = detailed.items.filter {
                    let st = $0.item.status
                    return st != .normal && st != .untracked && st != .ignored && st != .external
                }
                self.items = revertible
                self.selectedRelPaths = Set(revertible.map(\.item.relativePath))
            }
        }
    }
}

// MARK: - SVN Move / Rename

struct SvnMoveRenameWindowView: View {
    let repoPath: String
    let sourcePath: String
    let isMove: Bool

    @State private var destination: String
    @State private var force: Bool = false

    init(repoPath: String, sourcePath: String, isMove: Bool) {
        self.repoPath = repoPath
        self.sourcePath = sourcePath
        self.isMove = isMove
        let rel = PathUtils.relativePath(of: sourcePath, inside: repoPath) ?? sourcePath
        _destination = State(initialValue: rel)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Text(L("Source:", "源路径：") + " \(PathUtils.relativePath(of: sourcePath, inside: repoPath) ?? sourcePath)")
                    .font(.caption.monospaced())
                HStack {
                    TextField(
                        isMove ? L("Destination path:", "目标路径：") : L("New name / path:", "新名称 / 路径："),
                        text: $destination
                    )
                    .textFieldStyle(.roundedBorder)
                    if isMove {
                        Button(L("Browse…", "浏览…")) {
                            if let folder = AlertHelper.pickFolder(title: L("Select Destination Folder", "选择目标文件夹")) {
                                let name = URL(fileURLWithPath: sourcePath).lastPathComponent
                                let targetAbs = folder.appendingPathComponent(name).path
                                destination = PathUtils.relativePath(of: targetAbs, inside: repoPath) ?? targetAbs
                            }
                        }
                    }
                }
                Toggle(L("Force (--force)", "强制移动 (--force)"), isOn: $force)
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button(L("Cancel", "取消")) {
                    AppContainer.shared.windowCoordinator.closeWindow(key: "svn-move-\(sourcePath)")
                }
                .keyboardShortcut(.escape, modifiers: [])
                Button(isMove ? L("Move", "移动") : L("Rename", "重命名")) {
                    let dest = destination.trimmingCharacters(in: .whitespacesAndNewlines)
                    let f = force
                    AppContainer.shared.windowCoordinator.closeWindow(key: "svn-move-\(sourcePath)")
                    AppContainer.shared.windowCoordinator.runTaskWithProgress(
                        title: isMove ? L("SVN Move", "SVN 移动") : L("SVN Rename", "SVN 重命名"),
                        repoPath: repoPath
                    ) { onLine in
                        try await AppContainer.shared.svnProvider.move(
                            repoPath: repoPath,
                            sourcePath: sourcePath,
                            destinationPath: dest,
                            force: f,
                            onOutputLine: { line, _ in onLine(line) }
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()
        }
    }
}

// MARK: - SVN Add to Ignore List

struct SvnAddToIgnoreWindowView: View {
    let repoPath: String
    let targetPaths: [String]

    @State private var mode: Int = 0
    @State private var scope: Int = 0
    @State private var customPattern: String = ""

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Picker(L("Pattern:", "忽略模式："), selection: $mode) {
                    Text(L("Exact file / folder name", "仅当前文件/目录名")).tag(0)
                    Text(L("All items with same extension (*.\(sampleExt))", "同扩展名全部文件 (*.\(sampleExt))")).tag(1)
                    Text(L("Custom wildcard pattern", "自定义通配符规则")).tag(2)
                }
                if mode == 2 {
                    TextField(L("Wildcard pattern (e.g. *.log):", "通配符规则（如 *.log）："), text: $customPattern)
                        .textFieldStyle(.roundedBorder)
                }

                Picker(L("Ignore Target:", "写入位置："), selection: $scope) {
                    Text(L("Parent folder svn:ignore property", "父目录 svn:ignore 属性")).tag(0)
                    Text(L("Global SVN ignores (~/.subversion/config)", "SVN 全局忽略配置 (~/.subversion/config)")).tag(1)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button(L("Cancel", "取消")) {
                    AppContainer.shared.windowCoordinator.closeWindow(key: "svn-ignore-\(repoPath)")
                }
                .keyboardShortcut(.escape, modifiers: [])
                Button(L("Add to Ignore List", "添加到忽略清单")) {
                    applyIgnore()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()
        }
    }

    private var sampleExt: String {
        let ext = targetPaths.first.map { URL(fileURLWithPath: $0).pathExtension } ?? ""
        return ext.isEmpty ? "tmp" : ext
    }

    private func applyIgnore() {
        var patternsByDir: [String: [String]] = [:]
        for path in targetPaths {
            let norm = PathUtils.normalize(path)
            let url = URL(fileURLWithPath: norm)
            let parent = url.deletingLastPathComponent().path
            let name = url.lastPathComponent
            let ext = url.pathExtension
            let pattern: String
            switch mode {
            case 1: pattern = ext.isEmpty ? name : "*.\(ext)"
            case 2: pattern = customPattern.trimmingCharacters(in: .whitespacesAndNewlines)
            default: pattern = name
            }
            if !pattern.isEmpty {
                patternsByDir[parent, default: []].append(pattern)
            }
        }

        AppContainer.shared.windowCoordinator.closeWindow(key: "svn-ignore-\(repoPath)")
        Task {
            do {
                if scope == 1 {
                    var existing = AppContainer.shared.svnProvider.readGlobalIgnores()
                    for list in patternsByDir.values {
                        for p in list where !existing.contains(p) {
                            existing.append(p)
                        }
                    }
                    try AppContainer.shared.svnProvider.writeGlobalIgnores(existing)
                } else {
                    for (dir, patterns) in patternsByDir {
                        try await AppContainer.shared.svnProvider.appendIgnorePatterns(
                            repoPath: repoPath,
                            directoryPath: dir,
                            patterns: patterns
                        )
                    }
                }
                AppContainer.shared.triggerRefresh(repoPath: repoPath)
            } catch {
                AlertHelper.showError(error)
            }
        }
    }
}

// MARK: - SVN Info

struct SvnInfoWindowView: View {
    let repoPath: String
    let targetPath: String

    @State private var info: SvnInfoResult?
    @State private var rawOutput: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let info {
                Form {
                    LabeledContent(L("Path:", "路径："), value: targetPath)
                    LabeledContent(L("Working Copy Root:", "工作副本根目录："), value: info.wcRoot ?? repoPath)
                    LabeledContent(L("URL:", "版本库 URL："), value: info.url)
                    LabeledContent(L("Relative URL:", "相对路径："), value: info.relativeURL)
                    LabeledContent(L("Repository Root:", "仓库根地址："), value: info.repositoryRoot)
                    LabeledContent(L("Repository UUID:", "仓库 UUID："), value: info.repositoryUUID)
                    LabeledContent(L("Revision:", "当前版本："), value: "r\(info.revision)")
                    LabeledContent(L("Node Kind:", "节点类型："), value: info.nodeKind)
                    LabeledContent(L("Last Changed Rev:", "最后更改版本："), value: "r\(info.lastChangedRev)")
                    LabeledContent(L("Last Changed Author:", "最后更改作者："), value: info.lastChangedAuthor)
                    if let d = info.lastChangedDate {
                        LabeledContent(L("Last Changed Date:", "最后更改时间："), value: d.formatted(date: .long, time: .standard))
                    }
                    if let lock = info.lock {
                        LabeledContent(L("Lock Owner:", "锁定者："), value: lock.owner)
                        LabeledContent(L("Lock Token:", "锁令牌："), value: lock.token)
                    }
                }
                .formStyle(.grouped)
            } else {
                ScrollView {
                    Text(rawOutput)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding()
                }
            }

            Divider()
            HStack {
                if let info {
                    Button(L("Copy URL", "拷贝 URL")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(info.url, forType: .string)
                    }
                    Button(L("Relocate…", "重定位…")) {
                        AppContainer.shared.windowCoordinator.dispatch(
                            action: .svnRelocate,
                            repoPath: repoPath,
                            targetDir: repoPath,
                            selectedPaths: [repoPath]
                        )
                    }
                }
                Spacer()
                Button(L("Close", "关闭")) {
                    AppContainer.shared.windowCoordinator.closeWindow(key: "svn-info-\(targetPath)")
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding()
        }
        .onAppear {
            Task {
                if let res = try? await AppContainer.shared.svnProvider.info(target: targetPath, workingDirectory: repoPath) {
                    self.info = res
                } else {
                    self.rawOutput = L("Failed to read svn info.", "无法读取 svn info。")
                }
            }
        }
    }
}
