import SwiftUI
import RepoShellShared
import RepoShellVcs

struct PullWindowView: View {
    let repoPath: String

    @State private var remotes: [GitRemote] = []
    @State private var remoteName: String = "origin"
    @State private var remoteBranches: [String] = []
    @State private var remoteBranch: String = ""
    @State private var currentBranch: String = ""
    @State private var strategy: GitPullStrategy = .merge
    @State private var noFastForward = false
    @State private var noCommit = false
    @State private var includeLog = false
    @State private var fetchTags = true
    @State private var fetchAllRemotes = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Picker(L("Pull from Remote:", "从远程拉取："), selection: $remoteName) {
                    ForEach(remotes) { r in Text(r.name).tag(r.name) }
                }
                Picker(L("Remote Branch:", "远程分支："), selection: $remoteBranch) {
                    Text(L("Default Tracking", "默认跟踪分支")).tag("")
                    ForEach(remoteBranches, id: \.self) { b in Text(b).tag(b) }
                }
                HStack {
                    Text(L("Into Local Branch:", "拉取至本地分支："))
                    Spacer()
                    Text(currentBranch).fontWeight(.medium)
                }
                Picker(L("Strategy:", "合并方式："), selection: $strategy) {
                    Text(L("Merge", "合并 (Merge)")).tag(GitPullStrategy.merge)
                    Text(L("Rebase", "变基 (Rebase)")).tag(GitPullStrategy.rebase)
                    Text(L("Fast-forward only", "仅快进 (Fast-forward only)")).tag(GitPullStrategy.fastForwardOnly)
                }
                Section(header: Text(L("Options", "选项"))) {
                    Toggle(L("Fetch all remotes", "从远程获取所有分支"), isOn: $fetchAllRemotes)
                    Toggle(L("Fetch all tags", "同时获取所有标签"), isOn: $fetchTags)
                    if strategy == .merge {
                        Toggle(L("No fast-forward (--no-ff)", "即使可以快进也要创建新提交"), isOn: $noFastForward)
                    }
                    Toggle(L("Do not auto-commit (--no-commit)", "合并后不立即自动提交"), isOn: $noCommit)
                    Toggle(L("Include merge commit summaries (--log)", "包含被合并提交的消息"), isOn: $includeLog)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button(L("Manage Remotes", "管理远程")) {
                    AppContainer.shared.windowCoordinator.openRemotes(repoPath: repoPath)
                }
                Button(L("Authentication", "身份验证")) {
                    AppContainer.shared.windowCoordinator.openAuthConfig(for: repoPath)
                }
                Spacer()
                Button(L("Cancel", "取消")) {
                    AppContainer.shared.windowCoordinator.closeWindow(key: "pull-\(repoPath)")
                }
                .keyboardShortcut(.escape, modifiers: [])
                Button(L("Pull", "拉取")) {
                    let opts = GitPullOptions(
                        remote: remoteName,
                        remoteBranch: remoteBranch.isEmpty ? nil : remoteBranch,
                        strategy: strategy,
                        noFastForward: noFastForward,
                        noCommit: noCommit,
                        includeMergeLog: includeLog,
                        fetchTags: fetchTags,
                        fetchAllRemotes: fetchAllRemotes
                    )
                    let env = AppContainer.shared.authEnv(for: repoPath)
                    AppContainer.shared.windowCoordinator.closeWindow(key: "pull-\(repoPath)")
                    AppContainer.shared.windowCoordinator.runTaskWithProgress(title: L("Git Pull", "Git 拉取"), repoPath: repoPath) { log in
                        try await AppContainer.shared.gitProvider.pull(repoPath: repoPath, options: opts, extraEnv: env) { line, _ in log(line) }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()
        }
        .task {
            let gp = AppContainer.shared.gitProvider
            remotes = (try? await gp.listRemotes(repoPath: repoPath)) ?? []
            if let first = remotes.first { remoteName = first.name }
            if let refs = try? await gp.listReferences(repoPath: repoPath) {
                currentBranch = refs.first(where: { $0.isCurrent })?.shortName ?? "HEAD"
                remoteBranches = refs.filter { $0.kind == .remoteBranch }.map {
                    $0.shortName.split(separator: "/", maxSplits: 1).dropFirst().first.map(String.init) ?? $0.shortName
                }
            }
        }
    }
}

struct FetchWindowView: View {
    let repoPath: String

    @State private var remotes: [GitRemote] = []
    @State private var remoteName: String = "origin"
    @State private var fetchAll = false
    @State private var prune = true
    @State private var fetchTags = true

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Toggle(L("Fetch from all remotes", "从所有远程获取"), isOn: $fetchAll)
                if !fetchAll {
                    Picker(L("Remote:", "远程："), selection: $remoteName) {
                        ForEach(remotes) { r in Text(r.name).tag(r.name) }
                    }
                }
                Toggle(L("Prune stale remote-tracking branches (--prune)", "修剪远程已不存在的跟踪分支"), isOn: $prune)
                Toggle(L("Fetch all tags (--tags)", "获取所有标签"), isOn: $fetchTags)
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button(L("Manage Remotes", "管理远程")) {
                    AppContainer.shared.windowCoordinator.openRemotes(repoPath: repoPath)
                }
                Button(L("Authentication", "身份验证")) {
                    AppContainer.shared.windowCoordinator.openAuthConfig(for: repoPath)
                }
                Spacer()
                Button(L("Cancel", "取消")) {
                    AppContainer.shared.windowCoordinator.closeWindow(key: "fetch-\(repoPath)")
                }
                .keyboardShortcut(.escape, modifiers: [])
                Button(L("Fetch", "获取")) {
                    let opts = GitFetchOptions(remote: remoteName, fetchAllRemotes: fetchAll, prune: prune, fetchTags: fetchTags)
                    let env = AppContainer.shared.authEnv(for: repoPath)
                    AppContainer.shared.windowCoordinator.closeWindow(key: "fetch-\(repoPath)")
                    AppContainer.shared.windowCoordinator.runTaskWithProgress(title: L("Git Fetch", "Git 获取"), repoPath: repoPath) { log in
                        try await AppContainer.shared.gitProvider.fetch(repoPath: repoPath, options: opts, extraEnv: env) { line, _ in log(line) }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()
        }
        .task {
            remotes = (try? await AppContainer.shared.gitProvider.listRemotes(repoPath: repoPath)) ?? []
            if let first = remotes.first { remoteName = first.name }
        }
    }
}

struct PushWindowView: View {
    let repoPath: String

    @State private var remotes: [GitRemote] = []
    @State private var remoteName: String = "origin"
    @State private var mappings: [GitPushBranchMapping] = []
    @State private var allTags: [String] = []
    @State private var selectedTags: Set<String> = []
    @State private var pushAllTags = false
    @State private var setUpstream = true
    @State private var force = false
    @State private var forceWithLease = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Picker(L("Push to Remote:", "推送至远程："), selection: $remoteName) {
                    ForEach(remotes) { r in Text(r.name).tag(r.name) }
                }

                Section(header: Text(L("Branches to Push", "要推送的分支"))) {
                    ForEach($mappings) { $m in
                        HStack {
                            Toggle("", isOn: $m.isSelected).labelsHidden()
                            Text(m.localBranch).frame(width: 150, alignment: .leading)
                            Image(systemName: "arrow.right")
                            TextField(L("Remote branch", "远程分支"), text: $m.remoteBranch)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }

                Section(header: Text(L("Options", "选项"))) {
                    Toggle(L("Set upstream tracking (-u)", "设置跟踪 (-u)"), isOn: $setUpstream)
                    Toggle(L("Push all tags (--tags)", "推送所有标签"), isOn: $pushAllTags)
                    Toggle(L("Force with lease (--force-with-lease)", "带保护的强制推送"), isOn: $forceWithLease)
                    Toggle(L("Force push (--force)", "强制推送"), isOn: $force)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button(L("Manage Remotes", "管理远程")) {
                    AppContainer.shared.windowCoordinator.openRemotes(repoPath: repoPath)
                }
                Button(L("Authentication", "身份验证")) {
                    AppContainer.shared.windowCoordinator.openAuthConfig(for: repoPath)
                }
                Spacer()
                Button(L("Cancel", "取消")) {
                    AppContainer.shared.windowCoordinator.closeWindow(key: "push-\(repoPath)")
                }
                .keyboardShortcut(.escape, modifiers: [])
                Button(L("Push", "推送")) {
                    let opts = GitPushOptions(
                        remote: remoteName,
                        branchMappings: mappings,
                        tags: Array(selectedTags),
                        pushAllTags: pushAllTags,
                        setUpstream: setUpstream,
                        force: force,
                        forceWithLease: forceWithLease
                    )
                    let env = AppContainer.shared.authEnv(for: repoPath)
                    AppContainer.shared.windowCoordinator.closeWindow(key: "push-\(repoPath)")
                    AppContainer.shared.windowCoordinator.runTaskWithProgress(title: L("Git Push", "Git 推送"), repoPath: repoPath) { log in
                        try await AppContainer.shared.gitProvider.push(repoPath: repoPath, options: opts, extraEnv: env) { line, _ in log(line) }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()
        }
        .task {
            let gp = AppContainer.shared.gitProvider
            remotes = (try? await gp.listRemotes(repoPath: repoPath)) ?? []
            if let first = remotes.first { remoteName = first.name }
            if let refs = try? await gp.listReferences(repoPath: repoPath) {
                let locals = refs.filter { $0.kind == .localBranch }
                mappings = locals.map {
                    GitPushBranchMapping(localBranch: $0.shortName, remoteBranch: $0.shortName, isSelected: $0.isCurrent)
                }
                allTags = refs.filter { $0.kind == .tag }.map { $0.shortName }
            }
        }
    }
}

struct CloneWindowView: View {
    let initialParentDir: String

    @State private var urlText: String = ""
    @State private var directoryPath: String
    @State private var singleBranch = false
    @State private var branchName = ""
    @State private var recursiveSubmodules = true
    @State private var bare = false
    @State private var recentURLs: [String] = []

    init(initialParentDir: String) {
        self.initialParentDir = initialParentDir
        _directoryPath = State(initialValue: initialParentDir)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                HStack {
                    TextField(L("Repository URL:", "版本库 URL："), text: $urlText)
                    if !recentURLs.isEmpty {
                        Menu(L("History", "历史")) {
                            ForEach(recentURLs, id: \.self) { u in
                                Button(u) { urlText = u }
                            }
                        }
                        .frame(width: 75)
                    }
                }
                HStack {
                    TextField(L("Destination Directory:", "目标目录："), text: $directoryPath)
                    Button(L("Browse…", "浏览…")) {
                        if let folder = AlertHelper.pickFolder(title: L("Choose Clone Destination", "选择克隆目标目录")) {
                            directoryPath = folder.path
                        }
                    }
                }
                Toggle(L("Clone a single branch", "克隆单一分支"), isOn: $singleBranch)
                if singleBranch {
                    TextField(L("Branch:", "分支："), text: $branchName)
                }
                Toggle(L("Initialize all submodules recursively", "递归初始化所有子模块"), isOn: $recursiveSubmodules)
                Toggle(L("Clone as bare repository (--bare)", "克隆至裸版本库 (--bare)"), isOn: $bare)
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button(L("Cancel", "取消")) {
                    AppContainer.shared.windowCoordinator.closeWindow(key: "clone-\(initialParentDir)")
                }
                .keyboardShortcut(.escape, modifiers: [])
                Button(L("Clone", "克隆")) {
                    performClone()
                }
                .buttonStyle(.borderedProminent)
                .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty || directoryPath.isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()
        }
        .onAppear {
            recentURLs = AppContainer.shared.recentHistoryStore.load().remoteURLs
        }
        .onChange(of: urlText) { newURL in
            let trimmed = newURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            var repoName = URL(string: trimmed)?.lastPathComponent ?? ""
            if repoName.hasSuffix(".git") {
                repoName = String(repoName.dropLast(4))
            }
            if !repoName.isEmpty && PathUtils.normalize(directoryPath) == PathUtils.normalize(initialParentDir) {
                directoryPath = PathUtils.normalize("\(initialParentDir)/\(repoName)")
            }
        }
    }

    private func performClone() {
        let trimmedURL = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        let dest = PathUtils.normalize(directoryPath)
        AppContainer.shared.recentHistoryStore.recordRemoteURL(trimmedURL)

        let opts = GitCloneOptions(
            url: trimmedURL,
            destinationPath: dest,
            branch: singleBranch && !branchName.isEmpty ? branchName : nil,
            singleBranch: singleBranch,
            recursiveSubmodules: recursiveSubmodules,
            bare: bare
        )
        let env = AppContainer.shared.authEnv(for: nil)
        AppContainer.shared.windowCoordinator.closeWindow(key: "clone-\(initialParentDir)")
        AppContainer.shared.windowCoordinator.runTaskWithProgress(title: L("Git Clone", "Git 克隆"), repoPath: dest) { log in
            let res = try await AppContainer.shared.gitProvider.clone(options: opts, extraEnv: env) { line, _ in log(line) }
            if !bare {
                _ = try? await AppContainer.shared.repositoryManager.addRepository(at: dest)
            }
            return res
        }
    }
}

struct CreateRepoWindowView: View {
    let initialPath: String
    @State private var targetPath: String
    @State private var bare = false
    @State private var autoMonitor = true

    init(initialPath: String) {
        self.initialPath = initialPath
        _targetPath = State(initialValue: initialPath)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                HStack {
                    TextField(L("Folder:", "目录："), text: $targetPath)
                    Button(L("Browse…", "浏览…")) {
                        if let u = AlertHelper.pickFolder(title: L("Select Folder", "选择目录")) {
                            targetPath = u.path
                        }
                    }
                }
                Toggle(L("Create bare repository (--bare)", "创建裸版本库 (--bare)"), isOn: $bare)
                Toggle(L("Add to RepoShell monitoring", "添加到 RepoShell 监控列表"), isOn: $autoMonitor)
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button(L("Cancel", "取消")) {
                    AppContainer.shared.windowCoordinator.closeWindow(key: "init-\(initialPath)")
                }
                .keyboardShortcut(.escape, modifiers: [])
                Button(L("Create", "创建")) {
                    let norm = PathUtils.normalize(targetPath)
                    Task {
                        do {
                            _ = try await AppContainer.shared.gitProvider.initRepository(at: norm, bare: bare)
                            if autoMonitor && !bare {
                                _ = try? await AppContainer.shared.repositoryManager.addRepository(at: norm)
                                AppContainer.shared.triggerRefresh(repoPath: norm)
                            }
                            AppContainer.shared.windowCoordinator.closeWindow(key: "init-\(initialPath)")
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
