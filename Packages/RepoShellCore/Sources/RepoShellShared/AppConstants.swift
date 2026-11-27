import Foundation
import CryptoKit

public enum AppConstants {
    public static let appName = "RepoShell"
    public static let mainBundleID = "com.leaf.reposhell"
    public static let finderSyncBundleID = "com.leaf.reposhell.FinderSync"
    public static let developmentTeamID = "YM3PT5F5G4"
    public static let appGroupID = "\(developmentTeamID).\(mainBundleID)"
    public static let urlScheme = "reposhell"

    public static let developerName = "leaf"
    public static let developerEmail = "flying_butterfly@126.com"
    public static let defaultVersion = "0.1.3"
    public static let defaultBuildNumber = "1"
    public static let githubRepo = "backkom/repo-shell"
    public static let copyright = "Copyright © 2026 leaf (flying_butterfly@126.com)"

    public static var currentVersion: String {
        if let ver = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           !ver.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ver
        }
        return defaultVersion
    }

    public static var currentBuildNumber: String {
        if let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
           !build.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return build
        }
        return defaultBuildNumber
    }

    public static var githubRepoSlug: String {
        if let slug = Bundle.main.object(forInfoDictionaryKey: "RepoShellGitHubRepo") as? String,
           !slug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return slug.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return githubRepo
    }

    public static var githubRepositoryURL: URL {
        URL(string: "https://github.com/\(githubRepoSlug)")!
    }

    public static let credentialHelperName = "git-credential-reposhell"
    public static let askpassHelperName = "reposhell-askpass"

    public static let keychainGitService = "\(mainBundleID).git.password"
    public static let keychainSshService = "\(mainBundleID).ssh.passphrase"

    public static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    public static var groupContainerURL: URL {
        if isSandboxed,
           let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            return url
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Group Containers", isDirectory: true)
            .appendingPathComponent(appGroupID, isDirectory: true)
    }

    public enum DistributedNotification: String {
        case configDidUpdate = "com.leaf.reposhell.configDidUpdate"
        case statusDidUpdate = "com.leaf.reposhell.statusDidUpdate"
        case requestRefresh = "com.leaf.reposhell.requestRefresh"
        case diffLaterDidUpdate = "com.leaf.reposhell.diffLaterDidUpdate"
        case actionTriggered = "com.leaf.reposhell.actionTriggered"
        case updateStateDidUpdate = "com.leaf.reposhell.updateStateDidUpdate"

        public var cfName: Notification.Name {
            Notification.Name(rawValue)
        }
    }

    public static func postDistributed(_ notification: DistributedNotification, userInfo: [AnyHashable: Any]? = nil) {
        DistributedNotificationCenter.default().postNotificationName(
            notification.cfName,
            object: mainBundleID,
            userInfo: userInfo,
            deliverImmediately: true
        )
    }
}

public enum PathUtils {
    public static func normalize(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        var result = url.path
        while result.count > 1 && result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }

    public static func repoHash(for repoPath: String) -> String {
        let normalized = normalize(repoPath)
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    public static func relativePath(of childPath: String, inside rootPath: String) -> String? {
        let normChild = normalize(childPath)
        let normRoot = normalize(rootPath)
        if normChild == normRoot {
            return ""
        }
        let prefix = normRoot == "/" ? "/" : normRoot + "/"
        guard normChild.hasPrefix(prefix) else { return nil }
        return String(normChild.dropFirst(prefix.count))
    }

    public static func isPath(_ path: String, insideOrEqualTo root: String) -> Bool {
        relativePath(of: path, inside: root) != nil
    }
}
