import SwiftUI
import RepoShellShared
import RepoShellVcs
import RepoShellServices

struct GeneralTabView: View {
    @ObservedObject private var repoManager = AppContainer.shared.repositoryManager
    @State private var extensionEnabled: Bool = false
    @State private var installedDiffTools: [DetectedToolInfo] = []
    @State private var installedMergeTools: [DetectedToolInfo] = []
    @State private var gitVersionText: String = ""

    var body: some View {
        Form {
            // Extension Status Banner
            Section {
                HStack(spacing: 12) {
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
                                extensionEnabled = await FinderExtensionHelper.enableNow()
                            }
                        }
                        .buttonStyle(.borderedProminent)
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
            Section(header: Text(L("Status Text Colors (Light / Dark)", "状态列表文字颜色（浅色 / 深色）"))) {
                StatusColorEditorRow(
                    title: L("Light Mode", "浅色模式"),
                    colors: binding(\.lightColors)
                )
                StatusColorEditorRow(
                    title: L("Dark Mode", "深色模式"),
                    colors: binding(\.darkColors)
                )
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
            extensionEnabled = await FinderExtensionHelper.isEnabled()
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
