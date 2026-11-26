import Cocoa
import Foundation
import RepoShellShared
import RepoShellServices
import RepoShellVcs

@MainActor
final class AppUpdateController: NSObject, ObservableObject, URLSessionDownloadDelegate {
    enum UpdatePhase: Equatable {
        case idle
        case checking
        case upToDate(Date)
        case available(AppUpdateState)
        case downloading(progress: Double, update: AppUpdateState)
        case installing(AppUpdateState)
        case failed(String)
    }

    @Published private(set) var phase: UpdatePhase = .idle
    @Published private(set) var availableUpdate: AppUpdateState?

    private let storage: SharedStorage
    private var periodicTimer: Timer?
    private var initialCheckTask: Task<Void, Never>?
    private var downloadSession: URLSession?
    private var activeDownloadTask: URLSessionDownloadTask?
    private var downloadContinuation: CheckedContinuation<URL, Error>?
    private var activeDownloadUpdate: AppUpdateState?
    private var isCancelledByUser = false

    init(storage: SharedStorage = .shared) {
        self.storage = storage
        super.init()
    }

    func start() {
        syncCachedStateWithCurrentVersion()

        initialCheckTask?.cancel()
        initialCheckTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self else { return }
            if self.storage.loadConfig().preferences.autoCheckUpdates {
                await self.checkForUpdates(userInitiated: false)
            }
        }

        periodicTimer?.invalidate()
        periodicTimer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.storage.loadConfig().preferences.autoCheckUpdates {
                    await self.checkForUpdates(userInitiated: false)
                }
            }
        }
    }

    func stop() {
        initialCheckTask?.cancel()
        initialCheckTask = nil
        periodicTimer?.invalidate()
        periodicTimer = nil
    }

    func checkForUpdates(userInitiated: Bool) async {
        switch phase {
        case .checking, .downloading, .installing:
            if userInitiated, availableUpdate != nil {
                AppContainer.shared.windowCoordinator.openUpdateWindow()
            }
            return
        default:
            break
        }

        phase = .checking
        do {
            let result = try await AppUpdateClient().checkForUpdate(
                repoSlug: AppConstants.githubRepoSlug,
                currentVersion: AppConstants.currentVersion
            )
            switch result {
            case .updateAvailable(let info):
                applyAvailableUpdate(info)
                if userInitiated {
                    AppContainer.shared.windowCoordinator.openUpdateWindow()
                }
            case .upToDate(_, _), .noPublishedRelease:
                clearAvailableUpdate(nextPhase: .upToDate(Date()))
                if userInitiated {
                    AlertHelper.showInfo(
                        L("You're Up to Date", "已是最新版本"),
                        message: String(
                            format: L("RepoShell %@ is currently the newest version available.", "当前 RepoShell %@ 已是最新版本。"),
                            AppConstants.currentVersion
                        )
                    )
                }
            }
        } catch {
            if let existing = availableUpdate {
                phase = .available(existing)
            } else {
                phase = .failed(error.localizedDescription)
            }
            if userInitiated {
                AlertHelper.showError(error, title: L("Update Check Failed", "检查更新失败"))
            }
        }
    }

    func startUpgrade() {
        if let update = availableUpdate {
            AppContainer.shared.windowCoordinator.openUpdateWindow()
            installUpdate(update)
            return
        }
        Task {
            await checkForUpdates(userInitiated: true)
            if let update = availableUpdate {
                AppContainer.shared.windowCoordinator.openUpdateWindow()
                installUpdate(update)
            }
        }
    }

    func installUpdate(_ update: AppUpdateState) {
        switch phase {
        case .downloading, .installing:
            return
        default:
            break
        }

        guard let urlStr = update.downloadURL, let downloadURL = URL(string: urlStr) else {
            if let pageURL = URL(string: update.htmlURL) {
                NSWorkspace.shared.open(pageURL)
            }
            return
        }

        isCancelledByUser = false
        activeDownloadUpdate = update
        phase = .downloading(progress: 0, update: update)

        Task {
            do {
                let archiveURL = try await downloadArchive(from: downloadURL)
                phase = .installing(update)
                try await stageAndLaunchUpdater(archiveURL: archiveURL, assetName: update.assetName ?? downloadURL.lastPathComponent)
            } catch is CancellationError {
                activeDownloadUpdate = nil
                phase = .available(update)
            } catch {
                activeDownloadUpdate = nil
                if isCancelledByUser {
                    phase = .available(update)
                } else {
                    phase = .failed(error.localizedDescription)
                    AlertHelper.showError(error, title: L("Upgrade Failed", "升级失败"))
                }
            }
        }
    }

    func cancelDownload() {
        isCancelledByUser = true
        activeDownloadTask?.cancel()
        activeDownloadTask = nil
        downloadSession?.invalidateAndCancel()
        downloadSession = nil
        if let cont = downloadContinuation {
            downloadContinuation = nil
            cont.resume(throwing: CancellationError())
        }
        if let update = availableUpdate {
            phase = .available(update)
        } else {
            phase = .idle
        }
    }

    // MARK: - URLSessionDownloadDelegate

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let progress: Double
        if totalBytesExpectedToWrite > 0 {
            progress = min(1.0, max(0.0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
        } else {
            progress = 0.0
        }
        Task { @MainActor [weak self] in
            guard let self, let update = self.activeDownloadUpdate else { return }
            if case .downloading = self.phase {
                self.phase = .downloading(progress: progress, update: update)
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Must copy the temp file synchronously before delegate method returns.
        let tempCopy = FileManager.default.temporaryDirectory
            .appendingPathComponent("reposhell-download-\(UUID().uuidString)-\(downloadTask.originalRequest?.url?.lastPathComponent ?? "update.zip")")
        do {
            try? FileManager.default.removeItem(at: tempCopy)
            try FileManager.default.copyItem(at: location, to: tempCopy)
            Task { @MainActor [weak self] in
                guard let self else { return }
                let cont = self.downloadContinuation
                self.downloadContinuation = nil
                self.activeDownloadTask = nil
                self.downloadSession?.finishTasksAndInvalidate()
                self.downloadSession = nil
                cont?.resume(returning: tempCopy)
            }
        } catch {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let cont = self.downloadContinuation
                self.downloadContinuation = nil
                self.activeDownloadTask = nil
                self.downloadSession?.finishTasksAndInvalidate()
                self.downloadSession = nil
                cont?.resume(throwing: error)
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let cont = self.downloadContinuation
            self.downloadContinuation = nil
            self.activeDownloadTask = nil
            self.downloadSession?.invalidateAndCancel()
            self.downloadSession = nil
            if (error as NSError).code == NSURLErrorCancelled {
                cont?.resume(throwing: CancellationError())
            } else {
                cont?.resume(throwing: error)
            }
        }
    }

    // MARK: - Private Helpers

    private func syncCachedStateWithCurrentVersion() {
        if let cached = storage.loadUpdateState() {
            if cached.isNewer(than: AppConstants.currentVersion) {
                availableUpdate = cached
                phase = .available(cached)
                AppConstants.postDistributed(.updateStateDidUpdate)
            } else {
                clearAvailableUpdate(nextPhase: .idle)
            }
        }
    }

    private func applyAvailableUpdate(_ info: AppUpdateState) {
        availableUpdate = info
        phase = .available(info)
        try? storage.saveUpdateState(info)
        AppConstants.postDistributed(.updateStateDidUpdate)
    }

    private func clearAvailableUpdate(nextPhase: UpdatePhase) {
        availableUpdate = nil
        phase = nextPhase
        try? storage.saveUpdateState(nil)
        AppConstants.postDistributed(.updateStateDidUpdate)
    }

    private func downloadArchive(from url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 600
            let session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
            var request = URLRequest(url: url)
            request.setValue("\(AppConstants.appName)/\(AppConstants.currentVersion)", forHTTPHeaderField: "User-Agent")
            let task = session.downloadTask(with: request)
            self.downloadSession = session
            self.activeDownloadTask = task
            self.downloadContinuation = continuation
            task.resume()
        }
    }

    private func stageAndLaunchUpdater(archiveURL: URL, assetName: String) async throws {
        let fm = FileManager.default
        let stagingDir = fm.temporaryDirectory.appendingPathComponent("RepoShellUpdate-\(UUID().uuidString)", isDirectory: true)
        let extractedDir = stagingDir.appendingPathComponent("extracted", isDirectory: true)
        try fm.createDirectory(at: extractedDir, withIntermediateDirectories: true)

        let lowerName = assetName.lowercased()
        if lowerName.hasSuffix(".dmg") {
            let mountPoint = stagingDir.appendingPathComponent("mount", isDirectory: true)
            try fm.createDirectory(at: mountPoint, withIntermediateDirectories: true)
            let attachRes = try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/hdiutil"),
                arguments: ["attach", archiveURL.path, "-nobrowse", "-readonly", "-mountpoint", mountPoint.path]
            )
            guard attachRes.exitCode == 0 else {
                throw NSError(domain: "RepoShellUpdate", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: L("Failed to mount update disk image.", "挂载更新 DMG 镜像失败。") + " \(attachRes.stderrString)"
                ])
            }
            defer {
                let detach = Process()
                detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                detach.arguments = ["detach", mountPoint.path, "-force"]
                try? detach.run()
                detach.waitUntilExit()
            }
            let mountedApp = mountPoint.appendingPathComponent("RepoShell.app", isDirectory: true)
            guard fm.fileExists(atPath: mountedApp.path) else {
                throw NSError(domain: "RepoShellUpdate", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: L("RepoShell.app was not found inside the downloaded DMG.", "下载的 DMG 中未找到 RepoShell.app。")
                ])
            }
            let destApp = extractedDir.appendingPathComponent("RepoShell.app", isDirectory: true)
            let dittoRes = try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/ditto"),
                arguments: [mountedApp.path, destApp.path]
            )
            guard dittoRes.exitCode == 0 else {
                throw NSError(domain: "RepoShellUpdate", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: L("Failed to copy RepoShell.app from DMG.", "从 DMG 复制 RepoShell.app 失败。")
                ])
            }
        } else {
            let dittoRes = try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/ditto"),
                arguments: ["-xk", archiveURL.path, extractedDir.path]
            )
            guard dittoRes.exitCode == 0 else {
                throw NSError(domain: "RepoShellUpdate", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: L("Failed to extract downloaded update archive.", "解压下载的更新包失败。") + " \(dittoRes.stderrString)"
                ])
            }
        }
        try? fm.removeItem(at: archiveURL)

        guard let newAppURL = findAppBundle(in: extractedDir) else {
            throw NSError(domain: "RepoShellUpdate", code: 5, userInfo: [
                NSLocalizedDescriptionKey: L("RepoShell.app was not found in the downloaded archive.", "下载的更新包中未找到 RepoShell.app。")
            ])
        }

        if let newBundleID = Bundle(url: newAppURL)?.bundleIdentifier,
           newBundleID != AppConstants.mainBundleID {
            throw NSError(domain: "RepoShellUpdate", code: 6, userInfo: [
                NSLocalizedDescriptionKey: String(format: L("Unexpected bundle identifier: %@", "更新包 Bundle ID 不匹配：%@"), newBundleID)
            ])
        }

        let currentBundle = Bundle.main.bundleURL
        let targetAppURL: URL
        if currentBundle.pathExtension == "app" && !currentBundle.path.hasPrefix("/Volumes/") {
            targetAppURL = currentBundle
        } else {
            targetAppURL = URL(fileURLWithPath: "/Applications/RepoShell.app", isDirectory: true)
        }

        let parentDir = targetAppURL.deletingLastPathComponent()
        let needsAdmin = !fm.isWritableFile(atPath: parentDir.path)
            || (fm.fileExists(atPath: targetAppURL.path) && !fm.isWritableFile(atPath: targetAppURL.path))

        let scriptURL = fm.temporaryDirectory.appendingPathComponent("reposhell-updater-\(UUID().uuidString).sh")
        let script = """
        #!/bin/bash
        set -euo pipefail
        OLD_PID="$1"
        NEW_APP="$2"
        TARGET_APP="$3"
        STAGING_DIR="$4"

        for _ in $(seq 1 150); do
          if ! kill -0 "$OLD_PID" 2>/dev/null; then
            break
          fi
          sleep 0.1
        done

        BACKUP_APP="${TARGET_APP}.backup-$$"
        rm -rf "$BACKUP_APP"
        if [ -e "$TARGET_APP" ]; then
          mv "$TARGET_APP" "$BACKUP_APP"
        fi

        if /usr/bin/ditto "$NEW_APP" "$TARGET_APP"; then
          rm -rf "$BACKUP_APP"
        else
          rm -rf "$TARGET_APP"
          if [ -e "$BACKUP_APP" ]; then
            mv "$BACKUP_APP" "$TARGET_APP"
          fi
          exit 1
        fi

        /usr/bin/xattr -dr com.apple.quarantine "$TARGET_APP" 2>/dev/null || true
        LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        if [ -x "$LSREGISTER" ]; then
          "$LSREGISTER" -f "$TARGET_APP" 2>/dev/null || true
        fi
        APPEX="$TARGET_APP/Contents/PlugIns/RepoShellFinderSync.appex"
        if [ -d "$APPEX" ]; then
          /usr/bin/pluginkit -a "$APPEX" 2>/dev/null || true
        fi
        rm -rf "$STAGING_DIR"
        /usr/bin/open -n "$TARGET_APP"
        rm -f "$0"
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let pid = String(ProcessInfo.processInfo.processIdentifier)
        if needsAdmin {
            let quotedArgs = [scriptURL.path, pid, newAppURL.path, targetAppURL.path, stagingDir.path]
                .map { shellEscape($0) }
                .joined(separator: " ")
            let appleScript = "do shell script \"/bin/bash \(quotedArgs.replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
            let osascript = Process()
            osascript.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            osascript.arguments = ["-e", appleScript]
            try osascript.run()
        } else {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = [scriptURL.path, pid, newAppURL.path, targetAppURL.path, stagingDir.path]
            try proc.run()
        }

        clearAvailableUpdate(nextPhase: .idle)
        NSApp.terminate(nil)
    }

    private func findAppBundle(in directory: URL) -> URL? {
        let direct = directory.appendingPathComponent("RepoShell.app", isDirectory: true)
        if FileManager.default.fileExists(atPath: direct.path) {
            return direct
        }
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        for case let item as URL in enumerator {
            if item.lastPathComponent == "RepoShell.app" {
                return item
            }
            if item.pathExtension == "app" {
                enumerator.skipDescendants()
            }
        }
        return nil
    }

    private func shellEscape(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
