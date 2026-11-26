import Cocoa
import RepoShellShared

struct MenuActionBox {
    let action: MenuAction
    let targetDirectoryPath: String
    let selectedPaths: [String]
    let repoPath: String?
}

enum MenuBuilder {
    static func buildMenu(
        resolvedItems: [ResolvedMenuItem],
        cascade: Bool,
        topLevelActions: [MenuAction] = [],
        showIcons: Bool,
        showUpdateDot: Bool = false,
        targetDirectoryPath: String,
        selectedPaths: [String],
        repoPath: String?,
        target: AnyObject,
        selector: Selector
    ) -> (menu: NSMenu, actionsByTag: [Int: MenuActionBox]) {
        let rootMenu = NSMenu(title: AppConstants.appName)
        var nextTag = 1
        var actionsByTag: [Int: MenuActionBox] = [:]

        if cascade {
            let partitioned = MenuVisibilityResolver.partitionForCascade(
                items: resolvedItems,
                topLevelActions: topLevelActions
            )

            appendItems(
                partitioned.topLevel,
                to: rootMenu,
                showIcons: showIcons,
                targetDirectoryPath: targetDirectoryPath,
                selectedPaths: selectedPaths,
                repoPath: repoPath,
                target: target,
                selector: selector,
                nextTag: &nextTag,
                actionsByTag: &actionsByTag
            )

            if !partitioned.submenu.isEmpty {
                let subMenu = NSMenu(title: AppConstants.appName)
                appendItems(
                    partitioned.submenu,
                    to: subMenu,
                    showIcons: showIcons,
                    targetDirectoryPath: targetDirectoryPath,
                    selectedPaths: selectedPaths,
                    repoPath: repoPath,
                    target: target,
                    selector: selector,
                    nextTag: &nextTag,
                    actionsByTag: &actionsByTag
                )
                let topItem = NSMenuItem(title: AppConstants.appName, action: nil, keyEquivalent: "")
                topItem.submenu = subMenu
                if showIcons || showUpdateDot {
                    topItem.image = MenuActionIconRenderer.appBrandMenuIcon(showUpdateDot: showUpdateDot)
                }
                rootMenu.addItem(topItem)
            }
        } else {
            appendItems(
                resolvedItems,
                to: rootMenu,
                showIcons: showIcons,
                targetDirectoryPath: targetDirectoryPath,
                selectedPaths: selectedPaths,
                repoPath: repoPath,
                target: target,
                selector: selector,
                nextTag: &nextTag,
                actionsByTag: &actionsByTag
            )
        }

        return (rootMenu, actionsByTag)
    }

    private static func appendItems(
        _ items: [ResolvedMenuItem],
        to menu: NSMenu,
        showIcons: Bool,
        targetDirectoryPath: String,
        selectedPaths: [String],
        repoPath: String?,
        target: AnyObject,
        selector: Selector,
        nextTag: inout Int,
        actionsByTag: inout [Int: MenuActionBox]
    ) {
        for item in items {
            switch item {
            case .separator:
                if let last = menu.items.last, !last.isSeparatorItem {
                    menu.addItem(.separator())
                }

            case .item(let action, let title):
                let tag = nextTag
                nextTag += 1
                actionsByTag[tag] = MenuActionBox(
                    action: action,
                    targetDirectoryPath: targetDirectoryPath,
                    selectedPaths: selectedPaths,
                    repoPath: repoPath
                )

                let menuItem = NSMenuItem(title: title, action: selector, keyEquivalent: "")
                menuItem.target = target
                menuItem.tag = tag
                if action == .upgradeApp {
                    menuItem.image = MenuActionIconRenderer.redDotBadgeIcon()
                } else if showIcons {
                    menuItem.image = MenuActionIconRenderer.menuIcon(for: action)
                }
                menu.addItem(menuItem)

            case .submenu(let title, let symbolName, let children):
                let sub = NSMenu(title: title)
                appendItems(
                    children,
                    to: sub,
                    showIcons: showIcons,
                    targetDirectoryPath: targetDirectoryPath,
                    selectedPaths: selectedPaths,
                    repoPath: repoPath,
                    target: target,
                    selector: selector,
                    nextTag: &nextTag,
                    actionsByTag: &actionsByTag
                )
                let parentItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                parentItem.submenu = sub
                if showIcons {
                    parentItem.image = MenuActionIconRenderer.submenuIcon(symbolName: symbolName)
                }
                menu.addItem(parentItem)
            }
        }

        while let last = menu.items.last, last.isSeparatorItem {
            menu.removeItem(last)
        }
    }
}
