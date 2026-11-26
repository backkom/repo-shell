import Foundation
import RepoShellShared
import RepoShellVcs

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

    private var svnTrustedHostsURL: URL {
        storage.baseDirectoryURL.appendingPathComponent("svn-trusted-hosts.json", isDirectory: false)
    }

    public func trustedSvnHosts() -> Set<String> {
        let hosts = storage.read([String].self, from: svnTrustedHostsURL) ?? []
        return Set(hosts.map { $0.lowercased() })
    }

    public func trustSvnHostPermanently(_ host: String) {
        let clean = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !clean.isEmpty else { return }
        var hosts = trustedSvnHosts()
        hosts.insert(clean)
        try? storage.write(Array(hosts).sorted(), to: svnTrustedHostsURL)
    }

    public func saveSvnUrlCredentials(hostOrUrl: String, username: String, password: String) {
        guard let host = extractHostKey(hostOrUrl) else { return }
        let payload = "\(username)\n\(password)"
        _ = KeychainStore.saveSecret(payload, service: "com.leaf.reposhell.svn", account: host)
    }

    public func readSvnUrlCredentials(hostOrUrl: String) -> (username: String, password: String)? {
        guard let host = extractHostKey(hostOrUrl),
              let raw = KeychainStore.readSecret(service: "com.leaf.reposhell.svn", account: host) else {
            return nil
        }
        let parts = raw.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }

    private func extractHostKey(_ hostOrUrl: String) -> String? {
        let trimmed = hostOrUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if let url = URL(string: trimmed), let host = url.host, !host.isEmpty {
            if let port = url.port {
                return "\(host.lowercased()):\(port)"
            }
            return host.lowercased()
        }
        return trimmed.lowercased()
    }

    public func svnEnvironment(for repoPath: String?) -> [String: String] {
        var env: [String: String] = [:]
        let cfg = storage.loadConfig()
        let normRepo = repoPath.map { PathUtils.normalize($0) }

        if let norm = normRepo {
            env["REPOSHELL_REPO_PATH"] = norm
        }
        env["REPOSHELL_SOCKET_PATH"] = storage.askpassSocketURL.path

        if let askpassURL = helperURL(named: AppConstants.askpassHelperName) {
            env["SSH_ASKPASS"] = askpassURL.path
            env["SSH_ASKPASS_REQUIRE"] = "force"
            env["DISPLAY"] = ":0"
        }

        if let norm = normRepo,
           let repo = cfg.matchingRepository(for: norm),
           repo.authConfig.mode == .sshKey,
           !repo.authConfig.sshKeyPath.isEmpty {
            let key = repo.authConfig.sshKeyPath.replacingOccurrences(of: "'", with: "'\\''")
            let port = repo.authConfig.sshPort > 0 ? repo.authConfig.sshPort : 22
            env["SVN_SSH"] = "ssh -i '\(key)' -p \(port) -o IdentitiesOnly=yes"
        }

        return env
    }

    public func svnAuthOverrides(for repoPath: String?, targetURL: String? = nil) -> SvnAuthOverrides {
        var overrides = SvnAuthOverrides()
        let cfg = storage.loadConfig()

        if let repoPath, let repo = cfg.matchingRepository(for: repoPath),
           repo.authConfig.mode == .userPassword {
            if !repo.authConfig.username.isEmpty {
                overrides.username = repo.authConfig.username
            }
            if let secret = readSavedSecret(repoPath: repo.path, mode: .userPassword), !secret.isEmpty {
                overrides.password = secret
            }
        } else if let targetURL, let saved = readSvnUrlCredentials(hostOrUrl: targetURL) {
            overrides.username = saved.username
            overrides.password = saved.password
        }

        if let targetURL, let url = URL(string: targetURL), let host = url.host?.lowercased() {
            if trustedSvnHosts().contains(host) {
                overrides.trustServerCertFailures = SvnAuthOverrides.allCertFailures
            }
        }

        return overrides
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
