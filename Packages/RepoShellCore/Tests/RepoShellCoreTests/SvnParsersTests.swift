import XCTest
@testable import RepoShellShared
@testable import RepoShellVcs

final class SvnParsersTests: XCTestCase {

    func testParseInfoXmlAndFormattedBranchName() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <info>
          <entry path="." revision="1420" kind="dir">
            <url>https://svn.example.com/repo/branches/v2-release</url>
            <relative-url>^/branches/v2-release</relative-url>
            <repository>
              <root>https://svn.example.com/repo</root>
              <uuid>12345678-1234-1234-1234-1234567890ab</uuid>
            </repository>
            <wc-info>
              <wcroot-abspath>/Users/dev/project</wcroot-abspath>
            </wc-info>
            <commit revision="1418">
              <author>alice</author>
              <date>2026-05-01T08:30:15.123456Z</date>
            </commit>
          </entry>
        </info>
        """
        let entries = try SvnXmlParsers.parseInfoXml(Data(xml.utf8))
        XCTAssertEqual(entries.count, 1)
        let info = entries[0]
        XCTAssertEqual(info.revision, "1420")
        XCTAssertEqual(info.lastChangedRev, "1418")
        XCTAssertEqual(info.lastChangedAuthor, "alice")
        XCTAssertEqual(info.wcRoot, "/Users/dev/project")
        XCTAssertEqual(info.formattedBranchName, "branches/v2-release (r1420)")

        var trunk = info
        trunk.relativeURL = "^/trunk"
        XCTAssertEqual(trunk.formattedBranchName, "trunk (r1420)")

        var root = info
        root.relativeURL = "^/"
        XCTAssertEqual(root.formattedBranchName, "root (r1420)")
    }

    func testParseStatusXmlAllStatusesChangelistsAndRemoteStatus() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <status>
          <target path=".">
            <entry path="mod.swift">
              <wc-status item="modified" props="none" revision="10"><commit revision="9"><author>bob</author></commit></wc-status>
              <repos-status item="modified" props="none"><lock><owner>carol</owner><comment>editing</comment><token>opaquelocktoken:1</token></lock></repos-status>
            </entry>
            <entry path="props-mod"><wc-status item="normal" props="modified" revision="10"/></entry>
            <entry path="added.txt"><wc-status item="added" props="none"/></entry>
            <entry path="deleted.txt"><wc-status item="deleted" props="none" revision="10"/></entry>
            <entry path="replaced.txt"><wc-status item="replaced" props="none" revision="10"/></entry>
            <entry path="conflict.txt"><wc-status item="conflicted" props="none" revision="10"/></entry>
            <entry path="tree-conflict"><wc-status item="normal" props="none" tree-conflicted="true" revision="10"/></entry>
            <entry path="missing.txt"><wc-status item="missing" props="none" revision="10"/></entry>
            <entry path="obstructed.txt"><wc-status item="obstructed" props="none" revision="10"/></entry>
            <entry path="中文 空格/file.txt"><wc-status item="unversioned" props="none"/></entry>
            <entry path="build/out.o"><wc-status item="ignored" props="none"/></entry>
            <entry path="vendor/lib"><wc-status item="external" props="none"/></entry>
            <entry path="locked.bin"><wc-status item="normal" props="none" revision="10"><lock><owner>me</owner><token>t2</token></lock></wc-status></entry>
            <against revision="15"/>
          </target>
          <changelist name="feature-cl">
            <entry path="cl-item.swift"><wc-status item="modified" props="none" revision="10"/></entry>
          </changelist>
        </status>
        """
        let res = try SvnXmlParsers.parseStatusXml(Data(xml.utf8), repoPath: "/tmp/wc")
        XCTAssertEqual(res.againstRevision, "15")

        let byPath = Dictionary(uniqueKeysWithValues: res.items.map { ($0.item.relativePath, $0) })
        XCTAssertEqual(byPath["mod.swift"]?.item.status, .modified)
        XCTAssertEqual(byPath["mod.swift"]?.remoteItemStatus, "modified")
        XCTAssertEqual(byPath["mod.swift"]?.remoteLock?.owner, "carol")
        XCTAssertEqual(byPath["props-mod"]?.item.status, .modified)
        XCTAssertEqual(byPath["added.txt"]?.item.status, .added)
        XCTAssertEqual(byPath["deleted.txt"]?.item.status, .deleted)
        XCTAssertEqual(byPath["replaced.txt"]?.item.status, .replaced)
        XCTAssertEqual(byPath["conflict.txt"]?.item.status, .unmerged)
        XCTAssertEqual(byPath["tree-conflict"]?.item.status, .unmerged)
        XCTAssertEqual(byPath["missing.txt"]?.item.status, .missing)
        XCTAssertEqual(byPath["obstructed.txt"]?.item.status, .obstructed)
        XCTAssertEqual(byPath["中文 空格/file.txt"]?.item.status, .untracked)
        XCTAssertEqual(byPath["build/out.o"]?.item.status, .ignored)
        XCTAssertEqual(byPath["vendor/lib"]?.item.status, .external)
        XCTAssertEqual(byPath["locked.bin"]?.item.status, .locked)
        XCTAssertEqual(byPath["cl-item.swift"]?.changelist, "feature-cl")
    }

    func testParseLogListBlamePropertiesAndDiffSummarizeXml() throws {
        let logXml = """
        <log>
          <logentry revision="42">
            <author>alice</author>
            <date>2026-05-02T12:00:00.000000Z</date>
            <paths>
              <path action="A" copyfrom-path="/trunk/old.swift" copyfrom-rev="40">/branches/v2/new.swift</path>
              <path action="M">/trunk/README.md</path>
            </paths>
            <msg>Implement SVN
        Details line 2</msg>
          </logentry>
        </log>
        """
        let commits = try SvnXmlParsers.parseLogXml(Data(logXml.utf8))
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits[0].hash, "42")
        XCTAssertEqual(commits[0].shortHash, "r42")
        XCTAssertEqual(commits[0].subject, "Implement SVN")
        XCTAssertEqual(commits[0].body, "Details line 2")
        XCTAssertEqual(commits[0].changedPaths.count, 2)
        XCTAssertEqual(commits[0].changedPaths[0].copyFromPath, "/trunk/old.swift")

        let listXml = """
        <lists><list path="https://svn.example.com/repo/trunk">
          <entry kind="dir"><name>Sources</name><commit revision="11"><author>a</author></commit></entry>
          <entry kind="file"><name>README.md</name><size>256</size><commit revision="12"><author>b</author></commit></entry>
        </list></lists>
        """
        let list = try SvnXmlParsers.parseListXml(Data(listXml.utf8), baseRelativePath: "trunk")
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[0].kind, .tree)
        XCTAssertEqual(list[0].path, "trunk/Sources")
        XCTAssertEqual(list[1].kind, .blob)
        XCTAssertEqual(list[1].size, 256)
        XCTAssertEqual(list[1].objectHash, "r12")

        let blameXml = """
        <blame><target path="a.swift">
          <entry line-number="1"><commit revision="5"><author>alice</author><date>2026-05-01T00:00:00.000000Z</date></commit></entry>
          <entry line-number="2"><commit revision="7"><author>bob</author></commit></entry>
        </target></blame>
        """
        let blame = try SvnXmlParsers.parseBlameXml(Data(blameXml.utf8), contentLines: ["line 1", "line 2"])
        XCTAssertEqual(blame.count, 2)
        XCTAssertEqual(blame[0].shortHash, "r5")
        XCTAssertEqual(blame[1].content, "line 2")

        let b64 = Data("*.tmp\n*.log\n".utf8).base64EncodedString()
        let propsXml = """
        <properties><target path=".">
          <property name="svn:eol-style">native</property>
          <property name="svn:ignore" encoding="base64">\(b64)</property>
        </target></properties>
        """
        let props = try SvnXmlParsers.parsePropertiesXml(Data(propsXml.utf8))
        XCTAssertEqual(props.count, 2)
        XCTAssertEqual(props[0].value, "native")
        XCTAssertEqual(props[1].value, "*.tmp\n*.log\n")

        let diffXml = """
        <diff><paths>
          <path item="added" props="none" kind="file">https://svn.example.com/repo/trunk/new.txt</path>
          <path item="deleted" props="none" kind="file">https://svn.example.com/repo/trunk/old.txt</path>
        </paths></diff>
        """
        let diffs = try SvnXmlParsers.parseDiffSummarizeXml(Data(diffXml.utf8), baseURL: "https://svn.example.com/repo/trunk")
        XCTAssertEqual(diffs.map(\.action), ["A", "D"])
        XCTAssertEqual(diffs.map(\.path), ["new.txt", "old.txt"])
    }

    func testAuthRedactionAndErrorClassifier() {
        let cmd = "svn commit -m hi --username alice --password super_secret --non-interactive"
        let redacted = SvnAuthOverrides.redactPassword(in: cmd)
        XCTAssertFalse(redacted.contains("super_secret"))
        XCTAssertTrue(redacted.contains("--password ******"))

        let authErr = "svn: E170001: Authentication failed for '<https://svn.example.com:443> Repo'"
        if case .authenticationRequired(let realm, _) = SvnErrorClassifier.classify(stderr: authErr) {
            XCTAssertEqual(realm, "https://svn.example.com:443")
        } else {
            XCTFail("Expected authenticationRequired")
        }

        let sslErr = "svn: E230001: Unable to connect: Server certificate verification failed for https://192.168.1.10/svn: issuer is not trusted"
        if case .sslCertificateUntrusted(_, let host) = SvnErrorClassifier.classify(stderr: sslErr) {
            XCTAssertEqual(host, "192.168.1.10")
        } else {
            XCTFail("Expected sslCertificateUntrusted")
        }

        XCTAssertEqual(
            SvnErrorClassifier.classify(stderr: "svn: E155004: Working copy locked; run 'svn cleanup'"),
            .workingCopyLocked(detail: "svn: E155004: Working copy locked; run 'svn cleanup'")
        )
        XCTAssertEqual(
            SvnErrorClassifier.classify(stderr: "svn: E155036: The working copy is too old; please run 'svn upgrade'"),
            .workingCopyUpgradeRequired(detail: "svn: E155036: The working copy is too old; please run 'svn upgrade'")
        )
        if case .transientLocalNetwork = SvnErrorClassifier.classify(stderr: "svn: E170013: Unable to connect\nsvn: E000050: Can't assign requested address") {
        } else {
            XCTFail("Expected transientLocalNetwork")
        }
    }
}
