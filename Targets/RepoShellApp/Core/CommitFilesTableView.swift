import Cocoa
import SwiftUI
import UniformTypeIdentifiers
import RepoShellShared
import RepoShellServices

struct CommitFileRow: Identifiable, Equatable {
    var id: String { relativePath }
    let relativePath: String
    let absolutePath: String
    let extensionText: String
    let status: VcsFileStatus
    let statusDisplayText: String
    let isDirectory: Bool
    let detailText: String
    let tooltipText: String
    var stagedText: String = ""
    var sizeText: String = ""
}

enum CommitFileContextAction {
    case diff(CommitFileRow)
    case diffPrevious(CommitFileRow)
    case showLog(CommitFileRow)
    case blame(CommitFileRow)
    case add([CommitFileRow])
    case revert([CommitFileRow])
    case delete([CommitFileRow])
    case addToIgnore([CommitFileRow])
    case hideFiles([CommitFileRow])
    case moveToChangelist([CommitFileRow], UUID?)
    case openFile(CommitFileRow)
    case revealInFinder([CommitFileRow])
    case copyPaths([CommitFileRow])
}

private final class CommitCheckCellView: NSTableCellView {
    let checkbox: NSButton
    var rowPath: String = ""
    var onToggle: ((String, Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        checkbox.controlSize = .small
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        super.init(frame: frameRect)
        checkbox.target = self
        checkbox.action = #selector(clicked)
        addSubview(checkbox)
        NSLayoutConstraint.activate([
            checkbox.centerXAnchor.constraint(equalTo: centerXAnchor),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func clicked() {
        onToggle?(rowPath, checkbox.state == .on)
    }
}

private final class CommitPathCellView: NSTableCellView {
    let iconView: NSImageView
    let label: NSTextField
    var normalTextColor: NSColor = .labelColor {
        didSet { applyTextColor() }
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyTextColor() }
    }

    override init(frame frameRect: NSRect) {
        iconView = NSImageView()
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 12.5)
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.usesSingleLineMode = true
        label.allowsExpansionToolTips = true
        label.translatesAutoresizingMaskIntoConstraints = false

        super.init(frame: frameRect)
        addSubview(iconView)
        addSubview(label)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func applyTextColor() {
        label.textColor = (backgroundStyle == .emphasized) ? .selectedControlTextColor : normalTextColor
    }
}

private final class CommitTextCellView: NSTableCellView {
    let label: NSTextField
    var normalTextColor: NSColor = .labelColor {
        didSet { applyTextColor() }
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyTextColor() }
    }

    init(alignment: NSTextAlignment, font: NSFont) {
        label = NSTextField(labelWithString: "")
        label.font = font
        label.alignment = alignment
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.usesSingleLineMode = true
        label.allowsExpansionToolTips = true
        label.translatesAutoresizingMaskIntoConstraints = false

        super.init(frame: .zero)
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func applyTextColor() {
        label.textColor = (backgroundStyle == .emphasized) ? .selectedControlTextColor : normalTextColor
    }
}

fileprivate final class CommitNSTableView: NSTableView {
    var onSpaceKey: (() -> Void)?
    var onReturnKey: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 { // Spacebar
            if !selectedRowIndexes.isEmpty {
                onSpaceKey?()
                return
            }
        } else if event.keyCode == 36 || event.keyCode == 76 { // Return / Enter
            if !selectedRowIndexes.isEmpty {
                onReturnKey?()
                return
            }
        }
        super.keyDown(with: event)
    }
}

struct CommitFilesTableView: NSViewRepresentable {
    let rows: [CommitFileRow]
    @Binding var checkedPaths: Set<String>
    @Binding var highlightedPaths: Set<String>
    let detailColumnTitle: String
    let vcsType: VcsType
    let changelists: [Changelist]
    var showsCheckboxes: Bool = true
    var showsStagedAndSizeColumns: Bool = false
    let onDoubleClick: (CommitFileRow) -> Void
    let onContextAction: (CommitFileContextAction) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .controlBackgroundColor

        let table = CommitNSTableView()
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.allowsColumnReordering = false
        table.allowsColumnResizing = true
        table.rowHeight = 22
        table.intercellSpacing = NSSize(width: 6, height: 0)
        table.columnAutoresizingStyle = .sequentialColumnAutoresizingStyle
        table.focusRingType = .none

        if showsCheckboxes {
            let colCheck = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("check"))
            colCheck.title = ""
            colCheck.width = 26
            colCheck.minWidth = 26
            colCheck.maxWidth = 26
            colCheck.resizingMask = []
            colCheck.sortDescriptorPrototype = NSSortDescriptor(key: "check", ascending: true)
            table.addTableColumn(colCheck)
        }

        let colPath = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("path"))
        colPath.title = L("Path", "路径")
        colPath.width = 390
        colPath.minWidth = 180
        colPath.resizingMask = [.autoresizingMask, .userResizingMask]
        colPath.sortDescriptorPrototype = NSSortDescriptor(key: "path", ascending: true)

        let colExt = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ext"))
        colExt.title = L("Extension", "扩展名")
        colExt.width = 72
        colExt.minWidth = 48
        colExt.maxWidth = 120
        colExt.resizingMask = [.userResizingMask]
        colExt.sortDescriptorPrototype = NSSortDescriptor(key: "ext", ascending: true)

        let colStatus = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("status"))
        colStatus.title = L("Status", "状态")
        colStatus.width = 96
        colStatus.minWidth = 72
        colStatus.maxWidth = 150
        colStatus.resizingMask = [.userResizingMask]
        colStatus.sortDescriptorPrototype = NSSortDescriptor(key: "status", ascending: true)

        table.addTableColumn(colPath)
        table.addTableColumn(colExt)
        table.addTableColumn(colStatus)

        if showsStagedAndSizeColumns {
            let colStaged = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("staged"))
            colStaged.title = L("Staged", "暂存")
            colStaged.width = 64
            colStaged.minWidth = 48
            colStaged.maxWidth = 100
            colStaged.resizingMask = [.userResizingMask]
            colStaged.sortDescriptorPrototype = NSSortDescriptor(key: "staged", ascending: true)
            table.addTableColumn(colStaged)
        }

        let colDetail = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("detail"))
        colDetail.title = detailColumnTitle
        colDetail.width = 96
        colDetail.minWidth = 64
        colDetail.maxWidth = 180
        colDetail.resizingMask = [.userResizingMask]
        colDetail.headerCell.alignment = .right
        colDetail.sortDescriptorPrototype = NSSortDescriptor(key: "detail", ascending: true)
        table.addTableColumn(colDetail)

        if showsStagedAndSizeColumns {
            let colSize = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
            colSize.title = L("Size", "大小")
            colSize.width = 74
            colSize.minWidth = 54
            colSize.maxWidth = 120
            colSize.resizingMask = [.userResizingMask]
            colSize.headerCell.alignment = .right
            colSize.sortDescriptorPrototype = NSSortDescriptor(key: "size", ascending: true)
            table.addTableColumn(colSize)
        }

        let coord = context.coordinator
        table.delegate = coord
        table.dataSource = coord
        table.target = coord
        table.doubleAction = #selector(Coordinator.handleDoubleClick(_:))
        if showsCheckboxes {
            table.onSpaceKey = { [weak coord] in coord?.handleSpaceToggle() }
        }
        table.onReturnKey = { [weak coord] in coord?.handleReturnOpen() }

        let contextMenu = NSMenu()
        contextMenu.delegate = coord
        table.menu = contextMenu

        coord.tableView = table
        coord.syncData(rows: rows, forceReload: true)

        scrollView.documentView = table
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let coord = context.coordinator
        coord.parent = self
        if let detailCol = coord.tableView?.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("detail")) {
            if detailCol.title != detailColumnTitle {
                detailCol.title = detailColumnTitle
            }
        }
        coord.syncData(rows: rows, forceReload: false)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: CommitFilesTableView
        fileprivate weak var tableView: CommitNSTableView?

        private var sourceRows: [CommitFileRow] = []
        private var displayedRows: [CommitFileRow] = []
        private var lastCheckedSnapshot: Set<String> = []
        private var isUpdatingSelectionProgrammatically = false
        private var menuTargetRows: [CommitFileRow] = []

        init(parent: CommitFilesTableView) {
            self.parent = parent
        }

        func syncData(rows: [CommitFileRow], forceReload: Bool) {
            guard let table = tableView else { return }

            let rowsChanged = forceReload || (rows != sourceRows)
            let checksChanged = (parent.checkedPaths != lastCheckedSnapshot)

            if rowsChanged {
                sourceRows = rows
                applySort(using: table.sortDescriptors)
                table.reloadData()
                restoreHighlightSelection(on: table)
                lastCheckedSnapshot = parent.checkedPaths
            } else if checksChanged {
                lastCheckedSnapshot = parent.checkedPaths
                if !displayedRows.isEmpty {
                    table.reloadData(
                        forRowIndexes: IndexSet(0..<displayedRows.count),
                        columnIndexes: IndexSet(integer: 0)
                    )
                }
            }
        }

        private func restoreHighlightSelection(on table: NSTableView) {
            let targetSet = parent.highlightedPaths
            var indexSet = IndexSet()
            if !targetSet.isEmpty {
                for (idx, row) in displayedRows.enumerated() where targetSet.contains(row.relativePath) {
                    indexSet.insert(idx)
                }
            }
            isUpdatingSelectionProgrammatically = true
            table.selectRowIndexes(indexSet, byExtendingSelection: false)
            isUpdatingSelectionProgrammatically = false
        }

        private func applySort(using descriptors: [NSSortDescriptor]) {
            guard let first = descriptors.first, let key = first.key else {
                displayedRows = sourceRows
                return
            }
            let asc = first.ascending
            let checked = parent.checkedPaths
            displayedRows = sourceRows.sorted { lhs, rhs in
                let cmp: ComparisonResult
                switch key {
                case "check":
                    let l = checked.contains(lhs.relativePath) ? 1 : 0
                    let r = checked.contains(rhs.relativePath) ? 1 : 0
                    if l == r {
                        cmp = lhs.relativePath.localizedStandardCompare(rhs.relativePath)
                    } else {
                        cmp = l > r ? .orderedAscending : .orderedDescending
                    }
                case "ext":
                    if lhs.extensionText.caseInsensitiveCompare(rhs.extensionText) == .orderedSame {
                        cmp = lhs.relativePath.localizedStandardCompare(rhs.relativePath)
                    } else {
                        cmp = lhs.extensionText.localizedStandardCompare(rhs.extensionText)
                    }
                case "status":
                    if lhs.statusDisplayText.localizedCompare(rhs.statusDisplayText) == .orderedSame {
                        cmp = lhs.relativePath.localizedStandardCompare(rhs.relativePath)
                    } else {
                        cmp = lhs.statusDisplayText.localizedCompare(rhs.statusDisplayText)
                    }
                case "staged":
                    if lhs.stagedText.localizedStandardCompare(rhs.stagedText) == .orderedSame {
                        cmp = lhs.relativePath.localizedStandardCompare(rhs.relativePath)
                    } else {
                        cmp = lhs.stagedText.localizedStandardCompare(rhs.stagedText)
                    }
                case "size":
                    if lhs.sizeText.localizedStandardCompare(rhs.sizeText) == .orderedSame {
                        cmp = lhs.relativePath.localizedStandardCompare(rhs.relativePath)
                    } else {
                        cmp = lhs.sizeText.localizedStandardCompare(rhs.sizeText)
                    }
                case "detail":
                    if lhs.detailText.localizedStandardCompare(rhs.detailText) == .orderedSame {
                        cmp = lhs.relativePath.localizedStandardCompare(rhs.relativePath)
                    } else {
                        cmp = lhs.detailText.localizedStandardCompare(rhs.detailText)
                    }
                default:
                    cmp = lhs.relativePath.localizedStandardCompare(rhs.relativePath)
                }
                return asc ? (cmp == .orderedAscending) : (cmp == .orderedDescending)
            }
        }

        // MARK: - NSTableViewDataSource

        func numberOfRows(in tableView: NSTableView) -> Int {
            displayedRows.count
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            applySort(using: tableView.sortDescriptors)
            tableView.reloadData()
            restoreHighlightSelection(on: tableView)
        }

        // MARK: - NSTableViewDelegate

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row >= 0, row < displayedRows.count, let colId = tableColumn?.identifier.rawValue else {
                return nil
            }
            let item = displayedRows[row]
            let isDark = tableView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let rowColor = statusColor(for: item.status, isDark: isDark)

            switch colId {
            case "check":
                let id = NSUserInterfaceItemIdentifier("CommitCheckCell")
                let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? CommitCheckCellView) ?? {
                    let v = CommitCheckCellView(frame: .zero)
                    v.identifier = id
                    return v
                }()
                cell.rowPath = item.relativePath
                cell.checkbox.state = parent.checkedPaths.contains(item.relativePath) ? .on : .off
                cell.onToggle = { [weak self] path, isOn in
                    self?.toggleCheck(path: path, isOn: isOn)
                }
                return cell

            case "path":
                let id = NSUserInterfaceItemIdentifier("CommitPathCell")
                let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? CommitPathCellView) ?? {
                    let v = CommitPathCellView(frame: .zero)
                    v.identifier = id
                    return v
                }()
                cell.iconView.image = SharedFileIconCache.icon(forPath: item.relativePath, isDirectory: item.isDirectory)
                cell.label.stringValue = item.relativePath
                cell.toolTip = item.tooltipText
                cell.normalTextColor = rowColor
                return cell

            case "ext":
                let id = NSUserInterfaceItemIdentifier("CommitExtCell")
                let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? CommitTextCellView) ?? {
                    let v = CommitTextCellView(alignment: .left, font: .systemFont(ofSize: 12))
                    v.identifier = id
                    return v
                }()
                cell.label.stringValue = item.extensionText
                cell.normalTextColor = rowColor
                return cell

            case "status":
                let id = NSUserInterfaceItemIdentifier("CommitStatusCell")
                let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? CommitTextCellView) ?? {
                    let v = CommitTextCellView(alignment: .left, font: .systemFont(ofSize: 12, weight: .medium))
                    v.identifier = id
                    return v
                }()
                cell.label.stringValue = item.statusDisplayText
                cell.normalTextColor = rowColor
                return cell

            case "staged":
                let id = NSUserInterfaceItemIdentifier("CommitStagedCell")
                let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? CommitTextCellView) ?? {
                    let v = CommitTextCellView(alignment: .left, font: .systemFont(ofSize: 11.5))
                    v.identifier = id
                    return v
                }()
                cell.label.stringValue = item.stagedText
                cell.normalTextColor = item.stagedText.isEmpty ? .secondaryLabelColor : .systemGreen
                return cell

            case "detail":
                let id = NSUserInterfaceItemIdentifier("CommitDetailCell")
                let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? CommitTextCellView) ?? {
                    let v = CommitTextCellView(alignment: .right, font: .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular))
                    v.identifier = id
                    return v
                }()
                cell.label.stringValue = item.detailText
                cell.normalTextColor = .secondaryLabelColor
                return cell

            case "size":
                let id = NSUserInterfaceItemIdentifier("CommitSizeCell")
                let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? CommitTextCellView) ?? {
                    let v = CommitTextCellView(alignment: .right, font: .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular))
                    v.identifier = id
                    return v
                }()
                cell.label.stringValue = item.sizeText
                cell.normalTextColor = .secondaryLabelColor
                return cell

            default:
                return nil
            }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isUpdatingSelectionProgrammatically, let table = tableView else { return }
            let selected = Set(table.selectedRowIndexes.compactMap { idx -> String? in
                guard idx >= 0, idx < displayedRows.count else { return nil }
                return displayedRows[idx].relativePath
            })
            if parent.highlightedPaths != selected {
                parent.highlightedPaths = selected
            }
        }

        // MARK: - Actions & Keyboard

        private func toggleCheck(path: String, isOn: Bool) {
            var updated = parent.checkedPaths
            if isOn {
                updated.insert(path)
            } else {
                updated.remove(path)
            }
            lastCheckedSnapshot = updated
            parent.checkedPaths = updated
        }

        func handleSpaceToggle() {
            guard let table = tableView else { return }
            let selectedRows = table.selectedRowIndexes.compactMap { idx -> CommitFileRow? in
                guard idx >= 0, idx < displayedRows.count else { return nil }
                return displayedRows[idx]
            }
            guard !selectedRows.isEmpty else { return }

            let allChecked = selectedRows.allSatisfy { parent.checkedPaths.contains($0.relativePath) }
            var updated = parent.checkedPaths
            for row in selectedRows {
                if allChecked {
                    updated.remove(row.relativePath)
                } else {
                    updated.insert(row.relativePath)
                }
            }
            lastCheckedSnapshot = updated
            parent.checkedPaths = updated
            table.reloadData(forRowIndexes: table.selectedRowIndexes, columnIndexes: IndexSet(integer: 0))
        }

        func handleReturnOpen() {
            guard let table = tableView, let first = table.selectedRowIndexes.first,
                  first >= 0, first < displayedRows.count else { return }
            parent.onDoubleClick(displayedRows[first])
        }

        @objc func handleDoubleClick(_ sender: Any?) {
            guard let table = tableView else { return }
            let row = table.clickedRow
            guard row >= 0, row < displayedRows.count else { return }
            parent.onDoubleClick(displayedRows[row])
        }

        // MARK: - Dynamic Context Menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table = tableView else { return }

            let clicked = table.clickedRow
            guard clicked >= 0, clicked < displayedRows.count else {
                menuTargetRows = []
                return
            }

            if !table.selectedRowIndexes.contains(clicked) {
                table.selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false)
            }

            let targets = table.selectedRowIndexes.compactMap { idx -> CommitFileRow? in
                guard idx >= 0, idx < displayedRows.count else { return nil }
                return displayedRows[idx]
            }
            menuTargetRows = targets
            guard !targets.isEmpty else { return }

            if targets.count == 1, let single = targets.first {
                let diffTitle = single.status == .untracked
                    ? L("Open", "打开")
                    : (parent.vcsType == .svn ? L("Diff with Base", "与 Base 对比") : L("Diff with HEAD", "与 HEAD 对比"))
                addItem(diffTitle, action: #selector(ctxDiff), to: menu)
                if single.status != .untracked {
                    addItem(L("Diff with Previous Version", "和前一版本对比"), action: #selector(ctxDiffPrev), to: menu)
                }
                menu.addItem(.separator())
            }

            if parent.showsCheckboxes {
                let allChecked = targets.allSatisfy { parent.checkedPaths.contains($0.relativePath) }
                addItem(
                    allChecked ? L("Uncheck Selected", "取消勾选选中项") : L("Check Selected", "勾选选中项"),
                    action: #selector(ctxToggleCheck),
                    to: menu
                )
                menu.addItem(.separator())
            }

            if targets.count == 1, let single = targets.first {
                addItem(L("Show Log", "显示日志"), action: #selector(ctxShowLog), to: menu)
                if !single.isDirectory && single.status != .untracked {
                    addItem(L("Blame…", "追溯…"), action: #selector(ctxBlame), to: menu)
                }
                menu.addItem(.separator())
            }

            if targets.contains(where: { $0.status == .untracked }) {
                addItem(L("Add", "添加"), action: #selector(ctxAdd), to: menu)
            }
            if targets.contains(where: { $0.status != .untracked }) {
                addItem(L("Revert…", "复原…"), action: #selector(ctxRevert), to: menu)
                addItem(L("Delete…", "删除…"), action: #selector(ctxDelete), to: menu)
            }
            addItem(L("Add to Ignore List…", "添加到忽略清单…"), action: #selector(ctxIgnore), to: menu)
            addItem(L("Hide Selected File(s)", "隐藏所选文件"), action: #selector(ctxHide), to: menu)

            if parent.vcsType == .git || !parent.changelists.isEmpty {
                let clMenuItem = NSMenuItem(title: L("Move to Changelist", "移动到变更列表"), action: nil, keyEquivalent: "")
                let clSub = NSMenu()
                let clearItem = NSMenuItem(title: L("No Changelist", "无变更列表"), action: #selector(ctxMoveChangelist(_:)), keyEquivalent: "")
                clearItem.target = self
                clearItem.representedObject = nil
                clSub.addItem(clearItem)
                if !parent.changelists.isEmpty {
                    clSub.addItem(.separator())
                }
                for cl in parent.changelists {
                    let item = NSMenuItem(title: cl.name, action: #selector(ctxMoveChangelist(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = cl.id
                    clSub.addItem(item)
                }
                clMenuItem.submenu = clSub
                menu.addItem(clMenuItem)
            }

            menu.addItem(.separator())
            if targets.count == 1 {
                addItem(L("Open", "打开"), action: #selector(ctxOpenFile), to: menu)
            }
            addItem(L("Reveal in Finder", "在访达中显示"), action: #selector(ctxReveal), to: menu)
            addItem(L("Copy Path", "拷贝相对路径"), action: #selector(ctxCopyPath), to: menu)
        }

        private func addItem(_ title: String, action: Selector, to menu: NSMenu) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }

        @objc private func ctxDiff() {
            if let first = menuTargetRows.first { parent.onContextAction(.diff(first)) }
        }
        @objc private func ctxDiffPrev() {
            if let first = menuTargetRows.first { parent.onContextAction(.diffPrevious(first)) }
        }
        @objc private func ctxToggleCheck() {
            let allChecked = menuTargetRows.allSatisfy { parent.checkedPaths.contains($0.relativePath) }
            var updated = parent.checkedPaths
            for row in menuTargetRows {
                if allChecked { updated.remove(row.relativePath) }
                else { updated.insert(row.relativePath) }
            }
            lastCheckedSnapshot = updated
            parent.checkedPaths = updated
            if let table = tableView, !displayedRows.isEmpty {
                table.reloadData(forRowIndexes: IndexSet(0..<displayedRows.count), columnIndexes: IndexSet(integer: 0))
            }
        }
        @objc private func ctxShowLog() {
            if let first = menuTargetRows.first { parent.onContextAction(.showLog(first)) }
        }
        @objc private func ctxBlame() {
            if let first = menuTargetRows.first { parent.onContextAction(.blame(first)) }
        }
        @objc private func ctxAdd() { parent.onContextAction(.add(menuTargetRows)) }
        @objc private func ctxRevert() { parent.onContextAction(.revert(menuTargetRows)) }
        @objc private func ctxDelete() { parent.onContextAction(.delete(menuTargetRows)) }
        @objc private func ctxIgnore() { parent.onContextAction(.addToIgnore(menuTargetRows)) }
        @objc private func ctxHide() { parent.onContextAction(.hideFiles(menuTargetRows)) }
        @objc private func ctxMoveChangelist(_ sender: NSMenuItem) {
            parent.onContextAction(.moveToChangelist(menuTargetRows, sender.representedObject as? UUID))
        }
        @objc private func ctxOpenFile() {
            if let first = menuTargetRows.first { parent.onContextAction(.openFile(first)) }
        }
        @objc private func ctxReveal() { parent.onContextAction(.revealInFinder(menuTargetRows)) }
        @objc private func ctxCopyPath() { parent.onContextAction(.copyPaths(menuTargetRows)) }

        // MARK: - Status Text Colors

        private func statusColor(for status: VcsFileStatus, isDark: Bool) -> NSColor {
            let prefs = SharedStorage.shared.loadConfig().preferences
            let palette = isDark ? prefs.darkColors : prefs.lightColors

            func nsColor(_ c: RepoShellShared.RGBColor) -> NSColor {
                NSColor(
                    srgbRed: CGFloat(c.r) / 255.0,
                    green: CGFloat(c.g) / 255.0,
                    blue: CGFloat(c.b) / 255.0,
                    alpha: 1.0
                )
            }

            switch status {
            case .modified, .typeChanged:
                return nsColor(palette.modified)
            case .added, .renamed, .copied:
                return nsColor(palette.added)
            case .deleted, .missing:
                return nsColor(palette.deleted)
            case .unmerged, .obstructed:
                return nsColor(palette.unmerged)
            case .replaced:
                return .systemPurple
            case .locked:
                return .systemOrange
            case .untracked, .normal, .readOnly, .external, .ignored:
                return .labelColor
            }
        }
    }
}
