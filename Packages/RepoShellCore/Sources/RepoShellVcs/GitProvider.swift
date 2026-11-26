import Foundation
import RepoShellShared

public final class GitProvider: VcsProvider, @unchecked Sendable {
    public let vcsType: VcsType = .git
    public let capabilities: VcsCapability = .gitDefault

    private let preferencesProvider: @Sendable () -> AppPreferences
    private let bundle: Bundle

    public init(
        preferencesProvider: @escaping @Sendable () -> AppPreferences = { SharedStorage.shared.loadConfig().preferences },
        bundle: Bundle = .main
    ) {
        self.preferencesProvider = preferencesProvider
        self.bundle = bundle
    }

    // MARK: - Command Execution Core

    public func runGit(
        repoPath: String?,
        arguments: [String],
        extraEnv: [String: String] = [:],
        standardInput: Data? = nil,
        checkExitCode: Bool = true,
        onOutputLine: (@Sendable (String, Bool) -> Void)? = nil
    ) async throws -> ProcessOutput {
        let resolved = try GitExecutableResolver.resolve(preferences: preferencesProvider(), bundle: bundle)
        var fullArgs = ["-c", "core.quotepath=false"]
        fullArgs.append(contentsOf: arguments)

        var mergedEnv = resolved.extraEnvironment
        mergedEnv["GIT_TERMINAL_PROMPT"] = "0"
        for (k, v) in extraEnv {
            mergedEnv[k] = v
        }

        let workDir = repoPath.map { URL(fileURLWithPath: PathUtils.normalize($0)) }
        let output = try await ProcessRunner.run(
            executableURL: resolved.executableURL,
            arguments: fullArgs,
            workingDirectory: workDir,
            environment: mergedEnv,
            standardInputData: standardInput,
            onOutputLine: onOutputLine
        )

        if checkExitCode && output.exitCode != 0 {
            throw VcsError.commandFailed(
                command: "git " + fullArgs.joined(separator: " "),
                exitCode: output.exitCode,
                stderr: output.stderrString,
                stdout: output.stdoutString
            )
        }
        return output
    }

    public static func isLikelyTransientLocalNetworkError(stderr: String) -> Bool {
        stderr.contains("Failed to connect to")
            || stderr.contains("Couldn't connect to server")
            || stderr.contains("No route to host")
    }

    /// Retries short-lived local-network drops caused by macOS 15 NECP UUID cache refresh after rebuilds.
    private func runNetworkGit(
        repoPath: String?,
        arguments: [String],
        extraEnv: [String: String] = [:],
        standardInput: Data? = nil,
        checkExitCode: Bool = true,
        onOutputLine: (@Sendable (String, Bool) -> Void)? = nil
    ) async throws -> ProcessOutput {
        let retryDelays: [UInt64] = [600_000_000, 1_000_000_000]
        let fullCommand = "git -c core.quotepath=false " + arguments.joined(separator: " ")

        for attempt in 0...retryDelays.count {
            let hasRetriesRemaining = attempt < retryDelays.count
            let lineBuffer = TransientNetworkLineBuffer()
            let callback: (@Sendable (String, Bool) -> Void)?
            if let userCallback = onOutputLine {
                callback = { line, isStderr in
                    if hasRetriesRemaining && TransientNetworkLineBuffer.isTransientLine(line, isStderr: isStderr) {
                        lineBuffer.append(line: line, isStderr: isStderr)
                    } else {
                        userCallback(line, isStderr)
                    }
                }
            } else {
                callback = nil
            }

            let startedAt = Date()
            let output = try await runGit(
                repoPath: repoPath,
                arguments: arguments,
                extraEnv: extraEnv,
                standardInput: standardInput,
                checkExitCode: false,
                onOutputLine: callback
            )
            let elapsed = Date().timeIntervalSince(startedAt)

            if output.exitCode == 0 {
                if let onOutputLine = onOutputLine {
                    for entry in lineBuffer.takeAll() {
                        onOutputLine(entry.line, entry.isStderr)
                    }
                }
                return output
            }

            if hasRetriesRemaining,
               elapsed < 3.0,
               Self.isLikelyTransientLocalNetworkError(stderr: output.stderrString) {
                lineBuffer.clear()
                try await Task.sleep(nanoseconds: retryDelays[attempt])
                continue
            }

            if let onOutputLine = onOutputLine {
                for entry in lineBuffer.takeAll() {
                    onOutputLine(entry.line, entry.isStderr)
                }
            }
            if checkExitCode {
                throw VcsError.commandFailed(
                    command: fullCommand,
                    exitCode: output.exitCode,
                    stderr: output.stderrString,
                    stdout: output.stdoutString
                )
            }
            return output
        }

        fatalError("Unreachable")
    }

    // MARK: - Detection & State

    public func detectRepositoryRoot(for path: String) async -> String? {
        let fm = FileManager.default
        var current = URL(fileURLWithPath: PathUtils.normalize(path))
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: current.path, isDirectory: &isDir), !isDir.boolValue {
            current = current.deletingLastPathComponent()
        }
        guard fm.fileExists(atPath: current.path) else { return nil }

        if let out = try? await runGit(
            repoPath: current.path,
            arguments: ["rev-parse", "--show-toplevel"],
            checkExitCode: true
        ) {
            let root = out.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !root.isEmpty {
                return PathUtils.normalize(root)
            }
        }
        return nil
    }

    public func detectRepoState(repoPath: String) -> VcsRepoState {
        let gitDir = resolveGitDirectory(repoPath: repoPath)
        let fm = FileManager.default
        if fm.fileExists(atPath: gitDir.appendingPathComponent("MERGE_HEAD").path) {
            return .merging
        }
        if fm.fileExists(atPath: gitDir.appendingPathComponent("rebase-merge").path)
            || fm.fileExists(atPath: gitDir.appendingPathComponent("rebase-apply").path) {
            return .rebasing
        }
        if fm.fileExists(atPath: gitDir.appendingPathComponent("CHERRY_PICK_HEAD").path) {
            return .cherryPicking
        }
        if fm.fileExists(atPath: gitDir.appendingPathComponent("REVERT_HEAD").path) {
            return .reverting
        }
        if fm.fileExists(atPath: gitDir.appendingPathComponent("BISECT_LOG").path) {
            return .bisecting
        }
        return .normal
    }

    public func resolveGitDirectory(repoPath: String) -> URL {
        let norm = PathUtils.normalize(repoPath)
        let dotGit = URL(fileURLWithPath: norm).appendingPathComponent(".git")
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDir) {
            if isDir.boolValue {
                return dotGit
            }
            // Worktree or submodule: `.git` is a file containing `gitdir: <path>`
            if let text = try? String(contentsOf: dotGit, encoding: .utf8),
               let line = text.components(separatedBy: .newlines).first(where: { $0.hasPrefix("gitdir:") }) {
                let rawTarget = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
                if rawTarget.hasPrefix("/") {
                    return URL(fileURLWithPath: rawTarget)
                } else {
                    return URL(fileURLWithPath: norm).appendingPathComponent(rawTarget).standardizedFileURL
                }
            }
        }
        return dotGit
    }

    // MARK: - Status

    public func status(repoPath: String, options: VcsStatusOptions = VcsStatusOptions()) async throws -> VcsStatusResult {
        var args = ["status", "--porcelain=v2", "-z", "--branch"]
        args.append(options.includeUntracked ? "-uall" : "-uno")
        args.append(options.includeIgnored ? "--ignored=matching" : "--ignored=no")

        let out = try await runGit(repoPath: repoPath, arguments: args)
        var parsed = GitParsers.parsePorcelainV2Z(out.stdoutData, repoPath: repoPath)

        var lineStats: [String: (Int, Int)] = [:]
        if options.includeLineStats {
            let unstagedDiff = try? await runGit(repoPath: repoPath, arguments: ["diff", "--numstat", "-z"], checkExitCode: false)
            let stagedDiff = try? await runGit(repoPath: repoPath, arguments: ["diff", "--cached", "--numstat", "-z"], checkExitCode: false)
            if let d = unstagedDiff?.stdoutData {
                for (k, v) in GitParsers.parseNumstatZ(d) {
                    lineStats[k] = v
                }
            }
            if let d = stagedDiff?.stdoutData {
                for (k, v) in GitParsers.parseNumstatZ(d) {
                    let prev = lineStats[k] ?? (0, 0)
                    lineStats[k] = (prev.0 + v.0, prev.1 + v.1)
                }
            }
        }

        let fm = FileManager.default
        parsed.entries = parsed.entries.map { item in
            var copy = item
            if let stat = lineStats[item.relativePath] {
                copy.additions = stat.0
                copy.deletions = stat.1
            }
            if let attrs = try? fm.attributesOfItem(atPath: item.absolutePath) {
                copy.fileSize = attrs[.size] as? Int64
                copy.modificationDate = attrs[.modificationDate] as? Date
            }
            return copy
        }

        return VcsStatusResult(
            repoPath: PathUtils.normalize(repoPath),
            branchName: parsed.branchName,
            upstreamBranch: parsed.upstream,
            aheadCount: parsed.ahead,
            behindCount: parsed.behind,
            repoState: detectRepoState(repoPath: repoPath),
            items: parsed.entries
        )
    }

    // MARK: - Init & Clone

    public func initRepository(at path: String, bare: Bool = false) async throws -> VcsCommandResult {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        var args = ["init"]
        if bare { args.append("--bare") }
        let out = try await runGit(repoPath: path, arguments: args)
        return VcsCommandResult(command: "git init", exitCode: out.exitCode, stdout: out.stdoutString, stderr: out.stderrString)
    }

    public func clone(
        options: GitCloneOptions,
        extraEnv: [String: String] = [:],
        onOutputLine: (@Sendable (String, Bool) -> Void)? = nil
    ) async throws -> VcsCommandResult {
        var args = ["clone", "--progress"]
        if options.bare { args.append("--bare") }
        if options.singleBranch { args.append("--single-branch") }
        if let branch = options.branch, !branch.isEmpty {
            args.append(contentsOf: ["--branch", branch])
        }
        if options.recursiveSubmodules && !options.bare {
            args.append("--recursive")
        }
        args.append(options.url)
        args.append(options.destinationPath)

        let parentDir = URL(fileURLWithPath: options.destinationPath).deletingLastPathComponent().path
        try? FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
        let out = try await runNetworkGit(
            repoPath: parentDir,
            arguments: args,
            extraEnv: extraEnv,
            onOutputLine: onOutputLine
        )
        return VcsCommandResult(command: "git clone", exitCode: out.exitCode, stdout: out.stdoutString, stderr: out.stderrString)
    }

    // MARK: - Basic Working Tree & Commit

    public func add(repoPath: String, paths: [String]) async throws -> VcsCommandResult {
        let rels = relativePaths(paths, repoPath: repoPath)
        let targetArgs = rels.isEmpty ? ["."] : rels
        let out = try await runGit(repoPath: repoPath, arguments: ["add", "--"] + targetArgs)
        return VcsCommandResult(command: "git add", exitCode: out.exitCode, stdout: out.stdoutString, stderr: out.stderrString)
    }

    public func unstage(repoPath: String, paths: [String]) async throws -> VcsCommandResult {
        let rels = relativePaths(paths, repoPath: repoPath)
        let targetArgs = rels.isEmpty ? ["."] : rels
        let out = try await runGit(repoPath: repoPath, arguments: ["reset", "HEAD", "--"] + targetArgs)
        return VcsCommandResult(command: "git reset HEAD", exitCode: out.exitCode, stdout: out.stdoutString, stderr: out.stderrString)
    }

    public func commit(repoPath: String, options: VcsCommitOptions) async throws -> VcsCommandResult {
        let rels = relativePaths(options.paths, repoPath: repoPath)
        if options.stageSelectedPaths && !rels.isEmpty {
            // Stage additions/modifications/deletions for selected paths (`git add -A -- <paths>`)
            _ = try await runGit(repoPath: repoPath, arguments: ["add", "-A", "--"] + rels)
        }
        var args = ["commit", "-m", options.message]
        if options.amend { args.append("--amend") }
        if options.allowEmpty { args.append("--allow-empty") }
        if !options.stageSelectedPaths && !rels.isEmpty {
            args.append("--")
            args.append(contentsOf: rels)
        } else if options.stageSelectedPaths && !rels.isEmpty && !options.amend {
            // Only commit the selected paths (do not sweep unrelated staged changes unless amending)
            args.append("--")
            args.append(contentsOf: rels)
        }
        let out = try await runGit(repoPath: repoPath, arguments: args)
        return VcsCommandResult(command: "git commit", exitCode: out.exitCode, stdout: out.stdoutString, stderr: out.stderrString)
    }

    public func revert(repoPath: String, paths: [String]) async throws -> VcsCommandResult {
        let rels = relativePaths(paths, repoPath: repoPath)
        let statusResult = try await status(repoPath: repoPath, options: VcsStatusOptions(includeIgnored: false, includeUntracked: true))
        let untrackedSet = Set(statusResult.items.filter { $0.status == .untracked }.map { $0.relativePath })
        let addedSet = Set(statusResult.items.filter { $0.status == .added }.map { $0.relativePath })

        let targetRels = rels.isEmpty ? statusResult.items.map { $0.relativePath } : rels
        var trackedRels: [String] = []
        var untrackedToDelete: [String] = []
        var addedToUnstage: [String] = []

        for r in targetRels {
            if untrackedSet.contains(r) {
                untrackedToDelete.append(r)
            } else if addedSet.contains(r) {
                addedToUnstage.append(r)
            } else {
                trackedRels.append(r)
            }
        }

        var combinedStdout = ""
        if !addedToUnstage.isEmpty {
            let out = try await runGit(repoPath: repoPath, arguments: ["rm", "-f", "--cached", "--"] + addedToUnstage)
            combinedStdout += out.stdoutString
        }
        if !untrackedToDelete.isEmpty {
            let fm = FileManager.default
            for rel in untrackedToDelete {
                let full = PathUtils.normalize("\(repoPath)/\(rel)")
                try? fm.removeItem(atPath: full)
            }
        }
        if !trackedRels.isEmpty {
            // Unstage first if staged, then checkout HEAD
            _ = try? await runGit(repoPath: repoPath, arguments: ["reset", "HEAD", "--"] + trackedRels, checkExitCode: false)
            let out = try await runGit(repoPath: repoPath, arguments: ["checkout", "--"] + trackedRels)
            combinedStdout += out.stdoutString
        }

        return VcsCommandResult(command: "git revert files", exitCode: 0, stdout: combinedStdout, stderr: "")
    }

    public func remove(repoPath: String, paths: [String], keepLocal: Bool) async throws -> VcsCommandResult {
        let rels = relativePaths(paths, repoPath: repoPath)
        guard !rels.isEmpty else {
            return VcsCommandResult(command: "git rm", exitCode: 0, stdout: "", stderr: "")
        }
        var args = ["rm", "-r", "-f"]
        if keepLocal { args.append("--cached") }
        args.append("--")
        args.append(contentsOf: rels)
        let out = try await runGit(repoPath: repoPath, arguments: args)
        return VcsCommandResult(command: "git rm", exitCode: out.exitCode, stdout: out.stdoutString, stderr: out.stderrString)
    }

    public func rename(repoPath: String, from sourcePath: String, to destinationPath: String) async throws -> VcsCommandResult {
        let srcRel = PathUtils.relativePath(of: sourcePath, inside: repoPath) ?? sourcePath
        let dstRel = PathUtils.relativePath(of: destinationPath, inside: repoPath) ?? destinationPath
        let out = try await runGit(repoPath: repoPath, arguments: ["mv", "--", srcRel, dstRel])
        return VcsCommandResult(command: "git mv", exitCode: out.exitCode, stdout: out.stdoutString, stderr: out.stderrString)
    }

    public func resolveConflict(repoPath: String, path: String, strategy: ConflictResolutionStrategy) async throws -> VcsCommandResult {
        let rel = PathUtils.relativePath(of: path, inside: repoPath) ?? path
        switch strategy {
        case .ours:
            _ = try await runGit(repoPath: repoPath, arguments: ["checkout", "--ours", "--", rel])
            let out = try await runGit(repoPath: repoPath, arguments: ["add", "--", rel])
            return VcsCommandResult(command: "git resolve --ours", exitCode: out.exitCode, stdout: out.stdoutString, stderr: out.stderrString)
        case .theirs:
            _ = try await runGit(repoPath: repoPath, arguments: ["checkout", "--theirs", "--", rel])
            let out = try await runGit(repoPath: repoPath, arguments: ["add", "--", rel])
            return VcsCommandResult(command: "git resolve --theirs", exitCode: out.exitCode, stdout: out.stdoutString, stderr: out.stderrString)
        case .markResolved:
            let out = try await runGit(repoPath: repoPath, arguments: ["add", "--", rel])
            return VcsCommandResult(command: "git add (mark resolved)", exitCode: out.exitCode, stdout: out.stdoutString, stderr: out.stderrString)
        }
    }

    // MARK: - Remote Sync (Fetch / Pull / Push)

    public func fetch(
        repoPath: String,
        options: GitFetchOptions,
        extraEnv: [String: String] = [:],
        onOutputLine: (@Sendable (String, Bool) -> Void)? = nil
    ) async throws -> VcsCommandResult {
        var args = ["fetch", "--progress"]
        if options.fetchAllRemotes {
            args.append("--all")
        } else {
            args.append(options.remote)
        }
        if options.prune { args.append("--prune") }
        if options.fetchTags { args.append("--tags") }

        let out = try await runNetworkGit(repoPath: repoPath, arguments: args, extraEnv: extraEnv, onOutputLine: onOutputLine)
        return VcsCommandResult(command: "git fetch", exitCode: out.exitCode, stdout: out.stdoutString, stderr: out.stderrString)
    }

    public func pull(
        repoPath: String,
        options: GitPullOptions,
        extraEnv: [String: String] = [:],
        onOutputLine: (@Sendable (String, Bool) -> Void)? = nil
    ) async throws -> VcsCommandResult {
        if options.fetchAllRemotes {
            _ = try await fetch(repoPath: repoPath, options: GitFetchOptions(fetchAllRemotes: true, fetchTags: options.fetchTags), extraEnv: extraEnv, onOutputLine: onOutputLine)
        }
        var args = ["pull", "--progress"]
        switch options.strategy {
        case .merge:
            args.append("--no-rebase")
            if options.noFastForward { args.append("--no-ff") }
        case .rebase:
            args.append("--rebase")
        case .fastForwardOnly:
            args.append("--ff-only")
        }
        if options.noCommit { args.append("--no-commit") }
        if options.includeMergeLog { args.append("--log") }
        if options.fetchTags { args.append("--tags") }
        if !options.remote.isEmpty {
            args.append(options.remote)
            if let branch = options.remoteBranch, !branch.isEmpty {
                args.append(branch)
            }
        }
        let out = try await runNetworkGit(repoPath: repoPath, arguments: args, extraEnv: extraEnv, onOutputLine: onOutputLine)
        return VcsCommandResult(command: "git pull", exitCode: out.exitCode, stdout: out.stdoutString, stderr: out.stderrString)
    }

    public func push(
        repoPath: String,
        options: GitPushOptions,
        extraEnv: [String: String] = [:],
        onOutputLine: (@Sendable (String, Bool) -> Void)? = nil
    ) async throws -> VcsCommandResult {
        var args = ["push", "--progress"]
        if options.setUpstream { args.append("-u") }
        if options.forceWithLease {
            args.append("--force-with-lease")
        } else if options.force {
            args.append("--force")
        }
        args.append(options.remote)

        for mapping in options.branchMappings where mapping.isSelected {
            if mapping.remoteBranch.isEmpty || mapping.localBranch == mapping.remoteBranch {
                args.append(mapping.localBranch)
            } else {
                args.append("\(mapping.localBranch):\(mapping.remoteBranch)")
            }
        }
        if options.pushAllTags {
            args.append("--tags")
        } else {
            for tag in options.tags {
                args.append("refs/tags/\(tag)")
            }
        }
        let out = try await runNetworkGit(repoPath: repoPath, arguments: args, extraEnv: extraEnv, onOutputLine: onOutputLine)
        return VcsCommandResult(command: "git push", exitCode: out.exitCode, stdout: out.stdoutString, stderr: out.stderrString)
    }

    // MARK: - Log & History Mutation

    public func log(repoPath: String, query: VcsLogQuery) async throws -> [VcsCommit] {
        // Check if repo has any commits first
        let headCheck = try await runGit(repoPath: repoPath, arguments: ["rev-parse", "--verify", "HEAD"], checkExitCode: false)
        if headCheck.exitCode != 0 && query.revisionRange == nil {
            return []
        }

        let format = "%x1e%H%x1f%h%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%D%x1f%s%x1f%b%x1f%N%x1d"
        var args = ["log", "--format=\(format)", "--raw", "--numstat", "-n", "\(query.limit)", "--skip=\(query.skip)"]
        if query.noMerges { args.append("--no-merges") }
        if query.followRenames { args.append("--follow") }
        if let search = query.searchQuery, !search.isEmpty {
            args.append(contentsOf: ["--grep=\(search)", "-i"])
        }
        if let range = query.revisionRange, !range.isEmpty {
            args.append(range)
        } else {
            // Exclude internal notes and stash refs so note/stash commits do not pollute log history.
            args.append(contentsOf: ["--exclude=refs/notes/*", "--exclude=refs/stash", "--all"])
        }
        if let pathFilter = query.pathFilter, !pathFilter.isEmpty {
            let rel = PathUtils.relativePath(of: pathFilter, inside: repoPath) ?? pathFilter
            if !rel.isEmpty {
                args.append(contentsOf: ["--", rel])
            }
        }
        let out = try await runGit(repoPath: repoPath, arguments: args)
        return GitParsers.parseLogOutput(out.stdoutString)
    }

    public func revertCommit(repoPath: String, commitHash: String, noCommit: Bool = false) async throws -> VcsCommandResult {
        var args = ["revert", "--no-edit"]
        if noCommit { args.append("--no-commit") }
        args.append(commitHash)
        let out = try await runGit(repoPath: repoPath, arguments: args)
        return VcsCommandResult(command: "git revert \(commitHash)", exitCode: out.exitCode, stdout: out.stdoutString, stderr: out.stderrString)
    }

    public func editHeadCommitMessage(repoPath: String, newMessage: String) async throws -> VcsCommandResult {
        let out = try await runGit(repoPath: repoPath, arguments: ["commit", "--amend", "-m", newMessage])
        return VcsCommandResult(command: "git commit --amend", exitCode: out.exitCode, stdout: out.stdoutString, stderr: out.stderrString)
    }

    public func editNote(repoPath: String, commitHash: String, note: String) async throws -> VcsCommandResult {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let args: [String]
        if trimmed.isEmpty {
            args = ["notes", "remove", "--ignore-missing", commitHash]
        } else {
            args = ["notes", "add", "-f", "-m", trimmed, commitHash]
        }
        let out = try await runGit(repoPath: repoPath, arguments: args)
        return VcsCommandResult(command: "git notes", exitCode: out.exitCode, stdout: out.stdoutString, stderr: out.stderrString)
    }

    public func squashCommits(repoPath: String, baseParentHash: String, message: String) async throws -> VcsCommandResult {
        // Non-destructive reset --soft to parent of oldest commit + commit with combined message
        _ = try await runGit(repoPath: repoPath, arguments: ["reset", "--soft", baseParentHash])
        let out = try await runGit(repoPath: repoPath, arguments: ["commit", "-m", message])
        return VcsCommandResult(command: "squash commits", exitCode: out.exitCode, stdout: out.stdoutString, stderr: out.stderrString)
    }

    // MARK: - References (Branches & Tags)

    public func listReferences(repoPath: String) async throws -> [GitReference] {
        let format = "%(refname)%1f%(refname:short)%1f%(objectname)%1f%(HEAD)%1f%(upstream:short)%1f%(upstream:track,nobracket)%1f%(creatordate:unix)%1f%(contents:subject)%1e"
        let out = try await runGit(repoPath: repoPath, arguments: ["for-each-ref", "--format=\(format)", "refs/heads", "refs/remotes", "refs/tags"])
        return GitParsers.parseReferences(out.stdoutString)
    }

    public func checkout(
        repoPath: String,
        target: String,
        createBranchName: String? = nil,
        force: Bool = false,
        mergeLocalChanges: Bool = false,
        overwriteBranch: Bool = false,
        track: Bool = false
    ) async throws -> VcsCommandResult {
        var args = ["checkout"]
        if force { args.append("-f") }
        if mergeLocalChanges { args.append("-m") }
        if let newBranch = createBranchName, !newBranch.isEmpty {
            args.append(overwriteBranch ? "-B" : "-b")
            args.append(newBranch)
            if track { args.append("--track") }
        }
        args.append(target)
        let out = try await runGit(repoPath: repoPath, arguments: args)
        return VcsCommandResult(command: "git checkout", exitCode: out.exitCode, stdout: out.stdoutString, stderr: out.stderrString)
    }

    public func createBranch(
        repoPath: String,
        name: String,
        startPoint: String = "HEAD",
        force: Bool = false,
        checkoutAfter: Bool = false,
        track: Bool = false
    ) async throws -> VcsCommandResult {
        if checkoutAfter {
            return try await checkout(
                repoPath: repoPath,
                target: startPoint,
                createBranchName: name,
                overwriteBranch: force,
                track: track
            )
        }
        var args = ["branch"]
        if force { args.append("-f") }
        if track { args.append("--track") }
        args.append(name)
        args.append(startPoint)
        let out = try await runGit(repoPath: repoPath, arguments: args)
        return VcsCommandResult(command: "git branch", exitCode: out.exitCode, stdout: out.stdoutString, stderr: out.stderrString)
    }

    public func renameBranch(repoPath: String, oldName: String, newName: String) async throws -> VcsCommandResult {
        let out = try await runGit(repoPath: repoPath, arguments: ["branch", "-m", oldName, newName])
        return VcsCommandResult(command: "git branch -m", exitCode: out.exitCode, stdout: out.stdoutString, stderr: out.stderrString)
    }

    public func deleteBranch(repoPath: String, name: String, force: Bool = false) async throws -> VcsCommandResult {
        let out = try await runGit(repoPath: repoPath, arguments: ["branch", force ? "-D" : "-d", name])
        return VcsCommandResult(command: "git branch -d", exitCode: out.exitCode, stdout: out.stdoutString, stderr: out.stderrString)
    }

    public func deleteRemoteBranch(
        repoPath: String,
        remote: String,
        branchName: String,
        extraEnv: [String: String] = [:]
    ) async throws -> VcsCommandResult {
        let out = try await runNetworkGit(repoPath: repoPath, arguments: ["push", remote, "--delete", branchName], extraEnv: extraEnv)
        return VcsCommandResult(command: "git push --delete", exitCode: out.exitCode, stdout: out.stdoutString, stderr: out.stderrString)
    }

    public func createTag(
        repoPath: String,
        name: String,
        target: String = "HEAD",
        message: String? = nil,
        force: Bool = false
    ) async throws -> VcsCommandResult {
        var args = ["tag"]
        if force { args.append("-f") }
        if let msg = message, !msg.isEmpty {
            args.append(contentsOf: ["-a", name, "-m", msg, target])
        } else {
            args.append(contentsOf: [name, target])
        }
        let out = try await runGit(repoPath: repoPath, arguments: args)
        return VcsCommandResult(command: "git tag", exitCode: out.exitCode, stdout: out.stdoutString, stderr: out.stderrString)
    }

    public func deleteTag(repoPath: String, name: String) async throws -> VcsCommandResult {
        let out = try await runGit(repoPath: repoPath, arguments: ["tag", "-d", name])
        return VcsCommandResult(command: "git tag -d", exitCode: out.exitCode, stdout: out.stdoutString, stderr: out.stderrString)
    }

    // MARK: - Merge & Reset

    public func merge(repoPath: String, options: GitMergeOptions) async throws -> VcsCommandResult {
        var args = ["merge"]
        if options.noFastForward { args.append("--no-ff") }
        if options.squash { args.append("--squash") }
        if options.noCommit { args.append("--no-commit") }
        if let logCount = options.logCount, logCount > 0 {
            args.append("--log=\(logCount)")
        }
        if let msg = options.message, !msg.isEmpty {
            args.append(contentsOf: ["-m", msg])
        }
        args.append(options.sourceRef)
        let out = try await runGit(repoPath: repoPath, arguments: args)
        return VcsCommandResult(command: "git merge", exitCode: out.exitCode, stdout: out.stdoutString, stderr: out.stderrString)
    }

    public func abortMerge(repoPath: String) async throws -> VcsCommandResult {
        let out = try await runGit(repoPath: repoPath, arguments: ["merge", "--abort"])
        return VcsCommandResult(command: "git merge --abort", exitCode: out.exitCode, stdout: out.stdoutString, stderr: out.stderrString)
    }

    public func reset(repoPath: String, target: String, mode: GitResetMode) async throws -> VcsCommandResult {
        let out = try await runGit(repoPath: repoPath, arguments: ["reset", "--\(mode.rawValue)", target])
        return VcsCommandResult(command: "git reset --\(mode.rawValue)", exitCode: out.exitCode, stdout: out.stdoutString, stderr: out.stderrString)
    }

    // MARK: - Stash

    public func listStashes(repoPath: String) async throws -> [GitStashEntry] {
        let format = "%gd%x1f%H%x1f%h%x1f%ct%x1f%gs%x1e"
        let out = try await runGit(repoPath: repoPath, arguments: ["stash", "list", "--format=\(format)"])
        return GitParsers.parseStashList(out.stdoutString)
    }

    public func stashSave(
        repoPath: String,
        message: String,
        includeUntracked: Bool = false,
        includeAll: Bool = false,
        paths: [String] = []
    ) async throws -> VcsCommandResult {
        var args = ["stash", "push"]
        if includeAll {
            args.append("--all")
        } else if includeUntracked {
            args.append("--include-untracked")
        }
        if !message.isEmpty {
            args.append(contentsOf: ["-m", message])
        }
        let rels = relativePaths(paths, repoPath: repoPath)
        if !rels.isEmpty {
            args.append("--")
            args.append(contentsOf: rels)
        }
        let out = try await runGit(repoPath: repoPath, arguments: args)
        return VcsCommandResult(command: "git stash push", exitCode: out.exitCode, stdout: out.stdoutString, stderr: out.stderrString)
    }

    public func stashApply(repoPath: String, stashRef: String, pop: Bool = false) async throws -> VcsCommandResult {
        let sub = pop ? "pop" : "apply"
        let out = try await runGit(repoPath: repoPath, arguments: ["stash", sub, stashRef])
        return VcsCommandResult(command: "git stash \(sub)", exitCode: out.exitCode, stdout: out.stdoutString, stderr: out.stderrString)
    }

    public func stashDrop(repoPath: String, stashRef: String) async throws -> VcsCommandResult {
        let out = try await runGit(repoPath: repoPath, arguments: ["stash", "drop", stashRef])
        return VcsCommandResult(command: "git stash drop", exitCode: out.exitCode, stdout: out.stdoutString, stderr: out.stderrString)
    }

    public func stashClear(repoPath: String) async throws -> VcsCommandResult {
        let out = try await runGit(repoPath: repoPath, arguments: ["stash", "clear"])
        return VcsCommandResult(command: "git stash clear", exitCode: out.exitCode, stdout: out.stdoutString, stderr: out.stderrString)
    }

    public func stashBranch(repoPath: String, branchName: String, stashRef: String) async throws -> VcsCommandResult {
        let out = try await runGit(repoPath: repoPath, arguments: ["stash", "branch", branchName, stashRef])
        return VcsCommandResult(command: "git stash branch", exitCode: out.exitCode, stdout: out.stdoutString, stderr: out.stderrString)
    }

    // MARK: - Remotes & Repo Info

    public func listRemotes(repoPath: String) async throws -> [GitRemote] {
        let out = try await runGit(repoPath: repoPath, arguments: ["remote", "-v"])
        return GitParsers.parseRemotes(out.stdoutString)
    }

    public func addRemote(repoPath: String, name: String, url: String) async throws -> VcsCommandResult {
        let out = try await runGit(repoPath: repoPath, arguments: ["remote", "add", name, url])
        return VcsCommandResult(command: "git remote add", exitCode: out.exitCode, stdout: out.stdoutString, stderr: out.stderrString)
    }

    public func setRemoteURL(repoPath: String, name: String, url: String) async throws -> VcsCommandResult {
        let out = try await runGit(repoPath: repoPath, arguments: ["remote", "set-url", name, url])
        return VcsCommandResult(command: "git remote set-url", exitCode: out.exitCode, stdout: out.stdoutString, stderr: out.stderrString)
    }

    public func removeRemote(repoPath: String, name: String) async throws -> VcsCommandResult {
        let out = try await runGit(repoPath: repoPath, arguments: ["remote", "remove", name])
        return VcsCommandResult(command: "git remote remove", exitCode: out.exitCode, stdout: out.stdoutString, stderr: out.stderrString)
    }

    public func repoSummary(repoPath: String) async throws -> GitRepoSummary {
        let statusRes = try await status(repoPath: repoPath, options: VcsStatusOptions(includeIgnored: false, includeUntracked: false))
        let headOut = try? await runGit(repoPath: repoPath, arguments: ["rev-parse", "HEAD"], checkExitCode: false)
        let countOut = try? await runGit(repoPath: repoPath, arguments: ["rev-list", "--count", "HEAD"], checkExitCode: false)
        let bareOut = try? await runGit(repoPath: repoPath, arguments: ["rev-parse", "--is-bare-repository"], checkExitCode: false)
        let remotes = (try? await listRemotes(repoPath: repoPath)) ?? []
        let submodules = (try? await listSubmodules(repoPath: repoPath)) ?? []

        return GitRepoSummary(
            repoPath: PathUtils.normalize(repoPath),
            currentBranch: statusRes.branchName,
            headHash: headOut?.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            upstreamBranch: statusRes.upstreamBranch,
            totalCommits: Int(countOut?.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0") ?? 0,
            isBare: bareOut?.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == "true",
            repoState: statusRes.repoState,
            remotes: remotes,
            submodules: submodules
        )
    }

    public func cleanup(repoPath: String) async throws -> VcsCommandResult {
        let out = try await runGit(repoPath: repoPath, arguments: ["gc"])
        return VcsCommandResult(command: "git gc", exitCode: out.exitCode, stdout: out.stdoutString, stderr: out.stderrString)
    }

    // MARK: - Export, Diff, Compare, Repo Browser, Blame

    public func export(repoPath: String, revision: String, destinationPath: String, asZip: Bool) async throws -> VcsCommandResult {
        if asZip {
            let parent = URL(fileURLWithPath: destinationPath).deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let out = try await runGit(repoPath: repoPath, arguments: ["archive", "--format=zip", "--output=\(destinationPath)", revision])
            return VcsCommandResult(command: "git archive --format=zip", exitCode: out.exitCode, stdout: out.stdoutString, stderr: out.stderrString)
        } else {
            let tempZip = FileManager.default.temporaryDirectory.appendingPathComponent("reposhell-export-\(UUID().uuidString).zip")
            defer { try? FileManager.default.removeItem(at: tempZip) }
            _ = try await runGit(repoPath: repoPath, arguments: ["archive", "--format=zip", "--output=\(tempZip.path)", revision])
            try FileManager.default.createDirectory(atPath: destinationPath, withIntermediateDirectories: true)
            let unzip = try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/unzip"),
                arguments: ["-o", "-q", tempZip.path, "-d", destinationPath]
            )
            if unzip.exitCode != 0 {
                throw VcsError.commandFailed(command: "unzip", exitCode: unzip.exitCode, stderr: unzip.stderrString, stdout: unzip.stdoutString)
            }
            return VcsCommandResult(command: "git archive (directory)", exitCode: 0, stdout: "Exported \(revision) to \(destinationPath)", stderr: "")
        }
    }

    public func listDirectory(repoPath: String, path: String, revision: String) async throws -> [VcsTreeEntry] {
        let cleanPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var args = ["ls-tree", "-l", "-z", revision]
        if !cleanPath.isEmpty {
            args.append("--")
            args.append(cleanPath + "/")
        }
        let out = try await runGit(repoPath: repoPath, arguments: args)
        return GitParsers.parseLsTreeZ(out.stdoutData)
    }

    public func extractFile(repoPath: String, path: String, revision: String, to destinationPath: String) async throws {
        let rel = PathUtils.relativePath(of: path, inside: repoPath) ?? path
        let out = try await runGit(repoPath: repoPath, arguments: ["show", "\(revision):\(rel)"])
        let destURL = URL(fileURLWithPath: destinationPath)
        try FileManager.default.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try out.stdoutData.write(to: destURL, options: .atomic)
    }

    public func diffRevisions(repoPath: String, rev1: String, rev2: String) async throws -> [VcsChangedPath] {
        let nameStatus = try await runGit(repoPath: repoPath, arguments: ["diff", "--name-status", rev1, rev2])
        let numstat = try await runGit(repoPath: repoPath, arguments: ["diff", "--numstat", rev1, rev2])
        return GitParsers.parseCompareDiff(nameStatusOutput: nameStatus.stdoutString, numstatOutput: numstat.stdoutString)
    }

    public func blame(repoPath: String, path: String, revision: String?, ignoreWhitespace: Bool) async throws -> [VcsBlameLine] {
        let rel = PathUtils.relativePath(of: path, inside: repoPath) ?? path
        var args = ["blame", "--porcelain"]
        if ignoreWhitespace { args.append("-w") }
        if let rev = revision, !rev.isEmpty {
            args.append(rev)
        }
        args.append(contentsOf: ["--", rel])
        let out = try await runGit(repoPath: repoPath, arguments: args)
        return GitParsers.parseBlamePorcelain(out.stdoutString)
    }

    // MARK: - Advanced: Interactive Rebase, Cherry-Pick, RefLog, Submodules

    public func loadRebaseTodo(repoPath: String, upstream: String) async throws -> [GitRebaseTodoItem] {
        let format = "%H%x1f%h%x1f%an%x1f%at%x1f%s%x1e"
        let out = try await runGit(repoPath: repoPath, arguments: ["log", "--reverse", "--format=\(format)", "\(upstream)..HEAD"])
        let chunks = out.stdoutString.components(separatedBy: "\u{1E}")
        var items: [GitRebaseTodoItem] = []
        for (idx, chunk) in chunks.enumerated() {
            let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            let fields = trimmed.components(separatedBy: "\u{1F}")
            guard fields.count >= 5 else { continue }
            let ts = TimeInterval(fields[3]) ?? 0
            items.append(GitRebaseTodoItem(
                index: idx + 1,
                hash: fields[0],
                shortHash: fields[1],
                author: fields[2],
                date: Date(timeIntervalSince1970: ts),
                message: fields[4],
                action: .pick
            ))
        }
        return items
    }

    public func startInteractiveRebase(repoPath: String, upstream: String, todoItems: [GitRebaseTodoItem]) async throws -> VcsCommandResult {
        let tempDir = FileManager.default.temporaryDirectory
        let todoFile = tempDir.appendingPathComponent("reposhell-rebase-todo-\(UUID().uuidString).txt")
        let seqScript = tempDir.appendingPathComponent("reposhell-seq-editor-\(UUID().uuidString).sh")
        defer {
            try? FileManager.default.removeItem(at: todoFile)
            try? FileManager.default.removeItem(at: seqScript)
        }

        let todoLines = todoItems.map { item -> String in
            "\(item.action.rawValue) \(item.shortHash) \(item.message)"
        }.joined(separator: "\n") + "\n"
        try todoLines.write(to: todoFile, atomically: true, encoding: .utf8)

        // Overwrite git's generated todo file with our ordered todo list
        let scriptBody = """
        #!/bin/sh
        cp "\(todoFile.path)" "$1"
        """
        try scriptBody.write(to: seqScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: seqScript.path)

        let env: [String: String] = [
            "GIT_SEQUENCE_EDITOR": seqScript.path,
            "GIT_EDITOR": "true"
        ]
        let out = try await runGit(repoPath: repoPath, arguments: ["rebase", "-i", upstream], extraEnv: env)
        return VcsCommandResult(command: "git rebase -i", exitCode: out.exitCode, stdout: out.stdoutString, stderr: out.stderrString)
    }

    public func rebaseContinue(repoPath: String) async throws -> VcsCommandResult {
        let out = try await runGit(repoPath: repoPath, arguments: ["rebase", "--continue"], extraEnv: ["GIT_EDITOR": "true"])
        return VcsCommandResult(command: "git rebase --continue", exitCode: out.exitCode, stdout: out.stdoutString, stderr: out.stderrString)
    }

    public func rebaseSkip(repoPath: String) async throws -> VcsCommandResult {
        let out = try await runGit(repoPath: repoPath, arguments: ["rebase", "--skip"])
        return VcsCommandResult(command: "git rebase --skip", exitCode: out.exitCode, stdout: out.stdoutString, stderr: out.stderrString)
    }

    public func rebaseAbort(repoPath: String) async throws -> VcsCommandResult {
        let out = try await runGit(repoPath: repoPath, arguments: ["rebase", "--abort"])
        return VcsCommandResult(command: "git rebase --abort", exitCode: out.exitCode, stdout: out.stdoutString, stderr: out.stderrString)
    }

    public func cherryPick(
        repoPath: String,
        commits: [String],
        noCommit: Bool = false,
        recordOrigin: Bool = false
    ) async throws -> VcsCommandResult {
        var args = ["cherry-pick"]
        if noCommit { args.append("-n") }
        if recordOrigin { args.append("-x") }
        args.append(contentsOf: commits)
        let out = try await runGit(repoPath: repoPath, arguments: args)
        return VcsCommandResult(command: "git cherry-pick", exitCode: out.exitCode, stdout: out.stdoutString, stderr: out.stderrString)
    }

    public func cherryPickControl(repoPath: String, action: CherryPickControlAction) async throws -> VcsCommandResult {
        let out = try await runGit(repoPath: repoPath, arguments: ["cherry-pick", action.flag])
        return VcsCommandResult(command: "git cherry-pick \(action.flag)", exitCode: out.exitCode, stdout: out.stdoutString, stderr: out.stderrString)
    }

    public func reflog(repoPath: String, ref: String = "HEAD", limit: Int = 200) async throws -> [GitRefLogEntry] {
        let format = "%H%x1f%h%x1f%gd%x1f%ct%x1f%gs%x1e"
        let out = try await runGit(repoPath: repoPath, arguments: ["reflog", "show", ref, "-n", "\(limit)", "--format=\(format)"])
        return GitParsers.parseRefLog(out.stdoutString)
    }

    public func formatPatch(repoPath: String, commitHash: String, outputDirectory: String) async throws -> VcsCommandResult {
        try FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)
        let out = try await runGit(repoPath: repoPath, arguments: ["format-patch", "-1", commitHash, "-o", outputDirectory])
        return VcsCommandResult(command: "git format-patch", exitCode: out.exitCode, stdout: out.stdoutString, stderr: out.stderrString)
    }

    public func branchesContaining(repoPath: String, commitHash: String) async throws -> [String] {
        let out = try await runGit(repoPath: repoPath, arguments: ["branch", "-a", "--contains", commitHash])
        return out.stdoutString
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "* ")) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Submodules

    public func listSubmodules(repoPath: String) async throws -> [GitSubmodule] {
        let gitmodulesURL = URL(fileURLWithPath: PathUtils.normalize(repoPath)).appendingPathComponent(".gitmodules")
        guard FileManager.default.fileExists(atPath: gitmodulesURL.path) else {
            return []
        }

        let statusOut = try await runGit(repoPath: repoPath, arguments: ["submodule", "status"], checkExitCode: false)
        let configOut = try? await runGit(repoPath: repoPath, arguments: ["config", "-f", ".gitmodules", "--list"], checkExitCode: false)

        var urlByPath: [String: String] = [:]
        var branchByPath: [String: String] = [:]
        var pathByKey: [String: String] = [:]
        var tempURLByKey: [String: String] = [:]
        var tempBranchByKey: [String: String] = [:]

        if let configStr = configOut?.stdoutString {
            for line in configStr.components(separatedBy: .newlines) {
                guard let eqIdx = line.firstIndex(of: "=") else { continue }
                let fullKey = String(line[..<eqIdx])
                let val = String(line[line.index(after: eqIdx)...])
                let keyParts = fullKey.split(separator: ".").map(String.init)
                guard keyParts.count >= 3, keyParts[0] == "submodule" else { continue }
                let prop = keyParts.last!
                let name = keyParts[1..<(keyParts.count - 1)].joined(separator: ".")
                switch prop {
                case "path": pathByKey[name] = val
                case "url": tempURLByKey[name] = val
                case "branch": tempBranchByKey[name] = val
                default: break
                }
            }
            for (name, path) in pathByKey {
                if let url = tempURLByKey[name] { urlByPath[path] = url }
                if let br = tempBranchByKey[name] { branchByPath[path] = br }
            }
        }

        return GitParsers.parseSubmoduleStatus(statusOut.stdoutString, urlByPath: urlByPath, branchByPath: branchByPath)
    }

    public func addSubmodule(
        repoPath: String,
        url: String,
        path: String,
        branch: String? = nil,
        force: Bool = false,
        extraEnv: [String: String] = [:]
    ) async throws -> VcsCommandResult {
        var args = ["submodule", "add"]
        if force { args.append("-f") }
        if let br = branch, !br.isEmpty {
            args.append(contentsOf: ["-b", br])
        }
        args.append(contentsOf: [url, path])
        let out = try await runNetworkGit(repoPath: repoPath, arguments: args, extraEnv: extraEnv)
        return VcsCommandResult(command: "git submodule add", exitCode: out.exitCode, stdout: out.stdoutString, stderr: out.stderrString)
    }

    public func updateSubmodules(
        repoPath: String,
        options: GitSubmoduleUpdateOptions,
        extraEnv: [String: String] = [:]
    ) async throws -> VcsCommandResult {
        var args = ["submodule", "update"]
        if options.initSubmodules { args.append("--init") }
        if options.recursive { args.append("--recursive") }
        if options.remote { args.append("--remote") }
        if options.merge { args.append("--merge") }
        if options.rebase { args.append("--rebase") }
        if options.force { args.append("--force") }
        if options.noFetch { args.append("--no-fetch") }
        if !options.paths.isEmpty {
            args.append("--")
            args.append(contentsOf: options.paths)
        }
        let out = try await runNetworkGit(repoPath: repoPath, arguments: args, extraEnv: extraEnv)
        return VcsCommandResult(command: "git submodule update", exitCode: out.exitCode, stdout: out.stdoutString, stderr: out.stderrString)
    }

    public func updateSubmoduleConfig(repoPath: String, path: String, newURL: String, branch: String?) async throws -> VcsCommandResult {
        let keyOut = try? await runGit(repoPath: repoPath, arguments: ["config", "-f", ".gitmodules", "--get-regexp", #"^submodule\..*\.path$"#], checkExitCode: false)
        var submoduleKey = path
        if let lines = keyOut?.stdoutString.components(separatedBy: .newlines) {
            for line in lines {
                let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                if parts.count == 2 && parts[1] == path {
                    let prefix = "submodule."
                    let suffix = ".path"
                    if parts[0].hasPrefix(prefix) && parts[0].hasSuffix(suffix) {
                        submoduleKey = String(parts[0].dropFirst(prefix.count).dropLast(suffix.count))
                    }
                    break
                }
            }
        }
        let out = try await runGit(repoPath: repoPath, arguments: ["config", "-f", ".gitmodules", "submodule.\(submoduleKey).url", newURL])
        if let br = branch {
            if br.isEmpty {
                _ = try? await runGit(repoPath: repoPath, arguments: ["config", "-f", ".gitmodules", "--unset", "submodule.\(submoduleKey).branch"], checkExitCode: false)
            } else {
                _ = try? await runGit(repoPath: repoPath, arguments: ["config", "-f", ".gitmodules", "submodule.\(submoduleKey).branch", br])
            }
        }
        _ = try? await runGit(repoPath: repoPath, arguments: ["submodule", "sync", "--", path], checkExitCode: false)
        return VcsCommandResult(command: "update submodule config", exitCode: out.exitCode, stdout: out.stdoutString, stderr: out.stderrString)
    }

    // MARK: - Ignore & Global Git Config Helpers

    public func appendToGitIgnore(repoPath: String, patterns: [String]) throws {
        let ignoreURL = URL(fileURLWithPath: PathUtils.normalize(repoPath)).appendingPathComponent(".gitignore")
        var existing = (try? String(contentsOf: ignoreURL, encoding: .utf8)) ?? ""
        var existingLines = Set(existing.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) })

        var toAppend: [String] = []
        for pattern in patterns {
            let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !existingLines.contains(trimmed) {
                toAppend.append(trimmed)
                existingLines.insert(trimmed)
            }
        }
        guard !toAppend.isEmpty else { return }
        if !existing.isEmpty && !existing.hasSuffix("\n") {
            existing += "\n"
        }
        existing += toAppend.joined(separator: "\n") + "\n"
        try existing.write(to: ignoreURL, atomically: true, encoding: .utf8)
    }

    public func getGlobalConfigValue(key: String) async -> String {
        guard let out = try? await runGit(repoPath: nil, arguments: ["config", "--global", "--get", key], checkExitCode: false),
              out.exitCode == 0 else {
            return ""
        }
        return out.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func setGlobalConfigValue(key: String, value: String) async throws {
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = try? await runGit(repoPath: nil, arguments: ["config", "--global", "--unset-all", key], checkExitCode: false)
        } else {
            _ = try await runGit(repoPath: nil, arguments: ["config", "--global", key, value])
        }
    }

    // MARK: - Helpers

    private func relativePaths(_ paths: [String], repoPath: String) -> [String] {
        let normRepo = PathUtils.normalize(repoPath)
        return paths.compactMap { p in
            let norm = PathUtils.normalize(p)
            if norm == normRepo {
                return "."
            }
            if let rel = PathUtils.relativePath(of: norm, inside: normRepo) {
                return rel.isEmpty ? "." : rel
            }
            return p.hasPrefix("/") ? nil : p
        }
    }
}

public enum ConflictResolutionStrategy: String, Sendable {
    case ours
    case theirs
    case markResolved
}

public enum CherryPickControlAction: Sendable {
    case `continue`
    case skip
    case abort

    public var flag: String {
        switch self {
        case .continue: return "--continue"
        case .skip: return "--skip"
        case .abort: return "--abort"
        }
    }
}

private final class TransientNetworkLineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(line: String, isStderr: Bool)] = []

    static func isTransientLine(_ line: String, isStderr: Bool) -> Bool {
        guard isStderr else { return false }
        return line.contains("fatal: unable to access")
            || line.contains("Failed to connect to")
            || line.contains("Couldn't connect to server")
            || line.contains("No route to host")
    }

    func append(line: String, isStderr: Bool) {
        lock.withLock {
            entries.append((line: line, isStderr: isStderr))
        }
    }

    func takeAll() -> [(line: String, isStderr: Bool)] {
        lock.withLock {
            let copy = entries
            entries.removeAll()
            return copy
        }
    }

    func clear() {
        lock.withLock {
            entries.removeAll()
        }
    }
}
