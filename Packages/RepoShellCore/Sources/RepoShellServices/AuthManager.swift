import Foundation
import RepoShellShared

public final class AuthManager: @unchecked Sendable {
    private let storage: SharedStorage
    private let bundle: Bundle

    public init(storage: SharedStorage = .shared, bundle: Bundle = .main) {
        self.storage = storage
        self.bundle = bundle
    }

    public func keychainAccount(repoPath: String) -> String {
        PathUtils.normalize(repoPath)
    }

    public func saveCredentials(
        repoPath: String,
        authConfig: RepoAuthConfig,
        secret: String?
    ) {
        let account = keychainAccount(repoPath: repoPath)
        switch authConfig.mode {
        case .none:
            KeychainStore.deleteSecret(service: AppConstants.keychainGitService, account: account)
            KeychainStore.deleteSecret(service: AppConstants.keychainSshService, account: account)
        case .userPassword:
            if let secret = secret {
                _ = KeychainStore.saveSecret(secret, service: AppConstants.keychainGitService, account: account)
            }
        case .sshKey:
            if let secret = secret {
                _ = KeychainStore.saveSecret(secret, service: AppConstants.keychainSshService, account: account)
            }
        }
    }

    public func readSavedSecret(repoPath: String, mode: AuthMode) -> String? {
        let account = keychainAccount(repoPath: repoPath)
        switch mode {
        case .none:
            return nil
        case .userPassword:
            return KeychainStore.readSecret(service: AppConstants.keychainGitService, account: account)
        case .sshKey:
            return KeychainStore.readSecret(service: AppConstants.keychainSshService, account: account)
        }
    }

    public static func systemAppleOsxKeychainHelperPath() -> String? {
        let candidates = [
            "/Library/Developer/CommandLineTools/usr/libexec/git-core/git-credential-osxkeychain",
            "/Applications/Xcode.app/Contents/Developer/usr/libexec/git-core/git-credential-osxkeychain"
        ]
        let fm = FileManager.default
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    public static func shellQuotedCredentialHelper(path: String) -> String {
        let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
        return "!'\(escaped)'"
    }

    public func environment(for repoPath: String?) -> [String: String] {
        var env: [String: String] = [:]
        let cfg = storage.loadConfig()
        let normRepo = repoPath.map { PathUtils.normalize($0) }

        if let norm = normRepo {
            env["REPOSHELL_REPO_PATH"] = norm
        }
        env["REPOSHELL_SOCKET_PATH"] = storage.askpassSocketURL.path

        if let askpassURL = helperURL(named: AppConstants.askpassHelperName) {
            env["GIT_ASKPASS"] = askpassURL.path
            env["SSH_ASKPASS"] = askpassURL.path
            env["SSH_ASKPASS_REQUIRE"] = "force"
            env["DISPLAY"] = ":0"
        }

        var repoAuthMode: AuthMode = .none
        if let norm = normRepo,
           let repo = cfg.matchingRepository(for: norm) {
            repoAuthMode = repo.authConfig.mode
            if repo.authConfig.mode == .sshKey && !repo.authConfig.sshKeyPath.isEmpty {
                let key = repo.authConfig.sshKeyPath.replacingOccurrences(of: "'", with: "'\\''")
                let port = repo.authConfig.sshPort > 0 ? repo.authConfig.sshPort : 22
                env["GIT_SSH_COMMAND"] = "ssh -i '\(key)' -p \(port) -o IdentitiesOnly=yes"
            }
        }

        // Reset inherited helpers so bundled re-signed `git-credential-osxkeychain` is never picked up,
        // then invoke Apple's unmodified system helper (for `.none`) before falling back to RepoShell's helper.
        var helpers: [String] = [""]
        if repoAuthMode == .none {
            helpers.append(Self.systemAppleOsxKeychainHelperPath().map(Self.shellQuotedCredentialHelper(path:)) ?? "osxkeychain")
        }
        if let credURL = helperURL(named: AppConstants.credentialHelperName) {
            helpers.append(Self.shellQuotedCredentialHelper(path: credURL.path))
        }

        if helpers.count > 1 {
            env["GIT_CONFIG_COUNT"] = "\(helpers.count)"
            for (index, helper) in helpers.enumerated() {
                env["GIT_CONFIG_KEY_\(index)"] = "credential.helper"
                env["GIT_CONFIG_VALUE_\(index)"] = helper
            }
        }

        return env
    }

    private func helperURL(named name: String) -> URL? {
        let helpersDir = bundle.bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true)
        let candidate = helpersDir.appendingPathComponent(name, isDirectory: false)
        if FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        return nil
    }
}
