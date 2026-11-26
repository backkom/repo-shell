import Foundation
import RepoShellShared

/// Buffers per-attempt stderr lines for transient LAN (NECP) errors until all retries fail.
private final class SvnTransientLineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffered: [(String, Bool)] = []

    func record(line: String, isError: Bool, forward: (@Sendable (String, Bool) -> Void)?) {
        if isError && SvnErrorClassifier.isTransientLocalNetworkError(line) {
            lock.withLock {
                buffered.append((line, isError))
            }
            return
        }
        forward?(line, isError)
    }

    func flush(to forward: (@Sendable (String, Bool) -> Void)?) {
        let items = lock.withLock { () -> [(String, Bool)] in
            let copy = buffered
            buffered.removeAll(keepingCapacity: true)
            return copy
        }
        for (line, isError) in items {
            forward?(line, isError)
        }
    }

    func clear() {
        lock.withLock { buffered.removeAll(keepingCapacity: true) }
    }
}

public final class SvnProvider: VcsProvider, @unchecked Sendable {
    public let vcsType: VcsType = .svn
    public let capabilities: VcsCapability = .svnDefault

    private let preferencesProvider: @Sendable () -> AppPreferences

    public init(preferencesProvider: @escaping @Sendable () -> AppPreferences = { AppPreferences() }) {
        self.preferencesProvider = preferencesProvider
    }

    // MARK: - Executable & Command Runner

    public func resolvedExecutable() throws -> ResolvedSvnExecutable {
        try SvnExecutableResolver.resolve(preferences: preferencesProvider())
    }

    public func svnVersion() async -> String? {
        guard let resolved = try? resolvedExecutable() else { return nil }
        return SvnExecutableResolver.versionString(
            of: resolved.executableURL,
            extraEnvironment: resolved.extraEnvironment
        )
    }

    @discardableResult
    public func runSvn(
        arguments: [String],
        workingDirectory: String? = nil,
        environment: [String: String]? = nil,
        auth: SvnAuthOverrides = SvnAuthOverrides(),
        standardInputData: Data? = nil,
        nonInteractive: Bool = true,
        isNetworkOperation: Bool = false,
        onOutputLine: (@Sendable (String, Bool) -> Void)? = nil
    ) async throws -> VcsCommandResult {
        let resolved = try resolvedExecutable()
        var args = arguments
        if nonInteractive && !args.contains("--non-interactive") {
            args.append("--non-interactive")
        }
        args.append(contentsOf: auth.cliArguments)

        var mergedEnv = resolved.extraEnvironment
        mergedEnv["LC_ALL"] = "en_US.UTF-8"
        if let environment {
            for (k, v) in environment {
                mergedEnv[k] = v
            }
        }

        let workURL = workingDirectory.map { URL(fileURLWithPath: PathUtils.normalize($0)) }
        let rawDisplay = (["svn"] + args).joined(separator: " ")
        let safeDisplay = SvnAuthOverrides.redactPassword(in: rawDisplay)

        let backoffsNs: [UInt64] = isNetworkOperation ? [400_000_000, 1_000_000_000] : []
        let lineBuffer = SvnTransientLineBuffer()
        var attempt = 0

        let lineHandler: (@Sendable (String, Bool) -> Void)?
        if let onOutputLine {
            lineHandler = { @Sendable line, isError in
                if isNetworkOperation {
                    lineBuffer.record(line: line, isError: isError, forward: onOutputLine)
                } else {
                    onOutputLine(line, isError)
                }
            }
        } else {
            lineHandler = nil
        }

        while true {
            try Task.checkCancellation()
            let output: ProcessOutput = try await ProcessRunner.run(
                executableURL: resolved.executableURL,
                arguments: args,
                workingDirectory: workURL,
                environment: mergedEnv,
                standardInputData: standardInputData,
                onOutputLine: lineHandler
            )

            if output.exitCode == 0 {
                lineBuffer.clear()
                return VcsCommandResult(
                    command: safeDisplay,
                    exitCode: output.exitCode,
                    stdout: output.stdoutString,
                    stderr: output.stderrString
                )
            }

            if attempt < backoffsNs.count && SvnErrorClassifier.isTransientLocalNetworkError(output.stderrString) {
                lineBuffer.clear()
                let delay = backoffsNs[attempt]
                attempt += 1
                try await Task.sleep(nanoseconds: delay)
                continue
            }

            lineBuffer.flush(to: onOutputLine)
            throw VcsError.commandFailed(
                command: safeDisplay,
                exitCode: output.exitCode,
                stderr: output.stderrString,
                stdout: output.stdoutString
            )
        }
    }

    /// Runs `svn` writing raw stdout bytes directly to a destination file without UTF-8 lossy decoding.
    private func runSvnRawOutput(
        arguments: [String],
        workingDirectory: String? = nil,
        environment: [String: String]? = nil,
        auth: SvnAuthOverrides = SvnAuthOverrides(),
        outputFileURL: URL
    ) async throws {
        let resolved = try resolvedExecutable()
        var args = arguments
        if !args.contains("--non-interactive") {
            args.append("--non-interactive")
        }
        args.append(contentsOf: auth.cliArguments)

        var mergedEnv = ProcessInfo.processInfo.environment
        for (k, v) in resolved.extraEnvironment { mergedEnv[k] = v }
        mergedEnv["LC_ALL"] = "en_US.UTF-8"
        if let environment {
            for (k, v) in environment { mergedEnv[k] = v }
        }

        let fm = FileManager.default
        let parent = outputFileURL.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        fm.createFile(atPath: outputFileURL.path, contents: nil)

        let outHandle = try FileHandle(forWritingTo: outputFileURL)
        defer { try? outHandle.close() }

        let errPipe = Pipe()
        let process = Process()
        process.executableURL = resolved.executableURL
        process.arguments = args
        process.environment = mergedEnv
        if let workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: PathUtils.normalize(workingDirectory))
        }
        process.standardOutput = outHandle
        process.standardError = errPipe

        let safeDisplay = SvnAuthOverrides.redactPassword(in: (["svn"] + args).joined(separator: " "))

        let (status, stderrText): (Int32, String) = try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try process.run()
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    let errStr = String(data: errData, encoding: .utf8) ?? ""
                    cont.resume(returning: (process.terminationStatus, errStr))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }

        guard status == 0 else {
            throw VcsError.commandFailed(command: safeDisplay, exitCode: status, stderr: stderrText, stdout: "")
        }
    }

    // MARK: - Path & Revision Helpers

    public func escapePegPath(_ path: String) -> String {
        guard path.contains("@") else { return path }
        // Preserve already-pinned remote URL peg suffixes only when explicitly appending another @rev elsewhere;
        // for plain working-copy/URL targets without explicit peg revision, appending "@" tells svn it's a literal name.
        if let lastAt = path.lastIndex(of: "@") {
            let suffix = path[path.index(after: lastAt)...]
            if suffix.isEmpty { return path }
        }
        return "\(path)@"
    }

    public func cleanRevision(_ rev: String) -> String {
        let trimmed = rev.trimmingCharacters(in: .whitespacesAndNewlines)
        if (trimmed.hasPrefix("r") || trimmed.hasPrefix("R")) && trimmed.count > 1 {
            let tail = String(trimmed.dropFirst())
            if Int(tail) != nil {
                return tail
            }
        }
        return trimmed
    }

    private func resolveTargetArgs(_ paths: [String], repoPath: String) -> [String] {
        let normRepo = PathUtils.normalize(repoPath)
        let list = paths.isEmpty ? ["."] : paths
        return list.map { raw -> String in
            if !raw.hasPrefix("/") {
                let clean = raw == "." ? "." : raw
                return clean == "." ? "." : escapePegPath(clean)
            }
            let norm = PathUtils.normalize(raw)
            if norm == normRepo {
                return "."
            }
            if let rel = PathUtils.relativePath(of: norm, inside: normRepo), !rel.isEmpty {
                return escapePegPath(rel)
            }
            return escapePegPath(norm)
        }
    }

    private func normalizePathOrURL(_ path: String, repoPath: String) -> String {
        if path.contains("://") || path.hasPrefix("^/") {
            return path
        }
        if !path.hasPrefix("/") {
            return path == "." ? "." : escapePegPath(path)
        }
        let normRepo = PathUtils.normalize(repoPath)
        let norm = PathUtils.normalize(path)
        if norm == normRepo { return "." }
        if let rel = PathUtils.relativePath(of: norm, inside: normRepo), !rel.isEmpty {
            return escapePegPath(rel)
        }
        return escapePegPath(norm)
    }

    // MARK: - VcsProvider Core Conformance

    public func detectRepositoryRoot(for path: String) async -> String? {
        let fm = FileManager.default
        var current = URL(fileURLWithPath: PathUtils.normalize(path))
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: current.path, isDirectory: &isDir), !isDir.boolValue {
            current = current.deletingLastPathComponent()
        }

        // First walk ancestors for `.svn` (handles both SVN 1.7+ single `.svn` and SVN 1.6 nested `.svn`).
        var topMostSvnDir: String?
        var scan = current
        while true {
            let marker = scan.appendingPathComponent(".svn")
            if fm.fileExists(atPath: marker.path) {
                topMostSvnDir = scan.path
            } else if topMostSvnDir != nil {
                break
            }
            let parent = scan.deletingLastPathComponent()
            if parent.path == scan.path { break }
            scan = parent
        }

        if let res = try? await runSvn(
            arguments: ["info", "--show-item", "wc-root", escapePegPath(current.path)],
            workingDirectory: current.path
        ) {
            let wcRoot = res.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !wcRoot.isEmpty && fm.fileExists(atPath: wcRoot) {
                return PathUtils.normalize(wcRoot)
            }
        }

        return topMostSvnDir.map { PathUtils.normalize($0) }
    }

    public func status(repoPath: String, options: VcsStatusOptions) async throws -> VcsStatusResult {
        let norm = PathUtils.normalize(repoPath)
        async let infoTask = info(target: norm, workingDirectory: norm)
        async let statusTask = detailedStatus(
            repoPath: norm,
            checkRemote: false,
            includeIgnored: options.includeIgnored,
            includeUntracked: options.includeUntracked
        )

        let wcInfo = try? await infoTask
        let detailed = try await statusTask

        let branchName = wcInfo?.formattedBranchName ?? ""
        let vcsItems = detailed.items.map(\.item)
        let hasConflicts = vcsItems.contains { $0.status == .unmerged }

        return VcsStatusResult(
            repoPath: norm,
            branchName: branchName,
            upstreamBranch: wcInfo?.url,
            aheadCount: 0,
            behindCount: 0,
            repoState: hasConflicts ? .merging : .normal,
            items: vcsItems
        )
    }

    public func commit(repoPath: String, options: VcsCommitOptions) async throws -> VcsCommandResult {
        try await svnCommit(
            repoPath: repoPath,
            paths: options.paths,
            message: options.message
        )
    }

    public func log(repoPath: String, query: VcsLogQuery) async throws -> [VcsCommit] {
        let stopOnCopy = !query.followRenames
        return try await svnLog(
            target: query.pathFilter ?? ".",
            repoPath: repoPath,
            revisionRange: query.revisionRange,
            limit: query.limit,
            searchQuery: query.searchQuery,
            stopOnCopy: stopOnCopy
        )
    }

    public func revert(repoPath: String, paths: [String]) async throws -> VcsCommandResult {
        try await revert(repoPath: repoPath, paths: paths, depth: .infinity)
    }

    public func revert(
        repoPath: String,
        paths: [String],
        depth: SvnDepth = .infinity,
        onOutputLine: (@Sendable (String, Bool) -> Void)? = nil
    ) async throws -> VcsCommandResult {
        var args = ["revert", "--depth", depth.rawValue]
        args.append(contentsOf: resolveTargetArgs(paths, repoPath: repoPath))
        return try await runSvn(arguments: args, workingDirectory: repoPath, onOutputLine: onOutputLine)
    }

    public func add(repoPath: String, paths: [String]) async throws -> VcsCommandResult {
        try await add(repoPath: repoPath, paths: paths, onOutputLine: nil)
    }

    public func add(
        repoPath: String,
        paths: [String],
        onOutputLine: (@Sendable (String, Bool) -> Void)? = nil
    ) async throws -> VcsCommandResult {
        let targetArgs = resolveTargetArgs(paths, repoPath: repoPath)
        var args = ["add", "--parents", "--force"]
        args.append(contentsOf: targetArgs)
        return try await runSvn(arguments: args, workingDirectory: repoPath, onOutputLine: onOutputLine)
    }

    public func remove(repoPath: String, paths: [String], keepLocal: Bool) async throws -> VcsCommandResult {
        try await remove(repoPath: repoPath, paths: paths, keepLocal: keepLocal, force: preferencesProvider().svnDeleteForce)
    }

    public func remove(
        repoPath: String,
        paths: [String],
        keepLocal: Bool,
        force: Bool,
        onOutputLine: (@Sendable (String, Bool) -> Void)? = nil
    ) async throws -> VcsCommandResult {
        var args = ["delete"]
        if keepLocal { args.append("--keep-local") }
        if force { args.append("--force") }
        args.append(contentsOf: resolveTargetArgs(paths, repoPath: repoPath))
        return try await runSvn(arguments: args, workingDirectory: repoPath, onOutputLine: onOutputLine)
    }

    public func blame(
        repoPath: String,
        path: String,
        revision: String?,
        ignoreWhitespace: Bool
    ) async throws -> [VcsBlameLine] {
        try await svnBlame(
            repoPath: repoPath,
            target: path,
            revision: revision,
            ignoreWhitespace: ignoreWhitespace
        )
    }

    public func export(
        repoPath: String,
        revision: String,
        destinationPath: String,
        asZip: Bool
    ) async throws -> VcsCommandResult {
        let normDest = PathUtils.normalize(destinationPath)
        if asZip {
            let tempRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("reposhell-svn-export-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempRoot) }

            let baseName = URL(fileURLWithPath: normDest).deletingPathExtension().lastPathComponent
            let stagingDir = tempRoot.appendingPathComponent(baseName.isEmpty ? "export" : baseName, isDirectory: true)

            _ = try await svnExport(
                source: repoPath,
                destinationPath: stagingDir.path,
                revision: revision,
                workingDirectory: repoPath
            )

            let zipOut = try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/ditto"),
                arguments: ["-c", "-k", "--sequesterRsrc", "--keepParent", stagingDir.path, normDest]
            )
            guard zipOut.exitCode == 0 else {
                throw VcsError.commandFailed(
                    command: "ditto -c -k \(stagingDir.path) \(normDest)",
                    exitCode: zipOut.exitCode,
                    stderr: zipOut.stderrString,
                    stdout: zipOut.stdoutString
                )
            }
            return VcsCommandResult(
                command: "svn export + zip -> \(normDest)",
                exitCode: 0,
                stdout: zipOut.stdoutString,
                stderr: ""
            )
        }

        return try await svnExport(
            source: repoPath,
            destinationPath: normDest,
            revision: revision,
            workingDirectory: repoPath
        )
    }

    public func listDirectory(repoPath: String, path: String, revision: String) async throws -> [VcsTreeEntry] {
        let wcInfo = try await info(target: repoPath, workingDirectory: repoPath)
        let cleanRel = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let baseURL = wcInfo.url.hasSuffix("/") ? String(wcInfo.url.dropLast()) : wcInfo.url
        let targetURL = cleanRel.isEmpty ? baseURL : "\(baseURL)/\(cleanRel)"
        let cleanRev = revision.trimmingCharacters(in: .whitespacesAndNewlines)
        let revOpt = (cleanRev.isEmpty || cleanRev.uppercased() == "WORKING") ? nil : cleanRevision(cleanRev)

        return try await listURL(
            targetURL,
            revision: revOpt,
            baseRelativePath: cleanRel
        )
    }

    public func extractFile(repoPath: String, path: String, revision: String, to destinationPath: String) async throws {
        try await extractFile(
            repoPath: repoPath,
            path: path,
            revision: revision,
            to: destinationPath,
            environment: nil,
            auth: SvnAuthOverrides()
        )
    }

    public func extractFile(
        repoPath: String,
        path: String,
        revision: String,
        to destinationPath: String,
        environment: [String: String]? = nil,
        auth: SvnAuthOverrides = SvnAuthOverrides()
    ) async throws {
        let target = normalizePathOrURL(path, repoPath: repoPath)
        let rev = cleanRevision(revision)
        var args = ["cat"]
        if !rev.isEmpty && rev.uppercased() != "WORKING" {
            args.append(contentsOf: ["-r", rev])
        }
        args.append(target)

        try await runSvnRawOutput(
            arguments: args,
            workingDirectory: path.contains("://") ? nil : repoPath,
            environment: environment,
            auth: auth,
            outputFileURL: URL(fileURLWithPath: PathUtils.normalize(destinationPath))
        )
    }

    public func diffRevisions(repoPath: String, rev1: String, rev2: String) async throws -> [VcsChangedPath] {
        let r1 = cleanRevision(rev1)
        let r2 = cleanRevision(rev2)
        let baseURL = (try? await info(target: repoPath, workingDirectory: repoPath))?.url
        let range = (r1.isEmpty || r1 == r2) ? "-c" : "-r"
        let argVal = (r1.isEmpty || r1 == r2) ? r2 : "\(r1):\(r2)"

        let res = try await runSvn(
            arguments: ["diff", "--summarize", "--xml", range, argVal],
            workingDirectory: repoPath,
            isNetworkOperation: true
        )
        return try SvnXmlParsers.parseDiffSummarizeXml(Data(res.stdout.utf8), baseURL: baseURL)
    }

    // MARK: - SVN Extended Feature Methods

    public func info(
        target: String = ".",
        workingDirectory: String? = nil,
        revision: String? = nil,
        environment: [String: String]? = nil,
        auth: SvnAuthOverrides = SvnAuthOverrides()
    ) async throws -> SvnInfoResult {
        let isRemote = target.contains("://")
        var args = ["info", "--xml"]
        if let revision, !revision.isEmpty {
            args.append(contentsOf: ["-r", cleanRevision(revision)])
        }
        if let workingDirectory, !isRemote {
            args.append(normalizePathOrURL(target, repoPath: workingDirectory))
        } else {
            args.append(escapePegPath(target))
        }

        let res = try await runSvn(
            arguments: args,
            workingDirectory: workingDirectory,
            environment: environment,
            auth: auth,
            isNetworkOperation: isRemote
        )
        let parsed = try SvnXmlParsers.parseInfoXml(Data(res.stdout.utf8))
        guard let first = parsed.first else {
            throw VcsError.parseError("No <entry> returned by svn info --xml")
        }
        return first
    }

    public func detailedStatus(
        repoPath: String,
        paths: [String] = [],
        checkRemote: Bool = false,
        includeIgnored: Bool = true,
        includeUntracked: Bool = true,
        environment: [String: String]? = nil,
        auth: SvnAuthOverrides = SvnAuthOverrides()
    ) async throws -> SvnDetailedStatusResult {
        var args = ["status", "--xml"]
        if checkRemote {
            args.append("-u")
        }
        if includeIgnored {
            args.append("--no-ignore")
        }
        if !paths.isEmpty {
            args.append(contentsOf: resolveTargetArgs(paths, repoPath: repoPath))
        }

        let res = try await runSvn(
            arguments: args,
            workingDirectory: repoPath,
            environment: environment,
            auth: auth,
            isNetworkOperation: checkRemote
        )
        var parsed = try SvnXmlParsers.parseStatusXml(Data(res.stdout.utf8), repoPath: repoPath)
        if !includeUntracked {
            parsed.items.removeAll { $0.item.status == .untracked }
        }
        return parsed
    }

    public func svnCommit(
        repoPath: String,
        paths: [String] = [],
        message: String,
        changelist: String? = nil,
        keepLocks: Bool = false,
        keepChangelists: Bool = false,
        autoAddPaths: [String] = [],
        autoDeletePaths: [String] = [],
        environment: [String: String]? = nil,
        auth: SvnAuthOverrides = SvnAuthOverrides(),
        onOutputLine: (@Sendable (String, Bool) -> Void)? = nil
    ) async throws -> VcsCommandResult {
        if !autoAddPaths.isEmpty {
            _ = try await add(repoPath: repoPath, paths: autoAddPaths, onOutputLine: onOutputLine)
        }
        if !autoDeletePaths.isEmpty {
            _ = try await remove(
                repoPath: repoPath,
                paths: autoDeletePaths,
                keepLocal: false,
                force: true,
                onOutputLine: onOutputLine
            )
        }

        // Write commit message via temp UTF-8 file (`-F`) so newlines/quotes/Unicode never break.
        let msgURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("reposhell-svn-msg-\(UUID().uuidString).txt")
        try message.write(to: msgURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: msgURL) }

        var args = ["commit", "-F", msgURL.path, "--encoding", "UTF-8"]
        if keepLocks { args.append("--no-unlock") }
        if keepChangelists { args.append("--keep-changelists") }
        if let changelist, !changelist.isEmpty {
            args.append(contentsOf: ["--changelist", changelist])
        }
        if !paths.isEmpty {
            let resolvedCommit = resolveTargetArgs(paths, repoPath: repoPath)
            let resolvedAutoAdd = resolveTargetArgs(autoAddPaths, repoPath: repoPath)
            var merged: [String] = []
            var seen = Set<String>()
            for item in resolvedAutoAdd + resolvedCommit where seen.insert(item).inserted {
                merged.append(item)
            }
            args.append(contentsOf: merged)
        }

        return try await runSvn(
            arguments: args,
            workingDirectory: repoPath,
            environment: environment,
            auth: auth,
            isNetworkOperation: true,
            onOutputLine: onOutputLine
        )
    }

    public func svnLog(
        target: String = ".",
        repoPath: String? = nil,
        revisionRange: String? = nil,
        limit: Int = 100,
        searchQuery: String? = nil,
        stopOnCopy: Bool = false,
        useMergeHistory: Bool = false,
        environment: [String: String]? = nil,
        auth: SvnAuthOverrides = SvnAuthOverrides()
    ) async throws -> [VcsCommit] {
        var args = ["log", "--xml", "-v"]
        if limit > 0 {
            args.append(contentsOf: ["-l", String(limit)])
        }
        if let revisionRange, !revisionRange.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args.append(contentsOf: ["-r", cleanRevision(revisionRange)])
        } else {
            args.append(contentsOf: ["-r", "HEAD:0"])
        }
        if stopOnCopy {
            args.append("--stop-on-copy")
        }
        if useMergeHistory {
            args.append("-g")
        }
        if let searchQuery, !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args.append(contentsOf: ["--search", searchQuery])
        }

        if let repoPath, !target.contains("://") {
            args.append(normalizePathOrURL(target, repoPath: repoPath))
        } else {
            args.append(escapePegPath(target))
        }

        let res = try await runSvn(
            arguments: args,
            workingDirectory: target.contains("://") ? nil : repoPath,
            environment: environment,
            auth: auth,
            isNetworkOperation: true
        )
        return try SvnXmlParsers.parseLogXml(Data(res.stdout.utf8))
    }

    public func checkout(
        options: SvnCheckoutOptions,
        environment: [String: String]? = nil,
        auth: SvnAuthOverrides = SvnAuthOverrides(),
        onOutputLine: (@Sendable (String, Bool) -> Void)? = nil
    ) async throws -> VcsCommandResult {
        var args = ["checkout", options.url, PathUtils.normalize(options.destinationPath)]
        if let rev = options.revision, !rev.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args.append(contentsOf: ["-r", cleanRevision(rev)])
        }
        args.append(contentsOf: ["--depth", options.depth.rawValue])
        if options.ignoreExternals { args.append("--ignore-externals") }
        if options.force { args.append("--force") }

        return try await runSvn(
            arguments: args,
            environment: environment,
            auth: auth,
            isNetworkOperation: true,
            onOutputLine: onOutputLine
        )
    }

    public func createRepository(
        at path: String,
        fsType: String = "fsfs"
    ) async throws -> VcsCommandResult {
        let resolved = try resolvedExecutable()
        guard let svnadminURL = resolved.svnadminURL else {
            throw VcsError.executableNotFound("svnadmin binary not found near \(resolved.executableURL.path)")
        }

        let norm = PathUtils.normalize(path)
        try FileManager.default.createDirectory(
            atPath: norm,
            withIntermediateDirectories: true
        )

        let args = ["create", "--fs-type", fsType, norm]
        let out = try await ProcessRunner.run(
            executableURL: svnadminURL,
            arguments: args,
            environment: resolved.extraEnvironment
        )
        let cmd = "svnadmin " + args.joined(separator: " ")
        guard out.exitCode == 0 else {
            throw VcsError.commandFailed(command: cmd, exitCode: out.exitCode, stderr: out.stderrString, stdout: out.stdoutString)
        }
        return VcsCommandResult(command: cmd, exitCode: out.exitCode, stdout: out.stdoutString, stderr: out.stderrString)
    }

    public func update(
        repoPath: String,
        options: SvnUpdateOptions = SvnUpdateOptions(),
        environment: [String: String]? = nil,
        auth: SvnAuthOverrides = SvnAuthOverrides(),
        onOutputLine: (@Sendable (String, Bool) -> Void)? = nil
    ) async throws -> VcsCommandResult {
        var args = ["update"]
        if let rev = options.revision, !rev.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args.append(contentsOf: ["-r", cleanRevision(rev)])
        }
        if let depth = options.depth {
            if options.setDepthSticky {
                args.append(contentsOf: ["--set-depth", depth.rawValue])
            } else {
                args.append(contentsOf: ["--depth", depth.rawValue])
            }
        }
        if options.ignoreExternals { args.append("--ignore-externals") }
        if options.force { args.append("--force") }
        args.append(contentsOf: ["--accept", options.accept.rawValue])
        if !options.paths.isEmpty {
            args.append(contentsOf: resolveTargetArgs(options.paths, repoPath: repoPath))
        }

        return try await runSvn(
            arguments: args,
            workingDirectory: repoPath,
            environment: environment,
            auth: auth,
            isNetworkOperation: true,
            onOutputLine: onOutputLine
        )
    }

    public func move(
        repoPath: String,
        sourcePath: String,
        destinationPath: String,
        force: Bool = false,
        onOutputLine: (@Sendable (String, Bool) -> Void)? = nil
    ) async throws -> VcsCommandResult {
        var args = ["move", "--parents"]
        if force { args.append("--force") }
        args.append(normalizePathOrURL(sourcePath, repoPath: repoPath))
        args.append(normalizePathOrURL(destinationPath, repoPath: repoPath))
        return try await runSvn(arguments: args, workingDirectory: repoPath, onOutputLine: onOutputLine)
    }

    public func resolveConflict(
        repoPath: String,
        paths: [String],
        accept: SvnConflictAccept,
        recursive: Bool = false,
        onOutputLine: (@Sendable (String, Bool) -> Void)? = nil
    ) async throws -> VcsCommandResult {
        var args = ["resolve", "--accept", accept.rawValue]
        if recursive { args.append("-R") }
        args.append(contentsOf: resolveTargetArgs(paths, repoPath: repoPath))
        return try await runSvn(arguments: args, workingDirectory: repoPath, onOutputLine: onOutputLine)
    }

    public func cleanup(
        repoPath: String,
        options: SvnCleanupOptions = SvnCleanupOptions(),
        onOutputLine: (@Sendable (String, Bool) -> Void)? = nil
    ) async throws -> VcsCommandResult {
        var args = ["cleanup"]
        if options.removeUnversioned { args.append("--remove-unversioned") }
        if options.removeIgnored { args.append("--remove-ignored") }
        if options.vacuumPristines { args.append("--vacuum-pristines") }
        if options.includeExternals { args.append("--include-externals") }
        if !options.paths.isEmpty {
            args.append(contentsOf: resolveTargetArgs(options.paths, repoPath: repoPath))
        }
        return try await runSvn(arguments: args, workingDirectory: repoPath, onOutputLine: onOutputLine)
    }

    public func upgradeWorkingCopy(
        repoPath: String,
        onOutputLine: (@Sendable (String, Bool) -> Void)? = nil
    ) async throws -> VcsCommandResult {
        try await runSvn(arguments: ["upgrade"], workingDirectory: repoPath, onOutputLine: onOutputLine)
    }

    public func branchOrTag(
        repoPath: String?,
        source: String,
        destinationURL: String,
        revision: String? = nil,
        message: String,
        makeParents: Bool = true,
        environment: [String: String]? = nil,
        auth: SvnAuthOverrides = SvnAuthOverrides(),
        onOutputLine: (@Sendable (String, Bool) -> Void)? = nil
    ) async throws -> VcsCommandResult {
        let msgURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("reposhell-svn-copy-msg-\(UUID().uuidString).txt")
        try message.write(to: msgURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: msgURL) }

        var args = ["copy", "-F", msgURL.path, "--encoding", "UTF-8"]
        if makeParents { args.append("--parents") }
        if let revision, !revision.isEmpty {
            args.append(contentsOf: ["-r", cleanRevision(revision)])
        }
        if let repoPath, !source.contains("://") {
            args.append(normalizePathOrURL(source, repoPath: repoPath))
        } else {
            args.append(escapePegPath(source))
        }
        args.append(destinationURL)

        return try await runSvn(
            arguments: args,
            workingDirectory: repoPath,
            environment: environment,
            auth: auth,
            isNetworkOperation: true,
            onOutputLine: onOutputLine
        )
    }

    public func switchBranch(
        repoPath: String,
        targetPath: String = ".",
        url: String,
        revision: String? = nil,
        depth: SvnDepth? = nil,
        ignoreAncestry: Bool = false,
        ignoreExternals: Bool = false,
        force: Bool = false,
        accept: SvnConflictAccept = .postpone,
        environment: [String: String]? = nil,
        auth: SvnAuthOverrides = SvnAuthOverrides(),
        onOutputLine: (@Sendable (String, Bool) -> Void)? = nil
    ) async throws -> VcsCommandResult {
        var args = ["switch", url, normalizePathOrURL(targetPath, repoPath: repoPath)]
        if let revision, !revision.isEmpty {
            args.append(contentsOf: ["-r", cleanRevision(revision)])
        }
        if let depth {
            args.append(contentsOf: ["--depth", depth.rawValue])
        }
        if ignoreAncestry { args.append("--ignore-ancestry") }
        if ignoreExternals { args.append("--ignore-externals") }
        if force { args.append("--force") }
        args.append(contentsOf: ["--accept", accept.rawValue])

        return try await runSvn(
            arguments: args,
            workingDirectory: repoPath,
            environment: environment,
            auth: auth,
            isNetworkOperation: true,
            onOutputLine: onOutputLine
        )
    }

    public func merge(
        repoPath: String,
        targetPath: String = ".",
        options: SvnMergeOptions,
        environment: [String: String]? = nil,
        auth: SvnAuthOverrides = SvnAuthOverrides(),
        onOutputLine: (@Sendable (String, Bool) -> Void)? = nil
    ) async throws -> VcsCommandResult {
        var args = ["merge"]
        if options.dryRun { args.append("--dry-run") }
        if options.recordOnly { args.append("--record-only") }
        if options.ignoreAncestry { args.append("--ignore-ancestry") }
        if options.force { args.append("--force") }
        if let depth = options.depth { args.append(contentsOf: ["--depth", depth.rawValue]) }
        if options.ignoreWhitespace { args.append(contentsOf: ["-x", "-w"]) }
        if !options.dryRun {
            args.append(contentsOf: ["--accept", options.accept.rawValue])
        }

        switch options.mode {
        case .range:
            if options.reintegrate {
                // Reintegrate merges the specified branch URL automatically
                args.append(options.sourceURL1)
            } else {
                let rawRange = options.revisionRange.trimmingCharacters(in: .whitespacesAndNewlines)
                if !rawRange.isEmpty {
                    for part in rawRange.split(separator: ",").map({ String($0).trimmingCharacters(in: .whitespaces) }) where !part.isEmpty {
                        if part.contains(":") {
                            let bounds = part.split(separator: ":", maxSplits: 1).map { cleanRevision(String($0)) }
                            if bounds.count == 2 {
                                let formatted = options.reverseMerge ? "\(bounds[1]):\(bounds[0])" : "\(bounds[0]):\(bounds[1])"
                                args.append(contentsOf: ["-r", formatted])
                            }
                        } else {
                            let clean = cleanRevision(part)
                            args.append(contentsOf: ["-c", options.reverseMerge ? "-\(clean)" : clean])
                        }
                    }
                }
                args.append(options.sourceURL1)
            }
        case .twoTrees:
            let r1 = cleanRevision(options.revision1 ?? "HEAD")
            let r2 = cleanRevision(options.revision2 ?? "HEAD")
            let src2 = (options.sourceURL2?.isEmpty == false) ? options.sourceURL2! : options.sourceURL1
            args.append("\(options.sourceURL1)@\(r1.isEmpty ? "HEAD" : r1)")
            args.append("\(src2)@\(r2.isEmpty ? "HEAD" : r2)")
        }

        args.append(normalizePathOrURL(targetPath, repoPath: repoPath))

        return try await runSvn(
            arguments: args,
            workingDirectory: repoPath,
            environment: environment,
            auth: auth,
            isNetworkOperation: true,
            onOutputLine: onOutputLine
        )
    }

    public func lock(
        repoPath: String,
        paths: [String],
        message: String = "",
        force: Bool = false,
        environment: [String: String]? = nil,
        auth: SvnAuthOverrides = SvnAuthOverrides(),
        onOutputLine: (@Sendable (String, Bool) -> Void)? = nil
    ) async throws -> VcsCommandResult {
        var args = ["lock", "-m", message]
        if force { args.append("--force") }
        args.append(contentsOf: resolveTargetArgs(paths, repoPath: repoPath))

        return try await runSvn(
            arguments: args,
            workingDirectory: repoPath,
            environment: environment,
            auth: auth,
            isNetworkOperation: true,
            onOutputLine: onOutputLine
        )
    }

    public func unlock(
        repoPath: String,
        paths: [String],
        force: Bool = false,
        environment: [String: String]? = nil,
        auth: SvnAuthOverrides = SvnAuthOverrides(),
        onOutputLine: (@Sendable (String, Bool) -> Void)? = nil
    ) async throws -> VcsCommandResult {
        var args = ["unlock"]
        if force { args.append("--force") }
        args.append(contentsOf: resolveTargetArgs(paths, repoPath: repoPath))

        return try await runSvn(
            arguments: args,
            workingDirectory: repoPath,
            environment: environment,
            auth: auth,
            isNetworkOperation: true,
            onOutputLine: onOutputLine
        )
    }

    public func listProperties(
        repoPath: String?,
        target: String,
        revision: String? = nil,
        environment: [String: String]? = nil,
        auth: SvnAuthOverrides = SvnAuthOverrides()
    ) async throws -> [SvnPropertyEntry] {
        let isRemote = target.contains("://")
        var args = ["proplist", "--xml", "-v"]
        if let revision, !revision.isEmpty {
            args.append(contentsOf: ["-r", cleanRevision(revision)])
        }
        if let repoPath, !isRemote {
            args.append(normalizePathOrURL(target, repoPath: repoPath))
        } else {
            args.append(escapePegPath(target))
        }

        let res = try await runSvn(
            arguments: args,
            workingDirectory: isRemote ? nil : repoPath,
            environment: environment,
            auth: auth,
            isNetworkOperation: isRemote
        )
        return try SvnXmlParsers.parsePropertiesXml(Data(res.stdout.utf8))
    }

    public func setProperty(
        repoPath: String,
        target: String,
        name: String,
        value: String,
        recursive: Bool = false
    ) async throws -> VcsCommandResult {
        let valURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("reposhell-svn-prop-\(UUID().uuidString).txt")
        try value.write(to: valURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: valURL) }

        var args = ["propset", name, "-F", valURL.path]
        if recursive { args.append("-R") }
        args.append(normalizePathOrURL(target, repoPath: repoPath))
        return try await runSvn(arguments: args, workingDirectory: repoPath)
    }

    public func deleteProperty(
        repoPath: String,
        target: String,
        name: String,
        recursive: Bool = false
    ) async throws -> VcsCommandResult {
        var args = ["propdel", name]
        if recursive { args.append("-R") }
        args.append(normalizePathOrURL(target, repoPath: repoPath))
        return try await runSvn(arguments: args, workingDirectory: repoPath)
    }

    public func appendIgnorePatterns(
        repoPath: String,
        directoryPath: String,
        patterns: [String]
    ) async throws {
        let existingProps = (try? await listProperties(repoPath: repoPath, target: directoryPath)) ?? []
        let currentRaw = existingProps.first(where: { $0.name == "svn:ignore" })?.value ?? ""
        var lines = currentRaw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        for p in patterns {
            let trimmed = p.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !lines.contains(trimmed) {
                lines.append(trimmed)
            }
        }
        let updated = lines.joined(separator: "\n") + "\n"
        _ = try await setProperty(
            repoPath: repoPath,
            target: directoryPath,
            name: "svn:ignore",
            value: updated,
            recursive: false
        )
    }

    public func relocate(
        repoPath: String,
        fromURL: String? = nil,
        toURL: String,
        environment: [String: String]? = nil,
        auth: SvnAuthOverrides = SvnAuthOverrides(),
        onOutputLine: (@Sendable (String, Bool) -> Void)? = nil
    ) async throws -> VcsCommandResult {
        var args = ["relocate"]
        if let fromURL, !fromURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args.append(fromURL.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        args.append(toURL.trimmingCharacters(in: .whitespacesAndNewlines))
        return try await runSvn(
            arguments: args,
            workingDirectory: repoPath,
            environment: environment,
            auth: auth,
            isNetworkOperation: true,
            onOutputLine: onOutputLine
        )
    }

    public func importDirectory(
        localPath: String,
        remoteURL: String,
        message: String,
        noIgnore: Bool = false,
        noAutoProps: Bool = false,
        environment: [String: String]? = nil,
        auth: SvnAuthOverrides = SvnAuthOverrides(),
        onOutputLine: (@Sendable (String, Bool) -> Void)? = nil
    ) async throws -> VcsCommandResult {
        let msgURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("reposhell-svn-import-msg-\(UUID().uuidString).txt")
        try message.write(to: msgURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: msgURL) }

        var args = ["import", PathUtils.normalize(localPath), remoteURL, "-F", msgURL.path, "--encoding", "UTF-8"]
        if noIgnore { args.append("--no-ignore") }
        if noAutoProps { args.append("--no-auto-props") }

        return try await runSvn(
            arguments: args,
            environment: environment,
            auth: auth,
            isNetworkOperation: true,
            onOutputLine: onOutputLine
        )
    }

    public func editRevisionLog(
        repoPath: String,
        revision: String,
        newMessage: String,
        environment: [String: String]? = nil,
        auth: SvnAuthOverrides = SvnAuthOverrides()
    ) async throws -> VcsCommandResult {
        let msgURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("reposhell-svn-revlog-\(UUID().uuidString).txt")
        try newMessage.write(to: msgURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: msgURL) }

        return try await runSvn(
            arguments: ["propset", "--revprop", "-r", cleanRevision(revision), "svn:log", "-F", msgURL.path],
            workingDirectory: repoPath,
            environment: environment,
            auth: auth,
            isNetworkOperation: true
        )
    }

    public func revertRevisionChanges(
        repoPath: String,
        revisions: [String],
        environment: [String: String]? = nil,
        auth: SvnAuthOverrides = SvnAuthOverrides(),
        onOutputLine: (@Sendable (String, Bool) -> Void)? = nil
    ) async throws -> VcsCommandResult {
        var args = ["merge"]
        for rev in revisions {
            let clean = cleanRevision(rev)
            if !clean.isEmpty {
                args.append(contentsOf: ["-c", "-\(clean)"])
            }
        }
        args.append(".")
        return try await runSvn(
            arguments: args,
            workingDirectory: repoPath,
            environment: environment,
            auth: auth,
            isNetworkOperation: true,
            onOutputLine: onOutputLine
        )
    }

    public func svnBlame(
        repoPath: String?,
        target: String,
        revision: String? = nil,
        revisionRange: String? = nil,
        ignoreWhitespace: Bool = false,
        environment: [String: String]? = nil,
        auth: SvnAuthOverrides = SvnAuthOverrides()
    ) async throws -> [VcsBlameLine] {
        let isRemote = target.contains("://")
        let normalizedTarget = (!isRemote && repoPath != nil)
            ? normalizePathOrURL(target, repoPath: repoPath!)
            : escapePegPath(target)

        var blameArgs = ["blame", "--xml"]
        var catArgs = ["cat"]
        if let range = revisionRange, !range.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blameArgs.append(contentsOf: ["-r", cleanRevision(range)])
            let endRev = range.components(separatedBy: ":").last.map { cleanRevision($0) } ?? ""
            if !endRev.isEmpty && endRev.uppercased() != "WORKING" {
                catArgs.append(contentsOf: ["-r", endRev])
            }
        } else if let revision, !revision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let rev = cleanRevision(revision)
            if rev.uppercased() != "WORKING" {
                blameArgs.append(contentsOf: ["-r", rev])
                catArgs.append(contentsOf: ["-r", rev])
            }
        }
        if ignoreWhitespace {
            blameArgs.append(contentsOf: ["-x", "-w"])
        }
        blameArgs.append(normalizedTarget)
        catArgs.append(normalizedTarget)

        let blameRes = try await runSvn(
            arguments: blameArgs,
            workingDirectory: isRemote ? nil : repoPath,
            environment: environment,
            auth: auth,
            isNetworkOperation: true
        )

        let rawContent: String
        if !isRemote, revision == nil && (revisionRange?.isEmpty ?? true) {
            let absTarget = target.hasPrefix("/") ? PathUtils.normalize(target) : PathUtils.normalize("\(repoPath ?? "")/\(target)")
            rawContent = (try? String(contentsOfFile: absTarget, encoding: .utf8)) ?? ""
        } else {
            let catRes = try await runSvn(
                arguments: catArgs,
                workingDirectory: isRemote ? nil : repoPath,
                environment: environment,
                auth: auth,
                isNetworkOperation: true
            )
            rawContent = catRes.stdout
        }

        let lines = rawContent.components(separatedBy: .newlines)
        return try SvnXmlParsers.parseBlameXml(Data(blameRes.stdout.utf8), contentLines: lines)
    }

    public func listURL(
        _ url: String,
        revision: String? = nil,
        baseRelativePath: String = "",
        environment: [String: String]? = nil,
        auth: SvnAuthOverrides = SvnAuthOverrides()
    ) async throws -> [VcsTreeEntry] {
        var args = ["list", "--xml"]
        if let revision, !revision.isEmpty {
            args.append(contentsOf: ["-r", cleanRevision(revision)])
        }
        args.append(escapePegPath(url))

        let res = try await runSvn(
            arguments: args,
            environment: environment,
            auth: auth,
            isNetworkOperation: true
        )
        return try SvnXmlParsers.parseListXml(Data(res.stdout.utf8), baseRelativePath: baseRelativePath)
    }

    public func remoteMakeDirectory(
        url: String,
        message: String,
        makeParents: Bool = true,
        environment: [String: String]? = nil,
        auth: SvnAuthOverrides = SvnAuthOverrides()
    ) async throws -> VcsCommandResult {
        var args = ["mkdir", "-m", message]
        if makeParents { args.append("--parents") }
        args.append(url)
        return try await runSvn(arguments: args, environment: environment, auth: auth, isNetworkOperation: true)
    }

    public func remoteCopyOrMove(
        sourceURL: String,
        destinationURL: String,
        isMove: Bool,
        message: String,
        makeParents: Bool = true,
        environment: [String: String]? = nil,
        auth: SvnAuthOverrides = SvnAuthOverrides()
    ) async throws -> VcsCommandResult {
        var args = [isMove ? "move" : "copy", "-m", message]
        if makeParents { args.append("--parents") }
        args.append(escapePegPath(sourceURL))
        args.append(destinationURL)
        return try await runSvn(arguments: args, environment: environment, auth: auth, isNetworkOperation: true)
    }

    public func remoteDelete(
        urls: [String],
        message: String,
        environment: [String: String]? = nil,
        auth: SvnAuthOverrides = SvnAuthOverrides()
    ) async throws -> VcsCommandResult {
        var args = ["delete", "-m", message]
        args.append(contentsOf: urls.map { escapePegPath($0) })
        return try await runSvn(arguments: args, environment: environment, auth: auth, isNetworkOperation: true)
    }

    public func svnExport(
        source: String,
        destinationPath: String,
        revision: String? = nil,
        depth: SvnDepth = .infinity,
        ignoreExternals: Bool = false,
        force: Bool = true,
        workingDirectory: String? = nil,
        environment: [String: String]? = nil,
        auth: SvnAuthOverrides = SvnAuthOverrides(),
        onOutputLine: (@Sendable (String, Bool) -> Void)? = nil
    ) async throws -> VcsCommandResult {
        let isRemote = source.contains("://")
        var args = ["export", "--depth", depth.rawValue]
        if force { args.append("--force") }
        if ignoreExternals { args.append("--ignore-externals") }
        if let revision, !revision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let clean = cleanRevision(revision)
            if clean.uppercased() != "WORKING" {
                args.append(contentsOf: ["-r", clean])
            }
        }
        args.append(escapePegPath(source))
        args.append(PathUtils.normalize(destinationPath))

        return try await runSvn(
            arguments: args,
            workingDirectory: isRemote ? nil : workingDirectory,
            environment: environment,
            auth: auth,
            isNetworkOperation: isRemote || (revision != nil && revision?.uppercased() != "WORKING"),
            onOutputLine: onOutputLine
        )
    }

    public func diffText(
        repoPath: String,
        paths: [String] = [],
        revision1: String? = nil,
        revision2: String? = nil,
        environment: [String: String]? = nil,
        auth: SvnAuthOverrides = SvnAuthOverrides()
    ) async throws -> String {
        var args = ["diff", "--internal-diff"]
        let r1 = revision1.map { cleanRevision($0) } ?? ""
        let r2 = revision2.map { cleanRevision($0) } ?? ""
        if !r1.isEmpty && !r2.isEmpty {
            args.append(contentsOf: ["-r", "\(r1):\(r2)"])
        } else if !r1.isEmpty {
            args.append(contentsOf: ["-r", r1])
        }
        if !paths.isEmpty {
            args.append(contentsOf: resolveTargetArgs(paths, repoPath: repoPath))
        }
        let isNet = !r1.isEmpty
        let res = try await runSvn(
            arguments: args,
            workingDirectory: repoPath,
            environment: environment,
            auth: auth,
            isNetworkOperation: isNet
        )
        return res.stdout
    }

    public func createPatch(
        repoPath: String,
        paths: [String] = [],
        destinationFile: String,
        revisionRange: String? = nil
    ) async throws -> VcsCommandResult {
        var args = ["diff", "--internal-diff"]
        if let revRange = revisionRange, !revRange.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args.append(contentsOf: ["-r", cleanRevision(revRange)])
        }
        if !paths.isEmpty {
            args.append(contentsOf: resolveTargetArgs(paths, repoPath: repoPath))
        }
        let dest = PathUtils.normalize(destinationFile)
        try await runSvnRawOutput(
            arguments: args,
            workingDirectory: repoPath,
            outputFileURL: URL(fileURLWithPath: dest)
        )
        return VcsCommandResult(
            command: "svn \(args.joined(separator: " ")) > \(dest)",
            exitCode: 0,
            stdout: dest,
            stderr: ""
        )
    }

    public func applyPatch(
        repoPath: String,
        patchFile: String,
        stripCount: Int = 0,
        reverseDiff: Bool = false,
        dryRun: Bool = false,
        ignoreWhitespace: Bool = false,
        onOutputLine: (@Sendable (String, Bool) -> Void)? = nil
    ) async throws -> VcsCommandResult {
        var args = ["patch", PathUtils.normalize(patchFile), "."]
        if stripCount > 0 { args.append(contentsOf: ["--strip", String(stripCount)]) }
        if reverseDiff { args.append("--reverse-diff") }
        if dryRun { args.append("--dry-run") }
        if ignoreWhitespace { args.append("--ignore-whitespace") }
        return try await runSvn(arguments: args, workingDirectory: repoPath, onOutputLine: onOutputLine)
    }

    public func previousRevision(of filePath: String, repoPath: String) async throws -> String? {
        let wcInfo = try? await info(target: filePath, workingDirectory: repoPath)
        let baseRev = Int(wcInfo?.lastChangedRev ?? "") ?? Int(wcInfo?.revision ?? "")
        if let baseRev, baseRev > 1 {
            return String(baseRev - 1)
        }
        let commits = try? await svnLog(target: filePath, repoPath: repoPath, limit: 2)
        if let commits, commits.count >= 2 {
            return commits[1].hash
        }
        return nil
    }

    // MARK: - ~/.subversion/config & Global Ignores

    public static func subversionConfigDirectoryURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".subversion", isDirectory: true)
    }

    public static func subversionConfigFileURL() -> URL {
        subversionConfigDirectoryURL().appendingPathComponent("config", isDirectory: false)
    }

    public func ensureSubversionConfigExists() {
        let dir = Self.subversionConfigDirectoryURL()
        let file = Self.subversionConfigFileURL()
        let fm = FileManager.default
        if !fm.fileExists(atPath: file.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let defaultContent = """
            [auth]
            password-stores = keychain

            [helpers]

            [tunnels]

            [miscellany]
            global-ignores = *.o *.lo *.la *.al .libs *.so *.so.[0-9]* *.a *.pyc *.pyo __pycache__ *.rej *~ #*# .#* .*.swp .DS_Store [Tt]humbs.db

            [auto-props]
            """
            try? defaultContent.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    public func readRawSubversionConfig() -> String {
        ensureSubversionConfigExists()
        return (try? String(contentsOf: Self.subversionConfigFileURL(), encoding: .utf8)) ?? ""
    }

    public func writeRawSubversionConfig(_ content: String) throws {
        ensureSubversionConfigExists()
        try content.write(to: Self.subversionConfigFileURL(), atomically: true, encoding: .utf8)
    }

    public func readGlobalIgnores() -> [String] {
        let raw = readRawSubversionConfig()
        var inMiscellany = false
        for line in raw.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                inMiscellany = trimmed.lowercased() == "[miscellany]"
                continue
            }
            if !inMiscellany || trimmed.hasPrefix("#") || trimmed.isEmpty {
                continue
            }
            if let eqIdx = trimmed.firstIndex(of: "=") {
                let key = trimmed[..<eqIdx].trimmingCharacters(in: .whitespaces).lowercased()
                if key == "global-ignores" {
                    let val = trimmed[trimmed.index(after: eqIdx)...].trimmingCharacters(in: .whitespaces)
                    return val.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                }
            }
        }
        return []
    }

    public func writeGlobalIgnores(_ patterns: [String]) throws {
        ensureSubversionConfigExists()
        let cleaned = patterns
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let newLine = "global-ignores = \(cleaned.joined(separator: " "))"

        let raw = readRawSubversionConfig()
        var lines = raw.components(separatedBy: .newlines)
        var inMiscellany = false
        var miscellanyStartIdx: Int?
        var replaced = false

        for i in lines.indices {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                if inMiscellany && !replaced {
                    lines.insert(newLine, at: i)
                    replaced = true
                    break
                }
                inMiscellany = trimmed.lowercased() == "[miscellany]"
                if inMiscellany { miscellanyStartIdx = i }
                continue
            }
            if inMiscellany {
                let noComment = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces) : trimmed
                if noComment.lowercased().hasPrefix("global-ignores") && noComment.contains("=") {
                    lines[i] = newLine
                    replaced = true
                    break
                }
            }
        }

        if !replaced {
            if let start = miscellanyStartIdx {
                lines.insert(newLine, at: start + 1)
            } else {
                lines.append("")
                lines.append("[miscellany]")
                lines.append(newLine)
            }
        }

        try writeRawSubversionConfig(lines.joined(separator: "\n"))
    }
}
