import XCTest
@testable import RepoShellShared
@testable import RepoShellServices

final class ServicesTests: XCTestCase {

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("reposhell-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testSharedStorageAtomicRoundTrip() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = SharedStorage(baseDirectoryURL: dir)

        var cfg = SharedConfig()
        let repo = RepositoryEntry(path: "/tmp/repo-a", vcsType: .git)
        cfg.repositories = [repo]
        cfg.preferences.cascadeMenu = false
        try storage.saveConfig(cfg)

        let loaded = storage.loadConfig()
        XCTAssertEqual(loaded.repositories.count, 1)
        XCTAssertEqual(loaded.preferences.cascadeMenu, false)

        let snap = RepoStatusSnapshot(
            repoPath: "/tmp/repo-a",
            branchName: "main",
            repoState: .normal,
            fileStatuses: ["a.swift": .modified]
        )
        try storage.saveStatusSnapshot(snap)
        let loadedSnap = storage.loadStatusSnapshot(for: "/tmp/repo-a")
        XCTAssertEqual(loadedSnap?.fileStatuses["a.swift"], .modified)

        let payload = ActionPayload(
            actionRawValue: MenuAction.gitCommit.rawValue,
            targetDirectoryPath: "/tmp/repo-a",
            selectedPaths: ["/tmp/repo-a/a.swift"],
            repoPath: "/tmp/repo-a"
        )
        _ = try storage.saveActionPayload(payload)
        let consumed = storage.loadAndConsumeActionPayload(id: payload.id)
        XCTAssertEqual(consumed?.selectedPaths, ["/tmp/repo-a/a.swift"])
        XCTAssertNil(storage.loadAndConsumeActionPayload(id: payload.id))
    }

    func testWorkspaceAutoDiscoveryAndExclusions() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let storageDir = dir.appendingPathComponent("storage", isDirectory: true)
        let workspace = dir.appendingPathComponent("workspace", isDirectory: true)
        let repo1 = workspace.appendingPathComponent("project1", isDirectory: true)
        let repo2 = workspace.appendingPathComponent("nested/project2", isDirectory: true)
        let excludedRepo = workspace.appendingPathComponent("ignored-repo", isDirectory: true)
        let svnRepo = workspace.appendingPathComponent("legacy-svn", isDirectory: true)

        for r in [repo1, repo2, excludedRepo] {
            try FileManager.default.createDirectory(at: r.appendingPathComponent(".git"), withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: svnRepo.appendingPathComponent(".svn"), withIntermediateDirectories: true)

        let storage = SharedStorage(baseDirectoryURL: storageDir)
        let mgr = RepositoryManager(storage: storage)
        mgr.excludeRepository(at: excludedRepo.path)
        let discovered = mgr.addWorkspaceRoot(at: workspace.path, maxDepth: 3)

        let paths = Set(discovered.map { $0.path })
        XCTAssertTrue(paths.contains(PathUtils.normalize(repo1.path)))
        XCTAssertTrue(paths.contains(PathUtils.normalize(repo2.path)))
        XCTAssertTrue(paths.contains(PathUtils.normalize(svnRepo.path)))
        XCTAssertFalse(paths.contains(PathUtils.normalize(excludedRepo.path)))
    }

    func testDiffToolPresetsAndCommandRenderingAndImageDetection() {
        let mgr = DiffToolManager()
        XCTAssertGreaterThanOrEqual(DiffToolManager.diffPresets.count, 20)
        XCTAssertGreaterThanOrEqual(DiffToolManager.mergePresets.count, 10)
        XCTAssertTrue(DiffToolManager.isImageFile("/tmp/screenshot.PNG"))
        XCTAssertFalse(DiffToolManager.isImageFile("/tmp/code.swift"))

        let rendered = mgr.renderCommandLine(
            template: "tool \"$LOCAL\" \"$REMOTE\" \"$BASE\" \"$MERGED\"",
            local: "/tmp/a b.txt",
            remote: "/tmp/c\"d.txt",
            base: "/tmp/base.txt",
            merged: "/tmp/out.txt"
        )
        XCTAssertTrue(rendered.contains("/tmp/a b.txt"))
        XCTAssertTrue(rendered.contains("/tmp/c\\\"d.txt"))
    }

    func testQuickActionWorkflowGenerationAndRemoval() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let mgr = QuickActionManager(
            servicesDirectoryURL: dir,
            runnerScriptPath: "/Applications/RepoShell.app/Contents/Resources/Scripts/quickaction-runner.sh"
        )
        let wfURL = try mgr.install(action: .gitCommit, language: .en)
        XCTAssertTrue(FileManager.default.fileExists(atPath: wfURL.appendingPathComponent("Contents/Info.plist").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: wfURL.appendingPathComponent("Contents/document.wflow").path))

        let items = mgr.availableActions(language: .en)
        XCTAssertTrue(items.first(where: { $0.action == .gitCommit })?.isInstalled == true)

        try mgr.uninstall(action: .gitCommit, language: .en)
        let after = mgr.availableActions(language: .en)
        XCTAssertTrue(after.first(where: { $0.action == .gitCommit })?.isInstalled == false)
    }

    func testFinderTagCloudDriveDetection() {
        let indicators = AppPreferences().cloudDriveIndicators
        XCTAssertTrue(FinderTagService.isCloudDrivePath("/Users/test/Library/CloudStorage/OneDrive-Corp/repo", indicators: indicators))
        XCTAssertTrue(FinderTagService.isCloudDrivePath("/Users/test/Dropbox/work/repo", indicators: indicators))
        XCTAssertFalse(FinderTagService.isCloudDrivePath("/Users/test/Documents/code/repo", indicators: indicators))
    }
}
