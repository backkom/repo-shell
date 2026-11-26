import XCTest
@testable import RepoShellShared
@testable import RepoShellVcs
@testable import RepoShellServices

final class SvnProviderIntegrationTests: XCTestCase {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reposhell-svn-it-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testFullBasicAndAdvancedSvnWorkflow() async throws {
        guard (try? SvnExecutableResolver.resolve(preferences: AppPreferences())) != nil,
              SvnExecutableResolver.resolveSvnadmin() != nil else {
            throw XCTSkip("svn or svnadmin executable not found")
        }

        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let provider = SvnProvider()
        let repoStorage = root.appendingPathComponent("svn-repo", isDirectory: true)
        _ = try await provider.createRepository(at: repoStorage.path)

        let baseRepoURL = URL(fileURLWithPath: repoStorage.path).absoluteString
        let cleanRepoURL = baseRepoURL.hasSuffix("/") ? String(baseRepoURL.dropLast()) : baseRepoURL

        // 1. Remote mkdir trunk / branches / tags
        _ = try await provider.remoteMakeDirectory(url: "\(cleanRepoURL)/trunk", message: "init trunk")
        _ = try await provider.remoteMakeDirectory(url: "\(cleanRepoURL)/branches", message: "init branches")
        _ = try await provider.remoteMakeDirectory(url: "\(cleanRepoURL)/tags", message: "init tags")

        // 2. Checkout two working copies
        let wc1 = root.appendingPathComponent("wc1", isDirectory: true)
        let wc2 = root.appendingPathComponent("wc2", isDirectory: true)
        let trunkURL = "\(cleanRepoURL)/trunk"
        _ = try await provider.checkout(options: SvnCheckoutOptions(url: trunkURL, destinationPath: wc1.path))
        _ = try await provider.checkout(options: SvnCheckoutOptions(url: trunkURL, destinationPath: wc2.path))

        // 3. Nested detectRepositoryRoot + info formattedBranchName
        let subDir = wc1.appendingPathComponent("Sources/Sub", isDirectory: true)
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        let detected = await provider.detectRepositoryRoot(for: subDir.path)
        XCTAssertEqual(detected, PathUtils.normalize(wc1.path))

        let wcInfo = try await provider.info(target: wc1.path, workingDirectory: wc1.path)
        XCTAssertTrue(wcInfo.formattedBranchName.hasPrefix("trunk (r"))

        // 4. Add & auto-add untracked files (including `@2x.png` & Unicode/spaces) and Commit
        let txtFile = subDir.appendingPathComponent("hello 世界.txt")
        try "line 1\nline 2\nline 3\n".write(to: txtFile, atomically: true, encoding: .utf8)

        let binFile = wc1.appendingPathComponent("icon@2x.png")
        let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x01, 0x02])
        try pngBytes.write(to: binFile)

        _ = try await provider.svnCommit(
            repoPath: wc1.path,
            paths: [subDir.path, binFile.path],
            message: "initial files",
            autoAddPaths: ["Sources", "icon@2x.png"]
        )

        // Verify binary extractFile exact fidelity
        let extractedBin = root.appendingPathComponent("extracted.png")
        try await provider.extractFile(repoPath: wc1.path, path: binFile.path, revision: "HEAD", to: extractedBin.path)
        XCTAssertEqual(try Data(contentsOf: extractedBin), pngBytes)

        // 5. Update wc2 + Blame + Log
        _ = try await provider.update(repoPath: wc2.path)
        let wc2Txt = wc2.appendingPathComponent("Sources/Sub/hello 世界.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: wc2Txt.path))

        let blameLines = try await provider.svnBlame(repoPath: wc1.path, target: txtFile.path, revision: "HEAD")
        XCTAssertEqual(blameLines.count, 3)

        let logs = try await provider.svnLog(target: ".", repoPath: wc1.path, limit: 10)
        XCTAssertTrue(logs.contains(where: { $0.subject == "initial files" }))

        // 6. Detailed Status `-u` (outgoing/incoming check)
        try "line 1\nline 2 modified in wc2\nline 3\n".write(to: wc2Txt, atomically: true, encoding: .utf8)
        _ = try await provider.commit(repoPath: wc2.path, options: VcsCommitOptions(message: "wc2 edit", paths: [wc2Txt.path]))

        let remoteStatus = try await provider.detailedStatus(repoPath: wc1.path, checkRemote: true)
        XCTAssertTrue(remoteStatus.items.contains(where: { $0.item.relativePath.contains("hello") && $0.remoteItemStatus == "modified" }))

        // 7. Create a real text conflict in wc1 and resolveConflict
        try "line 1\nline 2 conflicting in wc1\nline 3\n".write(to: txtFile, atomically: true, encoding: .utf8)
        _ = try await provider.update(repoPath: wc1.path, options: SvnUpdateOptions(accept: .postpone))
        let conflictStatus = try await provider.status(repoPath: wc1.path, options: VcsStatusOptions())
        XCTAssertTrue(conflictStatus.items.contains(where: { $0.status == .unmerged }))

        _ = try await provider.resolveConflict(repoPath: wc1.path, paths: [txtFile.path], accept: .mineFull)
        _ = try await provider.commit(repoPath: wc1.path, options: VcsCommitOptions(message: "resolve with mine", paths: [txtFile.path]))

        // 8. Locking & Unlocking (local `file://` lock without explicit --username works using macOS user)
        _ = try await provider.lock(repoPath: wc1.path, paths: [txtFile.path], message: "locked for test")
        let lockedStatus = try await provider.status(repoPath: wc1.path, options: VcsStatusOptions())
        XCTAssertTrue(lockedStatus.items.contains(where: { $0.status == .locked }))
        _ = try await provider.unlock(repoPath: wc1.path, paths: [txtFile.path], force: true)

        // 9. Properties & appendIgnorePatterns
        _ = try await provider.setProperty(repoPath: wc1.path, target: txtFile.path, name: "svn:eol-style", value: "LF")
        let props = try await provider.listProperties(repoPath: wc1.path, target: txtFile.path)
        XCTAssertEqual(props.first(where: { $0.name == "svn:eol-style" })?.value.trimmingCharacters(in: .whitespacesAndNewlines), "LF")

        try await provider.appendIgnorePatterns(repoPath: wc1.path, directoryPath: wc1.path, patterns: ["*.tmp", "*.log"])
        let ignoredFile = wc1.appendingPathComponent("temp.tmp")
        try "temp".write(to: ignoredFile, atomically: true, encoding: .utf8)
        let afterIgnoreStatus = try await provider.status(repoPath: wc1.path, options: VcsStatusOptions(includeIgnored: true))
        XCTAssertTrue(afterIgnoreStatus.items.contains(where: { $0.relativePath == "temp.tmp" && $0.status == .ignored }))
        _ = try await provider.deleteProperty(repoPath: wc1.path, target: wc1.path, name: "svn:ignore")
        try? FileManager.default.removeItem(at: ignoredFile)
        _ = try await provider.revert(repoPath: wc1.path, paths: [wc1.path])

        // 10. Branch / Tag + Switch + Merge (--dry-run & range)
        let branchURL = "\(cleanRepoURL)/branches/feature-a"
        _ = try await provider.branchOrTag(
            repoPath: wc1.path,
            source: trunkURL,
            destinationURL: branchURL,
            revision: "HEAD",
            message: "create feature-a"
        )
        _ = try await provider.switchBranch(repoPath: wc2.path, url: branchURL)
        let branchFile = wc2.appendingPathComponent("feature.txt")
        try "from branch\n".write(to: branchFile, atomically: true, encoding: .utf8)
        _ = try await provider.add(repoPath: wc2.path, paths: [branchFile.path])
        let branchCommitRes = try await provider.commit(repoPath: wc2.path, options: VcsCommitOptions(message: "branch commit", paths: [branchFile.path]))
        XCTAssertEqual(branchCommitRes.exitCode, 0)

        let branchLogs = try await provider.svnLog(target: ".", repoPath: wc2.path, limit: 2)
        let branchRev = try XCTUnwrap(branchLogs.first?.hash)
        _ = try await provider.update(repoPath: wc1.path)
        _ = try await provider.merge(
            repoPath: wc1.path,
            options: SvnMergeOptions(mode: .range, sourceURL1: branchURL, revisionRange: branchRev, dryRun: true)
        )
        _ = try await provider.merge(
            repoPath: wc1.path,
            options: SvnMergeOptions(mode: .range, sourceURL1: branchURL, revisionRange: branchRev, dryRun: false)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: wc1.appendingPathComponent("feature.txt").path))
        _ = try await provider.commit(repoPath: wc1.path, options: VcsCommitOptions(message: "merged feature-a", paths: ["."]))

        // 11. Compare Revisions + Create/Apply Patch + Move + Delete Keep Local + Export + Cleanup
        let latestLog = try await provider.svnLog(target: ".", repoPath: wc1.path, limit: 1)
        let headRev = try XCTUnwrap(latestLog.first?.hash)
        let diffPaths = try await provider.diffRevisions(repoPath: wc1.path, rev1: "1", rev2: headRev)
        XCTAssertFalse(diffPaths.isEmpty)

        try "line 1\nline 2 patched\nline 3\n".write(to: txtFile, atomically: true, encoding: .utf8)
        let patchURL = root.appendingPathComponent("changes.patch")
        _ = try await provider.createPatch(repoPath: wc1.path, paths: [txtFile.path], destinationFile: patchURL.path)
        _ = try await provider.revert(repoPath: wc1.path, paths: [txtFile.path])
        _ = try await provider.applyPatch(repoPath: wc1.path, patchFile: patchURL.path)
        XCTAssertTrue((try String(contentsOf: txtFile, encoding: .utf8)).contains("patched"))
        _ = try await provider.revert(repoPath: wc1.path, paths: [txtFile.path])

        _ = try await provider.cleanup(repoPath: wc1.path, options: SvnCleanupOptions(vacuumPristines: true))

        let exportDir = root.appendingPathComponent("exported-dir")
        _ = try await provider.export(repoPath: wc1.path, revision: "HEAD", destinationPath: exportDir.path, asZip: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportDir.appendingPathComponent("feature.txt").path))

        let exportZip = root.appendingPathComponent("exported.zip")
        _ = try await provider.export(repoPath: wc1.path, revision: "HEAD", destinationPath: exportZip.path, asZip: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportZip.path))

        // 12. StatusEngine refreshes SVN repo locally without network `-u`
        let storageDir = root.appendingPathComponent("storage", isDirectory: true)
        let storage = SharedStorage(baseDirectoryURL: storageDir)
        let repoMgr = RepositoryManager(storage: storage, svnProvider: provider)
        _ = try await repoMgr.addRepository(at: wc1.path, vcsType: .svn)
        let engine = StatusEngine(storage: storage, repositoryManager: repoMgr, svnProvider: provider)
        await engine.refreshRepositoryNow(at: wc1.path)
        let snapshot = try XCTUnwrap(storage.loadStatusSnapshot(for: wc1.path))
        XCTAssertEqual(snapshot.vcsType, .svn)
        XCTAssertTrue(snapshot.branchName.hasPrefix("trunk (r"))
    }
}
