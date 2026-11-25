import Foundation
import RepoShellShared

public enum GitReferenceKind: String, Codable, Sendable {
    case localBranch
    case remoteBranch
    case tag
}

public struct GitReference: Identifiable, Equatable, Sendable {
    public var id: String { fullName }
    public var fullName: String
    public var shortName: String
    public var kind: GitReferenceKind
    public var objectHash: String
    public var isCurrent: Bool
    public var upstream: String?
    public var aheadBehind: String?
    public var lastCommitSubject: String
    public var lastCommitDate: Date?

    public init(
        fullName: String,
        shortName: String,
        kind: GitReferenceKind,
        objectHash: String,
        isCurrent: Bool = false,
        upstream: String? = nil,
        aheadBehind: String? = nil,
        lastCommitSubject: String = "",
        lastCommitDate: Date? = nil
    ) {
        self.fullName = fullName
        self.shortName = shortName
        self.kind = kind
        self.objectHash = objectHash
        self.isCurrent = isCurrent
        self.upstream = upstream
        self.aheadBehind = aheadBehind
        self.lastCommitSubject = lastCommitSubject
        self.lastCommitDate = lastCommitDate
    }
}

public struct GitRemote: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public var name: String
    public var fetchURL: String
    public var pushURL: String

    public init(name: String, fetchURL: String, pushURL: String? = nil) {
        self.name = name
        self.fetchURL = fetchURL
        self.pushURL = pushURL ?? fetchURL
    }
}

public struct GitStashEntry: Identifiable, Equatable, Sendable {
    public var id: String { refName }
    public var index: Int
    public var refName: String
    public var commitHash: String
    public var shortHash: String
    public var branchName: String
    public var message: String
    public var date: Date

    public init(
        index: Int,
        refName: String,
        commitHash: String,
        shortHash: String,
        branchName: String,
        message: String,
        date: Date
    ) {
        self.index = index
        self.refName = refName
        self.commitHash = commitHash
        self.shortHash = shortHash
        self.branchName = branchName
        self.message = message
        self.date = date
    }
}

public struct GitRefLogEntry: Identifiable, Equatable, Sendable {
    public var id: String { "\(selector):\(hash)" }
    public var index: Int
    public var selector: String
    public var hash: String
    public var shortHash: String
    public var actionSummary: String
    public var message: String
    public var date: Date

    public init(
        index: Int,
        selector: String,
        hash: String,
        shortHash: String,
        actionSummary: String,
        message: String,
        date: Date
    ) {
        self.index = index
        self.selector = selector
        self.hash = hash
        self.shortHash = shortHash
        self.actionSummary = actionSummary
        self.message = message
        self.date = date
    }
}

public struct GitSubmodule: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public var name: String
    public var path: String
    public var url: String
    public var branch: String?
    public var commitHash: String
    public var stateDescription: String

    public init(
        name: String,
        path: String,
        url: String,
        branch: String? = nil,
        commitHash: String,
        stateDescription: String
    ) {
        self.name = name
        self.path = path
        self.url = url
        self.branch = branch
        self.commitHash = commitHash
        self.stateDescription = stateDescription
    }
}

public enum GitRebaseAction: String, CaseIterable, Codable, Sendable {
    case pick
    case reword
    case edit
    case squash
    case fixup
    case drop

    public var displayTitle: String {
        switch self {
        case .pick: return "Pick"
        case .reword: return "Reword"
        case .edit: return "Edit"
        case .squash: return "Squash"
        case .fixup: return "Fixup"
        case .drop: return "Drop"
        }
    }
}

public struct GitRebaseTodoItem: Identifiable, Equatable, Sendable {
    public var id: String { hash }
    public var index: Int
    public var hash: String
    public var shortHash: String
    public var author: String
    public var date: Date
    public var message: String
    public var action: GitRebaseAction
    public var editedMessage: String?

    public init(
        index: Int,
        hash: String,
        shortHash: String,
        author: String,
        date: Date,
        message: String,
        action: GitRebaseAction = .pick,
        editedMessage: String? = nil
    ) {
        self.index = index
        self.hash = hash
        self.shortHash = shortHash
        self.author = author
        self.date = date
        self.message = message
        self.action = action
        self.editedMessage = editedMessage
    }
}

public struct GitCherryPickItem: Identifiable, Equatable, Sendable {
    public var id: String { hash }
    public var order: Int
    public var hash: String
    public var shortHash: String
    public var author: String
    public var date: Date
    public var message: String

    public init(
        order: Int,
        hash: String,
        shortHash: String,
        author: String,
        date: Date,
        message: String
    ) {
        self.order = order
        self.hash = hash
        self.shortHash = shortHash
        self.author = author
        self.date = date
        self.message = message
    }
}

public enum GitPullStrategy: String, CaseIterable, Sendable {
    case merge
    case rebase
    case fastForwardOnly
}

public enum GitResetMode: String, CaseIterable, Sendable {
    case soft
    case mixed
    case hard
}

public struct GitPullOptions: Sendable {
    public var remote: String
    public var remoteBranch: String?
    public var strategy: GitPullStrategy
    public var noFastForward: Bool
    public var noCommit: Bool
    public var includeMergeLog: Bool
    public var fetchTags: Bool
    public var fetchAllRemotes: Bool

    public init(
        remote: String = "origin",
        remoteBranch: String? = nil,
        strategy: GitPullStrategy = .merge,
        noFastForward: Bool = false,
        noCommit: Bool = false,
        includeMergeLog: Bool = false,
        fetchTags: Bool = true,
        fetchAllRemotes: Bool = false
    ) {
        self.remote = remote
        self.remoteBranch = remoteBranch
        self.strategy = strategy
        self.noFastForward = noFastForward
        self.noCommit = noCommit
        self.includeMergeLog = includeMergeLog
        self.fetchTags = fetchTags
        self.fetchAllRemotes = fetchAllRemotes
    }
}

public struct GitFetchOptions: Sendable {
    public var remote: String
    public var fetchAllRemotes: Bool
    public var prune: Bool
    public var fetchTags: Bool

    public init(
        remote: String = "origin",
        fetchAllRemotes: Bool = false,
        prune: Bool = false,
        fetchTags: Bool = true
    ) {
        self.remote = remote
        self.fetchAllRemotes = fetchAllRemotes
        self.prune = prune
        self.fetchTags = fetchTags
    }
}

public struct GitPushBranchMapping: Identifiable, Equatable, Sendable {
    public var id: String { "\(localBranch)->\(remoteBranch)" }
    public var localBranch: String
    public var remoteBranch: String
    public var isSelected: Bool

    public init(localBranch: String, remoteBranch: String, isSelected: Bool = true) {
        self.localBranch = localBranch
        self.remoteBranch = remoteBranch
        self.isSelected = isSelected
    }
}

public struct GitPushOptions: Sendable {
    public var remote: String
    public var branchMappings: [GitPushBranchMapping]
    public var tags: [String]
    public var pushAllTags: Bool
    public var setUpstream: Bool
    public var force: Bool
    public var forceWithLease: Bool

    public init(
        remote: String = "origin",
        branchMappings: [GitPushBranchMapping] = [],
        tags: [String] = [],
        pushAllTags: Bool = false,
        setUpstream: Bool = false,
        force: Bool = false,
        forceWithLease: Bool = false
    ) {
        self.remote = remote
        self.branchMappings = branchMappings
        self.tags = tags
        self.pushAllTags = pushAllTags
        self.setUpstream = setUpstream
        self.force = force
        self.forceWithLease = forceWithLease
    }
}

public struct GitMergeOptions: Sendable {
    public var sourceRef: String
    public var noFastForward: Bool
    public var squash: Bool
    public var noCommit: Bool
    public var logCount: Int?
    public var message: String?

    public init(
        sourceRef: String,
        noFastForward: Bool = false,
        squash: Bool = false,
        noCommit: Bool = false,
        logCount: Int? = nil,
        message: String? = nil
    ) {
        self.sourceRef = sourceRef
        self.noFastForward = noFastForward
        self.squash = squash
        self.noCommit = noCommit
        self.logCount = logCount
        self.message = message
    }
}

public struct GitCloneOptions: Sendable {
    public var url: String
    public var destinationPath: String
    public var branch: String?
    public var singleBranch: Bool
    public var recursiveSubmodules: Bool
    public var bare: Bool

    public init(
        url: String,
        destinationPath: String,
        branch: String? = nil,
        singleBranch: Bool = false,
        recursiveSubmodules: Bool = true,
        bare: Bool = false
    ) {
        self.url = url
        self.destinationPath = destinationPath
        self.branch = branch
        self.singleBranch = singleBranch
        self.recursiveSubmodules = recursiveSubmodules
        self.bare = bare
    }
}

public struct GitSubmoduleUpdateOptions: Sendable {
    public var paths: [String]
    public var initSubmodules: Bool
    public var recursive: Bool
    public var remote: Bool
    public var merge: Bool
    public var rebase: Bool
    public var force: Bool
    public var noFetch: Bool

    public init(
        paths: [String] = [],
        initSubmodules: Bool = true,
        recursive: Bool = true,
        remote: Bool = false,
        merge: Bool = false,
        rebase: Bool = false,
        force: Bool = false,
        noFetch: Bool = false
    ) {
        self.paths = paths
        self.initSubmodules = initSubmodules
        self.recursive = recursive
        self.remote = remote
        self.merge = merge
        self.rebase = rebase
        self.force = force
        self.noFetch = noFetch
    }
}

public struct GitRepoSummary: Equatable, Sendable {
    public var repoPath: String
    public var currentBranch: String
    public var headHash: String
    public var upstreamBranch: String?
    public var totalCommits: Int
    public var isBare: Bool
    public var repoState: VcsRepoState
    public var remotes: [GitRemote]
    public var submodules: [GitSubmodule]

    public init(
        repoPath: String,
        currentBranch: String,
        headHash: String,
        upstreamBranch: String?,
        totalCommits: Int,
        isBare: Bool,
        repoState: VcsRepoState,
        remotes: [GitRemote],
        submodules: [GitSubmodule]
    ) {
        self.repoPath = repoPath
        self.currentBranch = currentBranch
        self.headHash = headHash
        self.upstreamBranch = upstreamBranch
        self.totalCommits = totalCommits
        self.isBare = isBare
        self.repoState = repoState
        self.remotes = remotes
        self.submodules = submodules
    }
}
