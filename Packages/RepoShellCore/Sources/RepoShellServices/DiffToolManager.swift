import Foundation
import RepoShellShared
import RepoShellVcs

public struct DetectedToolInfo: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var commandPath: String?
    public var isInstalled: Bool { commandPath != nil }
}

public enum DiffLaunchOutcome: Equatable, Sendable {
    case launchedExternal(toolName: String)
    case openBuiltInImageDiff(leftPath: String, rightPath: String, leftTitle: String, rightTitle: String)
    case noToolConfigured
}

public final class DiffToolManager: @unchecked Sendable {
    public static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "tiff", "tif", "bmp", "heic", "ico"
    ]

    public static let diffPresets: [DiffToolPreset] = [
        DiffToolPreset(
            id: "code",
            name: "Visual Studio Code",
            appBundleIDs: ["com.microsoft.VSCode"],
            appPaths: ["/Applications/Visual Studio Code.app"],
            commandPaths: [
                "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code",
                "/usr/local/bin/code"
            ],
            argsTemplate: "--diff \"$LOCAL\" \"$REMOTE\""
        ),
        DiffToolPreset(
            id: "code-insiders",
            name: "Visual Studio Code Insiders",
            appBundleIDs: ["com.microsoft.VSCodeInsiders"],
            appPaths: ["/Applications/Visual Studio Code - Insiders.app"],
            commandPaths: [
                "/Applications/Visual Studio Code - Insiders.app/Contents/Resources/app/bin/code"
            ],
            argsTemplate: "--diff \"$LOCAL\" \"$REMOTE\""
        ),
        DiffToolPreset(
            id: "cursor",
            name: "Cursor",
            appBundleIDs: ["com.todesktop.230313mzl4w4u92"],
            appPaths: ["/Applications/Cursor.app"],
            commandPaths: [
                "/Applications/Cursor.app/Contents/Resources/app/bin/cursor",
                "/usr/local/bin/cursor"
            ],
            argsTemplate: "--diff \"$LOCAL\" \"$REMOTE\""
        ),
        DiffToolPreset(
            id: "bcomp",
            name: "Beyond Compare",
            appBundleIDs: ["com.ScooterSoftware.BeyondCompare"],
            appPaths: ["/Applications/Beyond Compare.app"],
            commandPaths: ["/Applications/Beyond Compare.app/Contents/MacOS/bcomp"],
            argsTemplate: "\"$LOCAL\" \"$REMOTE\""
        ),
        DiffToolPreset(
            id: "ksdiff",
            name: "Kaleidoscope",
            appBundleIDs: ["app.kaleidoscope.v4", "com.blackpixel.kaleidoscope"],
            appPaths: ["/Applications/Kaleidoscope.app"],
            commandPaths: [
                "/Applications/Kaleidoscope.app/Contents/Resources/bin/ksdiff",
                "/Applications/Kaleidoscope.app/Contents/MacOS/ksdiff",
                "/usr/local/bin/ksdiff"
            ],
            argsTemplate: "\"$LOCAL\" \"$REMOTE\""
        ),
        DiffToolPreset(
            id: "opendiff",
            name: "FileMerge",
            appBundleIDs: ["com.apple.FileMerge"],
            appPaths: ["/Applications/Xcode.app/Contents/Applications/FileMerge.app"],
            commandPaths: ["/Applications/Xcode.app/Contents/Developer/usr/bin/opendiff"],
            argsTemplate: "\"$LOCAL\" \"$REMOTE\""
        ),
        DiffToolPreset(
            id: "diffmerge",
            name: "DiffMerge",
            appBundleIDs: ["com.sourcegear.DiffMerge"],
            appPaths: ["/Applications/DiffMerge.app"],
            commandPaths: ["/Applications/DiffMerge.app/Contents/Resources/diffmerge.sh"],
            argsTemplate: "\"$LOCAL\" \"$REMOTE\""
        ),
        DiffToolPreset(
            id: "diffmerge-bingqian",
            name: "DiffMerge by Bing Qian",
            appBundleIDs: ["com.bingqian.macmerge"],
            appPaths: ["/Applications/DiffMerge.app"],
            commandPaths: ["/Applications/DiffMerge.app/Contents/Resources/diffmerge"],
            argsTemplate: "\"$LOCAL\" \"$REMOTE\""
        ),
        DiffToolPreset(
            id: "araxis",
            name: "Araxis Merge",
            appBundleIDs: ["com.araxis.merge"],
            appPaths: ["/Applications/Araxis Merge.app"],
            commandPaths: ["/Applications/Araxis Merge.app/Contents/Utilities/compare"],
            argsTemplate: "\"$LOCAL\" \"$REMOTE\""
        ),
        DiffToolPreset(
            id: "bbdiff",
            name: "BBEdit",
            appBundleIDs: ["com.barebones.bbedit"],
            appPaths: ["/Applications/BBEdit.app"],
            commandPaths: ["/usr/local/bin/bbdiff"],
            argsTemplate: "\"$LOCAL\" \"$REMOTE\""
        ),
        DiffToolPreset(
            id: "chdiff",
            name: "Changes",
            appBundleIDs: ["com.changesapp.Changes"],
            appPaths: ["/Applications/Changes.app"],
            commandPaths: ["/Applications/Changes.app/Contents/Resources/chdiff"],
            argsTemplate: "\"$LOCAL\" \"$REMOTE\""
        ),
        DiffToolPreset(
            id: "CompareMerge",
            name: "CompareMerge",
            appBundleIDs: ["com.vutienthinh.macos.MacMerge"],
            appPaths: ["/Applications/CompareMerge.app"],
            commandPaths: ["/Applications/CompareMerge.app/Contents/MacOS/CompareMerge"],
            argsTemplate: "\"$LOCAL\" \"$REMOTE\""
        ),
        DiffToolPreset(
            id: "CompareMerge2",
            name: "CompareMerge2",
            appBundleIDs: ["com.vutienthinh.macos.MacMergeLite"],
            appPaths: ["/Applications/CompareMerge2.app"],
            commandPaths: ["/Applications/CompareMerge2.app/Contents/MacOS/CompareMerge2"],
            argsTemplate: "\"$LOCAL\" \"$REMOTE\""
        ),
        DiffToolPreset(
            id: "deltawalker",
            name: "DeltaWalker",
            appBundleIDs: ["com.deltopia.DeltaWalker"],
            appPaths: ["/Applications/DeltaWalker.app"],
            commandPaths: ["/Applications/DeltaWalker.app/Contents/MacOS/DeltaWalker"],
            argsTemplate: "\"$LOCAL\" \"$REMOTE\""
        ),
        DiffToolPreset(
            id: "diffease",
            name: "diffease",
            appBundleIDs: ["com.diffease.dev"],
            appPaths: ["/Applications/diffease.app"],
            commandPaths: ["/Applications/diffease.app/Contents/MacOS/diffease"],
            argsTemplate: "\"$LOCAL\" \"$REMOTE\""
        ),
        DiffToolPreset(
            id: "ecmerge",
            name: "ECMerge",
            appBundleIDs: ["com.elliecomputing.guimerge"],
            appPaths: ["/Applications/ECMerge.app"],
            commandPaths: ["/Applications/ECMerge.app/Contents/MacOS/guimerge"],
            argsTemplate: "\"$LOCAL\" \"$REMOTE\""
        ),
        DiffToolPreset(
            id: "kdiff3",
            name: "KDiff3",
            appBundleIDs: ["org.kde.KDiff3"],
            appPaths: ["/Applications/kdiff3.app"],
            commandPaths: ["/Applications/kdiff3.app/Contents/MacOS/kdiff3"],
            argsTemplate: "\"$LOCAL\" \"$REMOTE\""
        ),
        DiffToolPreset(
            id: "macvim",
            name: "MacVim",
            appBundleIDs: ["org.vim.MacVim"],
            appPaths: ["/Applications/MacVim.app"],
            commandPaths: ["/Applications/MacVim.app/Contents/bin/mvimdiff"],
            argsTemplate: "-c 'redraw' \"$LOCAL\" \"$REMOTE\""
        ),
        DiffToolPreset(
            id: "meld",
            name: "Meld",
            appBundleIDs: ["org.gnome.meld"],
            appPaths: ["/Applications/Meld.app"],
            commandPaths: ["/Applications/Meld.app/Contents/MacOS/Meld"],
            argsTemplate: "\"$LOCAL\" \"$REMOTE\""
        ),
        DiffToolPreset(
            id: "p4merge",
            name: "P4Merge",
            appBundleIDs: ["com.perforce.p4merge"],
            appPaths: ["/Applications/p4merge.app"],
            commandPaths: ["/Applications/p4merge.app/Contents/MacOS/p4merge"],
            argsTemplate: "\"$LOCAL\" \"$REMOTE\""
        ),
        DiffToolPreset(
            id: "twdiff",
            name: "TextWrangler",
            appBundleIDs: ["com.barebones.textwrangler"],
            appPaths: ["/Applications/TextWrangler.app"],
            commandPaths: ["/usr/local/bin/twdiff"],
            argsTemplate: "\"$LOCAL\" \"$REMOTE\""
        ),
        DiffToolPreset(
            id: "visdiff",
            name: "VisualDiffer",
            appBundleIDs: ["com.visualdiffer"],
            appPaths: ["/Applications/VisualDiffer.app"],
            commandPaths: ["/Applications/VisualDiffer.app/Contents/Helpers/visdiff"],
            argsTemplate: "\"$LOCAL\" \"$REMOTE\""
        )
    ]

    public static let mergePresets: [MergeToolPreset] = [
        MergeToolPreset(
            id: "bcomp",
            name: "Beyond Compare",
            appPaths: ["/Applications/Beyond Compare.app"],
            commandPaths: ["/Applications/Beyond Compare.app/Contents/MacOS/bcomp"],
            argsTemplate: "\"$LOCAL\" \"$REMOTE\" \"$BASE\" -mergeoutput=\"$MERGED\""
        ),
        MergeToolPreset(
            id: "ksdiff",
            name: "Kaleidoscope",
            appPaths: ["/Applications/Kaleidoscope.app"],
            commandPaths: [
                "/Applications/Kaleidoscope.app/Contents/Resources/bin/ksdiff",
                "/usr/local/bin/ksdiff"
            ],
            argsTemplate: "\"$BASE\" \"$LOCAL\" \"$REMOTE\""
        ),
        MergeToolPreset(
            id: "opendiff",
            name: "FileMerge",
            appPaths: ["/Applications/Xcode.app/Contents/Applications/FileMerge.app"],
            commandPaths: ["/Applications/Xcode.app/Contents/Developer/usr/bin/opendiff"],
            argsTemplate: "\"$LOCAL\" \"$REMOTE\" -ancestor \"$BASE\" -merge \"$MERGED\""
        ),
        MergeToolPreset(
            id: "diffmerge",
            name: "DiffMerge",
            appPaths: ["/Applications/DiffMerge.app"],
            commandPaths: ["/Applications/DiffMerge.app/Contents/Resources/diffmerge.sh"],
            argsTemplate: "-merge -caption=\"$MERGED\" -result=\"$MERGED\" \"$LOCAL\" \"$REMOTE\" \"$BASE\""
        ),
        MergeToolPreset(
            id: "araxis",
            name: "Araxis Merge",
            appPaths: ["/Applications/Araxis Merge.app"],
            commandPaths: ["/Applications/Araxis Merge.app/Contents/Utilities/compare"],
            argsTemplate: "-wait -merge -3 -a1 \"$BASE\" \"$LOCAL\" \"$REMOTE\" \"$MERGED\""
        ),
        MergeToolPreset(
            id: "deltawalker",
            name: "DeltaWalker",
            appPaths: ["/Applications/DeltaWalker.app"],
            commandPaths: ["/Applications/DeltaWalker.app/Contents/MacOS/DeltaWalker"],
            argsTemplate: "\"$LOCAL\" \"$REMOTE\" \"$BASE\" -merged=\"$MERGED\""
        ),
        MergeToolPreset(
            id: "ecmerge",
            name: "ECMerge",
            appPaths: ["/Applications/ECMerge.app"],
            commandPaths: ["/Applications/ECMerge.app/Contents/MacOS/guimerge"],
            argsTemplate: "\"$BASE\" \"$LOCAL\" \"$REMOTE\" --default --mode=merge3 --to=\"$MERGED\""
        ),
        MergeToolPreset(
            id: "kdiff3",
            name: "KDiff3",
            appPaths: ["/Applications/kdiff3.app"],
            commandPaths: ["/Applications/kdiff3.app/Contents/MacOS/kdiff3"],
            argsTemplate: "\"$LOCAL\" \"$REMOTE\" \"$BASE\" -o \"$MERGED\""
        ),
        MergeToolPreset(
            id: "meld",
            name: "Meld",
            appPaths: ["/Applications/Meld.app"],
            commandPaths: ["/Applications/Meld.app/Contents/MacOS/Meld"],
            argsTemplate: "--output=\"$MERGED\" \"$LOCAL\" \"$BASE\" \"$REMOTE\""
        ),
        MergeToolPreset(
            id: "p4merge",
            name: "P4Merge",
            appPaths: ["/Applications/p4merge.app"],
            commandPaths: ["/Applications/p4merge.app/Contents/MacOS/p4merge"],
            argsTemplate: "\"$BASE\" \"$REMOTE\" \"$LOCAL\" \"$MERGED\""
        ),
        MergeToolPreset(
            id: "code",
            name: "Visual Studio Code",
            appPaths: ["/Applications/Visual Studio Code.app"],
            commandPaths: ["/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code", "/usr/local/bin/code"],
            argsTemplate: "--wait --merge \"$REMOTE\" \"$LOCAL\" \"$BASE\" \"$MERGED\""
        )
    ]

    private let storage: SharedStorage

    public init(storage: SharedStorage = .shared) {
        self.storage = storage
    }

    public static func isImageFile(_ path: String) -> Bool {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        return imageExtensions.contains(ext)
    }

    public func detectInstalledDiffTools() -> [DetectedToolInfo] {
        let fm = FileManager.default
        return Self.diffPresets.map { preset in
            let cmd = preset.commandPaths.first { fm.isExecutableFile(atPath: $0) }
            return DetectedToolInfo(id: preset.id, name: preset.name, commandPath: cmd)
        }
    }

    public func detectInstalledMergeTools() -> [DetectedToolInfo] {
        let fm = FileManager.default
        return Self.mergePresets.map { preset in
            let cmd = preset.commandPaths.first { fm.isExecutableFile(atPath: $0) }
            return DetectedToolInfo(id: preset.id, name: preset.name, commandPath: cmd)
        }
    }

    public func resolveDiffCommand(preferences: AppPreferences) -> (name: String, commandLineTemplate: String)? {
        if preferences.diffToolId == "custom" && !preferences.customDiffCommand.trimmingCharacters(in: .whitespaces).isEmpty {
            return ("Custom", preferences.customDiffCommand)
        }
        let detected = detectInstalledDiffTools()
        if preferences.diffToolId == "auto" {
            if let first = detected.first(where: { $0.isInstalled }),
               let cmd = first.commandPath,
               let preset = Self.diffPresets.first(where: { $0.id == first.id }) {
                return (preset.name, "\"\(cmd)\" \(preset.argsTemplate)")
            }
            return nil
        }
        if let info = detected.first(where: { $0.id == preferences.diffToolId }),
           let cmd = info.commandPath,
           let preset = Self.diffPresets.first(where: { $0.id == info.id }) {
            return (preset.name, "\"\(cmd)\" \(preset.argsTemplate)")
        }
        return nil
    }

    public func resolveMergeCommand(preferences: AppPreferences) -> (name: String, commandLineTemplate: String)? {
        if preferences.mergeToolId == "custom" && !preferences.customMergeCommand.trimmingCharacters(in: .whitespaces).isEmpty {
            return ("Custom", preferences.customMergeCommand)
        }
        let detected = detectInstalledMergeTools()
        if preferences.mergeToolId == "auto" {
            if let first = detected.first(where: { $0.isInstalled }),
               let cmd = first.commandPath,
               let preset = Self.mergePresets.first(where: { $0.id == first.id }) {
                return (preset.name, "\"\(cmd)\" \(preset.argsTemplate)")
            }
            return nil
        }
        if let info = detected.first(where: { $0.id == preferences.mergeToolId }),
           let cmd = info.commandPath,
           let preset = Self.mergePresets.first(where: { $0.id == info.id }) {
            return (preset.name, "\"\(cmd)\" \(preset.argsTemplate)")
        }
        return nil
    }

    public func renderCommandLine(
        template: String,
        local: String,
        remote: String,
        base: String = "",
        merged: String = ""
    ) -> String {
        template
            .replacingOccurrences(of: "$LOCAL", with: shellEscapeInsideQuotes(local))
            .replacingOccurrences(of: "$REMOTE", with: shellEscapeInsideQuotes(remote))
            .replacingOccurrences(of: "$BASE", with: shellEscapeInsideQuotes(base))
            .replacingOccurrences(of: "$MERGED", with: shellEscapeInsideQuotes(merged))
    }

    public func launchDiff(
        leftPath: String,
        rightPath: String,
        leftTitle: String = "Base",
        rightTitle: String = "Working",
        preferences: AppPreferences
    ) throws -> DiffLaunchOutcome {
        if Self.isImageFile(leftPath) && Self.isImageFile(rightPath) {
            return .openBuiltInImageDiff(
                leftPath: leftPath,
                rightPath: rightPath,
                leftTitle: leftTitle,
                rightTitle: rightTitle
            )
        }
        guard let resolved = resolveDiffCommand(preferences: preferences) else {
            return .noToolConfigured
        }
        let cmd = renderCommandLine(template: resolved.commandLineTemplate, local: leftPath, remote: rightPath)
        try spawnShellCommand(cmd)
        return .launchedExternal(toolName: resolved.name)
    }

    public func launchMerge(
        basePath: String,
        localPath: String,
        remotePath: String,
        mergedPath: String,
        preferences: AppPreferences
    ) throws -> Bool {
        guard let resolved = resolveMergeCommand(preferences: preferences) else {
            return false
        }
        let cmd = renderCommandLine(
            template: resolved.commandLineTemplate,
            local: localPath,
            remote: remotePath,
            base: basePath,
            merged: mergedPath
        )
        try spawnShellCommand(cmd)
        return true
    }

    // MARK: - Diff Later

    public func saveDiffLater(filePath: String) throws {
        try storage.saveDiffLater(DiffLaterState(filePath: filePath))
        AppConstants.postDistributed(.diffLaterDidUpdate)
    }

    public func loadDiffLater() -> DiffLaterState? {
        storage.loadDiffLater()
    }

    public func clearDiffLater() throws {
        try storage.saveDiffLater(nil)
        AppConstants.postDistributed(.diffLaterDidUpdate)
    }

    private func spawnShellCommand(_ command: String) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-l", "-c", command]
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
    }

    private func shellEscapeInsideQuotes(_ path: String) -> String {
        path.replacingOccurrences(of: "\"", with: "\\\"")
    }
}
