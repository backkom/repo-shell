import SwiftUI
import RepoShellShared

struct AuthenticationConfigView: View {
    let repoPath: String

    @State private var authConfig: RepoAuthConfig = RepoAuthConfig()
    @State private var secretInput: String = ""

    var body: some View {
        VStack(spacing: 0) {
            Form {
                LabeledContent(L("Repository:", "版本库路径："), value: repoPath)
                Picker(L("Authentication:", "身份验证："), selection: $authConfig.mode) {
                    Text(L("None (System Default)", "无（使用系统默认配置）")).tag(AuthMode.none)
                    Text(L("Username & Password / Token", "用户名和密码 / Token")).tag(AuthMode.userPassword)
                    Text(L("SSH Key", "SSH 密钥")).tag(AuthMode.sshKey)
                }

                if authConfig.mode == .userPassword {
                    TextField(L("Username:", "用户名："), text: $authConfig.username)
                    SecureField(L("Password / Token:", "密码 / Token："), text: $secretInput)
                } else if authConfig.mode == .sshKey {
                    HStack {
                        TextField(L("SSH Key Path:", "SSH 密钥："), text: $authConfig.sshKeyPath)
                        Button(L("Browse…", "浏览…")) {
                            if let url = AlertHelper.pickFile(title: L("Select SSH Private Key", "选择 SSH 私钥")) {
                                authConfig.sshKeyPath = url.path
                            }
                        }
                    }
                    TextField(L("SSH Port:", "SSH 端口："), value: $authConfig.sshPort, format: .number)
                    SecureField(L("Passphrase (optional):", "口令（可选）："), text: $secretInput)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if authConfig.mode != .none {
                    Button(L("Remove Credentials", "移除验证信息")) {
                        authConfig = RepoAuthConfig(mode: .none)
                        secretInput = ""
                        AppContainer.shared.repositoryManager.updateAuthConfig(for: repoPath, authConfig: authConfig)
                        AppContainer.shared.authManager.saveCredentials(repoPath: repoPath, authConfig: authConfig, secret: nil)
                    }
                }
                Spacer()
                Button(L("Cancel", "取消")) {
                    AppContainer.shared.windowCoordinator.closeWindow(key: "auth-\(repoPath)")
                }
                .keyboardShortcut(.escape, modifiers: [])
                Button(L("OK", "确定")) {
                    AppContainer.shared.repositoryManager.updateAuthConfig(for: repoPath, authConfig: authConfig)
                    AppContainer.shared.authManager.saveCredentials(
                        repoPath: repoPath,
                        authConfig: authConfig,
                        secret: secretInput.isEmpty ? nil : secretInput
                    )
                    AppContainer.shared.windowCoordinator.closeWindow(key: "auth-\(repoPath)")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()
        }
        .onAppear {
            let cfg = AppContainer.shared.repositoryManager.currentConfigSnapshot()
            if let repo = cfg.matchingRepository(for: repoPath) {
                authConfig = repo.authConfig
                secretInput = AppContainer.shared.authManager.readSavedSecret(repoPath: repoPath, mode: repo.authConfig.mode) ?? ""
            }
        }
    }
}

struct AskpassPromptView: View {
    let request: AskpassIPCRequest
    let onComplete: (AskpassIPCResponse) -> Void

    @State private var username: String
    @State private var secret: String = ""
    @State private var saveToKeychain: Bool = true

    init(request: AskpassIPCRequest, onComplete: @escaping (AskpassIPCResponse) -> Void) {
        self.request = request
        self.onComplete = onComplete
        _username = State(initialValue: request.defaultUsername)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(request.prompt)
                .font(.headline)
                .lineLimit(3)

            if !request.remoteHost.isEmpty {
                Text("\(request.protocolName)://\(request.remoteHost)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if request.kind == .hostTrust {
                Text(L("Accept host fingerprint and continue connecting?", "是否信任该主机公钥指纹并继续连接？"))
                    .font(.subheadline)
            } else {
                if request.kind == .credential || request.kind == .username {
                    TextField(L("Username:", "用户名："), text: $username)
                        .textFieldStyle(.roundedBorder)
                }
                if request.kind != .username {
                    SecureField(
                        request.kind == .passphrase ? L("SSH Passphrase:", "SSH 口令：") : L("Password / Token:", "密码 / Token："),
                        text: $secret
                    )
                    .textFieldStyle(.roundedBorder)
                }
                Toggle(L("Save in macOS Keychain", "保存到 macOS 钥匙串"), isOn: $saveToKeychain)
            }

            Spacer()
            HStack {
                Spacer()
                Button(L("Cancel", "取消")) {
                    onComplete(AskpassIPCResponse(approved: false))
                }
                .keyboardShortcut(.escape, modifiers: [])
                Button(request.kind == .hostTrust ? L("Trust & Continue", "信任并继续") : L("OK", "确定")) {
                    onComplete(AskpassIPCResponse(
                        approved: true,
                        username: username,
                        secret: secret,
                        saveToKeychain: saveToKeychain
                    ))
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(20)
    }
}
