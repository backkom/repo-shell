import SwiftUI
import RepoShellShared

enum GitPrefSubtab: String, CaseIterable {
    case user
    case contextMenu
    case gitconfig
    case globalIgnore
    case history
}

struct GitTabView: View {
    @State private var subtab: GitPrefSubtab = .user
    @State private var userName: String = ""
    @State private var userEmail: String = ""
    @State private var gitconfigText: String = ""
    @State private var globalIgnorePath: String = ""
    @State private var globalIgnoreText: String = ""
    @State private var historyData = RecentHistoryData()
    @State private var statusMessage: String = ""

    private var sidebarItems: [VcsSidebarNavItem<GitPrefSubtab>] {
        [
            VcsSidebarNavItem(id: .user, title: L("User", "用户"), systemImage: "person.crop.circle"),
            VcsSidebarNavItem(id: .contextMenu, title: L("Context Menu", "右键菜单"), systemImage: "list.bullet.rectangle"),
            VcsSidebarNavItem(id: .gitconfig, title: ".gitconfig", systemImage: "doc.text"),
            VcsSidebarNavItem(id: .globalIgnore, title: L("Global .gitignore", "全局 .gitignore"), systemImage: "eye.slash"),
            VcsSidebarNavItem(id: .history, title: L("History", "最近历史"), systemImage: "clock.arrow.circlepath"),
        ]
    }

    var body: some View {
        HStack(spacing: 0) {
            VcsPrefSidebar(items: sidebarItems, selection: $subtab)

            Divider()

            Group {
                switch subtab {
                case .user:
                    userView
                case .contextMenu:
                    contextMenuView
                case .gitconfig:
                    gitconfigView
                case .globalIgnore:
                    globalIgnoreView
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
            sectionTitle: L("Git top-level context menu actions", "Git 右键一级菜单常用操作"),
            descriptionText: L(
                "Selected actions appear directly in Finder's top-level context menu; remaining actions stay in the RepoShell submenu.",
                "勾选的操作将直接显示在访达右键一级菜单中，其余操作收纳在 RepoShell 子菜单内。"
            ),
            promotableActions: AppPreferences.promotableMenuActions,
            defaultActions: AppPreferences.defaultTopLevelMenuActions,
            actionsKeyPath: \.topLevelMenuActions
        )
    }

    private var userView: some View {
        Form {
            Section(header: Text(L("Name and Email will be used in new Git commits.", "姓名和 Email 地址将用在新的 Git 提交中。"))) {
                TextField(L("Name:", "姓名："), text: $userName)
                TextField(L("Email:", "Email 地址："), text: $userEmail)
                HStack {
                    Button(L("Save User Info", "保存用户信息")) {
                        Task {
                            do {
                                let gp = AppContainer.shared.gitProvider
                                try await gp.setGlobalConfigValue(key: "user.name", value: userName)
                                try await gp.setGlobalConfigValue(key: "user.email", value: userEmail)
                                statusMessage = L("Saved to ~/.gitconfig", "已保存至 ~/.gitconfig")
                                loadGitConfig()
                            } catch {
                                AlertHelper.showError(error)
                            }
                        }
                    }
                    if !statusMessage.isEmpty {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var gitconfigView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gitconfig").path)
                .font(.caption)
                .foregroundColor(.secondary)
            TextEditor(text: $gitconfigText)
                .font(.system(.body, design: .monospaced))
                .border(Color.secondary.opacity(0.25))
            HStack {
                Spacer()
                Button(L("Reload", "重新加载")) { loadGitConfig() }
                Button(L("Save", "保存")) {
                    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gitconfig")
                    do {
                        try gitconfigText.write(to: url, atomically: true, encoding: .utf8)
                        loadUser()
                    } catch {
                        AlertHelper.showError(error)
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding()
    }

    private var globalIgnoreView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("File:", "文件：") + " \(globalIgnorePath)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
            TextEditor(text: $globalIgnoreText)
                .font(.system(.body, design: .monospaced))
                .border(Color.secondary.opacity(0.25))
            HStack {
                Spacer()
                Button(L("Reload", "重新加载")) { loadGlobalIgnore() }
                Button(L("Save", "保存")) {
                    let target = globalIgnorePath
                    do {
                        try globalIgnoreText.write(toFile: target, atomically: true, encoding: .utf8)
                        Task {
                            try? await AppContainer.shared.gitProvider.setGlobalConfigValue(key: "core.excludesfile", value: target)
                        }
                    } catch {
                        AlertHelper.showError(error)
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding()
    }

    private var historyView: some View {
        VStack(spacing: 12) {
            HStack {
                Text(L("Recent Commit Messages (\(historyData.commitMessages.count))", "最近提交信息 (\(historyData.commitMessages.count))"))
                    .font(.headline)
                Spacer()
                Button(L("Clear", "清除")) {
                    AppContainer.shared.recentHistoryStore.clearCommitMessages()
                    historyData = AppContainer.shared.recentHistoryStore.load()
                }
            }
            List(historyData.commitMessages, id: \.self) { msg in
                Text(msg).lineLimit(2)
            }
            .frame(height: 120)

            HStack {
                Text(L("Recent Repository URLs (\(historyData.remoteURLs.count))", "最近版本库地址 (\(historyData.remoteURLs.count))"))
                    .font(.headline)
                Spacer()
                Button(L("Clear", "清除")) {
                    AppContainer.shared.recentHistoryStore.clearRemoteURLs()
                    historyData = AppContainer.shared.recentHistoryStore.load()
                }
            }
            List(historyData.remoteURLs, id: \.self) { url in
                Text(url).lineLimit(1)
            }
            .frame(height: 120)
        }
        .padding()
    }

    private func loadAll() {
        loadUser()
        loadGitConfig()
        loadGlobalIgnore()
        historyData = AppContainer.shared.recentHistoryStore.load()
    }

    private func loadUser() {
        Task {
            let gp = AppContainer.shared.gitProvider
            userName = await gp.getGlobalConfigValue(key: "user.name")
            userEmail = await gp.getGlobalConfigValue(key: "user.email")
        }
    }

    private func loadGitConfig() {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gitconfig")
        gitconfigText = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private func loadGlobalIgnore() {
        Task {
            let configured = await AppContainer.shared.gitProvider.getGlobalConfigValue(key: "core.excludesfile")
            let fallback = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gitignore_global").path
            let resolved = configured.isEmpty ? fallback : (configured as NSString).expandingTildeInPath
            globalIgnorePath = resolved
            globalIgnoreText = (try? String(contentsOfFile: resolved, encoding: .utf8)) ?? ""
        }
    }
}
