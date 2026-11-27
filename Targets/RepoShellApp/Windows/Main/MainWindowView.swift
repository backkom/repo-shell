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

            // macOS Preferences-style Top Navigation Bar
            HStack(spacing: 6) {
                MainNavTabButton(
                    title: L("Repositories", "工作副本"),
                    systemImage: "folder.badge.gearshape",
                    badgeCount: repoManager.config.repositories.count,
                    isSelected: selectedTab == .repositories
                ) { selectedTab = .repositories }

                MainNavTabButton(
                    title: L("General", "通用"),
                    systemImage: "gearshape",
                    isSelected: selectedTab == .general
                ) { selectedTab = .general }

                MainNavTabButton(
                    title: "Git & SVN",
                    systemImage: "arrow.triangle.branch",
                    isSelected: selectedTab == .vcs
                ) { selectedTab = .vcs }

                MainNavTabButton(
                    title: L("Quick Actions", "快速操作"),
                    systemImage: "bolt.circle",
                    isSelected: selectedTab == .quickActions
                ) { selectedTab = .quickActions }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))

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
        .onAppear {
            Task {
                _ = await AppContainer.shared.refreshFinderExtensionStatus()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task {
                _ = await AppContainer.shared.refreshFinderExtensionStatus()
            }
            AppContainer.shared.triggerRefresh(repoPath: nil)
        }
    }
}

private struct MainNavTabButton: View {
    let title: String
    let systemImage: String
    var badgeCount: Int? = nil
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: systemImage)
                        .font(.system(size: 16, weight: isSelected ? .semibold : .regular))
                        .frame(width: 24, height: 20)
                }
                HStack(spacing: 4) {
                    Text(title)
                        .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                    if let count = badgeCount, count > 0 {
                        Text("\(count)")
                            .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                            .padding(.horizontal, 4)
                            .padding(.vertical, 0.5)
                            .background(isSelected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.15))
                            .cornerRadius(4)
                    }
                }
            }
            .foregroundColor(isSelected ? .accentColor : .primary.opacity(0.82))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        isSelected
                            ? Color.accentColor.opacity(0.13)
                            : (isHovered ? Color.primary.opacity(0.05) : Color.clear)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor.opacity(0.28) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
