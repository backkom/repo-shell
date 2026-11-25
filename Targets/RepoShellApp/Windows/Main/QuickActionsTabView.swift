import SwiftUI
import RepoShellShared
import RepoShellServices

struct QuickActionsTabView: View {
    @State private var items: [QuickActionItem] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L(
                "Quick Actions provide RepoShell access inside cloud drive folders (OneDrive, Dropbox, Google Drive, iCloud). Enable or reorder installed actions in System Settings → Extensions → Finder.",
                "可通过快速操作在网盘目录（OneDrive、Dropbox、Google Drive、iCloud 等）访问 RepoShell 功能。安装后可在「系统设置 → 扩展 → 访达」中启用或排序。"
            ))
            .font(.subheadline)
            .foregroundColor(.secondary)

            List(items) { item in
                HStack {
                    Toggle(isOn: Binding(
                        get: { item.isInstalled },
                        set: { install in
                            toggle(item: item, install: install)
                        }
                    )) {
                        HStack(spacing: 8) {
                            Image(nsImage: MenuActionIconRenderer.menuIcon(for: item.action, size: 16))
                                .frame(width: 18, height: 18)
                            Text(item.title)
                        }
                    }
                    Spacer()
                    if item.isInstalled {
                        Text(L("Installed", "已安装"))
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                }
            }
            .listStyle(.inset)

            HStack {
                Button(L("Reveal in Finder", "在访达中展示")) {
                    let servicesDir = AppContainer.shared.quickActionManager.servicesDirectoryURL
                    try? FileManager.default.createDirectory(at: servicesDir, withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([servicesDir])
                }
                Button(L("Open System Settings", "打开系统设置")) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Spacer()
                Button(L("Refresh", "刷新")) { reload() }
            }
        }
        .padding()
        .onAppear(perform: reload)
    }

    private func reload() {
        let lang = AppContainer.shared.repositoryManager.currentConfigSnapshot().preferences.language
        items = AppContainer.shared.quickActionManager.availableActions(language: lang)
    }

    private func toggle(item: QuickActionItem, install: Bool) {
        let mgr = AppContainer.shared.quickActionManager
        let lang = AppContainer.shared.repositoryManager.currentConfigSnapshot().preferences.language
        do {
            if install {
                _ = try mgr.install(action: item.action, language: lang)
            } else {
                try mgr.uninstall(action: item.action, language: lang)
            }
            reload()
        } catch {
            AlertHelper.showError(error)
        }
    }
}
