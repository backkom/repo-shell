import Foundation
import RepoShellShared

public enum VcsError: LocalizedError, Sendable {
    case executableNotFound(String)
    case commandFailed(command: String, exitCode: Int32, stderr: String, stdout: String)
    case cancelled
    case invalidRepository(String)
    case unsupportedInV1(String)
    case parseError(String)

    public var errorDescription: String? {
        switch self {
        case .executableNotFound(let msg):
            return "Executable not found: \(msg)"
        case .commandFailed(let cmd, let code, let stderr, let stdout):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = detail.isEmpty ? fallback : detail
            return "Command failed (\(code)): \(cmd)\n\(message)"
        case .cancelled:
            return "Operation was cancelled."
        case .invalidRepository(let path):
            return "Not a valid repository: \(path)"
        case .unsupportedInV1(let feature):
            return "\(feature) will be supported in V2."
        case .parseError(let detail):
            return "Parse error: \(detail)"
        }
    }
}

public struct VcsCommandResult: Equatable, Sendable {
    public var command: String
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String

    public init(command: String, exitCode: Int32, stdout: String, stderr: String) {
        self.command = command
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public struct VcsStatusItem: Identifiable, Equatable, Sendable {
    public var id: String { relativePath }
    public var relativePath: String
    public var absolutePath: String
    public var originalPath: String?
    public var status: VcsFileStatus
    public var indexStatusCode: Character
    public var workTreeStatusCode: Character
    public var isDirectory: Bool
    public var isStaged: Bool
    public var additions: Int?
    public var deletions: Int?
    public var fileSize: Int64?
    public var modificationDate: Date?

    public init(
        relativePath: String,
        absolutePath: String,
        originalPath: String? = nil,
        status: VcsFileStatus,
        indexStatusCode: Character = " ",
        workTreeStatusCode: Character = " ",
        isDirectory: Bool = false,
        isStaged: Bool = false,
        additions: Int? = nil,
        deletions: Int? = nil,
        fileSize: Int64? = nil,
        modificationDate: Date? = nil
    ) {
        self.relativePath = relativePath
        self.absolutePath = absolutePath
        self.originalPath = originalPath
        self.status = status
        self.indexStatusCode = indexStatusCode
        self.workTreeStatusCode = workTreeStatusCode
        self.isDirectory = isDirectory
        self.isStaged = isStaged
        self.additions = additions
        self.deletions = deletions
        self.fileSize = fileSize
        self.modificationDate = modificationDate
    }
}

public struct VcsStatusResult: Equatable, Sendable {
    public var repoPath: String
    public var branchName: String
    public var upstreamBranch: String?
    public var aheadCount: Int
    public var behindCount: Int
    public var repoState: VcsRepoState
    public var items: [VcsStatusItem]

    public init(
        repoPath: String,
        branchName: String,
        upstreamBranch: String? = nil,
        aheadCount: Int = 0,
        behindCount: Int = 0,
        repoState: VcsRepoState = .normal,
        items: [VcsStatusItem] = []
    ) {
        self.repoPath = repoPath
        self.branchName = branchName
        self.upstreamBranch = upstreamBranch
        self.aheadCount = aheadCount
        self.behindCount = behindCount
        self.repoState = repoState
        self.items = items
    }
}

public struct VcsStatusOptions: Sendable {
    public var includeIgnored: Bool
    public var includeUntracked: Bool
    public var includeLineStats: Bool

    public init(
        includeIgnored: Bool = true,
        includeUntracked: Bool = true,
        includeLineStats: Bool = false
    ) {
        self.includeIgnored = includeIgnored
        self.includeUntracked = includeUntracked
        self.includeLineStats = includeLineStats
    }
}

public struct VcsChangedPath: Identifiable, Equatable, Sendable {
    public var id: String { "\(action):\(path)" }
    public var action: String // A, M, D, R, C, T, U
    public var path: String
    public var copyFromPath: String?
    public var additions: Int?
    public var deletions: Int?

    public init(
        action: String,
        path: String,
        copyFromPath: String? = nil,
        additions: Int? = nil,
        deletions: Int? = nil
    ) {
        self.action = action
        self.path = path
        self.copyFromPath = copyFromPath
        self.additions = additions
        self.deletions = deletions
    }
}

public struct VcsCommit: Identifiable, Equatable, Sendable {
    public var id: String { hash }
    public var hash: String
    public var shortHash: String
    public var parents: [String]
    public var author: String
    public var authorEmail: String
    public var date: Date
    public var subject: String
    public var body: String
    public var refs: [String]
    public var note: String?
    public var changedPaths: [VcsChangedPath]

    public init(
        hash: String,
        shortHash: String,
        parents: [String] = [],
        author: String,
        authorEmail: String,
        date: Date,
        subject: String,
        body: String = "",
        refs: [String] = [],
        note: String? = nil,
        changedPaths: [VcsChangedPath] = []
    ) {
        self.hash = hash
        self.shortHash = shortHash
        self.parents = parents
        self.author = author
        self.authorEmail = authorEmail
        self.date = date
        self.subject = subject
        self.body = body
        self.refs = refs
        self.note = note
        self.changedPaths = changedPaths
    }
}

public struct VcsLogQuery: Sendable {
    public var revisionRange: String?
    public var pathFilter: String?
    public var searchQuery: String?
    public var noMerges: Bool
    public var followRenames: Bool
    public var limit: Int
    public var skip: Int

    public init(
        revisionRange: String? = nil,
        pathFilter: String? = nil,
        searchQuery: String? = nil,
        noMerges: Bool = false,
        followRenames: Bool = false,
        limit: Int = 200,
        skip: Int = 0
    ) {
        self.revisionRange = revisionRange
        self.pathFilter = pathFilter
        self.searchQuery = searchQuery
        self.noMerges = noMerges
        self.followRenames = followRenames
        self.limit = limit
        self.skip = skip
    }
}

public struct VcsCommitOptions: Sendable {
    public var message: String
    public var paths: [String]
    public var amend: Bool
    public var allowEmpty: Bool
    public var stageSelectedPaths: Bool

    public init(
        message: String,
        paths: [String],
        amend: Bool = false,
        allowEmpty: Bool = false,
        stageSelectedPaths: Bool = true
    ) {
        self.message = message
        self.paths = paths
        self.amend = amend
        self.allowEmpty = allowEmpty
        self.stageSelectedPaths = stageSelectedPaths
    }
}

public struct VcsBlameLine: Identifiable, Equatable, Sendable {
    public var id: Int { lineNumber }
    public var lineNumber: Int
    public var originalLineNumber: Int
    public var commitHash: String
    public var shortHash: String
    public var author: String
    public var date: Date?
    public var summary: String
    public var content: String

    public init(
        lineNumber: Int,
        originalLineNumber: Int,
        commitHash: String,
        shortHash: String,
        author: String,
        date: Date?,
        summary: String,
        content: String
    ) {
        self.lineNumber = lineNumber
        self.originalLineNumber = originalLineNumber
        self.commitHash = commitHash
        self.shortHash = shortHash
        self.author = author
        self.date = date
        self.summary = summary
        self.content = content
    }
}

public struct VcsTreeEntry: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public var mode: String
    public var kind: EntryKind
    public var objectHash: String
    public var size: Int64?
    public var name: String
    public var path: String

    public enum EntryKind: String, Codable, Sendable {
        case blob
        case tree
        case submodule
    }

    public init(
        mode: String,
        kind: EntryKind,
        objectHash: String,
        size: Int64?,
        name: String,
        path: String
    ) {
        self.mode = mode
        self.kind = kind
        self.objectHash = objectHash
        self.size = size
        self.name = name
        self.path = path
    }
}

public protocol VcsProvider: Sendable {
    var vcsType: VcsType { get }
    var capabilities: VcsCapability { get }

    func detectRepositoryRoot(for path: String) async -> String?
    func status(repoPath: String, options: VcsStatusOptions) async throws -> VcsStatusResult
    func commit(repoPath: String, options: VcsCommitOptions) async throws -> VcsCommandResult
    func log(repoPath: String, query: VcsLogQuery) async throws -> [VcsCommit]
    func revert(repoPath: String, paths: [String]) async throws -> VcsCommandResult
    func add(repoPath: String, paths: [String]) async throws -> VcsCommandResult
    func remove(repoPath: String, paths: [String], keepLocal: Bool) async throws -> VcsCommandResult
    func blame(repoPath: String, path: String, revision: String?, ignoreWhitespace: Bool) async throws -> [VcsBlameLine]
    func export(repoPath: String, revision: String, destinationPath: String, asZip: Bool) async throws -> VcsCommandResult
    func listDirectory(repoPath: String, path: String, revision: String) async throws -> [VcsTreeEntry]
    func extractFile(repoPath: String, path: String, revision: String, to destinationPath: String) async throws
    func diffRevisions(repoPath: String, rev1: String, rev2: String) async throws -> [VcsChangedPath]
}
