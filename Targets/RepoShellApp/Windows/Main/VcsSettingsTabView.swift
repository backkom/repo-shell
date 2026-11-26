import SwiftUI
import RepoShellShared

enum VcsSettingsSubtab: String, CaseIterable {
    case git
    case svn
}

/// Combined Git & SVN settings tab with a secondary VCS switcher.
struct VcsSettingsTabView: View {
    @State private var selectedVcsTab: VcsSettingsSubtab = .git

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedVcsTab) {
                Label("Git", systemImage: "arrow.triangle.branch")
                    .tag(VcsSettingsSubtab.git)
                Label("SVN", systemImage: "server.rack")
                    .tag(VcsSettingsSubtab.svn)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            Group {
                switch selectedVcsTab {
                case .git:
                    GitTabView()
                case .svn:
                    SvnTabView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct VcsSidebarNavItem<Tab: Hashable>: Identifiable {
    let id: Tab
    let title: String
    let systemImage: String
}

/// Vertical navigation sidebar shared by Git and SVN preference views.
struct VcsPrefSidebar<Tab: Hashable>: View {
    let items: [VcsSidebarNavItem<Tab>]
    @Binding var selection: Tab

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items) { item in
                VcsSidebarButton(
                    title: item.title,
                    systemImage: item.systemImage,
                    isSelected: selection == item.id
                ) {
                    selection = item.id
                }
            }
            Spacer()
        }
        .padding(10)
        .frame(width: 176)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.45))
    }
}

private struct VcsSidebarButton: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .frame(width: 16, alignment: .center)
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        isSelected
                            ? Color.accentColor.opacity(0.15)
                            : (isHovered ? Color.primary.opacity(0.06) : Color.clear)
                    )
            )
            .foregroundColor(isSelected ? .accentColor : .primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

/// Reusable form section for configuring promoted top-level Finder context menu actions.
struct TopLevelContextMenuView: View {
    @ObservedObject private var repoManager = AppContainer.shared.repositoryManager

    let sectionTitle: String
    let descriptionText: String
    let promotableActions: [MenuAction]
    let defaultActions: [MenuAction]
    let actionsKeyPath: WritableKeyPath<AppPreferences, [MenuAction]>

    var body: some View {
        let cascadeEnabled = repoManager.config.preferences.cascadeMenu
        let loc = Localization(language: repoManager.config.preferences.language)

        Form {
            Section(header: Text(sectionTitle)) {
                if !cascadeEnabled {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .foregroundColor(.orange)
                        Text(L(
                            "Cascade context menu is disabled in General. Enable \"Cascade context menu items\" in General to customize top-level actions.",
                            "当前在「通用」中关闭了“级联显示右键菜单项”，开启后此处的勾选操作才会独立显示在访达右键一级菜单中。"
                        ))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 2)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text(descriptionText)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    LazyVGrid(
                        columns: [GridItem(.flexible()), GridItem(.flexible())],
                        alignment: .leading,
                        spacing: 6
                    ) {
                        ForEach(promotableActions, id: \.self) { action in
                            Toggle(isOn: actionBinding(action)) {
                                HStack(spacing: 6) {
                                    Image(nsImage: MenuActionIconRenderer.menuIcon(for: action, size: 15))
                                        .frame(width: 15, height: 15)
                                    Text(loc.string(action.localizationKey))
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    HStack(spacing: 10) {
                        Button(L("Reset Defaults", "恢复默认")) {
                            repoManager.updatePreferences { prefs in
                                prefs[keyPath: actionsKeyPath] = defaultActions
                            }
                        }
                        Button(L("All in Submenu", "全部收纳到子菜单")) {
                            repoManager.updatePreferences { prefs in
                                prefs[keyPath: actionsKeyPath] = []
                            }
                        }
                    }
                    .controlSize(.small)
                }
                .padding(.vertical, 4)
                .disabled(!cascadeEnabled)
                .opacity(cascadeEnabled ? 1.0 : 0.6)
            }
        }
        .formStyle(.grouped)
    }

    private func actionBinding(_ action: MenuAction) -> Binding<Bool> {
        Binding(
            get: { repoManager.config.preferences[keyPath: actionsKeyPath].contains(action) },
            set: { enabled in
                repoManager.updatePreferences { prefs in
                    var selected = Set(prefs[keyPath: actionsKeyPath])
                    if enabled {
                        selected.insert(action)
                    } else {
                        selected.remove(action)
                    }
                    prefs[keyPath: actionsKeyPath] = promotableActions.filter { selected.contains($0) }
                }
            }
        )
    }
}
