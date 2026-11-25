import Foundation

public struct RGBColor: Codable, Equatable, Sendable {
    public var r: Int
    public var g: Int
    public var b: Int

    public init(r: Int, g: Int, b: Int) {
        self.r = r
        self.g = g
        self.b = b
    }
}

public struct StatusTextColors: Codable, Equatable, Sendable {
    public var added: RGBColor
    public var deleted: RGBColor
    public var merged: RGBColor
    public var modified: RGBColor
    public var unmerged: RGBColor

    public init(
        added: RGBColor,
        deleted: RGBColor,
        merged: RGBColor,
        modified: RGBColor,
        unmerged: RGBColor
    ) {
        self.added = added
        self.deleted = deleted
        self.merged = merged
        self.modified = modified
        self.unmerged = unmerged
    }

    public static let defaultLight = StatusTextColors(
        added: RGBColor(r: 102, g: 0, b: 102),
        deleted: RGBColor(r: 102, g: 0, b: 0),
        merged: RGBColor(r: 0, g: 102, b: 0),
        modified: RGBColor(r: 0, g: 51, b: 153),
        unmerged: RGBColor(r: 255, g: 0, b: 0)
    )

    public static let defaultDark = StatusTextColors(
        added: RGBColor(r: 204, g: 0, b: 109),
        deleted: RGBColor(r: 204, g: 63, b: 2),
        merged: RGBColor(r: 0, g: 192, b: 0),
        modified: RGBColor(r: 50, g: 123, b: 246),
        unmerged: RGBColor(r: 255, g: 0, b: 0)
    )
}

public enum AuthMode: String, Codable, CaseIterable, Sendable {
    case none
    case userPassword
    case sshKey
}

public struct RepoAuthConfig: Codable, Equatable, Sendable {
    public var mode: AuthMode
    public var username: String
    public var sshKeyPath: String
    public var sshPort: Int

    public init(
        mode: AuthMode = .none,
        username: String = "",
        sshKeyPath: String = "",
        sshPort: Int = 22
    ) {
        self.mode = mode
        self.username = username
        self.sshKeyPath = sshKeyPath
        self.sshPort = sshPort
    }
}

public struct RepositoryEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var path: String
    public var name: String
    public var vcsType: VcsType
    public var isAutoDiscovered: Bool
    public var parentRootPath: String?
    public var authConfig: RepoAuthConfig

    public init(
        id: UUID = UUID(),
        path: String,
        name: String? = nil,
        vcsType: VcsType = .git,
        isAutoDiscovered: Bool = false,
        parentRootPath: String? = nil,
        authConfig: RepoAuthConfig = RepoAuthConfig()
    ) {
        let norm = PathUtils.normalize(path)
        self.id = id
        self.path = norm
        self.name = name ?? URL(fileURLWithPath: norm).lastPathComponent
        self.vcsType = vcsType
        self.isAutoDiscovered = isAutoDiscovered
        self.parentRootPath = parentRootPath.map { PathUtils.normalize($0) }
        self.authConfig = authConfig
    }
}

public struct WorkspaceScanRoot: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var path: String
    public var maxDepth: Int
    public var enabled: Bool

    public init(
        id: UUID = UUID(),
        path: String,
        maxDepth: Int = 3,
        enabled: Bool = true
    ) {
        self.id = id
        self.path = PathUtils.normalize(path)
        self.maxDepth = max(1, min(maxDepth, 8))
        self.enabled = enabled
    }
}

public enum AppLanguage: String, Codable, CaseIterable, Sendable {
    case system
    case en
    case zhHans = "zh-Hans"
}

public struct AppPreferences: Codable, Equatable, Sendable {
    public var cascadeMenu: Bool
    public var showMenuIcons: Bool
    public var showInMenuBar: Bool
    public var showPreferencesOnLaunch: Bool
    public var showSecurityWarning: Bool
    public var useBundledGit: Bool
    public var externalGitPath: String
    public var diffToolId: String
    public var customDiffCommand: String
    public var mergeToolId: String
    public var customMergeCommand: String
    public var useFinderTagsForCloudDrives: Bool
    public var useFinderTagsForLocalRepos: Bool
    public var checkEmptyCommitMessage: Bool
    public var commitAutoPush: Bool
    public var commitShowUntracked: Bool
    public var enableTrashOnDelete: Bool
    public var showHiddenFilesInRepoBrowser: Bool
    public var language: AppLanguage
    public var lightColors: StatusTextColors
    public var darkColors: StatusTextColors
    public var hasCompletedSetupWizard: Bool
    public var cloudDriveIndicators: [String]

    public init(
        cascadeMenu: Bool = true,
        showMenuIcons: Bool = true,
        showInMenuBar: Bool = false,
        showPreferencesOnLaunch: Bool = true,
        showSecurityWarning: Bool = true,
        useBundledGit: Bool = true,
        externalGitPath: String = "/usr/bin/git",
        diffToolId: String = "auto",
        customDiffCommand: String = "",
        mergeToolId: String = "auto",
        customMergeCommand: String = "",
        useFinderTagsForCloudDrives: Bool = true,
        useFinderTagsForLocalRepos: Bool = false,
        checkEmptyCommitMessage: Bool = true,
        commitAutoPush: Bool = false,
        commitShowUntracked: Bool = true,
        enableTrashOnDelete: Bool = true,
        showHiddenFilesInRepoBrowser: Bool = false,
        language: AppLanguage = .system,
        lightColors: StatusTextColors = .defaultLight,
        darkColors: StatusTextColors = .defaultDark,
        hasCompletedSetupWizard: Bool = false,
        cloudDriveIndicators: [String] = [
            "Library/CloudStorage",
            "Library/Mobile Documents",
            "Dropbox",
            "OneDrive",
            "Google Drive",
            "SynologyDrive",
            "Box"
        ]
    ) {
        self.cascadeMenu = cascadeMenu
        self.showMenuIcons = showMenuIcons
        self.showInMenuBar = showInMenuBar
        self.showPreferencesOnLaunch = showPreferencesOnLaunch
        self.showSecurityWarning = showSecurityWarning
        self.useBundledGit = useBundledGit
        self.externalGitPath = externalGitPath
        self.diffToolId = diffToolId
        self.customDiffCommand = customDiffCommand
        self.mergeToolId = mergeToolId
        self.customMergeCommand = customMergeCommand
        self.useFinderTagsForCloudDrives = useFinderTagsForCloudDrives
        self.useFinderTagsForLocalRepos = useFinderTagsForLocalRepos
        self.checkEmptyCommitMessage = checkEmptyCommitMessage
        self.commitAutoPush = commitAutoPush
        self.commitShowUntracked = commitShowUntracked
        self.enableTrashOnDelete = enableTrashOnDelete
        self.showHiddenFilesInRepoBrowser = showHiddenFilesInRepoBrowser
        self.language = language
        self.lightColors = lightColors
        self.darkColors = darkColors
        self.hasCompletedSetupWizard = hasCompletedSetupWizard
        self.cloudDriveIndicators = cloudDriveIndicators
    }
}

public struct SharedConfig: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var repositories: [RepositoryEntry]
    public var workspaceRoots: [WorkspaceScanRoot]
    public var excludedPaths: [String]
    public var preferences: AppPreferences

    public init(
        schemaVersion: Int = 1,
        repositories: [RepositoryEntry] = [],
        workspaceRoots: [WorkspaceScanRoot] = [],
        excludedPaths: [String] = [],
        preferences: AppPreferences = AppPreferences()
    ) {
        self.schemaVersion = schemaVersion
        self.repositories = repositories
        self.workspaceRoots = workspaceRoots
        self.excludedPaths = excludedPaths
        self.preferences = preferences
    }

    public func matchingRepository(for path: String) -> RepositoryEntry? {
        let norm = PathUtils.normalize(path)
        if excludedPaths.contains(where: { PathUtils.isPath(norm, insideOrEqualTo: $0) }) {
            return nil
        }
        // Pick deepest matching repository root (supports nested submodules)
        return repositories
            .filter { PathUtils.isPath(norm, insideOrEqualTo: $0.path) }
            .max(by: { $0.path.count < $1.path.count })
    }
}

public struct RepoStatusSnapshot: Codable, Equatable, Sendable {
    public var repoPath: String
    public var vcsType: VcsType
    public var branchName: String
    public var repoState: VcsRepoState
    public var updatedAt: Date
    /// Keys are repo-relative paths (`""` represents the repo root folder itself). Only non-normal entries are stored.
    public var fileStatuses: [String: VcsFileStatus]

    public init(
        repoPath: String,
        vcsType: VcsType = .git,
        branchName: String = "",
        repoState: VcsRepoState = .normal,
        updatedAt: Date = Date(),
        fileStatuses: [String: VcsFileStatus] = [:]
    ) {
        self.repoPath = PathUtils.normalize(repoPath)
        self.vcsType = vcsType
        self.branchName = branchName
        self.repoState = repoState
        self.updatedAt = updatedAt
        self.fileStatuses = fileStatuses
    }

    public func status(forAbsolutePath path: String) -> VcsFileStatus {
        guard let rel = PathUtils.relativePath(of: path, inside: repoPath) else {
            return .normal
        }
        if let exact = fileStatuses[rel] {
            return exact
        }
        // Check if any ancestor directory is marked ignored or external
        var components = rel.split(separator: "/").map(String.init)
        while components.count > 1 {
            components.removeLast()
            let ancestor = components.joined(separator: "/")
            if let st = fileStatuses[ancestor], st == .ignored || st == .external {
                return st
            }
        }
        return .normal
    }
}

public struct ActionPayload: Codable, Equatable, Sendable {
    public var id: UUID
    public var actionRawValue: String
    public var targetDirectoryPath: String
    public var selectedPaths: [String]
    public var repoPath: String?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        actionRawValue: String,
        targetDirectoryPath: String,
        selectedPaths: [String],
        repoPath: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.actionRawValue = actionRawValue
        self.targetDirectoryPath = PathUtils.normalize(targetDirectoryPath)
        self.selectedPaths = selectedPaths.map { PathUtils.normalize($0) }
        self.repoPath = repoPath.map { PathUtils.normalize($0) }
        self.createdAt = createdAt
    }
}

public struct DiffLaterState: Codable, Equatable, Sendable {
    public var filePath: String
    public var savedAt: Date

    public init(filePath: String, savedAt: Date = Date()) {
        self.filePath = PathUtils.normalize(filePath)
        self.savedAt = savedAt
    }

    public var fileName: String {
        URL(fileURLWithPath: filePath).lastPathComponent
    }
}

public struct DiffToolPreset: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var appBundleIDs: [String]
    public var appPaths: [String]
    public var commandPaths: [String]
    public var argsTemplate: String

    public init(
        id: String,
        name: String,
        appBundleIDs: [String] = [],
        appPaths: [String] = [],
        commandPaths: [String] = [],
        argsTemplate: String
    ) {
        self.id = id
        self.name = name
        self.appBundleIDs = appBundleIDs
        self.appPaths = appPaths
        self.commandPaths = commandPaths
        self.argsTemplate = argsTemplate
    }
}

public struct MergeToolPreset: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var appPaths: [String]
    public var commandPaths: [String]
    public var argsTemplate: String

    public init(
        id: String,
        name: String,
        appPaths: [String] = [],
        commandPaths: [String] = [],
        argsTemplate: String
    ) {
        self.id = id
        self.name = name
        self.appPaths = appPaths
        self.commandPaths = commandPaths
        self.argsTemplate = argsTemplate
    }
}

public struct Changelist: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var files: [String] // repo-relative paths

    public init(id: UUID = UUID(), name: String, files: [String] = []) {
        self.id = id
        self.name = name
        self.files = files
    }
}

public struct RecentHistoryData: Codable, Equatable, Sendable {
    public var commitMessages: [String]
    public var remoteURLs: [String]

    public init(commitMessages: [String] = [], remoteURLs: [String] = []) {
        self.commitMessages = commitMessages
        self.remoteURLs = remoteURLs
    }
}
