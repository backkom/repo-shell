import Foundation
import RepoShellShared

private func parseCredentialInput() -> [String: String] {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    let text = String(data: data, encoding: .utf8) ?? ""
    var dict: [String: String] = [:]
    for line in text.components(separatedBy: .newlines) {
        guard let idx = line.firstIndex(of: "=") else { continue }
        let key = String(line[..<idx])
        let value = String(line[line.index(after: idx)...])
        if !key.isEmpty {
            dict[key] = value
        }
    }
    return dict
}

private func accountKey(repoPath: String, host: String, protocolName: String) -> String {
    if !repoPath.isEmpty {
        return PathUtils.normalize(repoPath)
    }
    return "\(protocolName)://\(host)"
}

let action = CommandLine.arguments.dropFirst().first ?? "get"
let input = parseCredentialInput()
let env = ProcessInfo.processInfo.environment
let repoPath = env["REPOSHELL_REPO_PATH"] ?? ""
let socketPath = env["REPOSHELL_SOCKET_PATH"] ?? SharedStorage.shared.askpassSocketURL.path
let host = input["host"] ?? ""
let proto = input["protocol"] ?? "https"
let account = accountKey(repoPath: repoPath, host: host, protocolName: proto)

let storage = SharedStorage.shared
let config = storage.loadConfig()
let matchedRepo = repoPath.isEmpty ? nil : config.matchingRepository(for: repoPath)

switch action {
case "get":
    var username = input["username"] ?? ""
    if username.isEmpty, let repoUser = matchedRepo?.authConfig.username, !repoUser.isEmpty {
        username = repoUser
    }

    if let savedPassword = KeychainStore.readSecret(service: AppConstants.keychainGitService, account: account) {
        if !username.isEmpty {
            print("username=\(username)")
        }
        print("password=\(savedPassword)")
        exit(0)
    }

    // Fallback to host-level key if repo-level not found
    if !host.isEmpty, let hostPass = KeychainStore.readSecret(service: AppConstants.keychainGitService, account: "\(proto)://\(host)") {
        if !username.isEmpty {
            print("username=\(username)")
        }
        print("password=\(hostPass)")
        exit(0)
    }

    // Ask RepoShell main app interactively via Unix socket
    let req = AskpassIPCRequest(
        kind: .credential,
        prompt: "Authentication required for \(proto)://\(host)",
        repoPath: repoPath,
        remoteHost: host,
        protocolName: proto,
        defaultUsername: username
    )
    if let resp = AskpassSocketClient.send(request: req, socketURL: URL(fileURLWithPath: socketPath)), resp.approved {
        if !resp.username.isEmpty {
            print("username=\(resp.username)")
        }
        print("password=\(resp.secret)")
        exit(0)
    }
    exit(1)

case "store":
    if let password = input["password"], !password.isEmpty {
        _ = KeychainStore.saveSecret(password, service: AppConstants.keychainGitService, account: account)
    }
    exit(0)

case "erase":
    KeychainStore.deleteSecret(service: AppConstants.keychainGitService, account: account)
    exit(0)

default:
    exit(0)
}
