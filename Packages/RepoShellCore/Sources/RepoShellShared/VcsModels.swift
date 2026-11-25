import Foundation

public enum VcsType: String, Codable, CaseIterable, Sendable {
    case git
    case svn

    public var displayName: String {
        switch self {
        case .git: return "Git"
        case .svn: return "SVN"
        }
    }

    public var metadataDirectoryName: String {
        switch self {
        case .git: return ".git"
        case .svn: return ".svn"
        }
    }
}

/// Complete superset of file statuses covering both V1 Git and V2 SVN.
public enum VcsFileStatus: String, Codable, CaseIterable, Sendable {
    case normal
    case modified
    case added
    case deleted
    case renamed
    case copied
    case typeChanged
    case unmerged   // Conflict
    case untracked
    case ignored
    case external
    case locked
    case missing
    case obstructed
    case replaced
    case readOnly

    /// Lower number = higher severity when aggregating child statuses onto parent folders.
    public var folderAggregationPriority: Int {
        switch self {
        case .unmerged: return 1
        case .obstructed: return 2
        case .missing: return 3
        case .modified, .typeChanged: return 4
        case .deleted: return 5
        case .added: return 6
        case .renamed: return 7
        case .copied: return 8
        case .replaced: return 9
        case .locked: return 10
        case .untracked: return 11
        case .ignored: return 12
        case .external: return 13
        case .readOnly: return 14
        case .normal: return 15
        }
    }

    /// Ignored files never propagate onto parent folders; readOnly/external do not taint normal folders either.
    public var propagatesToParentFolder: Bool {
        switch self {
        case .ignored, .readOnly, .normal:
            return false
        default:
            return true
        }
    }

    public var badgeIdentifier: String {
        switch self {
        case .normal: return "normal"
        case .modified, .typeChanged: return "modified"
        case .added, .renamed, .copied, .replaced: return "added"
        case .deleted, .missing: return "deleted"
        case .unmerged, .obstructed: return "conflict"
        case .untracked: return "untracked"
        case .ignored: return "ignored"
        case .external: return "external"
        case .locked: return "locked"
        case .readOnly: return "readonly"
        }
    }

    public var localizedLabelKey: String {
        switch self {
        case .normal: return "status.normal"
        case .modified: return "status.modified"
        case .added: return "status.added"
        case .deleted: return "status.deleted"
        case .renamed: return "status.renamed"
        case .copied: return "status.copied"
        case .typeChanged: return "status.typeChanged"
        case .unmerged: return "status.unmerged"
        case .untracked: return "status.untracked"
        case .ignored: return "status.ignored"
        case .external: return "status.external"
        case .locked: return "status.locked"
        case .missing: return "status.missing"
        case .obstructed: return "status.obstructed"
        case .replaced: return "status.replaced"
        case .readOnly: return "status.readOnly"
        }
    }

    public var isActionableChange: Bool {
        switch self {
        case .normal, .ignored:
            return false
        default:
            return true
        }
    }

    public static func aggregateFolderStatus<S: Sequence>(_ statuses: S) -> VcsFileStatus where S.Element == VcsFileStatus {
        var best: VcsFileStatus = .normal
        for status in statuses where status.propagatesToParentFolder {
            if status.folderAggregationPriority < best.folderAggregationPriority {
                best = status
            }
        }
        return best
    }
}

public enum VcsRepoState: String, Codable, Sendable {
    case normal
    case merging
    case rebasing
    case cherryPicking
    case reverting
    case bisecting

    public var isInProgress: Bool {
        self != .normal
    }
}

public struct VcsCapability: OptionSet, Codable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let stagingIndex  = VcsCapability(rawValue: 1 << 0)
    public static let localBranches = VcsCapability(rawValue: 1 << 1)
    public static let stash         = VcsCapability(rawValue: 1 << 2)
    public static let rebase        = VcsCapability(rawValue: 1 << 3)
    public static let cherryPick    = VcsCapability(rawValue: 1 << 4)
    public static let reflog        = VcsCapability(rawValue: 1 << 5)
    public static let submodules    = VcsCapability(rawValue: 1 << 6)
    public static let pushFetch     = VcsCapability(rawValue: 1 << 7)
    public static let locking       = VcsCapability(rawValue: 1 << 8)   // V2 SVN
    public static let properties    = VcsCapability(rawValue: 1 << 9)   // V2 SVN
    public static let relocate      = VcsCapability(rawValue: 1 << 10)  // V2 SVN
    public static let changelists   = VcsCapability(rawValue: 1 << 11)

    public static let gitDefault: VcsCapability = [
        .stagingIndex, .localBranches, .stash, .rebase, .cherryPick,
        .reflog, .submodules, .pushFetch, .changelists
    ]

    public static let svnDefault: VcsCapability = [
        .locking, .properties, .relocate, .changelists
    ]
}
