import SwiftUI
import RepoShellShared
import RepoShellVcs

struct SubmodulesWindowView: View {
    let repoPath: String

    @State private var submodules: [GitSubmodule] = []
    @State private var editingSubmodule: GitSubmodule?
    @State private var editURL = ""
    @State private var editBranch = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("Submodules", "子模块")).font(.headline)
                Spacer()
                Button(L("Add…", "新增…")) {
                    AppContainer.shared.windowCoordinator.dispatch(action: .submoduleAdd, repoPath: repoPath, targetDir: repoPath, selectedPaths: [])
                }
                Button(L("Update…", "更新…")) {
                    AppContainer.shared.windowCoordinator.dispatch(action: .submoduleUpdate, repoPath: repoPath, targetDir: repoPath, selectedPaths: [])
                }
                Button(L("Refresh", "刷新")) { Task { await reload() } }
            }
            .padding()

            Divider()

            if submodules.isEmpty {
                EmptyStateBox(systemImage: "shippingbox", title: L("No Submodules", "无子模块"))
            } else {
                List(submodules) { sub in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sub.path).fontWeight(.semibold)
                            Text(sub.url).font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        Text(sub.stateDescription)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(String(sub.commitHash.prefix(7)))
                            .font(.caption.monospaced())
                            .foregroundColor(.secondary)
                        Button(L("Edit", "编辑")) {
                            editURL = sub.url
                            editBranch = sub.branch ?? ""
                            editingSubmodule = sub
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .sheet(item: $editingSubmodule) { sub in
            VStack(alignment: .leading, spacing: 12) {
                Text(L("Edit Submodule:", "编辑子模块：") + " \(sub.path)").font(.headline)
                TextField(L("URL:", "版本库地址："), text: $editURL).textFieldStyle(.roundedBorder)
                TextField(L("Branch (optional):", "分支（可选）："), text: $editBranch).textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button(L("Cancel", "取消")) { editingSubmodule = nil }
                    Button(L("Save", "保存")) {
                        Task {
                            _ = try? await AppContainer.shared.gitProvider.updateSubmoduleConfig(
                                repoPath: repoPath,
                                path: sub.path,
                                newURL: editURL,
                                branch: editBranch
                            )
                            editingSubmodule = nil
                            await reload()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
            .frame(width: 420)
        }
        .task { await reload() }
    }

    private func reload() async {
        submodules = (try? await AppContainer.shared.gitProvider.listSubmodules(repoPath: repoPath)) ?? []
    }
}

struct AddSubmoduleWindowView: View {
    let repoPath: String

    @State private var url: String = ""
    @State private var path: String = ""
    @State private var branch: String = ""
    @State private var force: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField(L("Repository URL:", "版本库地址："), text: $url)
                TextField(L("Relative Path:", "相对路径："), text: $path)
                TextField(L("Branch (optional):", "分支（可选）："), text: $branch)
                Toggle(L("Force (-f)", "强制执行 (-f)"), isOn: $force)
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button(L("Cancel", "取消")) {
                    AppContainer.shared.windowCoordinator.closeWindow(key: "sub-add-\(repoPath)")
                }
                .keyboardShortcut(.escape, modifiers: [])
                Button(L("Add", "添加")) {
                    let u = url.trimmingCharacters(in: .whitespaces)
                    let p = path.trimmingCharacters(in: .whitespaces)
                    let br = branch.trimmingCharacters(in: .whitespaces)
                    let env = AppContainer.shared.authEnv(for: repoPath)
                    AppContainer.shared.windowCoordinator.closeWindow(key: "sub-add-\(repoPath)")
                    AppContainer.shared.windowCoordinator.runTaskWithProgress(title: L("Add Submodule", "新增子模块"), repoPath: repoPath) { _ in
                        try await AppContainer.shared.gitProvider.addSubmodule(
                            repoPath: repoPath,
                            url: u,
                            path: p,
                            branch: br.isEmpty ? nil : br,
                            force: force,
                            extraEnv: env
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(url.isEmpty || path.isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()
        }
    }
}

struct UpdateSubmoduleWindowView: View {
    let repoPath: String

    @State private var submodules: [GitSubmodule] = []
    @State private var selectedPaths: Set<String> = []
    @State private var initSubmodules = true
    @State private var recursive = true
    @State private var remote = false
    @State private var strategy = 0 // 0=checkout, 1=merge, 2=rebase
    @State private var force = false
    @State private var noFetch = false

    var body: some View {
        VStack(spacing: 0) {
            List(submodules) { sub in
                Toggle(isOn: Binding(
                    get: { selectedPaths.contains(sub.path) },
                    set: { on in if on { selectedPaths.insert(sub.path) } else { selectedPaths.remove(sub.path) } }
                )) {
                    VStack(alignment: .leading) {
                        Text(sub.path).fontWeight(.medium)
                        Text(sub.url).font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            .frame(height: 140)

            Form {
                Toggle(L("Initialize (--init)", "初始化子模块 (--init)"), isOn: $initSubmodules)
                Toggle(L("Recursive (--recursive)", "递归 (--recursive)"), isOn: $recursive)
                Toggle(L("Use remote tracking branch (--remote)", "使用远程跟踪分支 (--remote)"), isOn: $remote)
                Toggle(L("Force (--force)", "强制执行 (--force)"), isOn: $force)
                Toggle(L("Do not fetch (--no-fetch)", "不获取 (--no-fetch)"), isOn: $noFetch)
                Picker(L("Update Mode:", "更新方式："), selection: $strategy) {
                    Text(L("Checkout", "签出")).tag(0)
                    Text(L("Merge", "合并")).tag(1)
                    Text(L("Rebase", "变基")).tag(2)
                }
                .pickerStyle(.segmented)
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button(L("Cancel", "取消")) {
                    AppContainer.shared.windowCoordinator.closeWindow(key: "sub-update-\(repoPath)")
                }
                .keyboardShortcut(.escape, modifiers: [])
                Button(L("Update", "更新")) {
                    let opts = GitSubmoduleUpdateOptions(
                        paths: selectedPaths.count == submodules.count ? [] : Array(selectedPaths),
                        initSubmodules: initSubmodules,
                        recursive: recursive,
                        remote: remote,
                        merge: strategy == 1,
                        rebase: strategy == 2,
                        force: force,
                        noFetch: noFetch
                    )
                    let env = AppContainer.shared.authEnv(for: repoPath)
                    AppContainer.shared.windowCoordinator.closeWindow(key: "sub-update-\(repoPath)")
                    AppContainer.shared.windowCoordinator.runTaskWithProgress(title: L("Update Submodules", "更新子模块"), repoPath: repoPath) { _ in
                        try await AppContainer.shared.gitProvider.updateSubmodules(repoPath: repoPath, options: opts, extraEnv: env)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()
        }
        .task {
            submodules = (try? await AppContainer.shared.gitProvider.listSubmodules(repoPath: repoPath)) ?? []
            selectedPaths = Set(submodules.map { $0.path })
        }
    }
}
