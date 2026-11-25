import Foundation
import RepoShellShared

let prompt = CommandLine.arguments.dropFirst().joined(separator: " ")
let env = ProcessInfo.processInfo.environment
let repoPath = env["REPOSHELL_REPO_PATH"] ?? ""
let socketPath = env["REPOSHELL_SOCKET_PATH"] ?? SharedStorage.shared.askpassSocketURL.path
let lower = prompt.lowercased()

let storage = SharedStorage.shared
let config = storage.loadConfig()
let matchedRepo = repoPath.isEmpty ? nil : config.matchingRepository(for: repoPath)

let kind: AskpassRequestKind
if lower.contains("(yes/no)") || lower.contains("continue connecting") || lower.contains("fingerprint") {
    kind = .hostTrust
} else if lower.contains("username") {
    kind = .username
} else if lower.contains("passphrase") || lower.contains("ssh") || lower.contains("key") {
    kind = .passphrase
} else {
    kind = .password
}

// Check configured repo credentials / Keychain before prompting user
if kind == .username, let user = matchedRepo?.authConfig.username, !user.isEmpty {
    print(user)
    exit(0)
}

if kind == .passphrase, !repoPath.isEmpty,
   let savedPassphrase = KeychainStore.readSecret(service: AppConstants.keychainSshService, account: PathUtils.normalize(repoPath)) {
    print(savedPassphrase)
    exit(0)
}

if kind == .password, !repoPath.isEmpty,
   let savedPassword = KeychainStore.readSecret(service: AppConstants.keychainGitService, account: PathUtils.normalize(repoPath)) {
    print(savedPassword)
    exit(0)
}

let req = AskpassIPCRequest(
    kind: kind,
    prompt: prompt.isEmpty ? "Authentication required" : prompt,
    repoPath: repoPath,
    defaultUsername: matchedRepo?.authConfig.username ?? ""
)

if let resp = AskpassSocketClient.send(request: req, socketURL: URL(fileURLWithPath: socketPath)), resp.approved {
    switch kind {
    case .hostTrust:
        print("yes")
    case .username:
        print(resp.username)
    case .password, .passphrase, .credential:
        print(resp.secret)
    }
    exit(0)
}

exit(1)
