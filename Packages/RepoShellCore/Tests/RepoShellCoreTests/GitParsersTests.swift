import XCTest
@testable import RepoShellShared
@testable import RepoShellVcs

final class GitParsersTests: XCTestCase {

    func testPorcelainV2ZWithUnicodeSpacesRenamesAndConflicts() {
        let records = [
            "# branch.oid 1234567890abcdef1234567890abcdef12345678",
            "# branch.head main",
            "# branch.upstream origin/main",
            "# branch.ab +2 -1",
            "1 .M N... 100644 100644 100644 abcdef1 abcdef2 src/中文 目录/hello world.swift",
            "1 A. N... 000000 100644 100644 0000000 abcdef3 added.txt",
            "1 D. N... 100644 000000 000000 abcdef4 0000000 deleted.txt",
            "2 R. N... 100644 100644 100644 abcdef5 abcdef6 R100 new name.swift",
            "old name.swift",
            "u UU N... 100644 100644 100644 100644 a1 b2 c3 conflict.txt",
            "? untracked dir/new file.md",
            "! build/ignored.o"
        ]
        let rawData = records.joined(separator: "\0").data(using: .utf8)! + Data([0])
        let parsed = GitParsers.parsePorcelainV2Z(rawData, repoPath: "/tmp/repo")

        XCTAssertEqual(parsed.branchName, "main")
        XCTAssertEqual(parsed.upstream, "origin/main")
        XCTAssertEqual(parsed.ahead, 2)
        XCTAssertEqual(parsed.behind, 1)
        XCTAssertEqual(parsed.entries.count, 7)

        XCTAssertEqual(parsed.entries[0].relativePath, "src/中文 目录/hello world.swift")
        XCTAssertEqual(parsed.entries[0].status, .modified)
        XCTAssertEqual(parsed.entries[1].status, .added)
        XCTAssertEqual(parsed.entries[2].status, .deleted)
        XCTAssertEqual(parsed.entries[3].status, .renamed)
        XCTAssertEqual(parsed.entries[3].relativePath, "new name.swift")
        XCTAssertEqual(parsed.entries[3].originalPath, "old name.swift")
        XCTAssertEqual(parsed.entries[4].status, .unmerged)
        XCTAssertEqual(parsed.entries[5].status, .untracked)
        XCTAssertEqual(parsed.entries[6].status, .ignored)
    }

    func testFolderStatusAggregationPriorityAndIgnoredIsolation() {
        let items = [
            VcsStatusItem(relativePath: "a/b/clean_unt.txt", absolutePath: "/repo/a/b/clean_unt.txt", status: .untracked),
            VcsStatusItem(relativePath: "a/b/mod.swift", absolutePath: "/repo/a/b/mod.swift", status: .modified),
            VcsStatusItem(relativePath: "a/c/conflict.swift", absolutePath: "/repo/a/c/conflict.swift", status: .unmerged),
            VcsStatusItem(relativePath: "ignored_dir/foo.o", absolutePath: "/repo/ignored_dir/foo.o", status: .ignored)
        ]

        let map = GitParsers.buildFolderStatuses(from: items)
        XCTAssertEqual(map["a/b"], .modified)
        XCTAssertEqual(map["a/c"], .unmerged)
        XCTAssertEqual(map["a"], .unmerged)
        XCTAssertEqual(map[""], .unmerged)
        XCTAssertNil(map["ignored_dir"])
    }

    func testParseLogWithRefsAndChangedFiles() {
        let raw = "\u{1E}abcdef1234567890\u{1F}abcdef1\u{1F}parent1 parent2\u{1F}Alice\u{1F}alice@example.com\u{1F}1700000000\u{1F}HEAD -> main, origin/main, tag: v1.0\u{1F}Initial release\u{1F}Body details line 1\u{1F}Review note\u{1D}:100644 100644 111 222 M\tsrc/app.swift\n:000000 100644 000 333 A\tREADME.md\n5\t2\tsrc/app.swift\n10\t0\tREADME.md\n"
        let commits = GitParsers.parseLogOutput(raw)
        XCTAssertEqual(commits.count, 1)
        let c = commits[0]
        XCTAssertEqual(c.shortHash, "abcdef1")
        XCTAssertEqual(c.parents, ["parent1", "parent2"])
        XCTAssertEqual(c.author, "Alice")
        XCTAssertEqual(c.refs, ["HEAD -> main", "origin/main", "tag: v1.0"])
        XCTAssertEqual(c.note, "Review note")
        XCTAssertEqual(c.changedPaths.count, 2)
        XCTAssertEqual(c.changedPaths[0].action, "M")
        XCTAssertEqual(c.changedPaths[0].additions, 5)
        XCTAssertEqual(c.changedPaths[0].deletions, 2)
    }

    func testParseBlamePorcelain() {
        let sample = """
        0123456789abcdef0123456789abcdef01234567 1 1 2
        author Bob
        author-mail <bob@example.com>
        author-time 1700000000
        summary First commit
        \tlet x = 1
        0123456789abcdef0123456789abcdef01234567 2 2
        \tlet y = 2
        """
        let lines = GitParsers.parseBlamePorcelain(sample)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].author, "Bob")
        XCTAssertEqual(lines[0].content, "let x = 1")
        XCTAssertEqual(lines[1].author, "Bob")
        XCTAssertEqual(lines[1].lineNumber, 2)
        XCTAssertEqual(lines[1].content, "let y = 2")
    }

    func testParseLsTreeZAndRemotesAndReflogAndStash() {
        let lsTreeData = "100644 blob 1111111111111111111111111111111111111111     123\tsrc/main.swift\0040000 tree 2222222222222222222222222222222222222222       -\tsrc/nested\0".data(using: .utf8)!
        let tree = GitParsers.parseLsTreeZ(lsTreeData)
        XCTAssertEqual(tree.count, 2)
        XCTAssertEqual(tree[0].kind, .blob)
        XCTAssertEqual(tree[0].size, 123)
        XCTAssertEqual(tree[1].kind, .tree)
        XCTAssertNil(tree[1].size)

        let remotesOut = """
        origin\tgit@github.com:user/repo.git (fetch)
        origin\tgit@github.com:user/repo.git (push)
        upstream\thttps://github.com/org/repo.git (fetch)
        """
        let remotes = GitParsers.parseRemotes(remotesOut)
        XCTAssertEqual(remotes.count, 2)
        XCTAssertEqual(remotes[0].name, "origin")

        let stashOut = "stash@{0}\u{1F}abcdef\u{1F}abc\u{1F}1700000000\u{1F}WIP on main: save work\u{1E}"
        let stashes = GitParsers.parseStashList(stashOut)
        XCTAssertEqual(stashes.count, 1)
        XCTAssertEqual(stashes[0].branchName, "main")
        XCTAssertEqual(stashes[0].message, "save work")

        let reflogOut = "abcdef\u{1F}abc\u{1F}HEAD@{0}\u{1F}1700000000\u{1F}commit: fix bug\u{1E}"
        let reflogs = GitParsers.parseRefLog(reflogOut)
        XCTAssertEqual(reflogs.count, 1)
        XCTAssertEqual(reflogs[0].actionSummary, "commit")
        XCTAssertEqual(reflogs[0].message, "fix bug")
    }
}
