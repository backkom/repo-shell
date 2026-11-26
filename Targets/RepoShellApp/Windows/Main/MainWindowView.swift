import SwiftUI
import RepoShellShared

enum MainTab: String, CaseIterable {
    case repositories
    case general
    case vcs
    case quickActions
}

struct MainWindowView: View {
    @State private var selectedTab: MainTab
    @ObservedObject private var repoManager = AppContainer.shared.repositoryManager
    @ObservedObject private var updateController = AppContainer.shared.updateController

    init(initialTab: MainTab = .repositories) {
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let update = updateController.availableUpdate {
                HStack(spacing: 10) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                    Text(String(
                        format: L("New version v%@ is available (current %@).", "发现新版本 v%@（当前版本 %@）。"),
                        update.latestVersion,
                        AppConstants.currentVersion
                    ))
                    .font(.subheadline)
                    Spacer()
                    Button(L("Upgrade Now…", "立即升级…")) {
                        updateController.startUpgrade()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.red.opacity(0.08))
                Divider()
            }

            Picker("", selection: $selectedTab) {
                Label(L("Repositories", "工作副本"), systemImage: "folder.badge.gearshape")
                    .tag(MainTab.repositories)
                Label(L("General", "通用"), systemImage: "gearshape")
                    .tag(MainTab.general)
                Label("Git & SVN", systemImage: "arrow.triangle.branch")
                    .tag(MainTab.vcs)
                Label(L("Quick Actions", "快速操作"), systemImage: "bolt.circle")
                    .tag(MainTab.quickActions)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 10)

            Divider()

            Group {
                switch selectedTab {
                case .repositories:
                    RepositoriesTabView()
                case .general:
                    GeneralTabView()
                case .vcs:
                    VcsSettingsTabView()
                case .quickActions:
                    QuickActionsTabView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .id(repoManager.config.preferences.language)
    }
}
