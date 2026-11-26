import Foundation
import RepoShellShared

public enum SvnXmlParsers {

    // MARK: - Date Helper

    private static func parseIsoDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = frac.date(from: trimmed) {
            return d
        }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: trimmed)
    }

    // MARK: - svn info --xml

    public static func parseInfoXml(_ data: Data) throws -> [SvnInfoResult] {
        let delegate = InfoXmlDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw VcsError.parseError(parser.parserError?.localizedDescription ?? "Invalid svn info XML")
        }
        return delegate.results
    }

    private final class InfoXmlDelegate: NSObject, XMLParserDelegate {
        var results: [SvnInfoResult] = []
        private var current: SvnInfoResult?
        private var currentText = ""
        private var inCommit = false
        private var inLock = false
        private var currentLock: SvnLockEntry?

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            currentText = ""
            switch elementName {
            case "entry":
                current = SvnInfoResult(
                    path: attributeDict["path"] ?? "",
                    revision: attributeDict["revision"] ?? "",
                    nodeKind: attributeDict["kind"] ?? ""
                )
            case "commit":
                inCommit = true
                if let rev = attributeDict["revision"] {
                    current?.lastChangedRev = rev
                }
            case "lock":
                inLock = true
                currentLock = SvnLockEntry()
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            currentText += string
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            switch elementName {
            case "url":
                current?.url = trimmed
            case "relative-url":
                current?.relativeURL = trimmed
            case "root":
                current?.repositoryRoot = trimmed
            case "uuid":
                current?.repositoryUUID = trimmed
            case "wcroot-abspath":
                if !trimmed.isEmpty { current?.wcRoot = trimmed }
            case "author":
                if inCommit { current?.lastChangedAuthor = trimmed }
            case "date":
                if inCommit { current?.lastChangedDate = parseIsoDate(trimmed) }
            case "token":
                if inLock { currentLock?.token = trimmed }
            case "owner":
                if inLock { currentLock?.owner = trimmed }
            case "comment":
                if inLock { currentLock?.comment = trimmed }
            case "created":
                if inLock { currentLock?.created = parseIsoDate(trimmed) }
            case "commit":
                inCommit = false
            case "lock":
                if let lock = currentLock { current?.lock = lock }
                currentLock = nil
                inLock = false
            case "entry":
                if let item = current { results.append(item) }
                current = nil
            default:
                break
            }
            currentText = ""
        }
    }

    // MARK: - svn status --xml

    public static func parseStatusXml(_ data: Data, repoPath: String) throws -> SvnDetailedStatusResult {
        let normalizedRepo = PathUtils.normalize(repoPath)
        let delegate = StatusXmlDelegate(repoPath: normalizedRepo)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw VcsError.parseError(parser.parserError?.localizedDescription ?? "Invalid svn status XML")
        }
        return SvnDetailedStatusResult(items: delegate.items, againstRevision: delegate.againstRevision)
    }

    public static func mapStatus(
        itemStatus: String,
        propsStatus: String,
        treeConflicted: Bool,
        hasLocalLock: Bool
    ) -> VcsFileStatus {
        if treeConflicted || itemStatus == "conflicted" || propsStatus == "conflicted" {
            return .unmerged
        }
        switch itemStatus {
        case "missing", "incomplete":
            return .missing
        case "obstructed":
            return .obstructed
        case "replaced":
            return .replaced
        case "added":
            return .added
        case "deleted":
            return .deleted
        case "modified":
            return .modified
        case "external":
            return .external
        case "ignored":
            return .ignored
        case "unversioned":
            return .untracked
        case "normal", "none":
            if propsStatus == "modified" {
                return .modified
            }
            if hasLocalLock {
                return .locked
            }
            return .normal
        default:
            return .modified
        }
    }

    private static func statusChar(for itemStatus: String) -> Character {
        switch itemStatus {
        case "added": return "A"
        case "deleted": return "D"
        case "modified": return "M"
        case "replaced": return "R"
        case "conflicted": return "C"
        case "missing": return "!"
        case "obstructed": return "~"
        case "external": return "X"
        case "ignored": return "I"
        case "unversioned": return "?"
        default: return " "
        }
    }

    private final class StatusXmlDelegate: NSObject, XMLParserDelegate {
        let repoPath: String
        var items: [SvnDetailedStatusItem] = []
        var againstRevision: String?

        private var activeChangelist: String?
        private var currentEntryPath: String?
        private var itemStatus = "none"
        private var propsStatus = "none"
        private var revision: String?
        private var wcLocked = false
        private var switched = false
        private var copied = false
        private var treeConflicted = false
        private var commitRev: String?
        private var commitAuthor: String?
        private var commitDate: Date?
        private var localLock: SvnLockEntry?

        private var remoteItemStatus: String?
        private var remotePropsStatus: String?
        private var remoteRev: String?
        private var remoteAuthor: String?
        private var remoteLock: SvnLockEntry?

        private var inWcStatus = false
        private var inReposStatus = false
        private var inCommit = false
        private var inLock = false
        private var buildingLock: SvnLockEntry?
        private var currentText = ""

        init(repoPath: String) {
            self.repoPath = repoPath
        }

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            currentText = ""
            switch elementName {
            case "changelist":
                activeChangelist = attributeDict["name"]
            case "against":
                againstRevision = attributeDict["revision"]
            case "entry":
                currentEntryPath = attributeDict["path"]
                itemStatus = "none"
                propsStatus = "none"
                revision = nil
                wcLocked = false
                switched = false
                copied = false
                treeConflicted = false
                commitRev = nil
                commitAuthor = nil
                commitDate = nil
                localLock = nil
                remoteItemStatus = nil
                remotePropsStatus = nil
                remoteRev = nil
                remoteAuthor = nil
                remoteLock = nil
            case "wc-status":
                inWcStatus = true
                itemStatus = attributeDict["item"] ?? "none"
                propsStatus = attributeDict["props"] ?? "none"
                revision = attributeDict["revision"]
                wcLocked = attributeDict["wc-locked"] == "true"
                switched = attributeDict["switched"] == "true"
                copied = attributeDict["copied"] == "true"
                treeConflicted = attributeDict["tree-conflicted"] == "true"
            case "repos-status":
                inReposStatus = true
                remoteItemStatus = attributeDict["item"]
                remotePropsStatus = attributeDict["props"]
            case "commit":
                inCommit = true
                let rev = attributeDict["revision"]
                if inReposStatus {
                    remoteRev = rev
                } else {
                    commitRev = rev
                }
            case "lock":
                inLock = true
                buildingLock = SvnLockEntry()
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            currentText += string
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            switch elementName {
            case "author":
                if inCommit {
                    if inReposStatus {
                        remoteAuthor = trimmed
                    } else {
                        commitAuthor = trimmed
                    }
                }
            case "date":
                if inCommit && !inReposStatus {
                    commitDate = parseIsoDate(trimmed)
                }
            case "token":
                if inLock { buildingLock?.token = trimmed }
            case "owner":
                if inLock { buildingLock?.owner = trimmed }
            case "comment":
                if inLock { buildingLock?.comment = trimmed }
            case "created":
                if inLock { buildingLock?.created = parseIsoDate(trimmed) }
            case "commit":
                inCommit = false
            case "lock":
                if let built = buildingLock {
                    if inReposStatus {
                        remoteLock = built
                    } else if inWcStatus {
                        localLock = built
                    }
                }
                buildingLock = nil
                inLock = false
            case "wc-status":
                inWcStatus = false
            case "repos-status":
                inReposStatus = false
            case "entry":
                if let rawPath = currentEntryPath {
                    let absPath: String
                    if rawPath.hasPrefix("/") {
                        absPath = PathUtils.normalize(rawPath)
                    } else if rawPath == "." || rawPath.isEmpty {
                        absPath = repoPath
                    } else {
                        absPath = PathUtils.normalize("\(repoPath)/\(rawPath)")
                    }
                    let relPath = PathUtils.relativePath(of: absPath, inside: repoPath) ?? rawPath
                    let mappedStatus = SvnXmlParsers.mapStatus(
                        itemStatus: itemStatus,
                        propsStatus: propsStatus,
                        treeConflicted: treeConflicted,
                        hasLocalLock: localLock != nil
                    )
                    var isDir: ObjCBool = false
                    _ = FileManager.default.fileExists(atPath: absPath, isDirectory: &isDir)

                    let code = SvnXmlParsers.statusChar(for: itemStatus)
                    let vcsItem = VcsStatusItem(
                        relativePath: relPath,
                        absolutePath: absPath,
                        originalPath: nil,
                        status: mappedStatus,
                        indexStatusCode: code,
                        workTreeStatusCode: code,
                        isDirectory: isDir.boolValue,
                        isStaged: false
                    )
                    items.append(SvnDetailedStatusItem(
                        item: vcsItem,
                        itemStatus: itemStatus,
                        propsStatus: propsStatus,
                        revision: revision,
                        commitRevision: commitRev,
                        commitAuthor: commitAuthor,
                        commitDate: commitDate,
                        wcLocked: wcLocked,
                        switched: switched,
                        copied: copied,
                        treeConflicted: treeConflicted,
                        changelist: activeChangelist,
                        localLock: localLock,
                        remoteItemStatus: remoteItemStatus,
                        remotePropsStatus: remotePropsStatus,
                        remoteRevision: remoteRev,
                        remoteAuthor: remoteAuthor,
                        remoteLock: remoteLock
                    ))
                }
                currentEntryPath = nil
            case "changelist":
                activeChangelist = nil
            default:
                break
            }
            currentText = ""
        }
    }

    // MARK: - svn log --xml

    public static func parseLogXml(_ data: Data) throws -> [VcsCommit] {
        let delegate = LogXmlDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw VcsError.parseError(parser.parserError?.localizedDescription ?? "Invalid svn log XML")
        }
        return delegate.commits
    }

    private final class LogXmlDelegate: NSObject, XMLParserDelegate {
        var commits: [VcsCommit] = []
        private var currentRev = ""
        private var author = ""
        private var date = Date(timeIntervalSince1970: 0)
        private var msg = ""
        private var changedPaths: [VcsChangedPath] = []
        private var currentPathAction = "M"
        private var copyFromPath: String?
        private var currentText = ""

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            currentText = ""
            switch elementName {
            case "logentry":
                currentRev = attributeDict["revision"] ?? ""
                author = ""
                date = Date(timeIntervalSince1970: 0)
                msg = ""
                changedPaths = []
            case "path":
                currentPathAction = attributeDict["action"] ?? "M"
                copyFromPath = attributeDict["copyfrom-path"]
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            currentText += string
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            switch elementName {
            case "author":
                author = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            case "date":
                date = parseIsoDate(currentText) ?? Date(timeIntervalSince1970: 0)
            case "msg":
                msg = currentText.trimmingCharacters(in: .newlines)
            case "path":
                let trimmedPath = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedPath.isEmpty {
                    changedPaths.append(VcsChangedPath(
                        action: currentPathAction,
                        path: trimmedPath,
                        copyFromPath: copyFromPath
                    ))
                }
            case "logentry":
                let lines = msg.components(separatedBy: .newlines)
                let subject = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let body = lines.count > 1
                    ? lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    : ""
                commits.append(VcsCommit(
                    hash: currentRev,
                    shortHash: "r\(currentRev)",
                    parents: [],
                    author: author.isEmpty ? "(no author)" : author,
                    authorEmail: "",
                    date: date,
                    subject: subject.isEmpty ? "(no message)" : subject,
                    body: body,
                    refs: [],
                    note: nil,
                    changedPaths: changedPaths
                ))
            default:
                break
            }
            currentText = ""
        }
    }

    // MARK: - svn list --xml

    public static func parseListXml(_ data: Data, baseRelativePath: String = "") throws -> [VcsTreeEntry] {
        let delegate = ListXmlDelegate(baseRelativePath: baseRelativePath)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw VcsError.parseError(parser.parserError?.localizedDescription ?? "Invalid svn list XML")
        }
        return delegate.entries
    }

    private final class ListXmlDelegate: NSObject, XMLParserDelegate {
        let baseRelativePath: String
        var entries: [VcsTreeEntry] = []

        private var kind = "file"
        private var name = ""
        private var size: Int64?
        private var commitRev = ""
        private var inCommit = false
        private var currentText = ""

        init(baseRelativePath: String) {
            self.baseRelativePath = baseRelativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            currentText = ""
            switch elementName {
            case "entry":
                kind = attributeDict["kind"] ?? "file"
                name = ""
                size = nil
                commitRev = ""
            case "commit":
                inCommit = true
                commitRev = attributeDict["revision"] ?? ""
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            currentText += string
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            switch elementName {
            case "name":
                name = trimmed
            case "size":
                size = Int64(trimmed)
            case "commit":
                inCommit = false
            case "entry":
                guard !name.isEmpty else { break }
                let fullRel = baseRelativePath.isEmpty ? name : "\(baseRelativePath)/\(name)"
                let entryKind: VcsTreeEntry.EntryKind = (kind == "dir") ? .tree : .blob
                let mode = (kind == "dir") ? "040000" : "100644"
                entries.append(VcsTreeEntry(
                    mode: mode,
                    kind: entryKind,
                    objectHash: commitRev.isEmpty ? "" : "r\(commitRev)",
                    size: entryKind == .blob ? size : nil,
                    name: name,
                    path: fullRel
                ))
            default:
                break
            }
            currentText = ""
        }
    }

    // MARK: - svn blame --xml

    public static func parseBlameXml(_ data: Data, contentLines: [String]) throws -> [VcsBlameLine] {
        let delegate = BlameXmlDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw VcsError.parseError(parser.parserError?.localizedDescription ?? "Invalid svn blame XML")
        }

        return delegate.rawEntries.map { raw in
            let lineIdx = raw.lineNumber - 1
            let content = (lineIdx >= 0 && lineIdx < contentLines.count) ? contentLines[lineIdx] : ""
            return VcsBlameLine(
                lineNumber: raw.lineNumber,
                originalLineNumber: raw.lineNumber,
                commitHash: raw.revision,
                shortHash: raw.revision.isEmpty ? "-" : "r\(raw.revision)",
                author: raw.author.isEmpty ? "-" : raw.author,
                date: raw.date,
                summary: "",
                content: content
            )
        }
    }

    private final class BlameXmlDelegate: NSObject, XMLParserDelegate {
        struct RawEntry {
            var lineNumber: Int
            var revision: String = ""
            var author: String = ""
            var date: Date?
        }

        var rawEntries: [RawEntry] = []
        private var current: RawEntry?
        private var currentText = ""

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            currentText = ""
            switch elementName {
            case "entry":
                let num = Int(attributeDict["line-number"] ?? "") ?? (rawEntries.count + 1)
                current = RawEntry(lineNumber: num)
            case "commit":
                current?.revision = attributeDict["revision"] ?? ""
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            currentText += string
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            switch elementName {
            case "author":
                current?.author = trimmed
            case "date":
                current?.date = parseIsoDate(trimmed)
            case "entry":
                if let entry = current { rawEntries.append(entry) }
                current = nil
            default:
                break
            }
            currentText = ""
        }
    }

    // MARK: - svn proplist --xml -v

    public static func parsePropertiesXml(_ data: Data) throws -> [SvnPropertyEntry] {
        let delegate = ProplistXmlDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw VcsError.parseError(parser.parserError?.localizedDescription ?? "Invalid svn proplist XML")
        }
        return delegate.properties
    }

    private final class ProplistXmlDelegate: NSObject, XMLParserDelegate {
        var properties: [SvnPropertyEntry] = []
        private var propName: String?
        private var isBase64 = false
        private var currentText = ""

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            currentText = ""
            if elementName == "property" {
                propName = attributeDict["name"]
                isBase64 = attributeDict["encoding"] == "base64"
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            currentText += string
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            if elementName == "property", let name = propName {
                let value: String
                if isBase64, let rawData = Data(base64Encoded: currentText.trimmingCharacters(in: .whitespacesAndNewlines)),
                   let decoded = String(data: rawData, encoding: .utf8) {
                    value = decoded
                } else {
                    value = currentText
                }
                properties.append(SvnPropertyEntry(name: name, value: value))
                propName = nil
                isBase64 = false
            }
            currentText = ""
        }
    }

    // MARK: - svn diff --summarize --xml

    public static func parseDiffSummarizeXml(_ data: Data, baseURL: String? = nil) throws -> [VcsChangedPath] {
        let delegate = DiffSummarizeXmlDelegate(baseURL: baseURL)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw VcsError.parseError(parser.parserError?.localizedDescription ?? "Invalid svn diff --summarize XML")
        }
        return delegate.paths
    }

    private final class DiffSummarizeXmlDelegate: NSObject, XMLParserDelegate {
        let baseURL: String?
        var paths: [VcsChangedPath] = []
        private var itemAction = "M"
        private var currentText = ""

        init(baseURL: String?) {
            if let baseURL, !baseURL.isEmpty {
                self.baseURL = baseURL.hasSuffix("/") ? baseURL : "\(baseURL)/"
            } else {
                self.baseURL = nil
            }
        }

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            currentText = ""
            if elementName == "path" {
                let item = attributeDict["item"] ?? "modified"
                let props = attributeDict["props"] ?? "none"
                switch item {
                case "added": itemAction = "A"
                case "deleted": itemAction = "D"
                case "replaced": itemAction = "R"
                case "modified": itemAction = "M"
                default: itemAction = (props == "modified") ? "M" : "M"
                }
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            currentText += string
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            if elementName == "path" {
                var rel = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                if let baseURL, rel.hasPrefix(baseURL) {
                    rel = String(rel.dropFirst(baseURL.count))
                }
                if !rel.isEmpty {
                    paths.append(VcsChangedPath(action: itemAction, path: rel))
                }
            }
            currentText = ""
        }
    }
}
