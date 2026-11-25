import XCTest
#if canImport(AppKit)
import AppKit
#endif
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

    func testPartitionForCascadePromotesDefaultActionsAndCleansSeparators() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reposhell-partition-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let repo = RepositoryEntry(path: dir.path, vcsType: .git)
        let snapshot = RepoStatusSnapshot(
            repoPath: dir.path,
            vcsType: .git,
            branchName: "master",
            repoState: .normal,
            fileStatuses: [:]
        )
        let insideCtx = MenuResolutionContext(
            targetDirectoryPath: dir.path,
            selectedPaths: [dir.path],
            matchedRepo: repo,
            snapshot: snapshot,
            diffLaterState: nil,
            directoryContainsGitFolder: true,
            language: .en
        )
        let resolved = MenuVisibilityResolver.resolveMenu(for: insideCtx)
        let partitioned = MenuVisibilityResolver.partitionForCascade(
            items: resolved,
            topLevelActions: AppPreferences.defaultTopLevelMenuActions
        )

        let topActions = partitioned.topLevel.compactMap { item -> MenuAction? in
            if case .item(let action, _) = item { return action }
            return nil
        }
        XCTAssertEqual(topActions, [.gitCommit, .gitPull, .gitFetch, .gitPush, .showLog])
        if case .item(_, let commitTitle) = partitioned.topLevel[0] {
            XCTAssertTrue(commitTitle.contains("master"))
        } else {
            XCTFail("Expected commit item first in topLevel")
        }

        let subActions = partitioned.submenu.compactMap { item -> MenuAction? in
            if case .item(let action, _) = item { return action }
            return nil
        }
        for promoted in topActions {
            XCTAssertFalse(subActions.contains(promoted))
        }
        if case .separator = partitioned.submenu.first { XCTFail("Leading separator should be removed") }
        if case .separator = partitioned.submenu.last { XCTFail("Trailing separator should be removed") }
        for idx in 1..<partitioned.submenu.count {
            if case .separator = partitioned.submenu[idx - 1],
               case .separator = partitioned.submenu[idx] {
                XCTFail("Adjacent separators should be collapsed")
            }
        }

        // Outside a monitored repo, none of the default git actions apply
        let outsideCtx = MenuResolutionContext(
            targetDirectoryPath: "/tmp/not-a-repo",
            selectedPaths: ["/tmp/not-a-repo"],
            matchedRepo: nil,
            snapshot: nil,
            diffLaterState: nil,
            directoryContainsGitFolder: false,
            language: .en
        )
        let outsideResolved = MenuVisibilityResolver.resolveMenu(for: outsideCtx)
        let outsidePartitioned = MenuVisibilityResolver.partitionForCascade(
            items: outsideResolved,
            topLevelActions: AppPreferences.defaultTopLevelMenuActions
        )
        XCTAssertTrue(outsidePartitioned.topLevel.isEmpty)
        XCTAssertEqual(outsidePartitioned.submenu.count, outsideResolved.count)
    }

    func testAllMenuActionColoredIconsRenderNonTemplateBitmaps() {
        #if canImport(AppKit)
        func assertColoredBitmap(_ image: NSImage, label: String) {
            XCTAssertFalse(image.isTemplate, "\(label) must not be a template image")
            XCTAssertEqual(image.size, NSSize(width: 16, height: 16), "\(label) point size mismatch")
            guard let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first else {
                XCTFail("\(label) missing NSBitmapImageRep")
                return
            }
            XCTAssertEqual(rep.pixelsWide, 32, "\(label) pixel width")
            XCTAssertEqual(rep.pixelsHigh, 32, "\(label) pixel height")

            var visiblePixels = 0
            var colorfulPixels = 0
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    if c.alphaComponent > 0.1 {
                        visiblePixels += 1
                        let spread = max(c.redComponent, c.greenComponent, c.blueComponent)
                            - min(c.redComponent, c.greenComponent, c.blueComponent)
                        if spread > 0.08 {
                            colorfulPixels += 1
                        }
                    }
                }
            }
            XCTAssertGreaterThan(visiblePixels, 10, "\(label) rendered empty bitmap")
            XCTAssertGreaterThan(colorfulPixels, 10, "\(label) rendered monochrome bitmap")
        }

        for action in MenuAction.allCases {
            assertColoredBitmap(MenuActionIconRenderer.menuIcon(for: action), label: "MenuAction.\(action.rawValue)")
        }
        assertColoredBitmap(MenuActionIconRenderer.appBrandMenuIcon(), label: "appBrandMenuIcon")
        assertColoredBitmap(MenuActionIconRenderer.submenuIcon(symbolName: "shippingbox.fill"), label: "submenuIcon")
        #endif
    }
}
