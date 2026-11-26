import SwiftUI
import RepoShellShared
import RepoShellVcs

struct SetupWizardView: View {
    let onFinish: () -> Void

    @ObservedObject private var container = AppContainer.shared
    @State private var step = 0
    @State private var gitStatus = ""
    @State private var addedCount = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 32))
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading) {
                    Text(L("Welcome to RepoShell", "欢迎使用 RepoShell"))
                        .font(.title2.bold())
                    Text(L("Step \(step + 1) of 3", "第 \(step + 1) / 3 步"))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding()

            Divider()

            Group {
                if step == 0 {
                    stepExtensionView
                } else if step == 1 {
                    stepGitToolsView
                } else {
                    stepAddReposView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)

            Divider()

            HStack {
                if step > 0 {
                    Button(L("Back", "上一步")) { step -= 1 }
                }
                Spacer()
                Button(L("Skip", "跳过")) {
                    completeWizard()
                }
                if step < 2 {
                    Button(L("Next", "下一步")) { step += 1 }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(L("Finish", "完成")) {
                        completeWizard()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
        .onAppear {
            checkExtension()
            checkGit()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            checkExtension()
        }
    }

    private var stepExtensionView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("1. Enable Finder Extension", "1. 启用访达扩展"))
                .font(.headline)
            Text(L(
                "RepoShell integrates status badges and context menus directly into Finder. On macOS 15+, look under Login Items & Extensions → Added Extensions / File Providers (not Finder Quick Actions) to enable \"RepoShell Finder Extension\", or click Enable Now.",
                "RepoShell 通过访达扩展在 Finder 中显示状态角标与右键菜单。在 macOS 15+ 中，请在「登录项与扩展 → 已添加的扩展 / 文件提供程序」（非快速操作 Finder 项）中启用“RepoShell 访达扩展”，或点击“一键启用”。"
            ))
            .foregroundColor(.secondary)
            HStack {
                if let extensionEnabled = container.isFinderExtensionEnabled {
                    Image(systemName: extensionEnabled ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundColor(extensionEnabled ? .green : .orange)
                    Text(extensionEnabled ? L("Extension enabled", "扩展已启用") : L("Waiting for extension activation", "等待启用扩展"))
                    Spacer()
                    if !extensionEnabled {
                        Button(L("Enable Now", "一键启用")) {
                            Task {
                                _ = await container.enableFinderExtensionNow()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    ProgressView()
                        .controlSize(.small)
                    Text(L("Checking extension status…", "正在检查扩展状态…"))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                Button(L("Check Again", "重新检测")) { checkExtension() }
                Button(L("Open System Settings", "打开系统设置")) {
                    FinderExtensionHelper.openManagementInterface()
                }
            }
            .padding()
            .background(Color.secondary.opacity(0.08))
            .cornerRadius(8)
        }
    }

    private var stepGitToolsView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("2. Verify Git & Diff Tools", "2. 验证 Git 与对比工具"))
                .font(.headline)
            Text(L(
                "RepoShell bundles a self-contained Git engine and automatically detects installed external diff/merge tools such as VS Code, Beyond Compare, Kaleidoscope, and FileMerge.",
                "RepoShell 内置自包含 Git 引擎，并自动探测本机已安装的 VS Code、Beyond Compare、Kaleidoscope、FileMerge 等外部对比/合并工具。"
            ))
            .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Label(gitStatus.isEmpty ? L("Checking Git…", "正在检查 Git…") : gitStatus, systemImage: "terminal")
                let detected = AppContainer.shared.diffToolManager.detectInstalledDiffTools().filter { $0.isInstalled }
                Label(
                    detected.isEmpty
                        ? L("No external diff tool detected yet (configure anytime in General).", "暂未探测到外部 Diff 工具（可随时在通用设置配置）。")
                        : L("Detected Diff Tools: ", "已探测到 Diff 工具：") + detected.map { $0.name }.joined(separator: ", "),
                    systemImage: "arrow.left.arrow.right.square"
                )
            }
            .padding()
            .background(Color.secondary.opacity(0.08))
            .cornerRadius(8)
        }
    }

    private var stepAddReposView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("3. Add Repositories or Workspace Folder", "3. 添加版本库或工作区目录"))
                .font(.headline)
            Text(L(
                "Add individual Git repositories or select a workspace parent folder to automatically discover all repositories inside.",
                "您可以添加单个 Git 版本库，或者选择一个工作区父目录以自动发现其中的全部版本库。"
            ))
            .foregroundColor(.secondary)

            HStack(spacing: 12) {
                Button(L("Add Git Repository…", "添加 Git 版本库…")) {
                    if let url = AlertHelper.pickFolder(title: L("Select Git Repository", "选择 Git 版本库")) {
                        Task {
                            if let _ = try? await AppContainer.shared.repositoryManager.addRepository(at: url.path) {
                                addedCount = AppContainer.shared.repositoryManager.config.repositories.count
                            }
                        }
                    }
                }
                Button(L("Add Workspace Folder…", "添加工作区父目录…")) {
                    if let url = AlertHelper.pickFolder(title: L("Select Workspace Folder", "选择工作区目录")) {
                        let repos = AppContainer.shared.repositoryManager.addWorkspaceRoot(at: url.path)
                        addedCount = repos.count
                    }
                }
            }
            if addedCount > 0 {
                Text(L("Monitored repositories: \(addedCount)", "当前已监控版本库数量：\(addedCount)"))
                    .foregroundColor(.green)
                    .font(.subheadline)
            }
        }
    }

    private func completeWizard() {
        AppContainer.shared.repositoryManager.updatePreferences { $0.hasCompletedSetupWizard = true }
        AppContainer.shared.statusEngine.rebuildWatchersAndRefreshAll()
        onFinish()
    }

    private func checkExtension() {
        Task {
            _ = await container.refreshFinderExtensionStatus()
        }
    }

    private func checkGit() {
        Task {
            if let exe = try? GitExecutableResolver.resolve(preferences: AppContainer.shared.repositoryManager.currentConfigSnapshot().preferences),
               let ver = await GitExecutableResolver.gitVersion(executable: exe) {
                gitStatus = ver
            }
        }
    }
}
