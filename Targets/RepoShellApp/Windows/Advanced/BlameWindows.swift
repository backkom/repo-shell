import SwiftUI
import RepoShellShared
import RepoShellVcs

struct BlameDialogView: View {
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
                TextField(L("Revision (e.g. HEAD):", "版本（如 HEAD）："), text: $revision)
                Toggle(L("Ignore whitespace changes (-w)", "忽略空白字符 (-w)"), isOn: $ignoreWhitespace)
                Toggle(L("Hide author and timestamp", "不显示作者和时间戳"), isOn: $hideAuthorAndDate)
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
                    let rev = revision.isEmpty ? "HEAD" : revision
                    let iw = ignoreWhitespace
                    let hide = hideAuthorAndDate
                    AppContainer.shared.windowCoordinator.closeWindow(key: "blame-dlg-\(filePath)")
                    AppContainer.shared.windowCoordinator.openBlameResult(
                        repoPath: repoPath,
                        filePath: filePath,
                        revision: rev,
                        ignoreWhitespace: iw,
                        hideAuthorAndDate: hide
                    )
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()
        }
    }
}

struct BlameResultWindowView: View {
    let repoPath: String
    let filePath: String
    let revision: String
    let ignoreWhitespace: Bool
    let hideAuthorAndDate: Bool
    var vcsType: VcsType = .git

    @State private var lines: [VcsBlameLine] = []
    @State private var filteredLines: [VcsBlameLine] = []
    @State private var lineIndexByID: [Int: VcsBlameLine] = [:]
    @State private var selectedLine: Int?
    @State private var displayedLineID: Int?
    @State private var detailUpdateTask: Task<Void, Never>?
    @State private var filterText: String = ""
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                FileTypeIconView(path: filePath)
                Text(PathUtils.relativePath(of: filePath, inside: repoPath) ?? filePath)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(revision)
                    .font(.caption.monospaced().weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.12))
                    .foregroundColor(.accentColor)
                    .cornerRadius(4)

                Spacer()

                SearchInputField(
                    placeholder: L("Filter code / author / commit…", "筛选代码 / 作者 / 提交…"),
                    text: $filterText,
                    width: 220
                )

                Button(L("Show File Log", "显示文件日志")) {
                    AppContainer.shared.windowCoordinator.dispatch(action: .showLog, repoPath: repoPath, targetDir: repoPath, selectedPaths: [filePath])
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            TableColumnHeaderBar(
                columns: headerColumns,
                horizontalPadding: 10,
                spacing: 8
            )

            if isLoading && lines.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredLines.isEmpty {
                EmptyStateBox(systemImage: "text.magnifyingglass", title: L("No Matching Lines", "无匹配代码行"))
            } else {
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filteredLines) { line in
                            BlameLineRowView(
                                line: line,
                                isSelected: selectedLine == line.id,
                                hideAuthorAndDate: hideAuthorAndDate
                            )
                            .equatable()
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedLine = line.id
                            }
                            .contextMenu {
                                Button(L("Copy Commit SHA", "拷贝提交版本号")) {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(line.commitHash, forType: .string)
                                }
                                Button(L("Copy Line Content", "拷贝代码行")) {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(line.content, forType: .string)
                                }
                                Divider()
                                Button(L("Show File Log", "显示文件日志")) {
                                    AppContainer.shared.windowCoordinator.dispatch(action: .showLog, repoPath: repoPath, targetDir: repoPath, selectedPaths: [filePath])
                                }
                                if vcsType == .git {
                                    Button(L("Diff Commit with Previous", "对比该提交前后差异")) {
                                        AppContainer.shared.windowCoordinator.openCompareRevisions(repoPath: repoPath, rev1: "\(line.commitHash)^", rev2: line.commitHash)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: selectedLine) { newVal in
                    scheduleFooterDetailUpdate(for: newVal)
                }
            }

            Divider()

            HStack {
                Text(String(format: L("%d lines", "共 %d 行"), filteredLines.count))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                if let sel = displayedLineID, let found = lineIndexByID[sel] {
                    Text("·")
                        .foregroundColor(.secondary)
                    Text("\(found.shortHash) — \(found.author): \(found.summary)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .onChange(of: filterText) { _ in
            recomputeFilteredLines()
        }
        .onDisappear {
            detailUpdateTask?.cancel()
            detailUpdateTask = nil
        }
        .task {
            isLoading = true
            defer { isLoading = false }
            do {
                let loaded: [VcsBlameLine]
                if vcsType == .svn {
                    loaded = try await AppContainer.shared.runSvnInteractive(repoPath: repoPath) { env, auth in
                        try await AppContainer.shared.svnProvider.svnBlame(
                            repoPath: repoPath,
                            target: filePath,
                            revision: revision == "WORKING" ? nil : revision,
                            ignoreWhitespace: ignoreWhitespace,
                            environment: env,
                            auth: auth
                        )
                    }
                } else {
                    loaded = try await AppContainer.shared.gitProvider.blame(
                        repoPath: repoPath,
                        path: filePath,
                        revision: revision,
                        ignoreWhitespace: ignoreWhitespace
                    )
                }
                lines = loaded
                lineIndexByID = Dictionary(loaded.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                recomputeFilteredLines()
            } catch {
                AlertHelper.showError(error)
            }
        }
    }

    private func recomputeFilteredLines() {
        let q = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            filteredLines = lines
            return
        }
        filteredLines = lines.filter {
            $0.content.localizedCaseInsensitiveContains(q)
            || $0.author.localizedCaseInsensitiveContains(q)
            || $0.shortHash.localizedCaseInsensitiveContains(q)
            || $0.summary.localizedCaseInsensitiveContains(q)
        }
    }

    private func scheduleFooterDetailUpdate(for lineID: Int?) {
        detailUpdateTask?.cancel()
        guard lineID != displayedLineID else {
            detailUpdateTask = nil
            return
        }
        detailUpdateTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 25_000_000)
            guard !Task.isCancelled else { return }
            displayedLineID = lineID
            detailUpdateTask = nil
        }
    }

    private var headerColumns: [TableColumnSpec] {
        var cols: [TableColumnSpec] = [
            TableColumnSpec(L("Line", "行"), width: 44, alignment: .trailing),
            TableColumnSpec(L("Commit", "提交"), width: 72)
        ]
        if !hideAuthorAndDate {
            cols.append(TableColumnSpec(L("Author", "作者"), width: 100))
            cols.append(TableColumnSpec(L("Date", "日期"), width: 78))
        }
        cols.append(TableColumnSpec(L("Code", "代码")))
        return cols
    }
}

private struct BlameLineRowView: View, Equatable {
    let line: VcsBlameLine
    let isSelected: Bool
    let hideAuthorAndDate: Bool

    var body: some View {
        let commitColor = Self.colorForHash(line.commitHash)
        HStack(spacing: 8) {
            Text("\(line.lineNumber)")
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 44, alignment: .trailing)

            HStack(spacing: 4) {
                Circle()
                    .fill(commitColor)
                    .frame(width: 6, height: 6)
                Text(line.shortHash)
                    .font(.caption.monospaced())
                    .foregroundColor(commitColor)
            }
            .frame(width: 72, alignment: .leading)

            if !hideAuthorAndDate {
                Text(line.author)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 100, alignment: .leading)
                    .lineLimit(1)
                Text(line.date.map { SharedDateFormatters.numericDateOnly.string(from: $0) } ?? "")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                    .frame(width: 78, alignment: .leading)
            }

            Text(line.content)
                .font(.system(size: 12, design: .monospaced))
                .fixedSize(horizontal: true, vertical: false)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
        .frame(minWidth: 700, alignment: .leading)
        .background(
            isSelected
                ? Color.accentColor.opacity(0.18)
                : (line.lineNumber % 2 == 0 ? Color(nsColor: .alternatingContentBackgroundColors.last ?? .controlBackgroundColor).opacity(0.45) : Color.clear)
        )
        .help("\(line.commitHash) • \(line.author)\n\(line.summary)")
    }

    private static func colorForHash(_ hash: String) -> Color {
        let colors: [Color] = [.blue, .purple, .orange, .teal, .pink, .indigo, .green]
        let val = hash.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return colors[val % colors.count]
    }
}
