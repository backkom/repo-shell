import Foundation

public enum MenuActionIconStyle: Equatable, Sendable {
    case badge(fill: RGBColor)
    case twoTone(primary: RGBColor, secondary: RGBColor)
    case solid(color: RGBColor)

    public var accentColor: RGBColor {
        switch self {
        case .badge(let fill):
            return fill
        case .twoTone(let primary, _):
            return primary
        case .solid(let color):
            return color
        }
    }
}

public enum MenuAction: String, Codable, CaseIterable, Sendable {
    // General & Repository Registration
    case showApp = "show-app"
    case addRepository = "add-repository"
    case excludeRepository = "exclude-repository"
    case refresh = "refresh"

    // Basic Git Operations
    case gitClone = "git-clone"
    case gitInit = "git-init"
    case gitCommit = "git-commit"
    case gitPull = "git-pull"
    case gitFetch = "git-fetch"
    case gitPush = "git-push"
    case showLog = "show-log"
    case checkForModifications = "check-for-modifications"
    case browseReferences = "browse-references"

    // Stash
    case stashPush = "git-stash-push"
    case stashList = "git-stash-list"

    // Working Tree & Files
    case repoBrowser = "repo-browser"
    case resolveConflicts = "git-resolve"
    case revert = "git-revert"
    case checkout = "git-checkout"
    case createBranch = "create-branch"
    case createTag = "create-tag"
    case merge = "git-merge"
    case abortMerge = "abort-merge"
    case reset = "git-reset"
    case export = "export"
    case diff = "git-diff"
    case diffPrevious = "git-diff-prev"
    case diffLater = "diff-later"
    case diffWithLater = "diff-with-later"
    case add = "git-add"
    case delete = "git-rm"
    case deleteKeepLocal = "git-rm-cached"
    case rename = "git-rename"
    case addToIgnore = "add-to-ignore"
    case repoInfo = "repo-info"
    case cleanup = "git-gc"

    // Advanced Git Operations
    case rebase = "git-rebase"
    case cherryPick = "git-cherry-pick"
    case showRefLog = "show-reflog"
    case compareRevisions = "compare-revisions"
    case blame = "git-blame"
    case submoduleAdd = "submodule-add"
    case submoduleUpdate = "submodule-update"
    case submoduleManage = "submodule-manage"

    // SVN Basic & Advanced Operations (SnailSVN 1.10 parity)
    case svnCommit = "svn-commit"
    case svnCheckout = "svn-checkout"
    case svnCreateRepo = "svn-create-repo"
    case svnImport = "svn-import"
    case svnUpdate = "svn-update"
    case svnUpdateToRevision = "svn-update-to-revision"
    case svnBranchTag = "svn-branch-tag"
    case svnSwitch = "svn-switch"
    case svnMerge = "svn-merge"
    case svnMove = "svn-move"
    case svnCleanup = "svn-cleanup"
    case svnInfo = "svn-info"
    case svnUpgrade = "svn-upgrade"
    case svnLock = "svn-lock"
    case svnUnlock = "svn-unlock"
    case svnProperties = "svn-properties"
    case svnRelocate = "svn-relocate"
    case svnCreatePatch = "svn-create-patch"
    case svnApplyPatch = "svn-apply-patch"

    public var acceptsSelectedFiles: Bool {
        switch self {
        case .gitCommit, .svnCommit, .svnUpdate, .svnUpdateToRevision, .svnCleanup, .svnInfo,
             .svnLock, .svnUnlock, .svnProperties, .svnCreatePatch, .svnApplyPatch,
             .showLog, .resolveConflicts, .revert, .diff, .diffPrevious,
             .diffLater, .diffWithLater, .add, .delete, .deleteKeepLocal, .rename, .svnMove,
             .addToIgnore, .blame, .checkForModifications:
            return true
        default:
            return false
        }
    }

    public var requiresSelectedFiles: Bool {
        switch self {
        case .diff, .diffPrevious, .diffLater, .diffWithLater, .add, .delete,
             .deleteKeepLocal, .rename, .svnMove, .addToIgnore, .blame:
            return true
        default:
            return false
        }
    }

    public var systemSymbolName: String {
        switch self {
        case .showApp: return "app.badge.fill"
        case .addRepository: return "plus.rectangle.on.folder.fill"
        case .excludeRepository: return "folder.fill.badge.minus"
        case .refresh: return "arrow.clockwise.circle.fill"
        case .gitClone, .svnCheckout: return "arrow.down.doc.fill"
        case .gitInit, .svnCreateRepo: return "folder.fill.badge.plus"
        case .gitCommit, .svnCommit: return "checkmark.circle.fill"
        case .gitPull, .svnUpdate: return "arrow.down.circle.fill"
        case .gitFetch, .svnUpdateToRevision: return "arrow.down.to.line.circle.fill"
        case .gitPush, .svnUpgrade: return "arrow.up.circle.fill"
        case .svnImport: return "square.and.arrow.down.fill"
        case .showLog: return "clock.arrow.circlepath"
        case .checkForModifications: return "doc.text.magnifyingglass"
        case .browseReferences: return "point.3.connected.trianglepath.dotted"
        case .stashPush: return "tray.and.arrow.down.fill"
        case .stashList: return "tray.full.fill"
        case .repoBrowser: return "sidebar.squares.left"
        case .resolveConflicts: return "exclamationmark.triangle.fill"
        case .revert: return "arrow.uturn.backward.circle.fill"
        case .checkout, .svnSwitch: return "arrow.triangle.swap"
        case .createBranch, .svnBranchTag: return "arrow.triangle.branch"
        case .createTag: return "tag.fill"
        case .merge, .svnMerge: return "arrow.triangle.merge"
        case .abortMerge: return "xmark.octagon.fill"
        case .reset: return "backward.end.circle.fill"
        case .export: return "square.and.arrow.up.fill"
        case .diff, .diffPrevious, .diffLater, .diffWithLater, .compareRevisions:
            return "arrow.left.arrow.right.square.fill"
        case .add: return "plus.circle.fill"
        case .delete: return "trash.fill"
        case .deleteKeepLocal: return "trash.slash.fill"
        case .rename: return "pencil.circle.fill"
        case .svnMove: return "arrow.right.circle.fill"
        case .addToIgnore: return "eye.slash.fill"
        case .repoInfo, .svnInfo: return "info.circle.fill"
        case .cleanup, .svnCleanup: return "sparkles"
        case .rebase: return "arrow.up.and.down.text.horizontal"
        case .cherryPick: return "wand.and.stars"
        case .showRefLog: return "list.bullet.rectangle.fill"
        case .blame: return "person.text.rectangle.fill"
        case .submoduleAdd, .submoduleUpdate, .submoduleManage:
            return "shippingbox.fill"
        case .svnLock: return "lock.fill"
        case .svnUnlock: return "lock.open.fill"
        case .svnProperties: return "slider.horizontal.3"
        case .svnRelocate: return "link.circle.fill"
        case .svnCreatePatch, .svnApplyPatch: return "bandage.fill"
        }
    }

    public var iconStyle: MenuActionIconStyle {
        switch self {
        case .gitCommit, .svnCommit, .add:
            return .badge(fill: RGBColor(r: 34, g: 168, b: 83))
        case .gitPull, .svnUpdate, .repoInfo, .svnInfo, .refresh, .rename, .svnMove:
            return .badge(fill: RGBColor(r: 29, g: 124, b: 242))
        case .gitFetch, .svnUpdateToRevision, .diff, .diffPrevious, .diffLater, .diffWithLater, .compareRevisions:
            return .badge(fill: RGBColor(r: 14, g: 154, b: 180))
        case .gitPush, .svnUpgrade:
            return .badge(fill: RGBColor(r: 238, g: 122, b: 24))
        case .resolveConflicts:
            return .badge(fill: RGBColor(r: 234, g: 148, b: 0))
        case .revert:
            return .badge(fill: RGBColor(r: 234, g: 134, b: 0))
        case .reset, .abortMerge:
            return .badge(fill: RGBColor(r: 224, g: 62, b: 62))
        case .svnRelocate:
            return .badge(fill: RGBColor(r: 219, g: 68, b: 143))
        case .showApp:
            return .twoTone(primary: RGBColor(r: 224, g: 62, b: 62), secondary: RGBColor(r: 29, g: 124, b: 242))
        case .addRepository, .gitInit, .svnCreateRepo:
            return .twoTone(primary: RGBColor(r: 34, g: 168, b: 83), secondary: RGBColor(r: 29, g: 124, b: 242))
        case .excludeRepository:
            return .twoTone(primary: RGBColor(r: 224, g: 62, b: 62), secondary: RGBColor(r: 100, g: 116, b: 139))
        case .checkForModifications:
            return .twoTone(primary: RGBColor(r: 29, g: 124, b: 242), secondary: RGBColor(r: 14, g: 154, b: 180))
        case .stashPush:
            return .twoTone(primary: RGBColor(r: 230, g: 134, b: 0), secondary: RGBColor(r: 204, g: 106, b: 0))
        case .gitClone, .svnCheckout, .checkout, .svnSwitch:
            return .solid(color: RGBColor(r: 29, g: 124, b: 242))
        case .showLog, .browseReferences, .merge, .svnMerge:
            return .solid(color: RGBColor(r: 126, g: 87, b: 224))
        case .showRefLog, .rebase, .svnProperties:
            return .solid(color: RGBColor(r: 99, g: 102, b: 241))
        case .repoBrowser, .export, .svnImport:
            return .solid(color: RGBColor(r: 14, g: 154, b: 180))
        case .blame, .svnCreatePatch, .svnApplyPatch:
            return .solid(color: RGBColor(r: 168, g: 85, b: 247))
        case .createBranch, .svnBranchTag, .svnUnlock:
            return .solid(color: RGBColor(r: 34, g: 168, b: 83))
        case .createTag, .cherryPick:
            return .solid(color: RGBColor(r: 219, g: 68, b: 143))
        case .stashList, .svnLock:
            return .solid(color: RGBColor(r: 230, g: 134, b: 0))
        case .submoduleAdd, .submoduleUpdate, .submoduleManage:
            return .solid(color: RGBColor(r: 186, g: 118, b: 42))
        case .delete:
            return .solid(color: RGBColor(r: 224, g: 62, b: 62))
        case .deleteKeepLocal:
            return .solid(color: RGBColor(r: 230, g: 110, b: 40))
        case .addToIgnore:
            return .solid(color: RGBColor(r: 100, g: 116, b: 139))
        case .cleanup, .svnCleanup:
            return .solid(color: RGBColor(r: 234, g: 160, b: 0))
        }
    }

    public var quickActionEligible: Bool {
        switch self {
        case .gitCommit, .gitPull, .gitFetch, .gitPush, .showLog,
             .checkForModifications, .browseReferences, .stashPush, .stashList,
             .repoBrowser, .revert, .checkout, .createBranch, .createTag, .merge,
             .diff, .diffPrevious, .add, .delete, .rename, .blame, .compareRevisions, .export, .repoInfo,
             .svnUpdate, .svnCheckout, .svnCleanup, .svnLock, .svnUnlock, .svnProperties:
            return true
        default:
            return false
        }
    }

    public var localizationKey: String {
        switch self {
        case .showApp: return "menu.showApp"
        case .addRepository: return "menu.addRepository"
        case .excludeRepository: return "menu.excludeRepository"
        case .refresh: return "menu.refresh"
        case .gitClone: return "menu.gitClone"
        case .gitInit: return "menu.gitInit"
        case .gitCommit: return "menu.gitCommit"
        case .gitPull: return "menu.gitPull"
        case .gitFetch: return "menu.gitFetch"
        case .gitPush: return "menu.gitPush"
        case .showLog: return "menu.showLog"
        case .checkForModifications: return "menu.checkModifications"
        case .browseReferences: return "menu.browseReferences"
        case .stashPush: return "menu.stashPush"
        case .stashList: return "menu.stashList"
        case .repoBrowser: return "menu.repoBrowser"
        case .resolveConflicts: return "menu.resolve"
        case .revert: return "menu.revert"
        case .checkout: return "menu.checkout"
        case .createBranch: return "menu.createBranch"
        case .createTag: return "menu.createTag"
        case .merge: return "menu.merge"
        case .abortMerge: return "menu.abortMerge"
        case .reset: return "menu.reset"
        case .export: return "menu.export"
        case .diff: return "menu.diff"
        case .diffPrevious: return "menu.diffPrev"
        case .diffLater: return "menu.diffLater"
        case .diffWithLater: return "menu.diffWithLater"
        case .add: return "menu.add"
        case .delete: return "menu.delete"
        case .deleteKeepLocal: return "menu.deleteKeepLocal"
        case .rename: return "menu.rename"
        case .addToIgnore: return "menu.addToIgnore"
        case .repoInfo: return "menu.repoInfo"
        case .cleanup: return "menu.cleanup"
        case .rebase: return "menu.rebase"
        case .cherryPick: return "menu.cherryPick"
        case .showRefLog: return "menu.showRefLog"
        case .compareRevisions: return "menu.compareRevisions"
        case .blame: return "menu.blame"
        case .submoduleAdd: return "menu.submoduleAdd"
        case .submoduleUpdate: return "menu.submoduleUpdate"
        case .submoduleManage: return "menu.submoduleManage"
        case .svnCommit: return "menu.svnCommit"
        case .svnCheckout: return "menu.svnCheckout"
        case .svnCreateRepo: return "menu.svnCreateRepo"
        case .svnImport: return "menu.svnImport"
        case .svnUpdate: return "menu.svnUpdate"
        case .svnUpdateToRevision: return "menu.svnUpdateToRevision"
        case .svnBranchTag: return "menu.svnBranchTag"
        case .svnSwitch: return "menu.svnSwitch"
        case .svnMerge: return "menu.svnMerge"
        case .svnMove: return "menu.svnMove"
        case .svnCleanup: return "menu.svnCleanup"
        case .svnInfo: return "menu.svnInfo"
        case .svnUpgrade: return "menu.svnUpgrade"
        case .svnLock: return "menu.svnLock"
        case .svnUnlock: return "menu.svnUnlock"
        case .svnProperties: return "menu.svnProperties"
        case .svnRelocate: return "menu.svnRelocate"
        case .svnCreatePatch: return "menu.svnCreatePatch"
        case .svnApplyPatch: return "menu.svnApplyPatch"
        }
    }
}

public enum ResolvedMenuItem: Equatable, Sendable {
    case item(action: MenuAction, title: String)
    case submenu(title: String, symbolName: String, items: [ResolvedMenuItem])
    case separator
}

public struct MenuResolutionContext: Sendable {
    public var targetDirectoryPath: String
    public var selectedPaths: [String]
    public var matchedRepo: RepositoryEntry?
    public var snapshot: RepoStatusSnapshot?
    public var diffLaterState: DiffLaterState?
    public var directoryContainsGitFolder: Bool
    public var directoryContainsSvnFolder: Bool
    public var isDirectoryCleanRepoCandidate: Bool
    public var language: AppLanguage

    public init(
        targetDirectoryPath: String,
        selectedPaths: [String],
        matchedRepo: RepositoryEntry?,
        snapshot: RepoStatusSnapshot?,
        diffLaterState: DiffLaterState?,
        directoryContainsGitFolder: Bool,
        directoryContainsSvnFolder: Bool = false,
        isDirectoryCleanRepoCandidate: Bool = true,
        language: AppLanguage = .system
    ) {
        self.targetDirectoryPath = PathUtils.normalize(targetDirectoryPath)
        self.selectedPaths = selectedPaths.map { PathUtils.normalize($0) }
        self.matchedRepo = matchedRepo
        self.snapshot = snapshot
        self.diffLaterState = diffLaterState
        self.directoryContainsGitFolder = directoryContainsGitFolder
        self.directoryContainsSvnFolder = directoryContainsSvnFolder
        self.isDirectoryCleanRepoCandidate = isDirectoryCleanRepoCandidate
        self.language = language
    }
}

public enum MenuVisibilityResolver {
    public static func resolveMenu(
        for context: MenuResolutionContext,
        forToolbar: Bool = false
    ) -> [ResolvedMenuItem] {
        let loc = Localization(language: context.language)

        // Outside any monitored repository
        guard let repo = context.matchedRepo else {
            var items: [ResolvedMenuItem] = []
            if context.directoryContainsGitFolder || context.directoryContainsSvnFolder {
                items.append(.item(action: .addRepository, title: loc.string("menu.addRepository")))
            }
            items.append(.item(action: .gitClone, title: loc.string("menu.gitClone")))
            if context.isDirectoryCleanRepoCandidate {
                items.append(.item(action: .gitInit, title: loc.string("menu.gitInit")))
            }
            items.append(.separator)
            items.append(.item(action: .svnCheckout, title: loc.string("menu.svnCheckout")))
            if context.isDirectoryCleanRepoCandidate {
                items.append(.item(action: .svnCreateRepo, title: loc.string("menu.svnCreateRepo")))
            }
            items.append(.item(action: .svnImport, title: loc.string("menu.svnImport")))
            items.append(.separator)
            items.append(.item(action: .showApp, title: loc.string("menu.showApp")))
            return items
        }

        let paths = context.selectedPaths.isEmpty ? [context.targetDirectoryPath] : context.selectedPaths
        let statuses: [VcsFileStatus] = paths.map { path in
            context.snapshot?.status(forAbsolutePath: path) ?? .normal
        }

        let singleFileSelected: String? = {
            guard context.selectedPaths.count == 1, let p = context.selectedPaths.first else {
                return nil
            }
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: p, isDirectory: &isDir) {
                return isDir.boolValue ? nil : p
            }
            // If file does not exist (e.g. deleted file or unit test), treat non-repo-root as file candidate
            return PathUtils.normalize(p) == repo.path ? nil : p
        }()

        switch repo.vcsType {
        case .svn:
            return resolveSvnMenu(
                repo: repo,
                context: context,
                paths: paths,
                statuses: statuses,
                singleFileSelected: singleFileSelected,
                forToolbar: forToolbar,
                loc: loc
            )
        case .git:
            return resolveGitMenu(
                repo: repo,
                context: context,
                paths: paths,
                statuses: statuses,
                singleFileSelected: singleFileSelected,
                forToolbar: forToolbar,
                loc: loc
            )
        }
    }

    private static func resolveSvnMenu(
        repo: RepositoryEntry,
        context: MenuResolutionContext,
        paths: [String],
        statuses: [VcsFileStatus],
        singleFileSelected: String?,
        forToolbar: Bool,
        loc: Localization
    ) -> [ResolvedMenuItem] {
        let branchName = context.snapshot?.branchName ?? ""
        let hasUntracked = statuses.contains(.untracked)
        let hasTrackedOrChanged = statuses.contains { $0 != .untracked && $0 != .ignored }
        let hasRevertible = statuses.contains { $0 != .normal && $0 != .untracked && $0 != .ignored }
        let hasConflicts = statuses.contains(.unmerged)
        let isRepoRootSelected = paths.count == 1 && PathUtils.normalize(paths[0]) == repo.path

        var items: [ResolvedMenuItem] = []

        items.append(.item(action: .svnUpdate, title: loc.string("menu.svnUpdate")))
        items.append(.item(action: .svnUpdateToRevision, title: loc.string("menu.svnUpdateToRevision")))

        let commitTitle = branchName.isEmpty
            ? loc.string("menu.svnCommit")
            : String(format: loc.string("menu.svnCommitBranch"), branchName)
        items.append(.item(action: .svnCommit, title: commitTitle))

        if !forToolbar, let file = singleFileSelected {
            let status = context.snapshot?.status(forAbsolutePath: file) ?? .normal
            if status != .untracked && status != .ignored {
                items.append(.item(action: .diff, title: loc.string("menu.diff")))
                items.append(.item(action: .diffPrevious, title: loc.string("menu.diffPrev")))
            }
            items.append(.item(action: .diffLater, title: loc.string("menu.diffLater")))
            if let later = context.diffLaterState, PathUtils.normalize(later.filePath) != PathUtils.normalize(file) {
                items.append(.item(
                    action: .diffWithLater,
                    title: String(format: loc.string("menu.diffWithLater"), later.fileName)
                ))
            }
        } else if !forToolbar && hasTrackedOrChanged {
            items.append(.item(action: .diff, title: loc.string("menu.diff")))
        }

        items.append(.separator)
        items.append(.item(action: .showLog, title: loc.string("menu.showLog")))
        items.append(.item(action: .checkForModifications, title: loc.string("menu.checkModifications")))
        items.append(.item(action: .repoBrowser, title: loc.string("menu.repoBrowser")))
        items.append(.item(action: .svnInfo, title: loc.string("menu.svnInfo")))

        items.append(.separator)
        if hasConflicts {
            items.append(.item(action: .resolveConflicts, title: loc.string("menu.resolve")))
        }
        if hasRevertible || !forToolbar {
            items.append(.item(action: .revert, title: loc.string("menu.revert")))
        }

        if !forToolbar {
            if hasUntracked {
                items.append(.item(action: .add, title: loc.string("menu.add")))
            }
            if hasUntracked || hasTrackedOrChanged {
                items.append(.item(action: .addToIgnore, title: loc.string("menu.addToIgnore")))
            }
            if hasTrackedOrChanged && !isRepoRootSelected {
                items.append(.item(action: .delete, title: loc.string("menu.delete")))
                items.append(.item(action: .deleteKeepLocal, title: loc.string("menu.deleteKeepLocal")))
                if context.selectedPaths.count == 1 {
                    items.append(.item(action: .rename, title: loc.string("menu.rename")))
                    items.append(.item(action: .svnMove, title: loc.string("menu.svnMove")))
                }
            }
            if singleFileSelected != nil {
                items.append(.item(action: .blame, title: loc.string("menu.blame")))
            }
        }

        items.append(.separator)
        items.append(.item(action: .svnBranchTag, title: loc.string("menu.svnBranchTag")))
        items.append(.item(action: .svnSwitch, title: loc.string("menu.svnSwitch")))
        items.append(.item(action: .svnMerge, title: loc.string("menu.svnMerge")))
        items.append(.item(action: .compareRevisions, title: loc.string("menu.compareRevisions")))
        items.append(.item(action: .export, title: loc.string("menu.export")))

        items.append(.separator)
        items.append(.item(action: .svnLock, title: loc.string("menu.svnLock")))
        items.append(.item(action: .svnUnlock, title: loc.string("menu.svnUnlock")))
        items.append(.item(action: .svnProperties, title: loc.string("menu.svnProperties")))

        items.append(.separator)
        items.append(.item(action: .svnCreatePatch, title: loc.string("menu.svnCreatePatch")))
        items.append(.item(action: .svnApplyPatch, title: loc.string("menu.svnApplyPatch")))
        items.append(.item(action: .svnRelocate, title: loc.string("menu.svnRelocate")))
        items.append(.item(action: .svnImport, title: loc.string("menu.svnImport")))

        items.append(.separator)
        items.append(.item(action: .svnCleanup, title: loc.string("menu.svnCleanup")))
        items.append(.item(action: .svnUpgrade, title: loc.string("menu.svnUpgrade")))
        items.append(.item(action: .refresh, title: loc.string("menu.refresh")))
        if isRepoRootSelected {
            items.append(.item(action: .excludeRepository, title: loc.string("menu.excludeRepository")))
        }
        items.append(.item(action: .showApp, title: loc.string("menu.showApp")))

        return items
    }

    private static func resolveGitMenu(
        repo: RepositoryEntry,
        context: MenuResolutionContext,
        paths: [String],
        statuses: [VcsFileStatus],
        singleFileSelected: String?,
        forToolbar: Bool,
        loc: Localization
    ) -> [ResolvedMenuItem] {
        // Inside a monitored Git repository
        let branchName = context.snapshot?.branchName ?? ""
        let repoState = context.snapshot?.repoState ?? .normal

        let hasUntracked = statuses.contains(.untracked)
        let hasTrackedOrChanged = statuses.contains { $0 != .untracked && $0 != .ignored }
        let hasRevertible = statuses.contains { $0 != .normal && $0 != .untracked && $0 != .ignored }
        let hasConflicts = repoState == .merging || statuses.contains(.unmerged)
        let isRepoRootSelected = paths.count == 1 && PathUtils.normalize(paths[0]) == repo.path

        var items: [ResolvedMenuItem] = []

        // Top primary action: Commit (with current branch)
        let commitTitle = branchName.isEmpty
            ? loc.string("menu.gitCommit")
            : String(format: loc.string("menu.gitCommitBranch"), branchName)
        items.append(.item(action: .gitCommit, title: commitTitle))

        if !forToolbar, let file = singleFileSelected {
            let status = context.snapshot?.status(forAbsolutePath: file) ?? .normal
            if status != .untracked && status != .ignored {
                items.append(.item(action: .diff, title: loc.string("menu.diff")))
                items.append(.item(action: .diffPrevious, title: loc.string("menu.diffPrev")))
            }
            items.append(.item(action: .diffLater, title: loc.string("menu.diffLater")))
            if let later = context.diffLaterState, PathUtils.normalize(later.filePath) != PathUtils.normalize(file) {
                items.append(.item(
                    action: .diffWithLater,
                    title: String(format: loc.string("menu.diffWithLater"), later.fileName)
                ))
            }
        }

        items.append(.separator)
        items.append(.item(action: .gitPull, title: loc.string("menu.gitPull")))
        items.append(.item(action: .gitFetch, title: loc.string("menu.gitFetch")))
        items.append(.item(action: .gitPush, title: loc.string("menu.gitPush")))

        items.append(.separator)
        items.append(.item(action: .showLog, title: loc.string("menu.showLog")))
        items.append(.item(action: .checkForModifications, title: loc.string("menu.checkModifications")))
        items.append(.item(action: .browseReferences, title: loc.string("menu.browseReferences")))
        items.append(.item(action: .showRefLog, title: loc.string("menu.showRefLog")))
        items.append(.item(action: .repoBrowser, title: loc.string("menu.repoBrowser")))

        items.append(.separator)
        if hasConflicts {
            items.append(.item(action: .resolveConflicts, title: loc.string("menu.resolve")))
        }
        if repoState == .merging {
            items.append(.item(action: .abortMerge, title: loc.string("menu.abortMerge")))
        }
        if hasRevertible || !forToolbar {
            items.append(.item(action: .revert, title: loc.string("menu.revert")))
        }

        if !forToolbar {
            if hasUntracked {
                items.append(.item(action: .add, title: loc.string("menu.add")))
            }
            if hasUntracked || hasTrackedOrChanged {
                items.append(.item(action: .addToIgnore, title: loc.string("menu.addToIgnore")))
            }
            if hasTrackedOrChanged && !isRepoRootSelected {
                items.append(.item(action: .delete, title: loc.string("menu.delete")))
                items.append(.item(action: .deleteKeepLocal, title: loc.string("menu.deleteKeepLocal")))
                if context.selectedPaths.count == 1 {
                    items.append(.item(action: .rename, title: loc.string("menu.rename")))
                }
            }
            if singleFileSelected != nil {
                items.append(.item(action: .blame, title: loc.string("menu.blame")))
            }
        }

        items.append(.separator)
        items.append(.item(action: .checkout, title: loc.string("menu.checkout")))
        items.append(.item(action: .createBranch, title: loc.string("menu.createBranch")))
        items.append(.item(action: .createTag, title: loc.string("menu.createTag")))
        items.append(.item(action: .merge, title: loc.string("menu.merge")))
        items.append(.item(action: .rebase, title: loc.string("menu.rebase")))
        items.append(.item(action: .cherryPick, title: loc.string("menu.cherryPick")))
        items.append(.item(action: .reset, title: loc.string("menu.reset")))

        items.append(.separator)
        items.append(.item(action: .stashPush, title: loc.string("menu.stashPush")))
        items.append(.item(action: .stashList, title: loc.string("menu.stashList")))
        items.append(.item(action: .compareRevisions, title: loc.string("menu.compareRevisions")))
        items.append(.item(action: .export, title: loc.string("menu.export")))

        let submoduleItems: [ResolvedMenuItem] = [
            .item(action: .submoduleAdd, title: loc.string("menu.submoduleAdd")),
            .item(action: .submoduleUpdate, title: loc.string("menu.submoduleUpdate")),
            .item(action: .submoduleManage, title: loc.string("menu.submoduleManage"))
        ]
        items.append(.submenu(title: loc.string("menu.submodules"), symbolName: "shippingbox.fill", items: submoduleItems))

        items.append(.separator)
        items.append(.item(action: .repoInfo, title: loc.string("menu.repoInfo")))
        items.append(.item(action: .cleanup, title: loc.string("menu.cleanup")))
        items.append(.item(action: .refresh, title: loc.string("menu.refresh")))
        if isRepoRootSelected {
            items.append(.item(action: .excludeRepository, title: loc.string("menu.excludeRepository")))
        }
        items.append(.item(action: .showApp, title: loc.string("menu.showApp")))

        return items
    }

    public static func partitionForCascade(
        items: [ResolvedMenuItem],
        topLevelActions: [MenuAction]
    ) -> (topLevel: [ResolvedMenuItem], submenu: [ResolvedMenuItem]) {
        guard !topLevelActions.isEmpty else {
            return ([], sanitizeSeparators(items))
        }
        let topSet = Set(topLevelActions)
        var topLevel: [ResolvedMenuItem] = []
        var rawSubmenu: [ResolvedMenuItem] = []

        for item in items {
            if case .item(let action, _) = item, topSet.contains(action) {
                topLevel.append(item)
            } else {
                rawSubmenu.append(item)
            }
        }
        return (topLevel, sanitizeSeparators(rawSubmenu))
    }

    private static func sanitizeSeparators(_ items: [ResolvedMenuItem]) -> [ResolvedMenuItem] {
        var result: [ResolvedMenuItem] = []
        for item in items {
            if case .separator = item {
                if result.isEmpty { continue }
                if case .separator = result.last { continue }
            }
            result.append(item)
        }
        while case .separator = result.last {
            result.removeLast()
        }
        return result
    }
}
