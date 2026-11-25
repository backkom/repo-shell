import SwiftUI
import RepoShellShared

enum MainTab: String, CaseIterable {
    case repositories
    case general
    case git
    case quickActions
}

struct MainWindowView: View {
    @State private var selectedTab: MainTab
    @ObservedObject private var repoManager = AppContainer.shared.repositoryManager

    init(initialTab: MainTab = .repositories) {
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                Label(L("Repositories", "工作副本"), systemImage: "folder.badge.gearshape")
                    .tag(MainTab.repositories)
                Label(L("General", "通用"), systemImage: "gearshape")
                    .tag(MainTab.general)
                Label("Git", systemImage: "arrow.triangle.branch")
                    .tag(MainTab.git)
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
                case .git:
                    GitTabView()
                case .quickActions:
                    QuickActionsTabView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .id(repoManager.config.preferences.language)
    }
}
