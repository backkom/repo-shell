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

    func testAuthManagerCredentialHelperChain() throws {
        XCTAssertEqual(
            AuthManager.shellQuotedCredentialHelper(path: "/Applications/Repo Shell/bin/it's helper"),
            "!'/Applications/Repo Shell/bin/it'\\''s helper'"
        )

        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bundleURL = dir.appendingPathComponent("TestApp.bundle", isDirectory: true)
        let contentsDir = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let helpersDir = contentsDir.appendingPathComponent("Helpers", isDirectory: true)
        try FileManager.default.createDirectory(at: helpersDir, withIntermediateDirectories: true)
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.leaf.reposhell.test</string></dict></plist>
        """
        try plist.write(to: contentsDir.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)

        let fakeCredURL = helpersDir.appendingPathComponent(AppConstants.credentialHelperName)
        try "#!/bin/sh\nexit 0\n".write(to: fakeCredURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCredURL.path)

        let testBundle = try XCTUnwrap(Bundle(url: bundleURL))
        let storageDir = dir.appendingPathComponent("storage", isDirectory: true)
        let storage = SharedStorage(baseDirectoryURL: storageDir)

        var cfg = SharedConfig()
        let repoDefault = RepositoryEntry(path: "/tmp/repo-default", vcsType: .git, authConfig: RepoAuthConfig(mode: .none))
        let repoPass = RepositoryEntry(path: "/tmp/repo-pass", vcsType: .git, authConfig: RepoAuthConfig(mode: .userPassword, username: "alice"))
        cfg.repositories = [repoDefault, repoPass]
        try storage.saveConfig(cfg)

        let auth = AuthManager(storage: storage, bundle: testBundle)

        let envDefault = auth.environment(for: repoDefault.path)
        XCTAssertEqual(envDefault["GIT_CONFIG_COUNT"], "3")
        XCTAssertEqual(envDefault["GIT_CONFIG_KEY_0"], "credential.helper")
        XCTAssertEqual(envDefault["GIT_CONFIG_VALUE_0"], "")
        XCTAssertEqual(envDefault["GIT_CONFIG_KEY_1"], "credential.helper")
        if let appleHelper = AuthManager.systemAppleOsxKeychainHelperPath() {
            XCTAssertEqual(envDefault["GIT_CONFIG_VALUE_1"], AuthManager.shellQuotedCredentialHelper(path: appleHelper))
        } else {
            XCTAssertEqual(envDefault["GIT_CONFIG_VALUE_1"], "osxkeychain")
        }
        XCTAssertEqual(envDefault["GIT_CONFIG_KEY_2"], "credential.helper")
        XCTAssertEqual(envDefault["GIT_CONFIG_VALUE_2"], AuthManager.shellQuotedCredentialHelper(path: fakeCredURL.path))

        let envPass = auth.environment(for: repoPass.path)
        XCTAssertEqual(envPass["GIT_CONFIG_COUNT"], "2")
        XCTAssertEqual(envPass["GIT_CONFIG_VALUE_0"], "")
        XCTAssertEqual(envPass["GIT_CONFIG_VALUE_1"], AuthManager.shellQuotedCredentialHelper(path: fakeCredURL.path))
    }

    func testLegacyConfigDecodingPreservesDataAndDefaultsTopLevelActions() throws {
        let legacyJSON = """
        {
          "schemaVersion": 1,
          "excludedPaths": [],
          "workspaceRoots": [],
          "repositories": [
            {
              "id": "2CD7AABB-9828-4370-BBF3-E5D029F8D91A",
              "path": "/tmp/legacy-repo",
              "name": "legacy-repo",
              "vcsType": "git",
              "isAutoDiscovered": false,
              "authConfig": { "mode": "none", "username": "", "sshKeyPath": "", "sshPort": 22 }
            }
          ],
          "preferences": {
            "cascadeMenu": true,
            "diffToolId": "bcomp",
            "hasCompletedSetupWizard": true,
            "useBundledGit": true
          }
        }
        """
        let data = try XCTUnwrap(legacyJSON.data(using: .utf8))
        let decoded = try JSONDecoder().decode(SharedConfig.self, from: data)
        XCTAssertEqual(decoded.repositories.count, 1)
        XCTAssertEqual(decoded.repositories[0].path, "/tmp/legacy-repo")
        XCTAssertFalse(decoded.repositories[0].isStarred)
        XCTAssertEqual(decoded.preferences.diffToolId, "bcomp")
        XCTAssertTrue(decoded.preferences.hasCompletedSetupWizard)
        XCTAssertEqual(decoded.preferences.topLevelMenuActions, AppPreferences.defaultTopLevelMenuActions)
        XCTAssertEqual(decoded.preferences.useBundledSvn, false)
        XCTAssertEqual(decoded.preferences.externalSvnPath, "")
        XCTAssertEqual(decoded.preferences.svnLogLimit, 100)
        XCTAssertEqual(decoded.preferences.svnDeleteForce, false)
        XCTAssertEqual(decoded.preferences.svnTopLevelMenuActions, AppPreferences.defaultSvnTopLevelMenuActions)

        let legacyHistoryJSON = #"{"commitMessages":["msg1"],"remoteURLs":["https://example.com"]}"#
        let decodedHistory = try JSONDecoder().decode(RecentHistoryData.self, from: XCTUnwrap(legacyHistoryJSON.data(using: .utf8)))
        XCTAssertEqual(decodedHistory.commitMessages, ["msg1"])
        XCTAssertEqual(decodedHistory.svnCommitMessages, [])
        XCTAssertEqual(decodedHistory.svnRepoURLs, [])
    }

    func testSvnAuthEnvironmentSslTrustAndQuickActions() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bundleURL = dir.appendingPathComponent("TestApp.bundle", isDirectory: true)
        let contentsDir = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let helpersDir = contentsDir.appendingPathComponent("Helpers", isDirectory: true)
        try FileManager.default.createDirectory(at: helpersDir, withIntermediateDirectories: true)
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.leaf.reposhell.test</string></dict></plist>
        """
        try plist.write(to: contentsDir.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        let fakeAskpassURL = helpersDir.appendingPathComponent(AppConstants.askpassHelperName)
        try "#!/bin/sh\nexit 0\n".write(to: fakeAskpassURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeAskpassURL.path)

        let storage = SharedStorage(baseDirectoryURL: dir.appendingPathComponent("storage", isDirectory: true))
        var cfg = SharedConfig()
        let sshRepo = RepositoryEntry(
            path: "/tmp/svn-ssh",
            vcsType: .svn,
            authConfig: RepoAuthConfig(mode: .sshKey, sshKeyPath: "/Users/test/.ssh/id_ed25519", sshPort: 2222)
        )
        cfg.repositories = [sshRepo]
        try storage.saveConfig(cfg)

        let auth = AuthManager(storage: storage, bundle: try XCTUnwrap(Bundle(url: bundleURL)))
        let svnEnv = auth.svnEnvironment(for: sshRepo.path)
        XCTAssertEqual(svnEnv["SSH_ASKPASS"], fakeAskpassURL.path)
        XCTAssertTrue(svnEnv["SVN_SSH"]?.contains("id_ed25519") == true)
        XCTAssertTrue(svnEnv["SVN_SSH"]?.contains("-p 2222") == true)

        auth.trustSvnHostPermanently("svn.local")
        let overrides = auth.svnAuthOverrides(for: nil, targetURL: "https://svn.local/repos/app")
        XCTAssertFalse(overrides.trustServerCertFailures.isEmpty)

        let qaDir = dir.appendingPathComponent("services", isDirectory: true)
        let qa = QuickActionManager(servicesDirectoryURL: qaDir, runnerScriptPath: "/tmp/runner.sh")
        let updateWf = try qa.install(action: .svnUpdate, language: .en)
        let propsWf = try qa.install(action: .svnProperties, language: .en)
        XCTAssertTrue(FileManager.default.fileExists(atPath: updateWf.appendingPathComponent("Contents/document.wflow").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: propsWf.appendingPathComponent("Contents/document.wflow").path))
        try qa.uninstall(action: .svnUpdate, language: .en)
        try qa.uninstall(action: .svnProperties, language: .en)
    }

    func testRepositoryStarToggleSortingAndRescanPreservation() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let storageDir = dir.appendingPathComponent("storage", isDirectory: true)
        let workspace = dir.appendingPathComponent("workspace", isDirectory: true)
        let alpha = workspace.appendingPathComponent("alpha", isDirectory: true)
        let zeta = workspace.appendingPathComponent("zeta", isDirectory: true)
        try FileManager.default.createDirectory(at: alpha.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: zeta.appendingPathComponent(".git"), withIntermediateDirectories: true)

        let storage = SharedStorage(baseDirectoryURL: storageDir)
        let mgr = RepositoryManager(storage: storage)
        let initial = mgr.addWorkspaceRoot(at: workspace.path, maxDepth: 2)
        XCTAssertEqual(initial.map(\.name), ["alpha", "zeta"])

        let zetaEntry = try XCTUnwrap(initial.first(where: { $0.name == "zeta" }))
        mgr.toggleStar(id: zetaEntry.id)

        let afterStar = storage.loadConfig().repositories
        XCTAssertEqual(afterStar.map(\.name), ["zeta", "alpha"])
        XCTAssertTrue(afterStar[0].isStarred)
        XCTAssertFalse(afterStar[1].isStarred)

        let afterRescan = mgr.rescanWorkspaceRoots()
        XCTAssertEqual(afterRescan.map(\.name), ["zeta", "alpha"])
        XCTAssertEqual(afterRescan[0].id, zetaEntry.id)
        XCTAssertTrue(afterRescan[0].isStarred)
    }

    func testSemanticVersionComparisonAndGitHubReleaseParsing() async throws {
        XCTAssertTrue(SemanticVersion.isUpdateAvailable(latest: "v0.2.0", current: "0.1.0"))
        XCTAssertTrue(SemanticVersion.isUpdateAvailable(latest: "0.1.1", current: "0.1.0"))
        XCTAssertTrue(SemanticVersion.isUpdateAvailable(latest: "0.2.0", current: "0.2.0-beta.1"))
        XCTAssertFalse(SemanticVersion.isUpdateAvailable(latest: "v0.1.0", current: "0.1.0"))
        XCTAssertFalse(SemanticVersion.isUpdateAvailable(latest: "0.0.9", current: "0.1.0"))

        XCTAssertEqual(AppConstants.developerName, "leaf")
        XCTAssertEqual(AppConstants.developerEmail, "flying_butterfly@126.com")
        XCTAssertEqual(AppConstants.defaultVersion, "0.1.1")
        XCTAssertEqual(AppConstants.githubRepo, "backkom/repo-shell")

        let releaseJSON = """
        {
          "tag_name": "v0.2.0",
          "name": "RepoShell 0.2.0",
          "body": "Bug fixes and improvements",
          "html_url": "https://github.com/backkom/repo-shell/releases/tag/v0.2.0",
          "draft": false,
          "prerelease": false,
          "published_at": "2026-11-26T08:00:00Z",
          "assets": [
            {
              "name": "RepoShell-0.2.0-macOS.dmg",
              "browser_download_url": "https://github.com/backkom/repo-shell/releases/download/v0.2.0/RepoShell-0.2.0-macOS.dmg",
              "size": 123456
            },
            {
              "name": "RepoShell-0.2.0-macOS.zip",
              "browser_download_url": "https://github.com/backkom/repo-shell/releases/download/v0.2.0/RepoShell-0.2.0-macOS.zip",
              "size": 120000
            }
          ]
        }
        """
        let client = AppUpdateClient { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(releaseJSON.utf8), response)
        }

        let result = try await client.checkForUpdate(repoSlug: "backkom/repo-shell", currentVersion: "0.1.0")
        guard case .updateAvailable(let info) = result else {
            return XCTFail("Expected updateAvailable, got \(result)")
        }
        XCTAssertEqual(info.latestVersion, "0.2.0")
        XCTAssertEqual(info.assetName, "RepoShell-0.2.0-macOS.zip")
        XCTAssertEqual(info.downloadURL, "https://github.com/backkom/repo-shell/releases/download/v0.2.0/RepoShell-0.2.0-macOS.zip")

        let upToDateResult = try await client.checkForUpdate(repoSlug: "backkom/repo-shell", currentVersion: "0.2.0")
        XCTAssertEqual(upToDateResult, .upToDate(currentVersion: "0.2.0", latestVersion: "0.2.0"))

        let notFoundClient = AppUpdateClient { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 404,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(), response)
        }
        let noReleaseResult = try await notFoundClient.checkForUpdate(repoSlug: "backkom/repo-shell", currentVersion: "0.1.0")
        XCTAssertEqual(noReleaseResult, .noPublishedRelease)

        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = SharedStorage(baseDirectoryURL: dir)
        try storage.saveUpdateState(info)
        let loaded = try XCTUnwrap(storage.loadUpdateState())
        XCTAssertEqual(loaded.latestVersion, info.latestVersion)
        XCTAssertEqual(loaded.tagName, info.tagName)
        XCTAssertEqual(loaded.downloadURL, info.downloadURL)
        XCTAssertEqual(loaded.assetName, info.assetName)
        XCTAssertEqual(loaded.assetSize, info.assetSize)
        try storage.saveUpdateState(nil)
        XCTAssertNil(storage.loadUpdateState())
    }
}
