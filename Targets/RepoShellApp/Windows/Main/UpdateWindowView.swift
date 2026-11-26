import SwiftUI
import RepoShellShared

struct UpdateWindowView: View {
    @ObservedObject private var updateController = AppContainer.shared.updateController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("RepoShell Software Update", "RepoShell 软件更新"))
                        .font(.title3.bold())
                    if let update = updateController.availableUpdate {
                        Text(String(
                            format: L("Version %@ is available (you have %@).", "发现新版本 %@（当前版本 %@）。"),
                            update.latestVersion,
                            AppConstants.currentVersion
                        ))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    } else {
                        Text(String(
                            format: L("Current version: %@", "当前版本：%@"),
                            AppConstants.currentVersion
                        ))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    }
                }
                Spacer()
            }

            if let update = updateController.availableUpdate {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Release Notes", "更新说明"))
                        .font(.headline)
                    ScrollView {
                        Text(update.releaseNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                             ? L("No release notes provided.", "暂无更新日志。")
                             : update.releaseNotes)
                        .font(.system(.callout))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(10)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
                }
            } else {
                Spacer()
            }

            statusProgressView

            HStack {
                if let update = updateController.availableUpdate,
                   let pageURL = URL(string: update.htmlURL) {
                    Button(L("View on GitHub", "在 GitHub 查看")) {
                        NSWorkspace.shared.open(pageURL)
                    }
                }

                Spacer()

                switch updateController.phase {
                case .downloading:
                    Button(L("Cancel", "取消")) {
                        updateController.cancelDownload()
                    }
                case .installing:
                    Button(L("Installing…", "正在安装…")) {}
                        .disabled(true)
                case .available(let update):
                    Button(L("Later", "稍后提醒")) {
                        NSApp.keyWindow?.close()
                    }
                    Button(L("Upgrade & Relaunch", "立即升级并重启")) {
                        updateController.installUpdate(update)
                    }
                    .buttonStyle(.borderedProminent)
                case .failed:
                    Button(L("Close", "关闭")) {
                        NSApp.keyWindow?.close()
                    }
                    if let update = updateController.availableUpdate {
                        Button(L("Retry Upgrade", "重试升级")) {
                            updateController.installUpdate(update)
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button(L("Check Again", "重新检查")) {
                            Task { await updateController.checkForUpdates(userInitiated: true) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                case .checking:
                    Button(L("Close", "关闭")) {
                        NSApp.keyWindow?.close()
                    }
                case .idle, .upToDate:
                    Button(L("Check for Updates", "检查更新")) {
                        Task { await updateController.checkForUpdates(userInitiated: true) }
                    }
                    Button(L("Close", "关闭")) {
                        NSApp.keyWindow?.close()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var statusProgressView: some View {
        switch updateController.phase {
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L("Checking GitHub Releases…", "正在检测 GitHub 最新版本…"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        case .downloading(let progress, _):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: progress)
                Text(String(format: L("Downloading update… %d%%", "正在下载新版本… %d%%"), Int((progress * 100).rounded())))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        case .installing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L("Installing new version and relaunching RepoShell…", "正在安装新版本并重启 RepoShell…"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundColor(.red)
        default:
            EmptyView()
        }
    }
}
