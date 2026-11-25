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

        if let credURL = helperURL(named: AppConstants.credentialHelperName) {
            // Configure git credential helper chain via GIT_CONFIG_* env vars (Git 2.31+):
            // - For `.none` (system default), try macOS `osxkeychain` first, then fall back to RepoShell Askpass helper.
            // - For `.userPassword`, clear inherited helpers first so per-repo Keychain credentials take precedence.
            env["GIT_CONFIG_COUNT"] = "2"
            env["GIT_CONFIG_KEY_0"] = "credential.helper"
            env["GIT_CONFIG_VALUE_0"] = (repoAuthMode == .userPassword) ? "" : "osxkeychain"
            env["GIT_CONFIG_KEY_1"] = "credential.helper"
            env["GIT_CONFIG_VALUE_1"] = credURL.path
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
