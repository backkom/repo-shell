import Foundation
import RepoShellShared

public struct ResolvedGitExecutable: Equatable, Sendable {
    public var executableURL: URL
    public var extraEnvironment: [String: String]
    public var isBundled: Bool

    public init(executableURL: URL, extraEnvironment: [String: String] = [:], isBundled: Bool) {
        self.executableURL = executableURL
        self.extraEnvironment = extraEnvironment
        self.isBundled = isBundled
    }
}

public enum GitExecutableResolver {
    public static func bundledGitRoot(in bundle: Bundle = .main) -> URL? {
        guard let resourceURL = bundle.resourceURL else { return nil }
        let root = resourceURL.appendingPathComponent("git", isDirectory: true)
        let binary = root.appendingPathComponent("bin/git", isDirectory: false)
        if FileManager.default.isExecutableFile(atPath: binary.path) {
            return root
        }
        return nil
    }

    public static func resolve(
        preferences: AppPreferences,
        bundle: Bundle = .main
    ) throws -> ResolvedGitExecutable {
        let fm = FileManager.default

        if preferences.useBundledGit, let root = bundledGitRoot(in: bundle) {
            let bin = root.appendingPathComponent("bin/git", isDirectory: false)
            if isExecutableUsableOnCurrentOS(bin) {
                var env: [String: String] = [:]
                let execPath = root.appendingPathComponent("libexec/git-core", isDirectory: true)
                if fm.fileExists(atPath: execPath.path) {
                    env["GIT_EXEC_PATH"] = execPath.path
                }
                let templateDir = root.appendingPathComponent("share/git-core/templates", isDirectory: true)
                if fm.fileExists(atPath: templateDir.path) {
                    env["GIT_TEMPLATE_DIR"] = templateDir.path
                }
                return ResolvedGitExecutable(executableURL: bin, extraEnvironment: env, isBundled: true)
            }
        }

        if !preferences.useBundledGit && !preferences.externalGitPath.isEmpty {
            let custom = URL(fileURLWithPath: PathUtils.normalize(preferences.externalGitPath))
            if fm.isExecutableFile(atPath: custom.path) {
                return ResolvedGitExecutable(executableURL: custom, extraEnvironment: [:], isBundled: false)
            }
        }

        let candidates = [
            preferences.externalGitPath,
            "/opt/homebrew/bin/git",
            "/usr/local/bin/git",
            "/usr/bin/git"
        ].filter { !$0.isEmpty }

        for path in candidates {
            let url = URL(fileURLWithPath: path)
            if fm.isExecutableFile(atPath: url.path) {
                return ResolvedGitExecutable(executableURL: url, extraEnvironment: [:], isBundled: false)
            }
        }

        throw VcsError.executableNotFound("No usable git binary found")
    }

    /// Quick smoke check cached per binary path so a binary built for newer macOS gracefully falls back.
    private static var verifiedPathsLock = NSLock()
    private static var verifiedPaths: [String: Bool] = [:]

    public static func isExecutableUsableOnCurrentOS(_ url: URL) -> Bool {
        let path = url.path
        verifiedPathsLock.lock()
        if let cached = verifiedPaths[path] {
            verifiedPathsLock.unlock()
            return cached
        }
        verifiedPathsLock.unlock()

        let process = Process()
        process.executableURL = url
        process.arguments = ["--version"]
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
        verifiedPaths[path] = ok
        verifiedPathsLock.unlock()
        return ok
    }

    public static func gitVersion(executable: ResolvedGitExecutable) async -> String? {
        guard let output = try? await ProcessRunner.run(
            executableURL: executable.executableURL,
            arguments: ["--version"],
            environment: executable.extraEnvironment
        ), output.exitCode == 0 else {
            return nil
        }
        return output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
