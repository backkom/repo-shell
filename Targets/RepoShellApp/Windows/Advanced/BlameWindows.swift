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

    @State private var lines: [VcsBlameLine] = []
    @State private var selectedLine: Int?
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(PathUtils.relativePath(of: filePath, inside: repoPath) ?? filePath)
                    .font(.headline)
                Text("(\(revision))")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                Button(L("Show File Log", "显示文件日志")) {
                    AppContainer.shared.windowCoordinator.dispatch(action: .showLog, repoPath: repoPath, targetDir: repoPath, selectedPaths: [filePath])
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if isLoading && lines.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(lines) { line in
                            HStack(spacing: 8) {
                                Text("\(line.lineNumber)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundColor(.secondary)
                                    .frame(width: 44, alignment: .trailing)

                                Text(line.shortHash)
                                    .font(.caption.monospaced())
                                    .foregroundColor(colorForHash(line.commitHash))
                                    .frame(width: 68, alignment: .leading)

                                if !hideAuthorAndDate {
                                    Text(line.author)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .frame(width: 100, alignment: .leading)
                                        .lineLimit(1)
                                    Text(line.date?.formatted(date: .numeric, time: .omitted) ?? "")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .frame(width: 78, alignment: .leading)
                                }

                                Text(line.content)
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 1)
                            .background(selectedLine == line.id ? Color.accentColor.opacity(0.14) : Color.clear)
                            .help("\(line.commitHash)\n\(line.summary)")
                            .onTapGesture {
                                selectedLine = line.id
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .task {
            isLoading = true
            defer { isLoading = false }
            do {
                lines = try await AppContainer.shared.gitProvider.blame(
                    repoPath: repoPath,
                    path: filePath,
                    revision: revision,
                    ignoreWhitespace: ignoreWhitespace
                )
            } catch {
                AlertHelper.showError(error)
            }
        }
    }

    private func colorForHash(_ hash: String) -> Color {
        let colors: [Color] = [.blue, .purple, .orange, .teal, .pink, .indigo, .green]
        let val = hash.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return colors[val % colors.count]
    }
}
