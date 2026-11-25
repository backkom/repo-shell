import XCTest
@testable import RepoShellShared

final class MenuAndStatusTests: XCTestCase {

    func testAllVcsStatusCasesCoverGitAndSvnSuperset() {
        let all = VcsFileStatus.allCases
        XCTAssertEqual(all.count, 16)
        XCTAssertTrue(all.contains(.locked))
        XCTAssertTrue(all.contains(.missing))
        XCTAssertTrue(all.contains(.obstructed))
        XCTAssertTrue(all.contains(.replaced))
        XCTAssertTrue(all.contains(.readOnly))
        XCTAssertTrue(all.contains(.external))

        let aggregated = VcsFileStatus.aggregateFolderStatus([.untracked, .modified, .locked, .unmerged])
        XCTAssertEqual(aggregated, .unmerged)
    }

    func testMenuVisibilityOutsideMonitoredRepoWithGitDir() {
        let ctx = MenuResolutionContext(
            targetDirectoryPath: "/tmp/my-repo",
            selectedPaths: ["/tmp/my-repo"],
            matchedRepo: nil,
            snapshot: nil,
            diffLaterState: nil,
            directoryContainsGitFolder: true,
            isDirectoryCleanRepoCandidate: false,
            language: .en
        )
        let resolved = MenuVisibilityResolver.resolveMenu(for: ctx)
        let actions = resolved.compactMap { item -> MenuAction? in
            if case .item(let action, _) = item { return action }
            return nil
        }
        XCTAssertTrue(actions.contains(.addRepository))
        XCTAssertTrue(actions.contains(.gitClone))
        XCTAssertFalse(actions.contains(.gitCommit))
    }

    func testMenuVisibilityInsideMonitoredRepoWithMergingAndDiffLater() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reposhell-menu-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let tempFile = dir.appendingPathComponent("foo.swift")
        try "conflict".write(to: tempFile, atomically: true, encoding: .utf8)

        let repo = RepositoryEntry(path: dir.path, vcsType: .git)
        let snapshot = RepoStatusSnapshot(
            repoPath: dir.path,
            vcsType: .git,
            branchName: "feature/x",
            repoState: .merging,
            fileStatuses: ["foo.swift": .unmerged]
        )
        let ctx = MenuResolutionContext(
            targetDirectoryPath: dir.path,
            selectedPaths: [tempFile.path],
            matchedRepo: repo,
            snapshot: snapshot,
            diffLaterState: DiffLaterState(filePath: dir.appendingPathComponent("bar.swift").path),
            directoryContainsGitFolder: true,
            language: .en
        )
        let resolved = MenuVisibilityResolver.resolveMenu(for: ctx)
        let items: [(MenuAction, String)] = resolved.compactMap {
            if case .item(let action, let title) = $0 { return (action, title) }
            return nil
        }
        XCTAssertTrue(items.contains(where: { $0.0 == .gitCommit && $0.1.contains("feature/x") }))
        XCTAssertTrue(items.contains(where: { $0.0 == .abortMerge }))
        XCTAssertTrue(items.contains(where: { $0.0 == .resolveConflicts }))
        XCTAssertTrue(items.contains(where: { $0.0 == .diffWithLater && $0.1.contains("bar.swift") }))
    }
}
