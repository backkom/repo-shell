import Foundation
import RepoShellShared

/// V2 SVN Provider blueprint placeholder conforming to VcsProvider.
/// Actual XML parsing and `svn` CLI commands will be implemented in V2.
public final class SvnProviderStub: VcsProvider {
    public let vcsType: VcsType = .svn
    public let capabilities: VcsCapability = .svnDefault

    public init() {}

    public func detectRepositoryRoot(for path: String) async -> String? {
        let fm = FileManager.default
        var current = URL(fileURLWithPath: PathUtils.normalize(path))
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: current.path, isDirectory: &isDir), !isDir.boolValue {
            current = current.deletingLastPathComponent()
        }
        var deepestSvnRoot: String?
        while true {
            let svnMarker = current.appendingPathComponent(".svn")
            if fm.fileExists(atPath: svnMarker.path) {
                deepestSvnRoot = current.path
            } else if deepestSvnRoot != nil {
                break
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return deepestSvnRoot
    }

    public func status(repoPath: String, options: VcsStatusOptions) async throws -> VcsStatusResult {
        throw VcsError.unsupportedInV1("SVN status")
    }

    public func commit(repoPath: String, options: VcsCommitOptions) async throws -> VcsCommandResult {
        throw VcsError.unsupportedInV1("SVN commit")
    }

    public func log(repoPath: String, query: VcsLogQuery) async throws -> [VcsCommit] {
        throw VcsError.unsupportedInV1("SVN log")
    }

    public func revert(repoPath: String, paths: [String]) async throws -> VcsCommandResult {
        throw VcsError.unsupportedInV1("SVN revert")
    }

    public func add(repoPath: String, paths: [String]) async throws -> VcsCommandResult {
        throw VcsError.unsupportedInV1("SVN add")
    }

    public func remove(repoPath: String, paths: [String], keepLocal: Bool) async throws -> VcsCommandResult {
        throw VcsError.unsupportedInV1("SVN delete")
    }

    public func blame(repoPath: String, path: String, revision: String?, ignoreWhitespace: Bool) async throws -> [VcsBlameLine] {
        throw VcsError.unsupportedInV1("SVN blame")
    }

    public func export(repoPath: String, revision: String, destinationPath: String, asZip: Bool) async throws -> VcsCommandResult {
        throw VcsError.unsupportedInV1("SVN export")
    }

    public func listDirectory(repoPath: String, path: String, revision: String) async throws -> [VcsTreeEntry] {
        throw VcsError.unsupportedInV1("SVN repo-browser")
    }

    public func extractFile(repoPath: String, path: String, revision: String, to destinationPath: String) async throws {
        throw VcsError.unsupportedInV1("SVN file extraction")
    }

    public func diffRevisions(repoPath: String, rev1: String, rev2: String) async throws -> [VcsChangedPath] {
        throw VcsError.unsupportedInV1("SVN diff")
    }
}
