import Cocoa
import SwiftUI
import RepoShellShared
import RepoShellVcs
import RepoShellServices

@MainActor
final class HostedWindowController: NSWindowController, NSWindowDelegate {
    private var onCloseCallback: (() -> Void)?

    init<Content: View>(
        title: String,
        size: NSSize,
        minSize: NSSize? = nil,
        autosaveName: String? = nil,
        rootView: Content,
        onClose: (() -> Void)? = nil
    ) {
        self.onCloseCallback = onClose

        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = title
        window.setContentSize(size)
        if let minSize = minSize {
            window.contentMinSize = minSize
        } else {
            window.contentMinSize = NSSize(width: min(size.width, 360), height: min(size.height, 240))
        }
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.center()

        super.init(window: window)
        window.delegate = self

        if let autosave = autosaveName {
            window.setFrameAutosaveName(autosave)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showAndFocus() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        onCloseCallback?()
        onCloseCallback = nil
    }
}

// MARK: - macOS 13 Compatible Shared UI Components

struct EmptyStateBox: View {
    let systemImage: String
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .regular))
                .foregroundColor(.secondary)
            Text(title)
                .font(.headline)
                .foregroundColor(.primary)
            if let subtitle = subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

struct StatusBadgeLabel: View {
    let status: VcsFileStatus
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let color = statusColor
        Text(AppContainer.shared.localized(status.localizedLabelKey))
            .font(.caption.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.14))
            .foregroundColor(color)
            .cornerRadius(4)
    }

    var statusColor: Color {
        let prefs = SharedStorage.shared.loadConfig().preferences
        let palette = colorScheme == .dark ? prefs.darkColors : prefs.lightColors
        switch status {
        case .added, .renamed, .copied, .replaced:
            return Color(red: Double(palette.added.r)/255.0, green: Double(palette.added.g)/255.0, blue: Double(palette.added.b)/255.0)
        case .deleted, .missing:
            return Color(red: Double(palette.deleted.r)/255.0, green: Double(palette.deleted.g)/255.0, blue: Double(palette.deleted.b)/255.0)
        case .modified, .typeChanged:
            return Color(red: Double(palette.modified.r)/255.0, green: Double(palette.modified.g)/255.0, blue: Double(palette.modified.b)/255.0)
        case .unmerged, .obstructed:
            return Color(red: Double(palette.unmerged.r)/255.0, green: Double(palette.unmerged.g)/255.0, blue: Double(palette.unmerged.b)/255.0)
        case .normal:
            return Color(red: Double(palette.merged.r)/255.0, green: Double(palette.merged.g)/255.0, blue: Double(palette.merged.b)/255.0)
        case .untracked:
            return .blue
        case .ignored, .readOnly:
            return .secondary
        case .external, .locked:
            return .teal
        }
    }
}

enum RefSelectionKind: String, CaseIterable {
    case branch
    case tag
    case commit
}

struct RefSelectionPicker: View {
    let repoPath: String
    @Binding var selectedRef: String
    var allowHEAD: Bool = true

    @State private var kind: RefSelectionKind = .branch
    @State private var references: [GitReference] = []
    @State private var commitInput: String = "HEAD"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $kind) {
                Text(L("Branch", "分支")).tag(RefSelectionKind.branch)
                Text(L("Tag", "标签")).tag(RefSelectionKind.tag)
                Text(L("Commit", "提交")).tag(RefSelectionKind.commit)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: kind) { newKind in
                syncSelectedFromKind(newKind)
            }

            if kind == .branch {
                let branches = references.filter { $0.kind == .localBranch || $0.kind == .remoteBranch }
                Picker("", selection: $selectedRef) {
                    if allowHEAD {
                        Text("HEAD").tag("HEAD")
                    }
                    ForEach(branches) { ref in
                        Text(ref.shortName + (ref.isCurrent ? " *" : "")).tag(ref.shortName)
                    }
                }
                .labelsHidden()
            } else if kind == .tag {
                let tags = references.filter { $0.kind == .tag }
                if tags.isEmpty {
                    Text(L("No tags available", "无可用标签"))
                        .foregroundColor(.secondary)
                        .font(.caption)
                } else {
                    Picker("", selection: $selectedRef) {
                        ForEach(tags) { ref in
                            Text(ref.shortName).tag(ref.shortName)
                        }
                    }
                    .labelsHidden()
                }
            } else {
                TextField(L("Commit SHA or revision (e.g. HEAD~1)", "提交哈希或版本号（如 HEAD~1）"), text: $commitInput)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: commitInput) { newVal in
                        selectedRef = newVal
                    }
            }
        }
        .task {
            if let refs = try? await AppContainer.shared.gitProvider.listReferences(repoPath: repoPath) {
                self.references = refs
                if selectedRef.isEmpty {
                    if let cur = refs.first(where: { $0.isCurrent }) {
                        selectedRef = cur.shortName
                    } else if allowHEAD {
                        selectedRef = "HEAD"
                    }
                }
            }
        }
    }

    private func syncSelectedFromKind(_ newKind: RefSelectionKind) {
        switch newKind {
        case .branch:
            let branches = references.filter { $0.kind == .localBranch || $0.kind == .remoteBranch }
            if let cur = branches.first(where: { $0.isCurrent }) ?? branches.first {
                selectedRef = cur.shortName
            } else if allowHEAD {
                selectedRef = "HEAD"
            }
        case .tag:
            let tags = references.filter { $0.kind == .tag }
            selectedRef = tags.first?.shortName ?? ""
        case .commit:
            commitInput = selectedRef.isEmpty ? "HEAD" : selectedRef
            selectedRef = commitInput
        }
    }
}

@MainActor
enum AlertHelper {
    static func showError(_ error: Error, title: String = L("Operation Failed", "操作失败")) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: L("OK", "确定"))
        alert.runModal()
    }

    static func showInfo(_ title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: L("OK", "确定"))
        alert.runModal()
    }

    static func confirm(title: String, message: String, confirmTitle: String = L("Confirm", "确定")) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: L("Cancel", "取消"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func pickFolder(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func pickFile(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
