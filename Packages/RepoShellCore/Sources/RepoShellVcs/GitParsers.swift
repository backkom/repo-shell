import Foundation
import RepoShellShared

public enum GitParsers {

    // MARK: - Porcelain v2 (-z) Status Parser

    public struct ParsedPorcelainStatus: Equatable, Sendable {
        public var branchName: String = ""
        public var branchOid: String = ""
        public var upstream: String?
        public var ahead: Int = 0
        public var behind: Int = 0
        public var entries: [VcsStatusItem] = []
    }

    public static func parsePorcelainV2Z(_ data: Data, repoPath: String) -> ParsedPorcelainStatus {
        var result = ParsedPorcelainStatus()
        let records = splitNullTerminatedRecords(data)
        var idx = 0

        while idx < records.count {
            let rec = records[idx]
            idx += 1
            if rec.isEmpty { continue }

            if rec.hasPrefix("# ") {
                parseBranchHeader(rec, into: &result)
                continue
            }

            if rec.hasPrefix("1 ") {
                if let item = parseOrdinaryEntry(rec, repoPath: repoPath) {
                    result.entries.append(item)
                }
            } else if rec.hasPrefix("2 ") {
                let origPath = idx < records.count ? records[idx] : nil
                if idx < records.count { idx += 1 }
                if let item = parseRenameCopyEntry(rec, origPath: origPath, repoPath: repoPath) {
                    result.entries.append(item)
                }
            } else if rec.hasPrefix("u ") {
                if let item = parseUnmergedEntry(rec, repoPath: repoPath) {
                    result.entries.append(item)
                }
            } else if rec.hasPrefix("? ") {
                let relPath = trimTrailingSlash(String(rec.dropFirst(2)))
                let absPath = PathUtils.normalize("\(repoPath)/\(relPath)")
                result.entries.append(VcsStatusItem(
                    relativePath: relPath,
                    absolutePath: absPath,
                    status: .untracked,
                    indexStatusCode: "?",
                    workTreeStatusCode: "?",
                    isDirectory: rec.hasSuffix("/")
                ))
            } else if rec.hasPrefix("! ") {
                let relPath = trimTrailingSlash(String(rec.dropFirst(2)))
                let absPath = PathUtils.normalize("\(repoPath)/\(relPath)")
                result.entries.append(VcsStatusItem(
                    relativePath: relPath,
                    absolutePath: absPath,
                    status: .ignored,
                    indexStatusCode: "!",
                    workTreeStatusCode: "!",
                    isDirectory: rec.hasSuffix("/")
                ))
            }
        }
        return result
    }

    private static func parseBranchHeader(_ line: String, into result: inout ParsedPorcelainStatus) {
        if line.hasPrefix("# branch.oid ") {
            result.branchOid = String(line.dropFirst("# branch.oid ".count))
        } else if line.hasPrefix("# branch.head ") {
            let head = String(line.dropFirst("# branch.head ".count))
            if head == "(detached)" {
                let short = result.branchOid.isEmpty ? "HEAD" : String(result.branchOid.prefix(7))
                result.branchName = "HEAD (\(short))"
            } else {
                result.branchName = head
            }
        } else if line.hasPrefix("# branch.upstream ") {
            result.upstream = String(line.dropFirst("# branch.upstream ".count))
        } else if line.hasPrefix("# branch.ab ") {
            let comps = line.dropFirst("# branch.ab ".count).split(separator: " ")
            for comp in comps {
                if comp.hasPrefix("+"), let val = Int(comp.dropFirst()) {
                    result.ahead = val
                } else if comp.hasPrefix("-"), let val = Int(comp.dropFirst()) {
                    result.behind = abs(val)
                }
            }
        }
    }

    private static func parseOrdinaryEntry(_ rec: String, repoPath: String) -> VcsStatusItem? {
        // Format: 1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>
        let fields = splitFixedFields(rec, count: 8)
        guard fields.count == 9 else { return nil }
        let xy = Array(fields[1])
        let sub = fields[2]
        let x: Character = xy.count > 0 ? xy[0] : "."
        let y: Character = xy.count > 1 ? xy[1] : "."
        let relPath = trimTrailingSlash(fields[8])
        let absPath = PathUtils.normalize("\(repoPath)/\(relPath)")
        let isSubmodule = sub.hasPrefix("S")

        let status = mapPorcelainXY(x: x, y: y, isSubmodule: isSubmodule)
        return VcsStatusItem(
            relativePath: relPath,
            absolutePath: absPath,
            status: status,
            indexStatusCode: x == "." ? " " : x,
            workTreeStatusCode: y == "." ? " " : y,
            isDirectory: isSubmodule || fields[8].hasSuffix("/"),
            isStaged: x != "."
        )
    }

    private static func parseRenameCopyEntry(_ rec: String, origPath: String?, repoPath: String) -> VcsStatusItem? {
        // Format: 2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <X><score> <path>
        let fields = splitFixedFields(rec, count: 9)
        guard fields.count == 10 else { return nil }
        let xy = Array(fields[1])
        let x: Character = xy.count > 0 ? xy[0] : "."
        let y: Character = xy.count > 1 ? xy[1] : "."
        let relPath = trimTrailingSlash(fields[9])
        let absPath = PathUtils.normalize("\(repoPath)/\(relPath)")

        let status: VcsFileStatus
        if x == "R" || y == "R" {
            status = .renamed
        } else if x == "C" || y == "C" {
            status = .copied
        } else {
            status = mapPorcelainXY(x: x, y: y, isSubmodule: false)
        }

        return VcsStatusItem(
            relativePath: relPath,
            absolutePath: absPath,
            originalPath: origPath,
            status: status,
            indexStatusCode: x == "." ? " " : x,
            workTreeStatusCode: y == "." ? " " : y,
            isStaged: x != "."
        )
    }

    private static func parseUnmergedEntry(_ rec: String, repoPath: String) -> VcsStatusItem? {
        // Format: u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>
        let fields = splitFixedFields(rec, count: 10)
        guard fields.count == 11 else { return nil }
        let xy = Array(fields[1])
        let x: Character = xy.count > 0 ? xy[0] : "U"
        let y: Character = xy.count > 1 ? xy[1] : "U"
        let relPath = trimTrailingSlash(fields[10])
        let absPath = PathUtils.normalize("\(repoPath)/\(relPath)")

        return VcsStatusItem(
            relativePath: relPath,
            absolutePath: absPath,
            status: .unmerged,
            indexStatusCode: x,
            workTreeStatusCode: y,
            isStaged: false
        )
    }

    public static func mapPorcelainXY(x: Character, y: Character, isSubmodule: Bool) -> VcsFileStatus {
        if x == "U" || y == "U" || (x == "A" && y == "A") || (x == "D" && y == "D") {
            return .unmerged
        }
        if y == "M" || x == "M" {
            return .modified
        }
        if y == "T" || x == "T" {
            return .typeChanged
        }
        if y == "D" && x == "." {
            return .missing
        }
        if x == "D" || y == "D" {
            return .deleted
        }
        if x == "A" || y == "A" {
            return .added
        }
        if x == "R" || y == "R" {
            return .renamed
        }
        if x == "C" || y == "C" {
            return .copied
        }
        if isSubmodule {
            return .external
        }
        return .normal
    }

    // MARK: - Folder Status Aggregation

    public static func buildFolderStatuses(from entries: [VcsStatusItem]) -> [String: VcsFileStatus] {
        var map: [String: VcsFileStatus] = [:]
        var childrenByFolder: [String: [VcsFileStatus]] = [:]

        for entry in entries {
            map[entry.relativePath] = entry.status
            guard entry.status.propagatesToParentFolder else { continue }

            var components = entry.relativePath.split(separator: "/").map(String.init)
            if !components.isEmpty {
                components.removeLast()
            }
            while true {
                let folderRel = components.joined(separator: "/")
                childrenByFolder[folderRel, default: []].append(entry.status)
                if components.isEmpty { break }
                components.removeLast()
            }
        }

        for (folderRel, childStatuses) in childrenByFolder {
            let agg = VcsFileStatus.aggregateFolderStatus(childStatuses)
            if agg != .normal {
                if let existing = map[folderRel] {
                    if agg.folderAggregationPriority < existing.folderAggregationPriority {
                        map[folderRel] = agg
                    }
                } else {
                    map[folderRel] = agg
                }
            }
        }
        return map
    }

    // MARK: - Numstat (-z)

    public static func parseNumstatZ(_ data: Data) -> [String: (additions: Int, deletions: Int)] {
        var result: [String: (Int, Int)] = [:]
        let records = splitNullTerminatedRecords(data)
        var idx = 0
        while idx < records.count {
            let rec = records[idx]
            idx += 1
            if rec.isEmpty { continue }
            let parts = rec.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3 else { continue }
            let add = Int(parts[0]) ?? 0
            let del = Int(parts[1]) ?? 0
            var path = parts[2]
            if path.isEmpty && idx + 1 < records.count {
                // -z rename format: "<add>\t<del>\t\0<old>\0<new>"
                _ = records[idx]
                path = records[idx + 1]
                idx += 2
            }
            if !path.isEmpty {
                let prev = result[path] ?? (0, 0)
                result[path] = (prev.0 + add, prev.1 + del)
            }
        }
        return result
    }

    // MARK: - Git Log Parser

    // Uses \u{1E} as record prefix and \u{1F} as field separator, combined with -z or \u{1D} before files
    public static func parseLogOutput(_ output: String) -> [VcsCommit] {
        let chunks = output.components(separatedBy: "\u{1E}")
        var commits: [VcsCommit] = []

        for chunk in chunks {
            let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            // Split header vs file changes section by \u{1D}
            let sections = chunk.components(separatedBy: "\u{1D}")
            let headerFields = sections[0].components(separatedBy: "\u{1F}")
            guard headerFields.count >= 9 else { continue }

            let hash = headerFields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let shortHash = headerFields[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let parents = headerFields[2]
                .split(separator: " ")
                .map(String.init)
                .filter { !$0.isEmpty }
            let author = headerFields[3]
            let email = headerFields[4]
            let timestamp = TimeInterval(headerFields[5].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            let date = Date(timeIntervalSince1970: timestamp)
            let refsRaw = headerFields[6].trimmingCharacters(in: .whitespacesAndNewlines)
            let refs: [String] = refsRaw.isEmpty ? [] : refsRaw
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let subject = headerFields[7]
            let body = headerFields[8].trimmingCharacters(in: .whitespacesAndNewlines)
            let noteRaw = headerFields.count > 9 ? headerFields[9].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            let note: String? = noteRaw.isEmpty ? nil : noteRaw

            var changedPaths: [VcsChangedPath] = []
            if sections.count > 1 {
                changedPaths = parseLogNumstatAndNameStatus(sections[1])
            }

            commits.append(VcsCommit(
                hash: hash,
                shortHash: shortHash,
                parents: parents,
                author: author,
                authorEmail: email,
                date: date,
                subject: subject,
                body: body,
                refs: refs,
                note: note,
                changedPaths: changedPaths
            ))
        }
        return commits
    }

    private static func parseLogNumstatAndNameStatus(_ rawSection: String) -> [VcsChangedPath] {
        // When invoked with --numstat, lines look like "<add>\t<del>\t<path>" or for rename "<add>\t<del>\told => new"
        var paths: [VcsChangedPath] = []
        let lines = rawSection.components(separatedBy: CharacterSet.newlines)
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }

            // Raw diff-tree line or numstat?
            // Check raw format: ":100644 100644 ... ... M\tpath" or numstat "<add>\t<del>\tpath"
            let parts = line.components(separatedBy: "\t")
            if line.hasPrefix(":"), parts.count >= 2 {
                let meta = parts[0].split(separator: " ")
                let actionToken = meta.last.map(String.init) ?? "M"
                let action = String(actionToken.prefix(1))
                if (action == "R" || action == "C"), parts.count >= 3 {
                    let oldPath = parts[1]
                    let newPath = parts[2]
                    if let existingIdx = paths.firstIndex(where: { $0.path == newPath }) {
                        paths[existingIdx].action = action
                        paths[existingIdx].copyFromPath = oldPath
                    } else {
                        paths.append(VcsChangedPath(action: action, path: newPath, copyFromPath: oldPath))
                    }
                } else {
                    let path = parts[1]
                    if let existingIdx = paths.firstIndex(where: { $0.path == path }) {
                        paths[existingIdx].action = action
                    } else {
                        paths.append(VcsChangedPath(action: action, path: path))
                    }
                }
            } else if parts.count >= 3 {
                let add = Int(parts[0])
                let del = Int(parts[1])
                let pathField = parts[2]
                if let existingIdx = paths.firstIndex(where: { $0.path == pathField }) {
                    paths[existingIdx].additions = add
                    paths[existingIdx].deletions = del
                } else {
                    paths.append(VcsChangedPath(
                        action: "M",
                        path: pathField,
                        additions: add,
                        deletions: del
                    ))
                }
            }
        }
        return paths
    }

    // MARK: - References Parser (for-each-ref)

    public static func parseReferences(_ output: String) -> [GitReference] {
        var refs: [GitReference] = []
        let lines = output.components(separatedBy: "\u{1E}")
        for raw in lines {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            let fields = trimmed.components(separatedBy: "\u{1F}")
            guard fields.count >= 7 else { continue }

            let fullName = fields[0]
            let shortName = fields[1]
            let objHash = fields[2]
            let headMarker = fields[3]
            let upstream = fields[4].isEmpty ? nil : fields[4]
            let track = fields[5].isEmpty ? nil : fields[5]
            let timestamp = TimeInterval(fields[6]) ?? 0
            let subject = fields.count > 7 ? fields[7] : ""

            let kind: GitReferenceKind
            if fullName.hasPrefix("refs/heads/") {
                kind = .localBranch
            } else if fullName.hasPrefix("refs/remotes/") {
                if shortName.hasSuffix("/HEAD") { continue }
                kind = .remoteBranch
            } else if fullName.hasPrefix("refs/tags/") {
                kind = .tag
            } else {
                continue
            }

            refs.append(GitReference(
                fullName: fullName,
                shortName: shortName,
                kind: kind,
                objectHash: objHash,
                isCurrent: headMarker == "*",
                upstream: upstream,
                aheadBehind: track,
                lastCommitSubject: subject,
                lastCommitDate: timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
            ))
        }
        return refs
    }

    // MARK: - Remotes Parser (git remote -v)

    public static func parseRemotes(_ output: String) -> [GitRemote] {
        var map: [String: (fetch: String?, push: String?)] = [:]
        var order: [String] = []
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard parts.count >= 2 else { continue }
            let name = parts[0]
            let url = parts[1]
            let kind = parts.count >= 3 ? parts[2] : "(fetch)"
            if map[name] == nil { order.append(name) }
            var current = map[name] ?? (nil, nil)
            if kind.contains("push") {
                current.push = url
            } else {
                current.fetch = url
            }
            map[name] = current
        }
        return order.compactMap { name in
            guard let entry = map[name] else { return nil }
            let fetch = entry.fetch ?? entry.push ?? ""
            return GitRemote(name: name, fetchURL: fetch, pushURL: entry.push ?? fetch)
        }
    }

    // MARK: - Stash List Parser

    public static func parseStashList(_ output: String) -> [GitStashEntry] {
        var entries: [GitStashEntry] = []
        let lines = output.components(separatedBy: "\u{1E}")
        for (idx, raw) in lines.enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            let fields = trimmed.components(separatedBy: "\u{1F}")
            guard fields.count >= 5 else { continue }
            let refName = fields[0] // stash@{0}
            let hash = fields[1]
            let shortHash = fields[2]
            let ts = TimeInterval(fields[3]) ?? 0
            let rawMsg = fields[4]

            var branchName = ""
            var message = rawMsg
            if let colonRange = rawMsg.range(of: ": ") {
                let prefix = String(rawMsg[..<colonRange.lowerBound])
                message = String(rawMsg[colonRange.upperBound...])
                if let onRange = prefix.range(of: " on ") {
                    branchName = String(prefix[onRange.upperBound...])
                } else if let wipRange = prefix.range(of: "WIP on ") {
                    branchName = String(prefix[wipRange.upperBound...])
                }
            }

            entries.append(GitStashEntry(
                index: idx,
                refName: refName,
                commitHash: hash,
                shortHash: shortHash,
                branchName: branchName,
                message: message,
                date: Date(timeIntervalSince1970: ts)
            ))
        }
        return entries
    }

    // MARK: - Blame Porcelain Parser

    public static func parseBlamePorcelain(_ output: String) -> [VcsBlameLine] {
        var linesResult: [VcsBlameLine] = []
        let rawLines = output.components(separatedBy: "\n")

        var commitMetadata: [String: (author: String, time: TimeInterval, summary: String)] = [:]
        var idx = 0

        while idx < rawLines.count {
            let header = rawLines[idx]
            idx += 1
            if header.isEmpty { continue }

            let parts = header.split(separator: " ").map(String.init)
            guard parts.count >= 3, parts[0].count >= 40 else { continue }

            let commitHash = parts[0]
            let origLine = Int(parts[1]) ?? 0
            let finalLine = Int(parts[2]) ?? 0

            var author = commitMetadata[commitHash]?.author ?? ""
            var authorTime = commitMetadata[commitHash]?.time ?? 0
            var summary = commitMetadata[commitHash]?.summary ?? ""
            var content = ""

            while idx < rawLines.count {
                let subLine = rawLines[idx]
                idx += 1
                if subLine.hasPrefix("\t") {
                    content = String(subLine.dropFirst())
                    break
                } else if subLine.hasPrefix("author ") {
                    author = String(subLine.dropFirst("author ".count))
                } else if subLine.hasPrefix("author-time ") {
                    authorTime = TimeInterval(String(subLine.dropFirst("author-time ".count))) ?? 0
                } else if subLine.hasPrefix("summary ") {
                    summary = String(subLine.dropFirst("summary ".count))
                }
            }

            commitMetadata[commitHash] = (author, authorTime, summary)
            linesResult.append(VcsBlameLine(
                lineNumber: finalLine,
                originalLineNumber: origLine,
                commitHash: commitHash,
                shortHash: String(commitHash.prefix(8)),
                author: author,
                date: authorTime > 0 ? Date(timeIntervalSince1970: authorTime) : nil,
                summary: summary,
                content: content
            ))
        }
        return linesResult
    }

    // MARK: - ls-tree (-l -z) Parser

    public static func parseLsTreeZ(_ data: Data) -> [VcsTreeEntry] {
        let records = splitNullTerminatedRecords(data)
        var entries: [VcsTreeEntry] = []

        for rec in records {
            if rec.isEmpty { continue }
            guard let tabIdx = rec.firstIndex(of: "\t") else { continue }
            let meta = String(rec[..<tabIdx])
            let fullPath = String(rec[rec.index(after: tabIdx)...])
            let metaParts = meta.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard metaParts.count >= 4 else { continue }

            let mode = metaParts[0]
            let typeStr = metaParts[1]
            let hash = metaParts[2]
            let sizeStr = metaParts[3]

            let kind: VcsTreeEntry.EntryKind
            switch typeStr {
            case "tree": kind = .tree
            case "commit": kind = .submodule
            default: kind = .blob
            }

            let name = URL(fileURLWithPath: fullPath).lastPathComponent
            entries.append(VcsTreeEntry(
                mode: mode,
                kind: kind,
                objectHash: hash,
                size: Int64(sizeStr),
                name: name,
                path: fullPath
            ))
        }
        return entries
    }

    // MARK: - RefLog Parser

    public static func parseRefLog(_ output: String) -> [GitRefLogEntry] {
        var entries: [GitRefLogEntry] = []
        let chunks = output.components(separatedBy: "\u{1E}")
        for (idx, chunk) in chunks.enumerated() {
            let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            let fields = trimmed.components(separatedBy: "\u{1F}")
            guard fields.count >= 5 else { continue }
            let hash = fields[0]
            let shortHash = fields[1]
            let selector = fields[2]
            let ts = TimeInterval(fields[3]) ?? 0
            let rawSubject = fields[4]

            var actionSummary = rawSubject
            var message = rawSubject
            if let colonRange = rawSubject.range(of: ": ") {
                actionSummary = String(rawSubject[..<colonRange.lowerBound])
                message = String(rawSubject[colonRange.upperBound...])
            }

            entries.append(GitRefLogEntry(
                index: idx,
                selector: selector,
                hash: hash,
                shortHash: shortHash,
                actionSummary: actionSummary,
                message: message,
                date: Date(timeIntervalSince1970: ts)
            ))
        }
        return entries
    }

    // MARK: - Submodule Parser

    public static func parseSubmoduleStatus(_ output: String, urlByPath: [String: String], branchByPath: [String: String]) -> [GitSubmodule] {
        var items: [GitSubmodule] = []
        for line in output.components(separatedBy: .newlines) {
            if line.count < 42 { continue }
            let marker = line.first!
            let rest = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            let parts = rest.split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count >= 2 else { continue }
            let hash = parts[0]
            let path = parts[1]

            let stateDesc: String
            switch marker {
            case "-": stateDesc = "Uninitialized"
            case "+": stateDesc = "Modified commit"
            case "U": stateDesc = "Merge conflict"
            default: stateDesc = "Clean"
            }

            items.append(GitSubmodule(
                name: path,
                path: path,
                url: urlByPath[path] ?? "",
                branch: branchByPath[path],
                commitHash: hash,
                stateDescription: stateDesc
            ))
        }
        return items
    }

    // MARK: - Diff --name-status + --numstat Parser

    public static func parseCompareDiff(nameStatusOutput: String, numstatOutput: String) -> [VcsChangedPath] {
        var statsMap: [String: (Int?, Int?)] = [:]
        for line in numstatOutput.components(separatedBy: .newlines) {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 3 else { continue }
            let add = Int(parts[0])
            let del = Int(parts[1])
            let path = parts.last ?? ""
            statsMap[path] = (add, del)
        }

        var results: [VcsChangedPath] = []
        for line in nameStatusOutput.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let parts = trimmed.components(separatedBy: "\t")
            guard parts.count >= 2 else { continue }
            let action = String(parts[0].prefix(1))
            if (action == "R" || action == "C"), parts.count >= 3 {
                let oldPath = parts[1]
                let newPath = parts[2]
                let st = statsMap[newPath]
                results.append(VcsChangedPath(
                    action: action,
                    path: newPath,
                    copyFromPath: oldPath,
                    additions: st?.0,
                    deletions: st?.1
                ))
            } else {
                let path = parts[1]
                let st = statsMap[path]
                results.append(VcsChangedPath(
                    action: action,
                    path: path,
                    additions: st?.0,
                    deletions: st?.1
                ))
            }
        }
        return results
    }

    // MARK: - Helpers

    public static func splitNullTerminatedRecords(_ data: Data) -> [String] {
        data.split(separator: 0x00, omittingEmptySubsequences: false).compactMap { slice in
            String(data: Data(slice), encoding: .utf8) ?? String(decoding: slice, as: UTF8.self)
        }
    }

    private static func splitFixedFields(_ str: String, count: Int) -> [String] {
        var fields: [String] = []
        var currentStart = str.startIndex
        for _ in 0..<count {
            guard let spaceIdx = str[currentStart...].firstIndex(of: " ") else { break }
            fields.append(String(str[currentStart..<spaceIdx]))
            currentStart = str.index(after: spaceIdx)
        }
        fields.append(String(str[currentStart...]))
        return fields
    }

    private static func trimTrailingSlash(_ path: String) -> String {
        var s = path
        while s.count > 1 && s.hasSuffix("/") {
            s.removeLast()
        }
        return s
    }
}
