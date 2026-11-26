import SwiftUI
import RepoShellShared
import RepoShellVcs
import RepoShellServices

enum SvnPrefSubtab: String, CaseIterable {
    case settings
    case contextMenu
    case globalIgnores
    case configFile
    case history
}

struct SvnTabView: View {
    @ObservedObject private var repoManager = AppContainer.shared.repositoryManager
    @State private var subtab: SvnPrefSubtab = .settings
    @State private var svnVersionText: String = ""
    @State private var svnadminStatusText: String = ""
    @State private var globalIgnoresText: String = ""
    @State private var rawConfigText: String = ""
    @State private var historyData = RecentHistoryData()
    @State private var statusMessage: String = ""

    private var sidebarItems: [VcsSidebarNavItem<SvnPrefSubtab>] {
        [
            VcsSidebarNavItem(id: .settings, title: L("Settings", "常规设置"), systemImage: "gearshape"),
            VcsSidebarNavItem(id: .contextMenu, title: L("Context Menu", "右键菜单"), systemImage: "list.bullet.rectangle"),
            VcsSidebarNavItem(id: .globalIgnores, title: L("Global Ignores", "全局忽略"), systemImage: "eye.slash"),
            VcsSidebarNavItem(id: .configFile, title: "~/.subversion/config", systemImage: "doc.text"),
            VcsSidebarNavItem(id: .history, title: L("History", "最近历史"), systemImage: "clock.arrow.circlepath"),
        ]
    }

    var body: some View {
        HStack(spacing: 0) {
            VcsPrefSidebar(items: sidebarItems, selection: $subtab)

            Divider()

            Group {
                switch subtab {
                case .settings:
                    settingsView
                case .contextMenu:
                    contextMenuView
                case .globalIgnores:
                    globalIgnoresView
                case .configFile:
                    configFileView
                case .history:
                    historyView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear(perform: loadAll)
    }

    private var contextMenuView: some View {
        TopLevelContextMenuView(
            sectionTitle: L("SVN top-level context menu actions", "SVN 右键一级菜单常用操作"),
            descriptionText: L(
                "Selected SVN actions appear directly in Finder's top-level context menu for SVN working copies.",
                "勾选的 SVN 操作将直接显示在访达右键一级菜单中，其余操作收纳在 RepoShell 子菜单内。"
            ),
            promotableActions: AppPreferences.promotableSvnMenuActions,
            defaultActions: AppPreferences.defaultSvnTopLevelMenuActions,
            actionsKeyPath: \.svnTopLevelMenuActions
        )
    }

    private var settingsView: some View {
        Form {
            Section(header: Text(L("SVN Executable", "SVN 可执行程序"))) {
                Picker(L("SVN Source:", "SVN 来源："), selection: prefBinding(\.useBundledSvn)) {
                    Text(L("Auto-detect / External SVN", "自动探测 / 外部 SVN")).tag(false)
                    Text(L("Bundled SVN (Reserved Slot)", "内置 SVN（预留槽位）")).tag(true)
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()

                HStack {
                    TextField(
                        L("Custom svn path (optional, e.g. /opt/homebrew/bin/svn)", "自定义 svn 路径（可选，如 /opt/homebrew/bin/svn）"),
                        text: prefBinding(\.externalSvnPath)
                    )
                    .textFieldStyle(.roundedBorder)
                    Button(L("Browse…", "浏览…")) {
                        if let url = AlertHelper.pickFile(title: L("Select svn executable", "选择 svn 可执行文件")) {
                            repoManager.updatePreferences { $0.externalSvnPath = url.path }
                            testSvnVersion()
                        }
                    }
                }

                HStack {
                    TextField(
                        L("DYLD_LIBRARY_PATH (optional custom dylib folder)", "DYLD_LIBRARY_PATH（可选自定义动态库目录）"),
                        text: prefBinding(\.svnDylibPath)
                    )
                    .textFieldStyle(.roundedBorder)
                    Button(L("Browse…", "浏览…")) {
                        if let url = AlertHelper.pickFolder(title: L("Select SVN dylib directory", "选择 SVN 动态库目录")) {
                            repoManager.updatePreferences { $0.svnDylibPath = url.path }
                            testSvnVersion()
                        }
                    }
                }

                HStack(spacing: 12) {
                    Button(L("Test SVN", "检测 SVN 版本")) {
                        testSvnVersion()
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        if !svnVersionText.isEmpty {
                            Text(svnVersionText)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        if !svnadminStatusText.isEmpty {
                            Text(svnadminStatusText)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            Section(header: Text(L("Working Copy & Log Options", "工作副本与日志选项"))) {
                HStack {
                    Text(L("Show Log entries per page:", "日志每次加载条数："))
                    Stepper(
                        value: prefBinding(\.svnLogLimit),
                        in: 20...1000,
                        step: 20
                    ) {
                        Text("\(repoManager.config.preferences.svnLogLimit)")
                            .monospacedDigit()
                            .frame(minWidth: 44, alignment: .trailing)
                    }
                }

                Toggle(
                    L("Use --force when deleting items in SVN", "执行 SVN 删除时默认附加 --force"),
                    isOn: prefBinding(\.svnDeleteForce)
                )
            }
        }
        .formStyle(.grouped)
    }

    private var globalIgnoresView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L(
                    "Patterns below sync with [miscellany] global-ignores in ~/.subversion/config (one pattern per line or space-separated).",
                    "以下规则将同步写入 ~/.subversion/config 的 [miscellany] global-ignores（支持每行或空格分隔）。"
                ))
                .font(.caption)
                .foregroundColor(.secondary)
                Spacer()
            }
            TextEditor(text: $globalIgnoresText)
                .font(.system(.body, design: .monospaced))
                .border(Color.secondary.opacity(0.25))
            HStack {
                if !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundColor(.green)
                }
                Spacer()
                Button(L("Reload", "重新加载")) { loadGlobalIgnores() }
                Button(L("Save", "保存")) {
                    let tokens = globalIgnoresText
                        .components(separatedBy: CharacterSet.whitespacesAndNewlines)
                        .filter { !$0.isEmpty }
                    do {
                        try AppContainer.shared.svnProvider.writeGlobalIgnores(tokens)
                        loadRawConfig()
                        statusMessage = L("Saved global-ignores", "已保存全局忽略规则")
                    } catch {
                        AlertHelper.showError(error)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding()
    }

    private var configFileView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(SvnProvider.subversionConfigFileURL().path)
                .font(.caption)
                .foregroundColor(.secondary)
            TextEditor(text: $rawConfigText)
                .font(.system(.body, design: .monospaced))
                .border(Color.secondary.opacity(0.25))
            HStack {
                Spacer()
                Button(L("Reload", "重新加载")) { loadRawConfig() }
                Button(L("Save", "保存")) {
                    do {
                        try AppContainer.shared.svnProvider.writeRawSubversionConfig(rawConfigText)
                        loadGlobalIgnores()
                    } catch {
                        AlertHelper.showError(error)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding()
    }

    private var historyView: some View {
        VStack(spacing: 12) {
            HStack {
                Text(L(
                    "Recent SVN Commit Messages (\(historyData.svnCommitMessages.count))",
                    "最近 SVN 提交信息 (\(historyData.svnCommitMessages.count))"
                ))
                .font(.headline)
                Spacer()
                Button(L("Clear", "清除")) {
                    AppContainer.shared.recentHistoryStore.clearSvnCommitMessages()
                    historyData = AppContainer.shared.recentHistoryStore.load()
                }
            }
            List(historyData.svnCommitMessages, id: \.self) { msg in
                Text(msg).lineLimit(2)
            }
            .frame(height: 120)

            HStack {
                Text(L(
                    "Recent SVN Repository URLs (\(historyData.svnRepoURLs.count))",
                    "最近 SVN 版本库地址 (\(historyData.svnRepoURLs.count))"
                ))
                .font(.headline)
                Spacer()
                Button(L("Clear", "清除")) {
                    AppContainer.shared.recentHistoryStore.clearSvnRepoURLs()
                    historyData = AppContainer.shared.recentHistoryStore.load()
                }
            }
            List(historyData.svnRepoURLs, id: \.self) { url in
                Text(url).lineLimit(1)
            }
            .frame(height: 120)
        }
        .padding()
    }

    private func prefBinding<T>(_ keyPath: WritableKeyPath<AppPreferences, T>) -> Binding<T> {
        Binding(
            get: { repoManager.config.preferences[keyPath: keyPath] },
            set: { newValue in
                repoManager.updatePreferences { prefs in
                    prefs[keyPath: keyPath] = newValue
                }
            }
        )
    }

    private func loadAll() {
        testSvnVersion()
        loadGlobalIgnores()
        loadRawConfig()
        historyData = AppContainer.shared.recentHistoryStore.load()
    }

    private func loadGlobalIgnores() {
        let items = AppContainer.shared.svnProvider.readGlobalIgnores()
        globalIgnoresText = items.joined(separator: "\n")
    }

    private func loadRawConfig() {
        rawConfigText = AppContainer.shared.svnProvider.readRawSubversionConfig()
    }

    private func testSvnVersion() {
        do {
            let exe = try SvnExecutableResolver.resolve(preferences: repoManager.config.preferences)
            let ver = SvnExecutableResolver.versionString(of: exe.executableURL, extraEnvironment: exe.extraEnvironment) ?? "Unknown"
            let src = exe.isBundled ? L("Bundled", "内置") : exe.executableURL.path
            svnVersionText = "svn \(ver) (\(src))"
            if let admin = exe.svnadminURL {
                svnadminStatusText = "svnadmin: \(admin.path)"
            } else {
                svnadminStatusText = L("svnadmin not found", "未检测到 svnadmin")
            }
        } catch {
            svnVersionText = error.localizedDescription
            svnadminStatusText = ""
        }
    }
}
