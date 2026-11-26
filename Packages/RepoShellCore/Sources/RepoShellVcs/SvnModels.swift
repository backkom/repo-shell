import Foundation
import RepoShellShared

public enum SvnDepth: String, CaseIterable, Codable, Sendable {
    case infinity = "infinity"
    case immediates = "immediates"
    case files = "files"
    case empty = "empty"

    public var displayTitle: String {
        switch self {
        case .infinity: return "Fully recursive (infinity)"
        case .immediates: return "Immediate children, including folders (immediates)"
        case .files: return "Only file children (files)"
        case .empty: return "Only this item (empty)"
        }
    }
}

public enum SvnConflictAccept: String, CaseIterable, Codable, Sendable {
    case postpone = "postpone"
    case base = "base"
    case mineFull = "mine-full"
    case theirsFull = "theirs-full"
    case mineConflict = "mine-conflict"
    case theirsConflict = "theirs-conflict"
    case working = "working"

    public var displayTitle: String {
        switch self {
        case .postpone: return "Postpone"
        case .base: return "Base"
        case .mineFull: return "Mine (Full File)"
        case .theirsFull: return "Theirs (Full File)"
        case .mineConflict: return "Mine (Conflict Blocks)"
        case .theirsConflict: return "Theirs (Conflict Blocks)"
        case .working: return "Working Copy (Mark Resolved)"
        }
    }
}

public struct SvnLockEntry: Equatable, Codable, Sendable {
    public var owner: String
    public var comment: String
    public var token: String
    public var created: Date?

    public init(owner: String = "", comment: String = "", token: String = "", created: Date? = nil) {
        self.owner = owner
        self.comment = comment
        self.token = token
        self.created = created
    }
}

public struct SvnInfoResult: Equatable, Sendable {
    public var path: String
    public var wcRoot: String?
    public var url: String
    public var relativeURL: String
    public var repositoryRoot: String
    public var repositoryUUID: String
    public var revision: String
    public var nodeKind: String
    public var lastChangedRev: String
    public var lastChangedAuthor: String
    public var lastChangedDate: Date?
    public var lock: SvnLockEntry?

    public var formattedBranchName: String {
        var rel = relativeURL
        if rel.hasPrefix("^/") {
            rel = String(rel.dropFirst(2))
        } else if rel.hasPrefix("^") {
            rel = String(rel.dropFirst(1))
        }
        let cleanRel = rel.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let label = cleanRel.isEmpty ? "root" : cleanRel
        if revision.isEmpty {
            return label
        }
        return "\(label) (r\(revision))"
    }

    public init(
        path: String = "",
        wcRoot: String? = nil,
        url: String = "",
        relativeURL: String = "",
        repositoryRoot: String = "",
        repositoryUUID: String = "",
        revision: String = "",
        nodeKind: String = "",
        lastChangedRev: String = "",
        lastChangedAuthor: String = "",
        lastChangedDate: Date? = nil,
        lock: SvnLockEntry? = nil
    ) {
        self.path = path
        self.wcRoot = wcRoot
        self.url = url
        self.relativeURL = relativeURL
        self.repositoryRoot = repositoryRoot
        self.repositoryUUID = repositoryUUID
        self.revision = revision
        self.nodeKind = nodeKind
        self.lastChangedRev = lastChangedRev
        self.lastChangedAuthor = lastChangedAuthor
        self.lastChangedDate = lastChangedDate
        self.lock = lock
    }
}

public struct SvnDetailedStatusItem: Identifiable, Equatable, Sendable {
    public var id: String { item.relativePath }
    public var item: VcsStatusItem
    public var itemStatus: String
    public var propsStatus: String
    public var revision: String?
    public var commitRevision: String?
    public var commitAuthor: String?
    public var commitDate: Date?
    public var wcLocked: Bool
    public var switched: Bool
    public var copied: Bool
    public var treeConflicted: Bool
    public var changelist: String?
    public var localLock: SvnLockEntry?
    public var remoteItemStatus: String?
    public var remotePropsStatus: String?
    public var remoteRevision: String?
    public var remoteAuthor: String?
    public var remoteLock: SvnLockEntry?

    public init(
        item: VcsStatusItem,
        itemStatus: String,
        propsStatus: String = "none",
        revision: String? = nil,
        commitRevision: String? = nil,
        commitAuthor: String? = nil,
        commitDate: Date? = nil,
        wcLocked: Bool = false,
        switched: Bool = false,
        copied: Bool = false,
        treeConflicted: Bool = false,
        changelist: String? = nil,
        localLock: SvnLockEntry? = nil,
        remoteItemStatus: String? = nil,
        remotePropsStatus: String? = nil,
        remoteRevision: String? = nil,
        remoteAuthor: String? = nil,
        remoteLock: SvnLockEntry? = nil
    ) {
        self.item = item
        self.itemStatus = itemStatus
        self.propsStatus = propsStatus
        self.revision = revision
        self.commitRevision = commitRevision
        self.commitAuthor = commitAuthor
        self.commitDate = commitDate
        self.wcLocked = wcLocked
        self.switched = switched
        self.copied = copied
        self.treeConflicted = treeConflicted
        self.changelist = changelist
        self.localLock = localLock
        self.remoteItemStatus = remoteItemStatus
        self.remotePropsStatus = remotePropsStatus
        self.remoteRevision = remoteRevision
        self.remoteAuthor = remoteAuthor
        self.remoteLock = remoteLock
    }
}

public struct SvnDetailedStatusResult: Equatable, Sendable {
    public var items: [SvnDetailedStatusItem]
    public var againstRevision: String?

    public init(items: [SvnDetailedStatusItem] = [], againstRevision: String? = nil) {
        self.items = items
        self.againstRevision = againstRevision
    }
}

public struct SvnPropertyEntry: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public struct SvnCheckoutOptions: Sendable {
    public var url: String
    public var destinationPath: String
    public var revision: String?
    public var depth: SvnDepth
    public var ignoreExternals: Bool
    public var force: Bool

    public init(
        url: String,
        destinationPath: String,
        revision: String? = nil,
        depth: SvnDepth = .infinity,
        ignoreExternals: Bool = false,
        force: Bool = false
    ) {
        self.url = url
        self.destinationPath = destinationPath
        self.revision = revision
        self.depth = depth
        self.ignoreExternals = ignoreExternals
        self.force = force
    }
}

public struct SvnUpdateOptions: Sendable {
    public var paths: [String]
    public var revision: String?
    public var depth: SvnDepth?
    public var setDepthSticky: Bool
    public var ignoreExternals: Bool
    public var force: Bool
    public var accept: SvnConflictAccept

    public init(
        paths: [String] = [],
        revision: String? = nil,
        depth: SvnDepth? = nil,
        setDepthSticky: Bool = false,
        ignoreExternals: Bool = false,
        force: Bool = false,
        accept: SvnConflictAccept = .postpone
    ) {
        self.paths = paths
        self.revision = revision
        self.depth = depth
        self.setDepthSticky = setDepthSticky
        self.ignoreExternals = ignoreExternals
        self.force = force
        self.accept = accept
    }
}

public enum SvnMergeMode: String, CaseIterable, Codable, Sendable {
    case range = "range"
    case twoTrees = "two-trees"
}

public struct SvnMergeOptions: Sendable {
    public var mode: SvnMergeMode
    public var sourceURL1: String
    public var revision1: String?
    public var sourceURL2: String?
    public var revision2: String?
    public var revisionRange: String
    public var reverseMerge: Bool
    public var reintegrate: Bool
    public var dryRun: Bool
    public var recordOnly: Bool
    public var ignoreAncestry: Bool
    public var force: Bool
    public var depth: SvnDepth?
    public var ignoreWhitespace: Bool
    public var accept: SvnConflictAccept

    public init(
        mode: SvnMergeMode = .range,
        sourceURL1: String,
        revision1: String? = nil,
        sourceURL2: String? = nil,
        revision2: String? = nil,
        revisionRange: String = "",
        reverseMerge: Bool = false,
        reintegrate: Bool = false,
        dryRun: Bool = false,
        recordOnly: Bool = false,
        ignoreAncestry: Bool = false,
        force: Bool = false,
        depth: SvnDepth? = nil,
        ignoreWhitespace: Bool = false,
        accept: SvnConflictAccept = .postpone
    ) {
        self.mode = mode
        self.sourceURL1 = sourceURL1
        self.revision1 = revision1
        self.sourceURL2 = sourceURL2
        self.revision2 = revision2
        self.revisionRange = revisionRange
        self.reverseMerge = reverseMerge
        self.reintegrate = reintegrate
        self.dryRun = dryRun
        self.recordOnly = recordOnly
        self.ignoreAncestry = ignoreAncestry
        self.force = force
        self.depth = depth
        self.ignoreWhitespace = ignoreWhitespace
        self.accept = accept
    }
}

public struct SvnCleanupOptions: Sendable {
    public var paths: [String]
    public var breakLocks: Bool
    public var removeUnversioned: Bool
    public var removeIgnored: Bool
    public var vacuumPristines: Bool
    public var includeExternals: Bool

    public init(
        paths: [String] = [],
        breakLocks: Bool = true,
        removeUnversioned: Bool = false,
        removeIgnored: Bool = false,
        vacuumPristines: Bool = false,
        includeExternals: Bool = false
    ) {
        self.paths = paths
        self.breakLocks = breakLocks
        self.removeUnversioned = removeUnversioned
        self.removeIgnored = removeIgnored
        self.vacuumPristines = vacuumPristines
        self.includeExternals = includeExternals
    }
}

public struct SvnAuthOverrides: Sendable {
    public var username: String?
    public var password: String?
    public var trustServerCertFailures: [String]
    public var forceNoAuthCache: Bool

    public static let allCertFailures: [String] = [
        "unknown-ca",
        "cn-mismatch",
        "expired",
        "not-yet-valid",
        "other"
    ]

    public init(
        username: String? = nil,
        password: String? = nil,
        trustServerCertFailures: [String] = [],
        forceNoAuthCache: Bool = false
    ) {
        self.username = username
        self.password = password
        self.trustServerCertFailures = trustServerCertFailures
        self.forceNoAuthCache = forceNoAuthCache
    }

    public var cliArguments: [String] {
        var args: [String] = []
        if let username, !username.isEmpty {
            args.append(contentsOf: ["--username", username])
        }
        if let password, !password.isEmpty {
            args.append(contentsOf: ["--password", password])
        }
        if !trustServerCertFailures.isEmpty {
            args.append(contentsOf: [
                "--trust-server-cert-failures",
                trustServerCertFailures.joined(separator: ",")
            ])
        }
        if forceNoAuthCache {
            args.append("--no-auth-cache")
        }
        return args
    }

    public static func redactPassword(in commandLine: String) -> String {
        let pattern = #"(--password\s+)(\S+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return commandLine }
        let range = NSRange(commandLine.startIndex..., in: commandLine)
        return regex.stringByReplacingMatches(in: commandLine, range: range, withTemplate: "$1******")
    }
}

public enum SvnErrorKind: Equatable, Sendable {
    case authenticationRequired(realm: String?, detail: String)
    case sslCertificateUntrusted(detail: String, suggestedHost: String?)
    case transientLocalNetwork(detail: String)
    case workingCopyLocked(detail: String)
    case workingCopyUpgradeRequired(detail: String)
    case other(detail: String)
}

public enum SvnErrorClassifier {
    public static func classify(stderr: String, stdout: String = "") -> SvnErrorKind {
        let combined = [stderr, stdout]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let lower = combined.lowercased()

        if lower.contains("e230001")
            || lower.contains("server certificate verification failed")
            || lower.contains("certificate issued for a different hostname")
            || lower.contains("issuer is not trusted")
            || lower.contains("certificate has expired") {
            let host = extractHost(from: combined)
            return .sslCertificateUntrusted(detail: combined, suggestedHost: host)
        }

        if lower.contains("e170001")
            || lower.contains("e215004")
            || lower.contains("e175013")
            || lower.contains("no more credentials")
            || lower.contains("authentication failed")
            || lower.contains("authorization failed")
            || lower.contains("401 unauthorized")
            || lower.contains("403 forbidden") {
            let realm = extractRealm(from: combined)
            return .authenticationRequired(realm: realm, detail: combined)
        }

        if lower.contains("e155004")
            || lower.contains("run 'svn cleanup'")
            || lower.contains("previous operation has not finished") {
            return .workingCopyLocked(detail: combined)
        }

        if lower.contains("e155036")
            || (lower.contains("working copy") && lower.contains("too old"))
            || lower.contains("svn upgrade") {
            return .workingCopyUpgradeRequired(detail: combined)
        }

        if isTransientLocalNetworkError(lower) {
            return .transientLocalNetwork(detail: combined)
        }

        return .other(detail: combined)
    }

    public static func isTransientLocalNetworkError(_ text: String) -> Bool {
        let lower = text.lowercased()
        let markers = [
            "e000050",
            "e000051",
            "e000060",
            "e000061",
            "e170013",
            "e175002",
            "e730060",
            "can't assign requested address",
            "network is unreachable",
            "no route to host",
            "connection refused",
            "failed to connect",
            "couldn't connect to server",
            "could not connect to server",
            "operation timed out",
            "timed out",
            "could not resolve hostname"
        ]
        return markers.contains(where: { lower.contains($0) })
    }

    private static func extractRealm(from text: String) -> String? {
        if let regex = try? NSRegularExpression(pattern: #"<([^>]+)>"#),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range(at: 1), in: text) {
            return String(text[range])
        }
        return nil
    }

    public static func extractHost(from text: String) -> String? {
        if let regex = try? NSRegularExpression(pattern: #"https?://([^/:>\s]+)"#, options: .caseInsensitive),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range(at: 1), in: text) {
            return String(text[range])
        }
        if let realm = extractRealm(from: text),
           let url = URL(string: realm.components(separatedBy: " ").first ?? ""),
           let host = url.host {
            return host
        }
        return nil
    }
}
