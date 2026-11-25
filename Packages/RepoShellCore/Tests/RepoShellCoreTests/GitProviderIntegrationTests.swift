import XCTest
@testable import RepoShellShared
@testable import RepoShellVcs

final class GitProviderIntegrationTests: XCTestCase {

    private var tempRoot: URL!
    private var provider: GitProvider!

    override func setUp() async throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("reposhell-git-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let prefs = AppPreferences(useBundledGit: false, externalGitPath: "/usr/bin/git")
        provider = GitProvider(preferencesProvider: { prefs })
    }

    override func tearDown() async throws {
        if let tempRoot = tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    private func configureUser(at repoPath: String) async throws {
        _ = try await provider.runGit(repoPath: repoPath, arguments: ["config", "user.name", "RepoShell Tester"])
        _ = try await provider.runGit(repoPath: repoPath, arguments: ["config", "user.email", "tester@reposhell.local"])
    }

    func testFullBasicAndAdvancedGitWorkflow() async throws {
        let remoteURL = tempRoot.appendingPathComponent("remote.git", isDirectory: true)
        let repoA = tempRoot.appendingPathComponent("repoA", isDirectory: true)
        let repoB = tempRoot.appendingPathComponent("repoB", isDirectory: true)

        // 1. Init bare remote & repoA
        _ = try await provider.initRepository(at: remoteURL.path, bare: true)
        _ = try await provider.initRepository(at: repoA.path, bare: false)
        try await configureUser(at: repoA.path)
        _ = try await provider.runGit(repoPath: repoA.path, arguments: ["checkout", "-b", "main"])
        _ = try await provider.addRemote(repoPath: repoA.path, name: "origin", url: remoteURL.path)

        // 2. Create files (including Chinese & space filename) and commit
        let file1 = repoA.appendingPathComponent("hello.txt")
        let fileCN = repoA.appendingPathComponent("中文 文件.txt")
        try "line 1\nline 2\n".write(to: file1, atomically: true, encoding: .utf8)
        try "你好世界\n".write(to: fileCN, atomically: true, encoding: .utf8)

        let status1 = try await provider.status(repoPath: repoA.path)
        XCTAssertTrue(status1.items.contains(where: { $0.relativePath == "中文 文件.txt" && $0.status == .untracked }))

        _ = try await provider.commit(
            repoPath: repoA.path,
            options: VcsCommitOptions(message: "Initial commit", paths: [file1.path, fileCN.path])
        )

        // 3. Push to bare remote & clone repoB
        _ = try await provider.push(
            repoPath: repoA.path,
            options: GitPushOptions(
                remote: "origin",
                branchMappings: [GitPushBranchMapping(localBranch: "main", remoteBranch: "main")],
                setUpstream: true
            )
        )
        _ = try await provider.clone(options: GitCloneOptions(url: remoteURL.path, destinationPath: repoB.path))
        try await configureUser(at: repoB.path)

        // 4. Amend, notes, blame, repo-browser, export zip
        try "line 1\nline 2 modified\n".write(to: file1, atomically: true, encoding: .utf8)
        _ = try await provider.commit(repoPath: repoA.path, options: VcsCommitOptions(message: "Second commit", paths: [file1.path]))
        _ = try await provider.editHeadCommitMessage(repoPath: repoA.path, newMessage: "Second commit (amended)")

        let log1 = try await provider.log(repoPath: repoA.path, query: VcsLogQuery(limit: 10))
        XCTAssertEqual(log1.count, 2)
        XCTAssertEqual(log1[0].subject, "Second commit (amended)")

        _ = try await provider.editNote(repoPath: repoA.path, commitHash: log1[0].hash, note: "QA verified")
        let logWithNote = try await provider.log(repoPath: repoA.path, query: VcsLogQuery(limit: 10))
        XCTAssertEqual(logWithNote[0].note, "QA verified")

        let blameLines = try await provider.blame(repoPath: repoA.path, path: "hello.txt", revision: "HEAD", ignoreWhitespace: false)
        XCTAssertEqual(blameLines.count, 2)

        let tree = try await provider.listDirectory(repoPath: repoA.path, path: "", revision: "HEAD")
        XCTAssertTrue(tree.contains(where: { $0.name == "hello.txt" }))

        let diffEntries = try await provider.diffRevisions(repoPath: repoA.path, rev1: log1[1].hash, rev2: log1[0].hash)
        XCTAssertEqual(diffEntries.count, 1)
        XCTAssertEqual(diffEntries[0].path, "hello.txt")

        let zipExport = tempRoot.appendingPathComponent("archive.zip")
        _ = try await provider.export(repoPath: repoA.path, revision: "HEAD", destinationPath: zipExport.path, asZip: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: zipExport.path))

        // 5. Stash save & apply/drop
        try "line 1\nline 2 stash\n".write(to: file1, atomically: true, encoding: .utf8)
        _ = try await provider.stashSave(repoPath: repoA.path, message: "wip stash")
        let stashes = try await provider.listStashes(repoPath: repoA.path)
        XCTAssertEqual(stashes.count, 1)
        _ = try await provider.stashApply(repoPath: repoA.path, stashRef: "stash@{0}", pop: true)
        XCTAssertTrue((try String(contentsOf: file1, encoding: .utf8)).contains("stash"))
        _ = try await provider.revert(repoPath: repoA.path, paths: [file1.path])

        // 6. Branch, merge conflict & resolve ours
        _ = try await provider.createBranch(repoPath: repoA.path, name: "feature", checkoutAfter: true)
        try "feature content\n".write(to: file1, atomically: true, encoding: .utf8)
        _ = try await provider.commit(repoPath: repoA.path, options: VcsCommitOptions(message: "Feature change", paths: [file1.path]))

        _ = try await provider.checkout(repoPath: repoA.path, target: "main")
        try "main content\n".write(to: file1, atomically: true, encoding: .utf8)
        _ = try await provider.commit(repoPath: repoA.path, options: VcsCommitOptions(message: "Main change", paths: [file1.path]))

        do {
            _ = try await provider.merge(repoPath: repoA.path, options: GitMergeOptions(sourceRef: "feature"))
            XCTFail("Expected merge conflict")
        } catch {
            XCTAssertEqual(provider.detectRepoState(repoPath: repoA.path), .merging)
        }

        _ = try await provider.resolveConflict(repoPath: repoA.path, path: file1.path, strategy: .ours)
        _ = try await provider.commit(repoPath: repoA.path, options: VcsCommitOptions(message: "Merge feature resolved ours", paths: []))
        XCTAssertEqual(provider.detectRepoState(repoPath: repoA.path), .normal)

        // 7. Tag, Cherry-Pick, Interactive Rebase, Reflog
        _ = try await provider.createTag(repoPath: repoA.path, name: "v0.1.0", target: "HEAD", message: "Tag 0.1.0")
        let refs = try await provider.listReferences(repoPath: repoA.path)
        XCTAssertTrue(refs.contains(where: { $0.kind == .tag && $0.shortName == "v0.1.0" }))

        let reflogEntries = try await provider.reflog(repoPath: repoA.path, ref: "HEAD", limit: 20)
        XCTAssertFalse(reflogEntries.isEmpty)

        // Cherry-pick onto a clean branch
        _ = try await provider.createBranch(repoPath: repoA.path, name: "cherry-test", startPoint: log1[1].hash, checkoutAfter: true)
        let extraFile = repoA.appendingPathComponent("extra.txt")
        try "a\n".write(to: extraFile, atomically: true, encoding: .utf8)
        _ = try await provider.commit(repoPath: repoA.path, options: VcsCommitOptions(message: "C1", paths: [extraFile.path]))
        try "b\n".write(to: extraFile, atomically: true, encoding: .utf8)
        _ = try await provider.commit(repoPath: repoA.path, options: VcsCommitOptions(message: "C2", paths: [extraFile.path]))

        let todo = try await provider.loadRebaseTodo(repoPath: repoA.path, upstream: log1[1].hash)
        XCTAssertEqual(todo.count, 2)
        var modifiedTodo = todo
        modifiedTodo[1].action = .fixup
        _ = try await provider.startInteractiveRebase(repoPath: repoA.path, upstream: log1[1].hash, todoItems: modifiedTodo)
        let afterRebase = try await provider.loadRebaseTodo(repoPath: repoA.path, upstream: log1[1].hash)
        XCTAssertEqual(afterRebase.count, 1)

        // Pull from repoA via bare remote into repoB
        _ = try await provider.checkout(repoPath: repoA.path, target: "main")
        _ = try await provider.push(
            repoPath: repoA.path,
            options: GitPushOptions(
                remote: "origin",
                branchMappings: [GitPushBranchMapping(localBranch: "main", remoteBranch: "main")]
            )
        )
        _ = try await provider.fetch(repoPath: repoB.path, options: GitFetchOptions(remote: "origin"))
        _ = try await provider.pull(repoPath: repoB.path, options: GitPullOptions(remote: "origin", remoteBranch: "main"))
        let contentInB = try String(contentsOf: repoB.appendingPathComponent("hello.txt"), encoding: .utf8)
        XCTAssertTrue(contentInB.contains("main content"))
    }
}
