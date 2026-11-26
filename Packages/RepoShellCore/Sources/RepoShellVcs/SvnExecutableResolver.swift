import Foundation
import RepoShellShared

public struct ResolvedSvnExecutable: Equatable, Sendable {
    public var executableURL: URL
    public var svnadminURL: URL?
    public var extraEnvironment: [String: String]
    public var isBundled: Bool

    public init(
        executableURL: URL,
        svnadminURL: URL? = nil,
        extraEnvironment: [String: String] = [:],
        isBundled: Bool = false
    ) {
        self.executableURL = executableURL
        self.svnadminURL = svnadminURL
        self.extraEnvironment = extraEnvironment
        self.isBundled = isBundled
    }
}

public enum SvnExecutableResolver {
    public static func bundledSvnRoot(in bundle: Bundle = .main) -> URL? {
        guard let resourceURL = bundle.resourceURL else { return nil }
        let root = resourceURL.appendingPathComponent("subversion", isDirectory: true)
        let binary = root.appendingPathComponent("bin/svn", isDirectory: false)
        if FileManager.default.isExecutableFile(atPath: binary.path) {
            return root
        }
        return nil
    }

    public static func resolve(
        preferences: AppPreferences,
        bundle: Bundle = .main
    ) throws -> ResolvedSvnExecutable {
        let fm = FileManager.default

        if preferences.useBundledSvn, let root = bundledSvnRoot(in: bundle) {
            let bin = root.appendingPathComponent("bin/svn", isDirectory: false)
            if isExecutableUsableOnCurrentOS(bin) {
                var env: [String: String] = [:]
                let libDir = root.appendingPathComponent("lib", isDirectory: true)
                if fm.fileExists(atPath: libDir.path) {
                    env["DYLD_LIBRARY_PATH"] = libDir.path
                }
                let adminBin = root.appendingPathComponent("bin/svnadmin", isDirectory: false)
                let adminURL = fm.isExecutableFile(atPath: adminBin.path) ? adminBin : resolveSvnadmin(near: bin)
                return ResolvedSvnExecutable(
                    executableURL: bin,
                    svnadminURL: adminURL,
                    extraEnvironment: env,
                    isBundled: true
                )
            }
        }

        let trimmedCustom = preferences.externalSvnPath.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates: [String] = []
        if !trimmedCustom.isEmpty {
            candidates.append(PathUtils.normalize(trimmedCustom))
        }
        candidates.append(contentsOf: [
            "/opt/homebrew/bin/svn",
            "/usr/local/bin/svn",
            "/usr/bin/svn"
        ])

        var seen = Set<String>()
        for path in candidates where seen.insert(path).inserted {
            let url = URL(fileURLWithPath: path)
            guard fm.isExecutableFile(atPath: url.path) else { continue }
            var env: [String: String] = [:]
            let trimmedDylib = preferences.svnDylibPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedDylib.isEmpty {
                env["DYLD_LIBRARY_PATH"] = PathUtils.normalize(trimmedDylib)
            }
            if isExecutableUsableOnCurrentOS(url, extraEnvironment: env) {
                return ResolvedSvnExecutable(
                    executableURL: url,
                    svnadminURL: resolveSvnadmin(near: url),
                    extraEnvironment: env,
                    isBundled: false
                )
            }
        }

        throw VcsError.executableNotFound(
            "No usable svn binary found (checked custom path, /opt/homebrew/bin/svn, /usr/local/bin/svn, /usr/bin/svn)."
        )
    }

    public static func resolveSvnadmin(near svnURL: URL? = nil) -> URL? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let svnURL {
            let sibling = svnURL.deletingLastPathComponent().appendingPathComponent("svnadmin").path
            candidates.append(sibling)
        }
        candidates.append(contentsOf: [
            "/opt/homebrew/bin/svnadmin",
            "/usr/local/bin/svnadmin",
            "/usr/bin/svnadmin"
        ])
        for path in candidates {
            if fm.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    private static let verifiedPathsLock = NSLock()
    private static var verifiedPaths: [String: Bool] = [:]

    public static func isExecutableUsableOnCurrentOS(
        _ url: URL,
        extraEnvironment: [String: String] = [:]
    ) -> Bool {
        let cacheKey = "\(url.path)|\(extraEnvironment["DYLD_LIBRARY_PATH"] ?? "")"
        verifiedPathsLock.lock()
        if let cached = verifiedPaths[cacheKey] {
            verifiedPathsLock.unlock()
            return cached
        }
        verifiedPathsLock.unlock()

        let process = Process()
        process.executableURL = url
        process.arguments = ["--version", "--quiet"]
        if !extraEnvironment.isEmpty {
            var env = ProcessInfo.processInfo.environment
            for (k, v) in extraEnvironment { env[k] = v }
            process.environment = env
        }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let ok: Bool
        do {
            try process.run()
            process.waitUntilExit()
            ok = process.terminationStatus == 0
        } catch {
            ok = false
        }

        verifiedPathsLock.lock()
        verifiedPaths[cacheKey] = ok
        verifiedPathsLock.unlock()
        return ok
    }

    public static func versionString(
        of executableURL: URL,
        extraEnvironment: [String: String] = [:]
    ) -> String? {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["--version", "--quiet"]
        if !extraEnvironment.isEmpty {
            var env = ProcessInfo.processInfo.environment
            for (k, v) in extraEnvironment { env[k] = v }
            process.environment = env
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }
}
