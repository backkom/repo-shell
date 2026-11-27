import SwiftUI
import RepoShellShared
import RepoShellVcs

struct RepoBrowserWindowView: View {
    let repoPath: String

    @State private var revision: String
    @State private var currentFolderPath: String = ""
    @State private var entries: [VcsTreeEntry] = []
    @State private var selectedEntryID: String?
    @State private var folderCache: [String: [VcsTreeEntry]] = [:]
    @State private var expandedFolders: Set<String> = [""]
    @State private var isLoading = false
    @State private var reloadTask: Task<Void, Never>?

    init(repoPath: String, initialRevision: String = "HEAD") {
        self.repoPath = repoPath
        _revision = State(initialValue: initialRevision)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(L("Revision:", "版本："))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                RefSelectionPicker(repoPath: repoPath, selectedRef: $revision, allowHEAD: true)
                    .frame(maxWidth: 320)
                    .onChange(of: revision) { _ in
                        folderCache = [:]
                        selectedEntryID = nil
                        entries = []
                        startReload()
                    }

                Spacer()
                Button(L("Export Revision…", "导出版本…")) {
                    AppContainer.shared.windowCoordinator.dispatch(action: .export, repoPath: repoPath, targetDir: repoPath, selectedPaths: [])
                }
                Button {
                    folderCache = [:]
                    startReload()
                } label: {
                    if isLoading {
                        ProgressView().controlSize(.small).frame(width: 14, height: 14)
                    } else {
                        Label(L("Refresh", "刷新"), systemImage: "arrow.clockwise")
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // Breadcrumb bar
            HStack(spacing: 5) {
                Image(systemName: "folder.fill")
                    .font(.caption)
                    .foregroundColor(.accentColor)
                Button(URL(fileURLWithPath: repoPath).lastPathComponent) {
                    selectFolder("")
                }
                .buttonStyle(.link)
                let segments = currentFolderPath.split(separator: "/").map(String.init)
                ForEach(Array(segments.enumerated()), id: \.offset) { idx, seg in
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Button(seg) {
                        selectFolder(segments[0...idx].joined(separator: "/"))
                    }
                    .buttonStyle(.link)
                }
                Spacer()
            }
            .font(.system(size: 12))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))

            Divider()

            HSplitView {
                // Left Pane: Directory Tree
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        GitFolderTreeRow(
                            folderPath: "",
                            name: URL(fileURLWithPath: repoPath).lastPathComponent,
                            depth: 0,
                            currentFolderPath: currentFolderPath,
                            expandedFolders: $expandedFolders,
                            folderCache: folderCache,
                            onSelect: selectFolder,
                            onToggleExpand: toggleExpand
                        )
                    }
                    .padding(6)
                }
                .frame(minWidth: 185, idealWidth: 225, maxWidth: 320)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))

                // Right Pane: Folder Contents Table
                VStack(spacing: 0) {
                    TableColumnHeaderBar(
                        columns: [
                            TableColumnSpec(L("Name", "名称")),
                            TableColumnSpec(L("Mode", "权限"), width: 58),
                            TableColumnSpec("SHA-1", width: 72),
                            TableColumnSpec(L("Size", "大小"), width: 76, alignment: .trailing)
                        ],
                        horizontalPadding: 12,
                        spacing: 10
                    )

                    if isLoading && entries.isEmpty {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if entries.isEmpty {
                        EmptyStateBox(systemImage: "folder", title: L("Empty Directory", "空目录"))
                    } else {
                        List(entries, selection: $selectedEntryID) { entry in
                            GitRepoBrowserRowView(entry: entry)
                                .equatable()
                                .contentShape(Rectangle())
                                .onListRowDoubleClick {
                                    if entry.kind == .tree {
                                        selectFolder(entry.path)
                                    } else if entry.kind == .blob {
                                        openFileInViewer(entry)
                                    }
                                }
                                .tag(entry.id)
                                .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 12))
                                .contextMenu {
                                if entry.kind == .blob {
                                    Button(L("Open", "打开")) { openFileInViewer(entry) }
                                    Button(L("Save Revision As…", "保存版本至…")) { saveFileAs(entry) }
                                    Button(L("Diff with Working Tree", "与工作目录进行比较")) {
                                        let abs = PathUtils.normalize("\(repoPath)/\(entry.path)")
                                        AppContainer.shared.windowCoordinator.openDiffWithRevision(
                                            repoPath: repoPath,
                                            filePath: abs,
                                            revision: revision,
                                            rightTitle: L("Working Tree", "工作区")
                                        )
                                    }
                                    Button(L("Replace Working Copy File…", "替换工作目录中的项目…")) {
                                        let abs = PathUtils.normalize("\(repoPath)/\(entry.path)")
                                        if AlertHelper.confirm(title: L("Replace File", "替换文件"), message: entry.path) {
                                            Task {
                                                try? await AppContainer.shared.gitProvider.extractFile(repoPath: repoPath, path: entry.path, revision: revision, to: abs)
                                                AppContainer.shared.triggerRefresh(repoPath: repoPath)
                                            }
                                        }
                                    }
                                    Divider()
                                }
                                Button(L("Show Log", "显示日志")) {
                                    let abs = PathUtils.normalize("\(repoPath)/\(entry.path)")
                                    AppContainer.shared.windowCoordinator.dispatch(action: .showLog, repoPath: repoPath, targetDir: repoPath, selectedPaths: [abs])
                                }
                                if entry.kind == .blob {
                                    Button(L("Blame…", "追溯…")) {
                                        let abs = PathUtils.normalize("\(repoPath)/\(entry.path)")
                                        AppContainer.shared.windowCoordinator.openBlameResult(repoPath: repoPath, filePath: abs, revision: revision, ignoreWhitespace: false, hideAuthorAndDate: false)
                                    }
                                }
                                Button(L("Copy Path", "拷贝路径到剪贴板")) {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(entry.path, forType: .string)
                                }
                                Button(L("Copy SHA-1", "拷贝 SHA-1 到剪贴板")) {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(entry.objectHash, forType: .string)
                                }
                            }
                        }
                        .listStyle(.inset)
                        .environment(\.defaultMinListRowHeight, 22)
                    }
                }
            }
        }
        .task { startReload() }
        .onDisappear {
            reloadTask?.cancel()
            reloadTask = nil
        }
    }

    private func selectFolder(_ path: String) {
        if currentFolderPath != path {
            selectedEntryID = nil
            entries = []
        }
        currentFolderPath = path
        if !path.isEmpty {
            var accum = ""
            for part in path.split(separator: "/").map(String.init) {
                accum = accum.isEmpty ? part : "\(accum)/\(part)"
                expandedFolders.insert(accum)
            }
        }
        expandedFolders.insert("")
        startReload()
    }

    private func startReload() {
        reloadTask?.cancel()
        reloadTask = Task {
            await reload()
        }
    }

    private func toggleExpand(_ path: String) {
        if expandedFolders.contains(path) {
            expandedFolders.remove(path)
        } else {
            expandedFolders.insert(path)
            if folderCache[path] == nil {
                Task { await loadChildren(for: path) }
            }
        }
    }

    private func loadChildren(for path: String) async {
        let rev = revision.isEmpty ? "HEAD" : revision
        let list = (try? await AppContainer.shared.gitProvider.listDirectory(repoPath: repoPath, path: path, revision: rev)) ?? []
        let sorted = sortEntries(list)
        folderCache[path] = sorted.filter { $0.kind == .tree }
    }

    private func reload() async {
        let targetFolder = currentFolderPath
        let rev = revision.isEmpty ? "HEAD" : revision
        isLoading = true
        defer {
            if !Task.isCancelled && currentFolderPath == targetFolder {
                isLoading = false
            }
        }
        let list = (try? await AppContainer.shared.gitProvider.listDirectory(repoPath: repoPath, path: targetFolder, revision: rev)) ?? []
        let activeRev = revision.isEmpty ? "HEAD" : revision
        guard !Task.isCancelled, currentFolderPath == targetFolder, activeRev == rev else { return }
        let sorted = sortEntries(list)
        entries = sorted
        folderCache[targetFolder] = sorted.filter { $0.kind == .tree }
    }

    private func sortEntries(_ list: [VcsTreeEntry]) -> [VcsTreeEntry] {
        list.sorted { a, b in
            if a.kind == .tree && b.kind != .tree { return true }
            if a.kind != .tree && b.kind == .tree { return false }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    private func openFileInViewer(_ entry: VcsTreeEntry) {
        Task {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(revision.prefix(7))_\(entry.name)")
            try? await AppContainer.shared.gitProvider.extractFile(repoPath: repoPath, path: entry.path, revision: revision, to: tmp.path)
            NSWorkspace.shared.open(tmp)
        }
    }

    private func saveFileAs(_ entry: VcsTreeEntry) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = entry.name
        if panel.runModal() == .OK, let dest = panel.url {
            Task {
                try? await AppContainer.shared.gitProvider.extractFile(repoPath: repoPath, path: entry.path, revision: revision, to: dest.path)
            }
        }
    }
}

private struct GitRepoBrowserRowView: View, Equatable {
    let entry: VcsTreeEntry

    var body: some View {
        HStack(spacing: 10) {
            if entry.kind == .submodule {
                Image(systemName: "shippingbox")
                    .foregroundColor(.teal)
                    .frame(width: 15, height: 15)
            } else {
                FileTypeIconView(path: entry.name, isDirectory: entry.kind == .tree)
            }
            Text(entry.name)
                .font(.system(size: 12.5))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.mode)
                .font(.caption.monospaced())
                .foregroundColor(.secondary)
                .frame(width: 58, alignment: .leading)
            Text(String(entry.objectHash.prefix(8)))
                .font(.caption.monospaced())
                .foregroundColor(.secondary)
                .frame(width: 72, alignment: .leading)
            Text(entry.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "")
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 76, alignment: .trailing)
        }
    }
}

private struct GitFolderTreeRow: View {
    let folderPath: String
    let name: String
    let depth: Int
    let currentFolderPath: String
    @Binding var expandedFolders: Set<String>
    let folderCache: [String: [VcsTreeEntry]]
    let onSelect: (String) -> Void
    let onToggleExpand: (String) -> Void

    var body: some View {
        let isSelected = currentFolderPath == folderPath
        let isExpanded = expandedFolders.contains(folderPath)
        let children = folderCache[folderPath] ?? []

        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Button {
                    onToggleExpand(folderPath)
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
                onSelect(folderPath)
            }

            if isExpanded {
                ForEach(children) { child in
                    GitFolderTreeRow(
                        folderPath: child.path,
                        name: child.name,
                        depth: depth + 1,
                        currentFolderPath: currentFolderPath,
                        expandedFolders: $expandedFolders,
                        folderCache: folderCache,
                        onSelect: onSelect,
                        onToggleExpand: onToggleExpand
                    )
                }
            }
        }
    }
}
