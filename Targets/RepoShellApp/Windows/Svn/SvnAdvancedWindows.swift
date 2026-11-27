import Cocoa
import SwiftUI
import RepoShellShared
import RepoShellVcs
import RepoShellServices

// MARK: - SVN Repo-browser

struct SvnRepoBrowserWindowView: View {
    let repoPath: String?
    var initialURL: String = ""
    var initialRevision: String = "HEAD"

    @State private var currentURL: String = ""
    @State private var revision: String = "HEAD"
    @State private var repoRootURL: String = ""
    @State private var entries: [VcsTreeEntry] = []
    @State private var folderCache: [String: [VcsTreeEntry]] = [:]
    @State private var expandedURLs: Set<String> = []
    @State private var selectedEntryID: String?
    @State private var isLoading: Bool = false
    @State private var loadTask: Task<Void, Never>?
    @State private var promptMode: BrowserPromptMode?

    enum BrowserPromptMode: Identifiable {
        case mkdir
        case copyOrMove(sourceURL: String, isMove: Bool)
        case delete(urls: [String])

        var id: String {
            switch self {
            case .mkdir: return "mkdir"
            case .copyOrMove(let s, let m): return "\(m ? "move" : "copy")-\(s)"
            case .delete(let u): return "del-\(u.joined())"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // URL bar
            HStack(spacing: 8) {
                Button {
                    navigateUp()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(!canNavigateUp)

                TextField(L("SVN URL…", "SVN 地址…"), text: $currentURL)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { loadDirectory() }

                TextField("HEAD", text: $revision)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .onSubmit { loadDirectory() }

                Button(L("Go", "转到")) { loadDirectory() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(10)

            Divider()

            // Toolbar
            HStack(spacing: 8) {
                Button {
                    promptMode = .mkdir
                } label: {
                    Label(L("New Folder…", "新建文件夹…"), systemImage: "folder.badge.plus")
                }

                Button {
                    AppContainer.shared.windowCoordinator.openSvnCheckout(initialURL: selectedURLOrCurrent)
                } label: {
                    Label(L("Checkout…", "签出…"), systemImage: "arrow.down.doc")
                }

                Button {
                    AppContainer.shared.windowCoordinator.openSvnExport(source: selectedURLOrCurrent, revision: revision)
                } label: {
                    Label(L("Export…", "导出…"), systemImage: "square.and.arrow.up")
                }

                Spacer()

                if let entry = selectedEntry {
                    Button(L("Copy / Branch…", "拷贝 / 分支…")) {
                        promptMode = .copyOrMove(sourceURL: urlForEntry(entry), isMove: false)
                    }
                    Button(L("Move / Rename…", "移动 / 重命名…")) {
                        promptMode = .copyOrMove(sourceURL: urlForEntry(entry), isMove: true)
                    }
                    Button(L("Delete…", "删除…")) {
                        promptMode = .delete(urls: [urlForEntry(entry)])
                    }
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            // Breadcrumb bar
            if !currentURL.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "server.rack")
                        .font(.caption)
                        .foregroundColor(.accentColor)
                    let rootBase = effectiveRootURL
                    Button(URL(string: rootBase)?.lastPathComponent ?? rootBase) {
                        selectTreeURL(rootBase)
                    }
                    .buttonStyle(.link)
                    let relSegs = relativeBreadcrumbSegments
                    ForEach(Array(relSegs.enumerated()), id: \.offset) { idx, seg in
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                        Button(seg) {
                            let target = ([rootBase] + relSegs[0...idx]).joined(separator: "/")
                            selectTreeURL(target)
                        }
                        .buttonStyle(.link)
                    }
                    Spacer()
                }
                .font(.system(size: 12))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))

                Divider()
            }

            HSplitView {
                // Left Pane: Remote SVN Folder Tree
                ScrollView {
                    if !effectiveRootURL.isEmpty {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            SvnFolderTreeRow(
                                folderURL: effectiveRootURL,
                                name: URL(string: effectiveRootURL)?.lastPathComponent ?? effectiveRootURL,
                                depth: 0,
                                currentURL: currentURL,
                                expandedURLs: $expandedURLs,
                                folderCache: folderCache,
                                onSelect: selectTreeURL,
                                onToggleExpand: toggleExpandTree
                            )
                        }
                        .padding(6)
                    }
                }
                .frame(minWidth: 185, idealWidth: 225, maxWidth: 320)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))

                // Right Pane: Directory Listing Table
                VStack(spacing: 0) {
                    TableColumnHeaderBar(
                        columns: [
                            TableColumnSpec(L("Name", "名称")),
                            TableColumnSpec(L("Revision", "修订"), width: 72, alignment: .trailing),
                            TableColumnSpec(L("Size", "大小"), width: 80, alignment: .trailing)
                        ],
                        horizontalPadding: 12,
                        spacing: 8
                    )

                    if isLoading && entries.isEmpty {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if entries.isEmpty {
                        EmptyStateBox(
                            systemImage: "sidebar.squares.left",
                            title: L("Empty Directory", "空目录"),
                            subtitle: currentURL
                        )
                    } else {
                        List(entries, selection: $selectedEntryID) { entry in
                            SvnRepoBrowserRowView(entry: entry)
                                .equatable()
                                .onListRowDoubleClick {
                                    if entry.kind == .tree {
                                        selectTreeURL(urlForEntry(entry))
                                    } else {
                                        extractAndOpen(entry)
                                    }
                                }
                                .tag(entry.id)
                                .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 12))
                                .contentShape(Rectangle())
                                .contextMenu {
                                let targetURL = urlForEntry(entry)
                                if entry.kind == .tree {
                                    Button(L("Open Folder", "打开目录")) {
                                        selectTreeURL(targetURL)
                                    }
                                } else {
                                    Button(L("Open / Extract File…", "打开 / 提取文件…")) {
                                        extractAndOpen(entry)
                                    }
                                    Button(L("Blame…", "追溯…")) {
                                        AppContainer.shared.windowCoordinator.openBlameResult(
                                            repoPath: repoPath ?? "",
                                            filePath: targetURL,
                                            revision: revision,
                                            ignoreWhitespace: false,
                                            hideAuthorAndDate: false
                                        )
                                    }
                                }
                                Divider()
                                Button(L("Show Log", "显示日志")) {
                                    AppContainer.shared.windowCoordinator.openSvnLog(repoPath: repoPath, target: targetURL)
                                }
                                Button(L("View Properties…", "查看属性…")) {
                                    AppContainer.shared.windowCoordinator.presentWindow(
                                        key: "svn-props-\(targetURL)",
                                        title: L("Properties", "属性") + " — \(entry.name)",
                                        size: NSSize(width: 620, height: 420),
                                        view: SvnPropertiesWindowView(repoPath: repoPath, target: targetURL, isRemoteURL: true)
                                    )
                                }
                                Divider()
                                Button(L("Copy / Tag to…", "拷贝 / 打标签到…")) {
                                    promptMode = .copyOrMove(sourceURL: targetURL, isMove: false)
                                }
                                Button(L("Move / Rename…", "移动 / 重命名…")) {
                                    promptMode = .copyOrMove(sourceURL: targetURL, isMove: true)
                                }
                                Button(L("Delete…", "删除…")) {
                                    promptMode = .delete(urls: [targetURL])
                                }
                                Divider()
                                Button(L("Checkout…", "签出…")) {
                                    AppContainer.shared.windowCoordinator.openSvnCheckout(initialURL: targetURL)
                                }
                                Button(L("Export…", "导出…")) {
                                    AppContainer.shared.windowCoordinator.openSvnExport(source: targetURL, revision: revision)
                                }
                                Button(L("Copy URL", "拷贝 URL")) {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(targetURL, forType: .string)
                                }
                            }
                        }
                        .listStyle(.inset)
                        .environment(\.defaultMinListRowHeight, 22)
                    }
                }
            }
        }
        .onAppear(perform: initializeAndLoad)
        .onDisappear {
            loadTask?.cancel()
            loadTask = nil
        }
        .sheet(item: $promptMode) { mode in
            SvnBrowserOperationSheet(
                mode: mode,
                baseURL: currentURL,
                repoPath: repoPath
            ) {
                promptMode = nil
                loadDirectory()
            } onCancel: {
                promptMode = nil
            }
        }
    }

    private func sortTreeEntries(_ list: [VcsTreeEntry]) -> [VcsTreeEntry] {
        list.sorted {
            if $0.kind != $1.kind { return $0.kind == .tree }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private var selectedEntry: VcsTreeEntry? {
        entries.first { $0.id == selectedEntryID }
    }

    private var selectedURLOrCurrent: String {
        selectedEntry.map { urlForEntry($0) } ?? currentURL
    }

    private var canNavigateUp: Bool {
        guard !repoRootURL.isEmpty else { return currentURL.split(separator: "/").count > 2 }
        return currentURL.count > repoRootURL.count
    }

    private func navigateUp() {
        guard let u = URL(string: currentURL) else { return }
        let parent = u.deletingLastPathComponent().absoluteString
        let next = parent.hasSuffix("/") && parent != "file:///" ? String(parent.dropLast()) : parent
        selectTreeURL(next)
    }

    private func urlForEntry(_ entry: VcsTreeEntry) -> String {
        let base = currentURL.hasSuffix("/") ? String(currentURL.dropLast()) : currentURL
        return "\(base)/\(entry.name)"
    }

    private var effectiveRootURL: String {
        let raw = repoRootURL.isEmpty ? currentURL : repoRootURL
        return raw.hasSuffix("/") ? String(raw.dropLast()) : raw
    }

    private var relativeBreadcrumbSegments: [String] {
        let root = effectiveRootURL
        let cleanCur = currentURL.hasSuffix("/") ? String(currentURL.dropLast()) : currentURL
        guard cleanCur.hasPrefix(root), cleanCur.count > root.count else { return [] }
        let suffix = String(cleanCur.dropFirst(root.count))
        return suffix.split(separator: "/").map(String.init)
    }

    private func selectTreeURL(_ url: String) {
        let cleanTarget = url.hasSuffix("/") ? String(url.dropLast()) : url
        let cleanCur = currentURL.hasSuffix("/") ? String(currentURL.dropLast()) : currentURL
        if cleanTarget != cleanCur {
            selectedEntryID = nil
            entries = []
        }
        currentURL = cleanTarget
        expandedURLs.insert(effectiveRootURL)
        expandedURLs.insert(cleanTarget)
        loadDirectory()
    }

    private func toggleExpandTree(_ url: String) {
        if expandedURLs.contains(url) {
            expandedURLs.remove(url)
        } else {
            expandedURLs.insert(url)
            if folderCache[url] == nil {
                let rev = revision.isEmpty ? nil : revision
                Task {
                    if let res = try? await AppContainer.shared.runSvnInteractive(repoPath: repoPath, targetURL: url, { env, auth in
                        try await AppContainer.shared.svnProvider.listURL(url, revision: rev, environment: env, auth: auth)
                    }) {
                        self.folderCache[url] = res.filter { $0.kind == .tree }.sorted {
                            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                        }
                    }
                }
            }
        }
    }

    private func initializeAndLoad() {
        revision = initialRevision
        if !initialURL.isEmpty {
            currentURL = initialURL
            expandedURLs.insert(initialURL)
            loadDirectory()
            return
        }
        guard let repoPath else { return }
        Task {
            if let info = try? await AppContainer.shared.svnProvider.info(target: repoPath, workingDirectory: repoPath) {
                self.currentURL = info.url
                self.repoRootURL = info.repositoryRoot
                self.expandedURLs.insert(info.repositoryRoot)
                self.expandedURLs.insert(info.url)
                loadDirectory()
            }
        }
    }

    private func loadDirectory() {
        guard !currentURL.isEmpty else { return }
        loadTask?.cancel()
        isLoading = true
        let target = currentURL.hasSuffix("/") ? String(currentURL.dropLast()) : currentURL
        let rev = revision.isEmpty ? nil : revision
        loadTask = Task {
            defer {
                if !Task.isCancelled { isLoading = false }
            }
            do {
                let res = try await AppContainer.shared.runSvnInteractive(repoPath: repoPath, targetURL: target) { env, auth in
                    try await AppContainer.shared.svnProvider.listURL(target, revision: rev, environment: env, auth: auth)
                }
                let activeTarget = currentURL.hasSuffix("/") ? String(currentURL.dropLast()) : currentURL
                guard !Task.isCancelled, activeTarget == target else { return }
                let sorted = sortTreeEntries(res)
                self.entries = sorted
                self.folderCache[target] = sorted.filter { $0.kind == .tree }
            } catch {
                if !Task.isCancelled {
                    AlertHelper.showError(error)
                }
            }
        }
    }

    private func extractAndOpen(_ entry: VcsTreeEntry) {
        let remoteURL = urlForEntry(entry)
        Task {
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString.prefix(6))-\(entry.name)")
            do {
                try await AppContainer.shared.svnProvider.extractFile(repoPath: repoPath ?? "", path: remoteURL, revision: revision, to: temp.path)
                NSWorkspace.shared.open(temp)
            } catch {
                AlertHelper.showError(error)
            }
        }
    }
}

private struct SvnRepoBrowserRowView: View, Equatable {
    let entry: VcsTreeEntry

    var body: some View {
        HStack(spacing: 8) {
            FileTypeIconView(path: entry.name, isDirectory: entry.kind == .tree)
            Text(entry.name)
                .font(.system(size: 12.5))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.objectHash)
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 72, alignment: .trailing)
            Text(entry.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "")
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .trailing)
        }
    }
}

private struct SvnFolderTreeRow: View {
    let folderURL: String
    let name: String
    let depth: Int
    let currentURL: String
    @Binding var expandedURLs: Set<String>
    let folderCache: [String: [VcsTreeEntry]]
    let onSelect: (String) -> Void
    let onToggleExpand: (String) -> Void

    var body: some View {
        let cleanCur = currentURL.hasSuffix("/") ? String(currentURL.dropLast()) : currentURL
        let cleanSelf = folderURL.hasSuffix("/") ? String(folderURL.dropLast()) : folderURL
        let isSelected = cleanCur == cleanSelf
        let isExpanded = expandedURLs.contains(cleanSelf) || expandedURLs.contains(folderURL)
        let children = folderCache[cleanSelf] ?? []

        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Button {
                    onToggleExpand(cleanSelf)
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)

                Image(systemName: isExpanded ? "folder.fill" : "folder")
                    .font(.system(size: 12))
                    .foregroundColor(.accentColor)

                Text(name)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(depth) * 14 + 4)
            .padding(.trailing, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                onSelect(cleanSelf)
            }

            if isExpanded {
                ForEach(children) { child in
                    SvnFolderTreeRow(
                        folderURL: "\(cleanSelf)/\(child.name)",
                        name: child.name,
                        depth: depth + 1,
                        currentURL: currentURL,
                        expandedURLs: $expandedURLs,
                        folderCache: folderCache,
                        onSelect: onSelect,
                        onToggleExpand: onToggleExpand
                    )
                }
            }
        }
    }
}

private struct SvnBrowserOperationSheet: View {
    let mode: SvnRepoBrowserWindowView.BrowserPromptMode
    let baseURL: String
    let repoPath: String?
    let onDone: () -> Void
    let onCancel: () -> Void

    @State private var inputValue: String = ""
    @State private var message: String = ""
    @State private var isBusy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(titleText).font(.headline)
            if case .delete(let urls) = mode {
                Text(urls.joined(separator: "\n"))
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
            } else {
                TextField(fieldLabel, text: $inputValue)
                    .textFieldStyle(.roundedBorder)
            }
            TextField(L("Commit Message:", "提交信息："), text: $message)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button(L("Cancel", "取消"), action: onCancel)
                Button(L("Execute", "确定")) { execute() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isBusy)
            }
        }
        .padding()
        .frame(width: 480)
        .onAppear {
            switch mode {
            case .mkdir:
                inputValue = "NewFolder"
                message = "Create folder"
            case .copyOrMove(let src, let isMove):
                inputValue = src
                message = isMove ? "Move item" : "Copy item"
            case .delete:
                message = "Delete item"
            }
        }
    }

    private var titleText: String {
        switch mode {
        case .mkdir: return L("Create Remote Folder", "新建远端目录")
        case .copyOrMove(_, let isMove): return isMove ? L("Remote Move / Rename", "远端移动 / 重命名") : L("Remote Copy", "远端拷贝")
        case .delete: return L("Delete Remote Item(s)", "删除远端项")
        }
    }

    private var fieldLabel: String {
        if case .mkdir = mode { return L("Folder Name:", "文件夹名称：") }
        return L("Destination URL:", "目标 URL：")
    }

    private func execute() {
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                _ = try await AppContainer.shared.runSvnInteractive(repoPath: repoPath, targetURL: baseURL) { env, auth in
                    switch mode {
                    case .mkdir:
                        let cleanBase = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
                        return try await AppContainer.shared.svnProvider.remoteMakeDirectory(
                            url: "\(cleanBase)/\(inputValue)",
                            message: message,
                            environment: env,
                            auth: auth
                        )
                    case .copyOrMove(let src, let isMove):
                        return try await AppContainer.shared.svnProvider.remoteCopyOrMove(
                            sourceURL: src,
                            destinationURL: inputValue,
                            isMove: isMove,
                            message: message,
                            environment: env,
                            auth: auth
                        )
                    case .delete(let urls):
                        return try await AppContainer.shared.svnProvider.remoteDelete(
                            urls: urls,
                            message: message,
                            environment: env,
                            auth: auth
                        )
                    }
                }
                onDone()
            } catch {
                AlertHelper.showError(error)
            }
        }
    }
}

// MARK: - SVN Branch / Tag

struct SvnBranchTagWindowView: View {
    let repoPath: String

    @State private var currentURL: String = ""
    @State private var repoRootURL: String = ""
    @State private var destinationURL: String = ""
    @State private var sourceMode: Int = 0 // 0=HEAD, 1=WC, 2=Revision
    @State private var specificRevision: String = ""
    @State private var message: String = ""
    @State private var switchAfterCopy: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(header: Text(L("Source", "拷贝源"))) {
                    Text(currentURL)
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                    Picker(L("Copy From:", "来源："), selection: $sourceMode) {
                        Text(L("HEAD revision in repository", "版本库最新修订 (HEAD)")).tag(0)
                        Text(L("Working copy", "当前工作副本")).tag(1)
                        Text(L("Specific revision", "指定修订号")).tag(2)
                    }
                    if sourceMode == 2 {
                        TextField(L("Revision:", "修订号："), text: $specificRevision)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                Section(header: Text(L("Destination URL", "目标分支/标签 URL"))) {
                    TextField("https://.../branches/feature-x", text: $destinationURL)
                        .textFieldStyle(.roundedBorder)
                    HStack(spacing: 8) {
                        Button("branches/") { setQuickPrefix("branches") }
                        Button("tags/") { setQuickPrefix("tags") }
                        Spacer()
                    }
                    .controlSize(.small)
                }

                Section(header: Text(L("Commit Message & Options", "提交信息与选项"))) {
                    TextField(L("Log message:", "提交备注："), text: $message)
                        .textFieldStyle(.roundedBorder)
                    Toggle(L("Switch working copy to new branch / tag", "创建后切换工作副本到新分支 / 标签"), isOn: $switchAfterCopy)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button(L("Cancel", "取消")) {
                    AppContainer.shared.windowCoordinator.closeWindow(key: "svn-branch-\(repoPath)")
                }
                .keyboardShortcut(.escape, modifiers: [])
                Button(L("Create Branch / Tag", "创建分支 / 标签")) {
                    let src = sourceMode == 1 ? repoPath : currentURL
                    let rev = sourceMode == 2 ? specificRevision : (sourceMode == 0 ? "HEAD" : nil)
                    let dest = destinationURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    let msg = message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Branch/Tag" : message
                    let doSwitch = switchAfterCopy

                    AppContainer.shared.windowCoordinator.closeWindow(key: "svn-branch-\(repoPath)")
                    AppContainer.shared.windowCoordinator.runTaskWithProgress(
                        title: L("SVN Branch / Tag", "SVN 分支 / 标签"),
                        repoPath: repoPath
                    ) { onLine in
                        try await AppContainer.shared.runSvnInteractive(repoPath: repoPath, targetURL: dest) { env, auth in
                            let res = try await AppContainer.shared.svnProvider.branchOrTag(
                                repoPath: repoPath,
                                source: src,
                                destinationURL: dest,
                                revision: rev,
                                message: msg,
                                makeParents: true,
                                environment: env,
                                auth: auth,
                                onOutputLine: { line, _ in onLine(line) }
                            )
                            if doSwitch {
                                _ = try await AppContainer.shared.svnProvider.switchBranch(
                                    repoPath: repoPath,
                                    url: dest,
                                    environment: env,
                                    auth: auth,
                                    onOutputLine: { line, _ in onLine(line) }
                                )
                            }
                            return res
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(destinationURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()
        }
        .onAppear {
            Task {
                if let info = try? await AppContainer.shared.svnProvider.info(target: repoPath, workingDirectory: repoPath) {
                    self.currentURL = info.url
                    self.repoRootURL = info.repositoryRoot
                    if destinationURL.isEmpty {
                        let cleanRoot = info.repositoryRoot.hasSuffix("/") ? String(info.repositoryRoot.dropLast()) : info.repositoryRoot
                        destinationURL = "\(cleanRoot)/branches/"
                    }
                }
            }
        }
    }

    private func setQuickPrefix(_ sub: String) {
        let cleanRoot = repoRootURL.hasSuffix("/") ? String(repoRootURL.dropLast()) : repoRootURL
        guard !cleanRoot.isEmpty else { return }
        destinationURL = "\(cleanRoot)/\(sub)/"
    }
}

// MARK: - SVN Switch

struct SvnSwitchWindowView: View {
    let repoPath: String

    @State private var targetURL: String = ""
    @State private var useHead: Bool = true
    @State private var revision: String = ""
    @State private var ignoreAncestry: Bool = false
    @State private var ignoreExternals: Bool = false
    @State private var force: Bool = false
    @State private var accept: SvnConflictAccept = .postpone

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField(L("Switch to URL:", "切换到 URL："), text: $targetURL)
                    .textFieldStyle(.roundedBorder)
                Toggle(L("HEAD revision", "最新修订 (HEAD)"), isOn: $useHead)
                if !useHead {
                    TextField(L("Revision:", "修订号："), text: $revision)
                        .textFieldStyle(.roundedBorder)
                }
                Toggle(L("Ignore ancestry (--ignore-ancestry)", "忽略祖先关系 (--ignore-ancestry)"), isOn: $ignoreAncestry)
                Toggle(L("Ignore externals (--ignore-externals)", "忽略外部定义"), isOn: $ignoreExternals)
                Toggle(L("Force (--force)", "强制切换 (--force)"), isOn: $force)
                Picker(L("On Conflict:", "遇到冲突时："), selection: $accept) {
                    ForEach(SvnConflictAccept.allCases, id: \.self) { c in
                        Text(c.displayTitle).tag(c)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button(L("Cancel", "取消")) {
                    AppContainer.shared.windowCoordinator.closeWindow(key: "svn-switch-\(repoPath)")
                }
                .keyboardShortcut(.escape, modifiers: [])
                Button(L("Switch", "切换")) {
                    let url = targetURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    let rev = useHead ? nil : revision
                    let ignAnc = ignoreAncestry
                    let ignExt = ignoreExternals
                    let f = force
                    let acc = accept

                    AppContainer.shared.windowCoordinator.closeWindow(key: "svn-switch-\(repoPath)")
                    AppContainer.shared.windowCoordinator.runTaskWithProgress(
                        title: L("SVN Switch", "SVN 切换"),
                        repoPath: repoPath
                    ) { onLine in
                        try await AppContainer.shared.runSvnInteractive(repoPath: repoPath, targetURL: url) { env, auth in
                            try await AppContainer.shared.svnProvider.switchBranch(
                                repoPath: repoPath,
                                url: url,
                                revision: rev,
                                ignoreAncestry: ignAnc,
                                ignoreExternals: ignExt,
                                force: f,
                                accept: acc,
                                environment: env,
                                auth: auth,
                                onOutputLine: { line, _ in onLine(line) }
                            )
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(targetURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()
        }
        .onAppear {
            Task {
                if let info = try? await AppContainer.shared.svnProvider.info(target: repoPath, workingDirectory: repoPath) {
                    targetURL = info.url
                }
            }
        }
    }
}

// MARK: - SVN Merge Wizard

struct SvnMergeWindowView: View {
    let repoPath: String

    @State private var mode: SvnMergeMode = .range
    @State private var url1: String = ""
    @State private var url2: String = ""
    @State private var revRange: String = ""
    @State private var rev1: String = ""
    @State private var rev2: String = "HEAD"
    @State private var reverseMerge: Bool = false
    @State private var reintegrate: Bool = false
    @State private var recordOnly: Bool = false
    @State private var ignoreAncestry: Bool = false
    @State private var ignoreWhitespace: Bool = false
    @State private var force: Bool = false
    @State private var accept: SvnConflictAccept = .postpone

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Picker(L("Merge Mode:", "合并模式："), selection: $mode) {
                    Text(L("Merge a range of revisions", "合并一定范围的修订版本")).tag(SvnMergeMode.range)
                    Text(L("Merge two different trees", "合并两个不同的分支目录树")).tag(SvnMergeMode.twoTrees)
                }
                .pickerStyle(.radioGroup)

                if mode == .range {
                    Section(header: Text(L("Revision Range Merge", "修订范围配置"))) {
                        TextField(L("URL to merge from:", "合并源 URL："), text: $url1)
                            .textFieldStyle(.roundedBorder)
                        Toggle(L("Reintegrate branch (automatic merge)", "重整合分支（不填范围时自动合并整个分支）"), isOn: $reintegrate)
                        if !reintegrate {
                            TextField(L("Revision range (e.g. 10-20 or 12,15, empty=all):", "版本号范围（如 10:20 或 12,15，留空合并全部）："), text: $revRange)
                                .textFieldStyle(.roundedBorder)
                            Toggle(L("Reverse merge", "反向合并"), isOn: $reverseMerge)
                        }
                        Toggle(L("Only record mergeinfo (--record-only)", "仅记录合并信息 (--record-only)"), isOn: $recordOnly)
                    }
                } else {
                    Section(header: Text(L("Two Trees Configuration", "双向目录树对比"))) {
                        TextField(L("From URL:", "起始 URL："), text: $url1)
                            .textFieldStyle(.roundedBorder)
                        TextField(L("From Revision (e.g. HEAD or rev):", "起始版本："), text: $rev1)
                            .textFieldStyle(.roundedBorder)
                        TextField(L("To URL:", "目标 URL："), text: $url2)
                            .textFieldStyle(.roundedBorder)
                        TextField(L("To Revision (e.g. HEAD or rev):", "目标版本："), text: $rev2)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                Section(header: Text(L("Merge Options", "合并选项"))) {
                    Toggle(L("Ignore ancestry (--ignore-ancestry)", "忽略祖先历史 (--ignore-ancestry)"), isOn: $ignoreAncestry)
                    Toggle(L("Ignore whitespace changes (-x -w)", "忽略空白符变更 (-x -w)"), isOn: $ignoreWhitespace)
                    Toggle(L("Force (--force)", "强制合并 (--force)"), isOn: $force)
                    Picker(L("On Conflict:", "冲突解决策略："), selection: $accept) {
                        ForEach(SvnConflictAccept.allCases, id: \.self) { c in
                            Text(c.displayTitle).tag(c)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button(L("Test Merge (--dry-run)", "模拟合并 (--dry-run)")) {
                    runMerge(dryRun: true)
                }
                .disabled(url1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Spacer()
                Button(L("Cancel", "取消")) {
                    AppContainer.shared.windowCoordinator.closeWindow(key: "svn-merge-\(repoPath)")
                }
                .keyboardShortcut(.escape, modifiers: [])
                Button(L("Merge", "执行合并")) {
                    runMerge(dryRun: false)
                }
                .buttonStyle(.borderedProminent)
                .disabled(url1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()
        }
        .onAppear {
            Task {
                if let info = try? await AppContainer.shared.svnProvider.info(target: repoPath, workingDirectory: repoPath) {
                    if url1.isEmpty { url1 = info.url }
                    if url2.isEmpty { url2 = info.url }
                }
            }
        }
    }

    private func runMerge(dryRun: Bool) {
        let normalizedRange = revRange.replacingOccurrences(of: "-", with: ":")
        let opts = SvnMergeOptions(
            mode: mode,
            sourceURL1: url1.trimmingCharacters(in: .whitespacesAndNewlines),
            revision1: rev1,
            sourceURL2: url2.trimmingCharacters(in: .whitespacesAndNewlines),
            revision2: rev2,
            revisionRange: normalizedRange,
            reverseMerge: reverseMerge,
            reintegrate: reintegrate,
            dryRun: dryRun,
            recordOnly: recordOnly,
            ignoreAncestry: ignoreAncestry,
            force: force,
            ignoreWhitespace: ignoreWhitespace,
            accept: accept
        )
        if !dryRun {
            AppContainer.shared.windowCoordinator.closeWindow(key: "svn-merge-\(repoPath)")
        }
        AppContainer.shared.windowCoordinator.runTaskWithProgress(
            title: dryRun ? L("SVN Test Merge (--dry-run)", "SVN 模拟合并") : L("SVN Merge", "SVN 合并"),
            repoPath: dryRun ? nil : repoPath
        ) { onLine in
            try await AppContainer.shared.runSvnInteractive(repoPath: repoPath, targetURL: opts.sourceURL1) { env, auth in
                try await AppContainer.shared.svnProvider.merge(
                    repoPath: repoPath,
                    options: opts,
                    environment: env,
                    auth: auth,
                    onOutputLine: { line, _ in onLine(line) }
                )
            }
        }
    }
}

// MARK: - SVN Get Lock / Release Lock

struct SvnLockUnlockWindowView: View {
    let repoPath: String
    let targetPaths: [String]
    let isUnlock: Bool

    @State private var comment: String = ""
    @State private var force: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Text(String(format: L("Target items: %d", "已选择 %d 个目标"), max(1, targetPaths.count)))
                    .font(.headline)
                if !isUnlock {
                    TextField(L("Lock comment (optional):", "锁备注信息（可选）："), text: $comment)
                        .textFieldStyle(.roundedBorder)
                }
                Toggle(
                    isUnlock
                        ? L("Break locks owned by others (--force)", "强制破坏其他用户的锁 (--force)")
                        : L("Steal locks owned by others (--force)", "强行抢夺现有锁 (--force)"),
                    isOn: $force
                )
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button(L("Cancel", "取消")) {
                    AppContainer.shared.windowCoordinator.closeWindow(key: "svn-\(isUnlock ? "unlock" : "lock")-\(repoPath)")
                }
                .keyboardShortcut(.escape, modifiers: [])
                Button(isUnlock ? L("Release Lock", "释放锁") : L("Get Lock", "获取锁")) {
                    let f = force
                    let msg = comment
                    AppContainer.shared.windowCoordinator.closeWindow(key: "svn-\(isUnlock ? "unlock" : "lock")-\(repoPath)")
                    AppContainer.shared.windowCoordinator.runTaskWithProgress(
                        title: isUnlock ? L("SVN Release Lock", "SVN 释放锁") : L("SVN Get Lock", "SVN 获取锁"),
                        repoPath: repoPath
                    ) { onLine in
                        try await AppContainer.shared.runSvnInteractive(repoPath: repoPath) { env, auth in
                            if isUnlock {
                                return try await AppContainer.shared.svnProvider.unlock(
                                    repoPath: repoPath,
                                    paths: targetPaths,
                                    force: f,
                                    environment: env,
                                    auth: auth,
                                    onOutputLine: { line, _ in onLine(line) }
                                )
                            } else {
                                return try await AppContainer.shared.svnProvider.lock(
                                    repoPath: repoPath,
                                    paths: targetPaths,
                                    message: msg,
                                    force: f,
                                    environment: env,
                                    auth: auth,
                                    onOutputLine: { line, _ in onLine(line) }
                                )
                            }
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

// MARK: - SVN Properties

struct SvnPropertiesWindowView: View {
    let repoPath: String?
    let target: String
    var isRemoteURL: Bool = false

    @State private var properties: [SvnPropertyEntry] = []
    @State private var selectedName: String?
    @State private var editName: String = "svn:ignore"
    @State private var editValue: String = ""
    @State private var recursive: Bool = false
    @State private var isLoading: Bool = false
    @State private var detailUpdateTask: Task<Void, Never>?

    private let presetNames = [
        "svn:ignore",
        "svn:externals",
        "svn:needs-lock",
        "svn:eol-style",
        "svn:executable",
        "svn:mime-type",
        "svn:keywords"
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(target)
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button(L("Refresh", "刷新")) { refresh() }
            }
            .padding(10)

            Divider()

            HSplitView {
                List(properties, selection: $selectedName) { prop in
                    SvnPropertyRowView(prop: prop)
                        .equatable()
                        .tag(prop.name)
                }
                .onChange(of: selectedName) { name in
                    schedulePropertyEditorUpdate(for: name)
                }
                .frame(minWidth: 200)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField(L("Property name:", "属性名称："), text: $editName)
                            .textFieldStyle(.roundedBorder)
                        Menu(L("Presets", "常用预设")) {
                            ForEach(presetNames, id: \.self) { preset in
                                Button(preset) {
                                    editName = preset
                                    if preset == "svn:needs-lock" || preset == "svn:executable" {
                                        editValue = "*"
                                    } else if preset == "svn:eol-style" {
                                        editValue = "native"
                                    }
                                }
                            }
                        }
                    }

                    TextEditor(text: $editValue)
                        .font(.system(.body, design: .monospaced))
                        .border(Color.secondary.opacity(0.25))

                    HStack {
                        if !isRemoteURL {
                            Toggle(L("Apply recursively (-R)", "递归应用到子目录 (-R)"), isOn: $recursive)
                        }
                        Spacer()
                        if !isRemoteURL {
                            Button(L("Delete", "删除")) { deleteProperty() }
                                .disabled(editName.trimmingCharacters(in: .whitespaces).isEmpty)
                            Button(L("Save Property", "保存属性")) { saveProperty() }
                                .buttonStyle(.borderedProminent)
                                .disabled(editName.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
                .padding(10)
            }
        }
        .onAppear(perform: refresh)
        .onDisappear {
            detailUpdateTask?.cancel()
            detailUpdateTask = nil
        }
    }

    private func schedulePropertyEditorUpdate(for name: String?) {
        detailUpdateTask?.cancel()
        guard let name, let found = properties.first(where: { $0.name == name }) else {
            detailUpdateTask = nil
            return
        }
        detailUpdateTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 25_000_000)
            guard !Task.isCancelled else { return }
            editName = found.name
            editValue = found.value
            detailUpdateTask = nil
        }
    }

    private func refresh() {
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                let list = try await AppContainer.shared.runSvnInteractive(repoPath: repoPath, targetURL: isRemoteURL ? target : nil) { env, auth in
                    try await AppContainer.shared.svnProvider.listProperties(
                        repoPath: repoPath,
                        target: target,
                        environment: env,
                        auth: auth
                    )
                }
                self.properties = list
            } catch {
                AlertHelper.showError(error)
            }
        }
    }

    private func saveProperty() {
        guard let repoPath else { return }
        let propName = editName.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                _ = try await AppContainer.shared.svnProvider.setProperty(
                    repoPath: repoPath,
                    target: target,
                    name: propName,
                    value: editValue,
                    recursive: recursive
                )
                AppContainer.shared.triggerRefresh(repoPath: repoPath)
                refresh()
            } catch {
                AlertHelper.showError(error)
            }
        }
    }

    private func deleteProperty() {
        guard let repoPath else { return }
        let propName = editName.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                _ = try await AppContainer.shared.svnProvider.deleteProperty(
                    repoPath: repoPath,
                    target: target,
                    name: propName,
                    recursive: recursive
                )
                AppContainer.shared.triggerRefresh(repoPath: repoPath)
                refresh()
            } catch {
                AlertHelper.showError(error)
            }
        }
    }
}

private struct SvnPropertyRowView: View, Equatable {
    let prop: SvnPropertyEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(prop.name).font(.headline)
            Text(prop.value.replacingOccurrences(of: "\n", with: " "))
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
    }
}

// MARK: - SVN Relocate & Import & Blame & Compare & Patches

struct SvnRelocateWindowView: View {
    let repoPath: String

    @State private var fromURL: String = ""
    @State private var toURL: String = ""

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField(L("From URL (current):", "原仓库 URL："), text: $fromURL)
                    .textFieldStyle(.roundedBorder)
                TextField(L("To URL (new):", "新仓库 URL："), text: $toURL)
                    .textFieldStyle(.roundedBorder)
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button(L("Cancel", "取消")) {
                    AppContainer.shared.windowCoordinator.closeWindow(key: "svn-relocate-\(repoPath)")
                }
                .keyboardShortcut(.escape, modifiers: [])
                Button(L("Relocate", "重定位")) {
                    let from = fromURL
                    let to = toURL
                    AppContainer.shared.windowCoordinator.closeWindow(key: "svn-relocate-\(repoPath)")
                    AppContainer.shared.windowCoordinator.runTaskWithProgress(
                        title: L("SVN Relocate", "SVN 重定位"),
                        repoPath: repoPath
                    ) { onLine in
                        try await AppContainer.shared.runSvnInteractive(repoPath: repoPath, targetURL: to) { env, auth in
                            try await AppContainer.shared.svnProvider.relocate(
                                repoPath: repoPath,
                                fromURL: from,
                                toURL: to,
                                environment: env,
                                auth: auth,
                                onOutputLine: { line, _ in onLine(line) }
                            )
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(toURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()
        }
        .onAppear {
            Task {
                if let info = try? await AppContainer.shared.svnProvider.info(target: repoPath, workingDirectory: repoPath) {
                    fromURL = info.url
                    toURL = info.url
                }
            }
        }
    }
}

struct SvnImportWindowView: View {
    let initialLocalPath: String

    @State private var localPath: String
    @State private var remoteURL: String = ""
    @State private var message: String = "Initial import"
    @State private var noIgnore: Bool = false
    @State private var noAutoProps: Bool = false
    @State private var recentURLs: [String] = []

    init(initialLocalPath: String) {
        self.initialLocalPath = initialLocalPath
        _localPath = State(initialValue: initialLocalPath)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                HStack {
                    TextField(L("Local Folder:", "本地文件夹："), text: $localPath)
                        .textFieldStyle(.roundedBorder)
                    Button(L("Browse…", "浏览…")) {
                        if let u = AlertHelper.pickFolder(title: L("Select Folder to Import", "选择要导入的文件夹")) {
                            localPath = u.path
                        }
                    }
                }
                HStack {
                    TextField(L("Remote SVN URL:", "目标 SVN 地址："), text: $remoteURL)
                        .textFieldStyle(.roundedBorder)
                    if !recentURLs.isEmpty {
                        Picker("", selection: $remoteURL) {
                            Text(L("History…", "历史…")).tag("")
                            ForEach(recentURLs, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 110)
                    }
                }
                TextField(L("Commit Message:", "提交备注："), text: $message)
                    .textFieldStyle(.roundedBorder)
                Toggle(L("Include ignored files (--no-ignore)", "包含忽略文件 (--no-ignore)"), isOn: $noIgnore)
                Toggle(L("Disable auto-props (--no-auto-props)", "禁用自动属性 (--no-auto-props)"), isOn: $noAutoProps)
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button(L("Cancel", "取消")) {
                    AppContainer.shared.windowCoordinator.closeWindow(key: "svn-import-\(initialLocalPath)")
                }
                .keyboardShortcut(.escape, modifiers: [])
                Button(L("Import", "导入")) {
                    let lp = localPath
                    let url = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    let msg = message
                    let ni = noIgnore
                    let nap = noAutoProps
                    AppContainer.shared.recentHistoryStore.recordSvnRepoURL(url)
                    AppContainer.shared.windowCoordinator.closeWindow(key: "svn-import-\(initialLocalPath)")
                    AppContainer.shared.windowCoordinator.runTaskWithProgress(
                        title: L("SVN Import", "SVN 导入"),
                        repoPath: nil
                    ) { onLine in
                        try await AppContainer.shared.runSvnInteractive(repoPath: nil, targetURL: url) { env, auth in
                            try await AppContainer.shared.svnProvider.importDirectory(
                                localPath: lp,
                                remoteURL: url,
                                message: msg,
                                noIgnore: ni,
                                noAutoProps: nap,
                                environment: env,
                                auth: auth,
                                onOutputLine: { line, _ in onLine(line) }
                            )
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(remoteURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()
        }
        .onAppear { recentURLs = AppContainer.shared.recentHistoryStore.load().svnRepoURLs }
    }
}

struct SvnBlameDialogView: View {
    let repoPath: String
    let filePath: String

    @State private var revision: String = "HEAD"
    @State private var ignoreWhitespace: Bool = false
    @State private var hideAuthorAndDate: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Text(URL(fileURLWithPath: filePath).lastPathComponent)
                    .font(.headline)
                TextField(L("Revision or Range (e.g. HEAD or 1:HEAD):", "版本号或范围（如 HEAD 或 1:HEAD）："), text: $revision)
                    .textFieldStyle(.roundedBorder)
                Toggle(L("Ignore whitespace changes (-x -w)", "忽略空白字符 (-x -w)"), isOn: $ignoreWhitespace)
                Toggle(L("Hide author and timestamp", "隐藏作者和时间戳"), isOn: $hideAuthorAndDate)
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button(L("Cancel", "取消")) {
                    AppContainer.shared.windowCoordinator.closeWindow(key: "blame-dlg-\(filePath)")
                }
                .keyboardShortcut(.escape, modifiers: [])
                Button(L("Blame", "追溯")) {
                    let rev = revision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "HEAD" : revision
                    let iw = ignoreWhitespace
                    let hide = hideAuthorAndDate
                    AppContainer.shared.windowCoordinator.closeWindow(key: "blame-dlg-\(filePath)")
                    AppContainer.shared.windowCoordinator.openBlameResult(
                        repoPath: repoPath,
                        filePath: filePath,
                        revision: rev,
                        ignoreWhitespace: iw,
                        hideAuthorAndDate: hide,
                        vcsType: .svn
                    )
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()
        }
    }
}

struct SvnCompareRevisionsWindowView: View {
    let repoPath: String
    var initialRev1: String = "PREV"
    var initialRev2: String = "HEAD"

    @State private var rev1: String
    @State private var rev2: String
    @State private var changedPaths: [VcsChangedPath] = []
    @State private var selectedID: String?
    @State private var isLoading: Bool = false

    init(repoPath: String, initialRev1: String = "1", initialRev2: String = "HEAD") {
        self.repoPath = repoPath
        _rev1 = State(initialValue: initialRev1)
        _rev2 = State(initialValue: initialRev2)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField(L("From Revision:", "起始版本："), text: $rev1)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                Text("↔")
                TextField(L("To Revision:", "目标版本："), text: $rev2)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                Button(L("Compare", "开始对比")) { compare() }
                    .buttonStyle(.borderedProminent)
                Spacer()
            }
            .padding(10)

            Divider()

            TableColumnHeaderBar(
                columns: [
                    TableColumnSpec("", width: 24, alignment: .center),
                    TableColumnSpec(L("Path", "路径"))
                ],
                horizontalPadding: 12,
                spacing: 8
            )

            if isLoading && changedPaths.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if changedPaths.isEmpty {
                EmptyStateBox(
                    systemImage: "arrow.left.arrow.right.square",
                    title: L("No Differences", "没有差异文件"),
                    subtitle: L("Enter two SVN revision numbers (e.g. 10 and 25) and click Compare.", "输入两个 SVN 版本号（如 10 和 25）并点击「开始对比」。")
                )
            } else {
                List(changedPaths, selection: $selectedID) { ch in
                    SvnCompareRowView(ch: ch)
                        .equatable()
                        .contentShape(Rectangle())
                        .onListRowDoubleClick {
                            openDiff(for: ch)
                        }
                        .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 12))
                        .tag(ch.id)
                }
            }
        }
        .onAppear {
            if !rev1.isEmpty && !rev2.isEmpty && rev1 != "1" {
                compare()
            }
        }
    }

    private func compare() {
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                let res = try await AppContainer.shared.runSvnInteractive(repoPath: repoPath) { _, _ in
                    try await AppContainer.shared.svnProvider.diffRevisions(repoPath: repoPath, rev1: rev1, rev2: rev2)
                }
                self.changedPaths = res
            } catch {
                AlertHelper.showError(error)
            }
        }
    }

    private func openDiff(for ch: VcsChangedPath) {
        let abs = PathUtils.normalize("\(repoPath)/\(ch.path)")
        AppContainer.shared.windowCoordinator.openDiffBetweenRevisions(
            repoPath: repoPath,
            filePath: abs,
            leftRev: rev1,
            rightRev: rev2
        )
    }
}

private struct SvnCompareRowView: View, Equatable {
    let ch: VcsChangedPath

    var body: some View {
        HStack(spacing: 8) {
            VcsActionBadge(action: ch.action)
                .frame(width: 24)
            FileTypeIconView(path: ch.path)
            Text(ch.path)
                .font(.system(size: 12.5))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
    }
}

struct SvnCreatePatchWindowView: View {
    let repoPath: String
    let targetPaths: [String]

    @State private var destinationFile: String = ""
    @State private var revisionRange: String = ""

    var body: some View {
        VStack(spacing: 0) {
            Form {
                HStack {
                    TextField(L("Save Patch File:", "保存补丁文件："), text: $destinationFile)
                        .textFieldStyle(.roundedBorder)
                    Button(L("Browse…", "浏览…")) {
                        if let u = AlertHelper.saveFile(title: L("Save SVN Patch", "保存 SVN 补丁"), defaultName: "changes.patch") {
                            destinationFile = u.path
                        }
                    }
                }
                TextField(L("Revision range (optional, empty = WC changes):", "修订范围（可选，留空生成当前工作副本改动补丁）："), text: $revisionRange)
                    .textFieldStyle(.roundedBorder)
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button(L("Cancel", "取消")) {
                    AppContainer.shared.windowCoordinator.closeWindow(key: "svn-mkpatch-\(repoPath)")
                }
                .keyboardShortcut(.escape, modifiers: [])
                Button(L("Create Patch", "生成补丁")) {
                    let dest = destinationFile.trimmingCharacters(in: .whitespacesAndNewlines)
                    let rev = revisionRange.trimmingCharacters(in: .whitespacesAndNewlines)
                    AppContainer.shared.windowCoordinator.closeWindow(key: "svn-mkpatch-\(repoPath)")
                    AppContainer.shared.windowCoordinator.runTaskWithProgress(
                        title: L("Create Patch", "创建补丁"),
                        repoPath: repoPath
                    ) { _ in
                        try await AppContainer.shared.svnProvider.createPatch(
                            repoPath: repoPath,
                            paths: targetPaths,
                            destinationFile: dest,
                            revisionRange: rev.isEmpty ? nil : rev
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(destinationFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()
        }
    }
}

struct SvnApplyPatchWindowView: View {
    let repoPath: String

    @State private var patchFile: String = ""
    @State private var stripCount: Int = 0
    @State private var reverseDiff: Bool = false
    @State private var ignoreWhitespace: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                HStack {
                    TextField(L("Patch File:", "补丁文件："), text: $patchFile)
                        .textFieldStyle(.roundedBorder)
                    Button(L("Browse…", "浏览…")) {
                        if let u = AlertHelper.pickFile(title: L("Select Patch File", "选择补丁文件")) {
                            patchFile = u.path
                        }
                    }
                }
                Stepper(
                    value: $stripCount,
                    in: 0...10
                ) {
                    Text(L("Strip leading path components (--strip):", "剥离路径前缀层级 (--strip):") + " \(stripCount)")
                }
                Toggle(L("Reverse patch (--reverse-diff)", "反向应用补丁 (--reverse-diff)"), isOn: $reverseDiff)
                Toggle(L("Ignore whitespace (--ignore-whitespace)", "忽略空白字符"), isOn: $ignoreWhitespace)
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button(L("Dry Run", "模拟测试 (--dry-run)")) { runPatch(dryRun: true) }
                    .disabled(patchFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer()
                Button(L("Cancel", "取消")) {
                    AppContainer.shared.windowCoordinator.closeWindow(key: "svn-appatch-\(repoPath)")
                }
                .keyboardShortcut(.escape, modifiers: [])
                Button(L("Apply Patch", "应用补丁")) { runPatch(dryRun: false) }
                    .buttonStyle(.borderedProminent)
                    .disabled(patchFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()
        }
    }

    private func runPatch(dryRun: Bool) {
        let pf = patchFile.trimmingCharacters(in: .whitespacesAndNewlines)
        let strip = stripCount
        let rev = reverseDiff
        let iw = ignoreWhitespace
        if !dryRun {
            AppContainer.shared.windowCoordinator.closeWindow(key: "svn-appatch-\(repoPath)")
        }
        AppContainer.shared.windowCoordinator.runTaskWithProgress(
            title: dryRun ? L("Test Apply Patch", "模拟应用补丁") : L("Apply Patch", "应用补丁"),
            repoPath: dryRun ? nil : repoPath
        ) { onLine in
            try await AppContainer.shared.svnProvider.applyPatch(
                repoPath: repoPath,
                patchFile: pf,
                stripCount: strip,
                reverseDiff: rev,
                dryRun: dryRun,
                ignoreWhitespace: iw,
                onOutputLine: { line, _ in onLine(line) }
            )
        }
    }
}
