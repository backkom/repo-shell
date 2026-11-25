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
        showIcons: Bool,
        targetDirectoryPath: String,
        selectedPaths: [String],
        repoPath: String?,
        target: AnyObject,
        selector: Selector
    ) -> (menu: NSMenu, actionsByTag: [Int: MenuActionBox]) {
        let rootMenu = NSMenu(title: AppConstants.appName)
        let containerMenu: NSMenu

        if cascade {
            let subMenu = NSMenu(title: AppConstants.appName)
            let topItem = NSMenuItem(title: AppConstants.appName, action: nil, keyEquivalent: "")
            topItem.submenu = subMenu
            if showIcons, let icon = NSImage(systemSymbolName: "chevron.left.forwardslash.chevron.right", accessibilityDescription: nil) {
                icon.isTemplate = true
                topItem.image = icon
            }
            rootMenu.addItem(topItem)
            containerMenu = subMenu
        } else {
            containerMenu = rootMenu
        }

        var nextTag = 1
        var actionsByTag: [Int: MenuActionBox] = [:]

        appendItems(
            resolvedItems,
            to: containerMenu,
            showIcons: showIcons,
            targetDirectoryPath: targetDirectoryPath,
            selectedPaths: selectedPaths,
            repoPath: repoPath,
            target: target,
            selector: selector,
            nextTag: &nextTag,
            actionsByTag: &actionsByTag
        )

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
                if showIcons,
                   let img = NSImage(systemSymbolName: action.systemSymbolName, accessibilityDescription: nil) {
                    img.isTemplate = true
                    menuItem.image = img
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
                if showIcons, let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
                    img.isTemplate = true
                    parentItem.image = img
                }
                menu.addItem(parentItem)
            }
        }

        while let last = menu.items.last, last.isSeparatorItem {
            menu.removeItem(last)
        }
    }
}
