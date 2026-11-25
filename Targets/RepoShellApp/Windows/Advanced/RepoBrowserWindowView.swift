import SwiftUI
import RepoShellShared
import RepoShellVcs

struct RepoBrowserWindowView: View {
    let repoPath: String

    @State private var revision: String
    @State private var currentFolderPath: String = ""
    @State private var entries: [VcsTreeEntry] = []
    @State private var isLoading = false

    init(repoPath: String, initialRevision: String = "HEAD") {
        self.repoPath = repoPath
        _revision = State(initialValue: initialRevision)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(L("Revision:", "版本：")).foregroundColor(.secondary)
                RefSelectionPicker(repoPath: repoPath, selectedRef: $revision, allowHEAD: true)
                    .frame(maxWidth: 320)
                    .onChange(of: revision) { _ in Task { await reload() } }

                Spacer()
                Button(L("Export Revision…", "导出版本…")) {
                    AppContainer.shared.windowCoordinator.dispatch(action: .export, repoPath: repoPath, targetDir: repoPath, selectedPaths: [])
                }
                Button(L("Refresh", "刷新")) { Task { await reload() } }
            }
            .padding()

            // Breadcrumb bar
            HStack(spacing: 6) {
                Button("/") {
                    currentFolderPath = ""
                    Task { await reload() }
                }
                .buttonStyle(.link)
                let segments = currentFolderPath.split(separator: "/").map(String.init)
                ForEach(Array(segments.enumerated()), id: \.offset) { idx, seg in
                    Text("/")
                        .foregroundColor(.secondary)
                    Button(seg) {
                        currentFolderPath = segments[0...idx].joined(separator: "/")
                        Task { await reload() }
                    }
                    .buttonStyle(.link)
                }
                Spacer()
            }
            .padding(.horizontal)
            .padding(.bottom, 6)

            Divider()

            if isLoading && entries.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if entries.isEmpty {
                EmptyStateBox(systemImage: "folder", title: L("Empty Directory", "空目录"))
            } else {
                List(entries) { entry in
                    HStack(spacing: 10) {
                        Image(systemName: entry.kind == .tree ? "folder.fill" : (entry.kind == .submodule ? "shippingbox" : "doc.text"))
                            .foregroundColor(entry.kind == .tree ? .accentColor : .secondary)
                        Text(entry.name)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(entry.mode)
                            .font(.caption.monospaced())
                            .foregroundColor(.secondary)
                        Text(String(entry.objectHash.prefix(8)))
                            .font(.caption.monospaced())
                            .foregroundColor(.secondary)
                        if let size = entry.size {
                            Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(width: 72, alignment: .trailing)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        if entry.kind == .tree {
                            currentFolderPath = entry.path
                            Task { await reload() }
                        } else if entry.kind == .blob {
                            openFileInViewer(entry)
                        }
                    }
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
            }
        }
        .task { await reload() }
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        let rev = revision.isEmpty ? "HEAD" : revision
        let list = (try? await AppContainer.shared.gitProvider.listDirectory(repoPath: repoPath, path: currentFolderPath, revision: rev)) ?? []
        entries = list.sorted { a, b in
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
