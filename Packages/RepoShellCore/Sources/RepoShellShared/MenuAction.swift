import Foundation

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

    // V2 SVN Extension Slots (unused in V1 Git UI, ready for V2)
    case svnCheckout = "svn-checkout"
    case svnUpdate = "svn-update"
    case svnLock = "svn-lock"
    case svnUnlock = "svn-unlock"
    case svnProperties = "svn-properties"
    case svnRelocate = "svn-relocate"
    case svnCreatePatch = "svn-create-patch"
    case svnApplyPatch = "svn-apply-patch"

    public var acceptsSelectedFiles: Bool {
        switch self {
        case .gitCommit, .showLog, .resolveConflicts, .revert, .diff, .diffPrevious,
             .diffLater, .diffWithLater, .add, .delete, .deleteKeepLocal, .rename,
             .addToIgnore, .blame, .checkForModifications:
            return true
        default:
            return false
        }
    }

    public var requiresSelectedFiles: Bool {
        switch self {
        case .diff, .diffPrevious, .diffLater, .diffWithLater, .add, .delete,
             .deleteKeepLocal, .rename, .addToIgnore, .blame:
            return true
        default:
            return false
        }
    }

    public var systemSymbolName: String {
        switch self {
        case .showApp: return "app.badge"
        case .addRepository: return "plus.rectangle.on.folder"
        case .excludeRepository: return "folder.badge.minus"
        case .refresh: return "arrow.clockwise"
        case .gitClone, .svnCheckout: return "arrow.down.doc"
        case .gitInit: return "folder.badge.plus"
        case .gitCommit: return "checkmark.circle"
        case .gitPull, .svnUpdate: return "arrow.down.circle"
        case .gitFetch: return "arrow.down.to.line"
        case .gitPush: return "arrow.up.circle"
        case .showLog: return "clock.arrow.circlepath"
        case .checkForModifications: return "doc.text.magnifyingglass"
        case .browseReferences: return "point.3.connected.trianglepath.dotted"
        case .stashPush: return "tray.and.arrow.down"
        case .stashList: return "tray.full"
        case .repoBrowser: return "sidebar.squares.left"
        case .resolveConflicts: return "exclamationmark.triangle"
        case .revert: return "arrow.uturn.backward"
        case .checkout: return "arrow.triangle.swap"
        case .createBranch: return "arrow.triangle.branch"
        case .createTag: return "tag"
        case .merge: return "arrow.triangle.merge"
        case .abortMerge: return "xmark.octagon"
        case .reset: return "backward.end"
        case .export: return "square.and.arrow.up"
        case .diff, .diffPrevious, .diffLater, .diffWithLater, .compareRevisions:
            return "arrow.left.arrow.right.square"
        case .add: return "plus.circle"
        case .delete, .deleteKeepLocal: return "trash"
        case .rename: return "pencil"
        case .addToIgnore: return "eye.slash"
        case .repoInfo: return "info.circle"
        case .cleanup: return "sparkles"
        case .rebase: return "arrow.up.and.down.text.horizontal"
        case .cherryPick: return "wand.and.stars"
        case .showRefLog: return "list.bullet.rectangle"
        case .blame: return "person.text.rectangle"
        case .submoduleAdd, .submoduleUpdate, .submoduleManage:
            return "shippingbox"
        default: return "gear"
        }
    }

    public var quickActionEligible: Bool {
        switch self {
        case .gitCommit, .gitPull, .gitFetch, .gitPush, .showLog,
             .checkForModifications, .browseReferences, .stashPush, .stashList,
             .repoBrowser, .revert, .checkout, .createBranch, .createTag, .merge,
             .diff, .diffPrevious, .add, .blame, .repoInfo:
            return true
        default:
            return false
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
    public var isDirectoryCleanRepoCandidate: Bool
    public var language: AppLanguage

    public init(
        targetDirectoryPath: String,
        selectedPaths: [String],
        matchedRepo: RepositoryEntry?,
        snapshot: RepoStatusSnapshot?,
        diffLaterState: DiffLaterState?,
        directoryContainsGitFolder: Bool,
        isDirectoryCleanRepoCandidate: Bool = true,
        language: AppLanguage = .system
    ) {
        self.targetDirectoryPath = PathUtils.normalize(targetDirectoryPath)
        self.selectedPaths = selectedPaths.map { PathUtils.normalize($0) }
        self.matchedRepo = matchedRepo
        self.snapshot = snapshot
        self.diffLaterState = diffLaterState
        self.directoryContainsGitFolder = directoryContainsGitFolder
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
            if context.directoryContainsGitFolder {
                items.append(.item(action: .addRepository, title: loc.string("menu.addRepository")))
            }
            items.append(.item(action: .gitClone, title: loc.string("menu.gitClone")))
            if context.isDirectoryCleanRepoCandidate {
                items.append(.item(action: .gitInit, title: loc.string("menu.gitInit")))
            }
            items.append(.separator)
            items.append(.item(action: .showApp, title: loc.string("menu.showApp")))
            return items
        }

        // Inside a monitored Git repository
        let branchName = context.snapshot?.branchName ?? ""
        let repoState = context.snapshot?.repoState ?? .normal
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
        items.append(.submenu(title: loc.string("menu.submodules"), symbolName: "shippingbox", items: submoduleItems))

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
}
