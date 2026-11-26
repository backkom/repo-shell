import SwiftUI
import RepoShellShared
import RepoShellVcs
import RepoShellServices

struct GeneralTabView: View {
    @ObservedObject private var container = AppContainer.shared
    @ObservedObject private var repoManager = AppContainer.shared.repositoryManager
    @ObservedObject private var updateController = AppContainer.shared.updateController
    @State private var installedDiffTools: [DetectedToolInfo] = AppContainer.shared.diffToolManager.detectInstalledDiffTools()
    @State private var installedMergeTools: [DetectedToolInfo] = AppContainer.shared.diffToolManager.detectInstalledMergeTools()
    @State private var gitVersionText: String = ""

    var body: some View {
        Form {
            // Extension Status Banner
            Section {
                HStack(spacing: 12) {
                    if let extensionEnabled = container.isFinderExtensionEnabled {
                        Image(systemName: extensionEnabled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundColor(extensionEnabled ? .green : .orange)
                            .font(.title2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(extensionEnabled
                                 ? L("RepoShell Finder Extension is enabled", "RepoShell 访达扩展已启用")
                                 : L("Enable \"RepoShell Finder Extension\" under Added Extensions / File Providers in System Settings.", "请在「系统设置 → 登录项与扩展 → 已添加的扩展 / 文件提供程序」中启用“RepoShell 访达扩展”。"))
                                .fontWeight(.medium)
                        }
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
                            .frame(width: 24, height: 24)
                        Text(L("Checking RepoShell Finder Extension status…", "正在检查 RepoShell 访达扩展状态…"))
                            .fontWeight(.medium)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    Button(L("Refresh", "刷新")) {
                        checkExtensionStatus()
                    }
                    Button(L("Open System Settings", "打开系统设置")) {
                        FinderExtensionHelper.openManagementInterface()
                    }
                }
                .padding(.vertical, 4)
            }

            // General Options
            Section(header: Text(L("General Options", "通用选项"))) {
                Toggle(L("Cascade context menu items", "级联显示右键菜单项"), isOn: binding(\.cascadeMenu))
                Toggle(L("Show icons in context menu", "在右键菜单中显示图标"), isOn: binding(\.showMenuIcons))
                Toggle(L("Show in menu bar (hide Dock icon)", "在菜单栏中显示（不在 Dock 上显示）"), isOn: binding(\.showInMenuBar))
                Toggle(L("Show preferences window on launch", "启动时显示此窗口"), isOn: binding(\.showPreferencesOnLaunch))
                Toggle(L("Check empty commit message", "检查空的提交信息"), isOn: binding(\.checkEmptyCommitMessage))

                Picker(L("Language / 语言", "语言 / Language"), selection: binding(\.language)) {
                    Text(L("Follow System", "跟随系统")).tag(AppLanguage.system)
                    Text("English").tag(AppLanguage.en)
                    Text("简体中文").tag(AppLanguage.zhHans)
                }
            }

            // Cloud Drive & Finder Tags Fallback
            Section(header: Text(L("Finder Tags Status Fallback", "Finder 标签状态标识"))) {
                Toggle(L("Use Finder Tags for cloud drive repositories (OneDrive, Dropbox, Google Drive, iCloud)", "在网盘目录中使用 Finder 标签来标识状态"), isOn: binding(\.useFinderTagsForCloudDrives))
                Toggle(L("Use Finder Tags for local repositories (when extension conflicts occur)", "在本地目录中使用 Finder 标签来标识状态"), isOn: binding(\.useFinderTagsForLocalRepos))
            }

            // Diff & Merge Tools
            Section(header: Text(L("Diff & Merge Tools", "对比与合并工具"))) {
                HStack {
                    Picker(L("Diff Tool:", "对比工具："), selection: binding(\.diffToolId)) {
                        Text(L("Auto", "自动")).tag("auto")
                        ForEach(installedDiffTools) { tool in
                            Text(tool.name + (tool.isInstalled ? "" : L(" (Not Installed)", " (未安装)"))).tag(tool.id)
                        }
                        Text(L("Custom Command…", "自定义命令…")).tag("custom")
                    }
                    Button {
                        refreshTools()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help(L("Refresh detected tools", "刷新工具检测"))
                }

                if repoManager.config.preferences.diffToolId == "custom" {
                    TextField(L("Command template (use $LOCAL and $REMOTE)", "命令模板（支持 $LOCAL 和 $REMOTE）"), text: binding(\.customDiffCommand))
                        .textFieldStyle(.roundedBorder)
                }

                Picker(L("Merge Tool:", "合并工具："), selection: binding(\.mergeToolId)) {
                    Text(L("Auto", "自动")).tag("auto")
                    ForEach(installedMergeTools) { tool in
                        Text(tool.name + (tool.isInstalled ? "" : L(" (Not Installed)", " (未安装)"))).tag(tool.id)
                    }
                    Text(L("Custom Command…", "自定义命令…")).tag("custom")
                }

                if repoManager.config.preferences.mergeToolId == "custom" {
                    TextField(L("Command template ($BASE $LOCAL $REMOTE $MERGED)", "命令模板（支持 $BASE $LOCAL $REMOTE $MERGED）"), text: binding(\.customMergeCommand))
                        .textFieldStyle(.roundedBorder)
                }
            }

            // Git Executable
            Section(header: Text(L("Git Executable", "Git 可执行程序"))) {
                Picker(L("Git Path:", "Git 路径："), selection: binding(\.useBundledGit)) {
                    Text(L("Bundled Git", "内置 Git")).tag(true)
                    Text(L("External Git", "外部 Git")).tag(false)
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()

                if !repoManager.config.preferences.useBundledGit {
                    HStack {
                        TextField("/usr/bin/git", text: binding(\.externalGitPath))
                            .textFieldStyle(.roundedBorder)
                        Button(L("Browse…", "浏览…")) {
                            if let url = AlertHelper.pickFile(title: L("Select git executable", "选择 git 可执行文件")) {
                                repoManager.updatePreferences { $0.externalGitPath = url.path }
                                testGitVersion()
                            }
                        }
                    }
                }

                HStack {
                    Button(L("Test Git", "检测 Git 版本")) {
                        testGitVersion()
                    }
                    if !gitVersionText.isEmpty {
                        Text(gitVersionText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            // Status Colors
            Section(header: HStack {
                Text(L("Status Text Colors (Light / Dark)", "状态列表文字颜色（浅色 / 深色）"))
                Spacer()
                Button(L("Reset Defaults", "恢复默认")) {
                    repoManager.updatePreferences { prefs in
                        prefs.lightColors = StatusTextColors.defaultLight
                        prefs.darkColors = StatusTextColors.defaultDark
                    }
                }
                .buttonStyle(.link)
                .font(.caption)
            }) {
                StatusColorEditorRow(
                    title: L("Light Mode", "浅色模式"),
                    colors: binding(\.lightColors)
                )
                StatusColorEditorRow(
                    title: L("Dark Mode", "深色模式"),
                    colors: binding(\.darkColors)
                )
            }

            // About & Updates
            Section(header: Text(L("About & Updates", "关于与软件更新"))) {
                LabeledContent(L("Version", "版本号")) {
                    Text("\(AppConstants.currentVersion) (\(AppConstants.currentBuildNumber))")
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
                LabeledContent(L("Developer", "开发者")) {
                    HStack(spacing: 6) {
                        Text(AppConstants.developerName)
                        Text("·").foregroundColor(.secondary)
                        if let mailURL = URL(string: "mailto:\(AppConstants.developerEmail)") {
                            Link(AppConstants.developerEmail, destination: mailURL)
                        } else {
                            Text(AppConstants.developerEmail)
                        }
                    }
                }
                LabeledContent("GitHub") {
                    Link(AppConstants.githubRepoSlug, destination: AppConstants.githubRepositoryURL)
                }
                Toggle(L("Automatically check for updates", "自动检测新版本"), isOn: binding(\.autoCheckUpdates))

                HStack(spacing: 10) {
                    if let update = updateController.availableUpdate {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 8, height: 8)
                        Text(String(format: L("New version v%@ available", "发现新版本 v%@"), update.latestVersion))
                            .foregroundColor(.primary)
                        Spacer()
                        Button(L("Upgrade Now…", "立即升级…")) {
                            updateController.startUpgrade()
                        }
                        .buttonStyle(.borderedProminent)
                    } else if case .checking = updateController.phase {
                        ProgressView().controlSize(.small)
                        Text(L("Checking for updates…", "正在检查更新…"))
                            .foregroundColor(.secondary)
                        Spacer()
                    } else {
                        if case .upToDate = updateController.phase {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text(L("Up to date", "已是最新版本"))
                                .foregroundColor(.secondary)
                        } else if case .failed(let msg) = updateController.phase {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text(msg)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                    }

                    Button(L("Check for Updates", "检查更新")) {
                        Task {
                            await updateController.checkForUpdates(userInitiated: true)
                        }
                    }
                    .disabled({
                        if case .checking = updateController.phase { return true }
                        if case .downloading = updateController.phase { return true }
                        if case .installing = updateController.phase { return true }
                        return false
                    }())
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            checkExtensionStatus()
            refreshTools()
            testGitVersion()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            checkExtensionStatus()
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<AppPreferences, T>) -> Binding<T> {
        Binding(
            get: { repoManager.config.preferences[keyPath: keyPath] },
            set: { newValue in
                repoManager.updatePreferences { prefs in
                    prefs[keyPath: keyPath] = newValue
                }
                if keyPath == \.useFinderTagsForCloudDrives || keyPath == \.useFinderTagsForLocalRepos {
                    AppContainer.shared.statusEngine.refreshAllRepositories()
                }
            }
        )
    }

    private func refreshTools() {
        installedDiffTools = AppContainer.shared.diffToolManager.detectInstalledDiffTools()
        installedMergeTools = AppContainer.shared.diffToolManager.detectInstalledMergeTools()
    }

    private func testGitVersion() {
        Task {
            do {
                let exe = try GitExecutableResolver.resolve(preferences: repoManager.config.preferences)
                let ver = await GitExecutableResolver.gitVersion(executable: exe) ?? "Unknown"
                let src = exe.isBundled ? L("Bundled", "内置") : exe.executableURL.path
                gitVersionText = "\(ver) (\(src))"
            } catch {
                gitVersionText = error.localizedDescription
            }
        }
    }

    private func checkExtensionStatus() {
        Task {
            _ = await container.refreshFinderExtensionStatus()
        }
    }
}

private struct StatusColorEditorRow: View {
    let title: String
    @Binding var colors: StatusTextColors

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundColor(.secondary)
            HStack(spacing: 14) {
                rgbPicker(L("Added", "新增"), keyPath: \.added)
                rgbPicker(L("Modified", "修改"), keyPath: \.modified)
                rgbPicker(L("Deleted", "删除"), keyPath: \.deleted)
                rgbPicker(L("Merged", "正常"), keyPath: \.merged)
                rgbPicker(L("Conflict", "冲突"), keyPath: \.unmerged)
            }
        }
    }

    private func rgbPicker(_ label: String, keyPath: WritableKeyPath<StatusTextColors, RepoShellShared.RGBColor>) -> some View {
        let colorBinding = Binding<Color>(
            get: {
                let c = colors[keyPath: keyPath]
                return Color(red: Double(c.r)/255.0, green: Double(c.g)/255.0, blue: Double(c.b)/255.0)
            },
            set: { newColor in
                if let ns = NSColor(newColor).usingColorSpace(.sRGB) {
                    colors[keyPath: keyPath] = RepoShellShared.RGBColor(
                        r: Int(round(ns.redComponent * 255)),
                        g: Int(round(ns.greenComponent * 255)),
                        b: Int(round(ns.blueComponent * 255))
                    )
                }
            }
        )
        return VStack(spacing: 2) {
            ColorPicker("", selection: colorBinding, supportsOpacity: false)
                .labelsHidden()
            Text(label).font(.caption2)
        }
    }
}
