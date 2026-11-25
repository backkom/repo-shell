import Foundation
import RepoShellShared

public struct QuickActionItem: Identifiable, Equatable, Sendable {
    public var id: String { action.rawValue }
    public var action: MenuAction
    public var title: String
    public var workflowName: String
    public var isInstalled: Bool

    public init(action: MenuAction, title: String, workflowName: String, isInstalled: Bool) {
        self.action = action
        self.title = title
        self.workflowName = workflowName
        self.isInstalled = isInstalled
    }
}

public final class QuickActionManager: Sendable {
    public let servicesDirectoryURL: URL
    public let runnerScriptPath: String

    public init(
        servicesDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Services", isDirectory: true),
        runnerScriptPath: String = "/Applications/RepoShell.app/Contents/Resources/Scripts/quickaction-runner.sh"
    ) {
        self.servicesDirectoryURL = servicesDirectoryURL
        self.runnerScriptPath = runnerScriptPath
    }

    public static func defaultRunnerScriptPath(in bundle: Bundle = .main) -> String {
        if let path = bundle.url(forResource: "quickaction-runner", withExtension: "sh", subdirectory: "Scripts")?.path {
            return path
        }
        return bundle.bundleURL
            .appendingPathComponent("Contents/Resources/Scripts/quickaction-runner.sh")
            .path
    }

    public func availableActions(language: AppLanguage = .system) -> [QuickActionItem] {
        let loc = Localization(language: language)
        let fm = FileManager.default
        return MenuAction.allCases
            .filter { $0.quickActionEligible }
            .map { action in
                let rawTitle = loc.string(menuKey(for: action))
                let cleanTitle = rawTitle.replacingOccurrences(of: "…", with: "")
                let wfName = workflowFileName(for: action, displayTitle: cleanTitle)
                let wfURL = servicesDirectoryURL.appendingPathComponent(wfName, isDirectory: true)
                let installed = fm.fileExists(atPath: wfURL.path)
                return QuickActionItem(
                    action: action,
                    title: rawTitle,
                    workflowName: wfName,
                    isInstalled: installed
                )
            }
    }

    public func install(action: MenuAction, language: AppLanguage = .system) throws -> URL {
        let loc = Localization(language: language)
        let rawTitle = loc.string(menuKey(for: action)).replacingOccurrences(of: "…", with: "")
        let serviceMenuTitle = "RepoShell - \(rawTitle)"
        let wfName = workflowFileName(for: action, displayTitle: rawTitle)
        let wfDir = servicesDirectoryURL.appendingPathComponent(wfName, isDirectory: true)
        let contentsDir = wfDir.appendingPathComponent("Contents", isDirectory: true)

        let fm = FileManager.default
        try fm.createDirectory(at: contentsDir, withIntermediateDirectories: true)

        let infoPlist = buildInfoPlist(serviceTitle: serviceMenuTitle, identifierSuffix: action.rawValue)
        let documentWflow = buildDocumentWorkflow(action: action)

        let infoData = try PropertyListSerialization.data(fromPropertyList: infoPlist, format: .xml, options: 0)
        let wflowData = try PropertyListSerialization.data(fromPropertyList: documentWflow, format: .xml, options: 0)

        try infoData.write(to: contentsDir.appendingPathComponent("Info.plist"), options: .atomic)
        try wflowData.write(to: contentsDir.appendingPathComponent("document.wflow"), options: .atomic)
        return wfDir
    }

    public func uninstall(action: MenuAction, language: AppLanguage = .system) throws {
        let fm = FileManager.default
        // Remove matching workflow regardless of language variant
        guard let entries = try? fm.contentsOfDirectory(at: servicesDirectoryURL, includingPropertiesForKeys: nil) else {
            return
        }
        let suffixTag = "[\(action.rawValue)]"
        for entry in entries where entry.pathExtension == "workflow" {
            let name = entry.lastPathComponent
            if name.contains(suffixTag) || name == workflowFileName(for: action, displayTitle: Localization(language: language).string(menuKey(for: action)).replacingOccurrences(of: "…", with: "")) {
                try? fm.removeItem(at: entry)
            }
        }
    }

    public func workflowFileName(for action: MenuAction, displayTitle: String) -> String {
        let sanitized = displayTitle
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return "RepoShell - \(sanitized) [\(action.rawValue)].workflow"
    }

    private func buildInfoPlist(serviceTitle: String, identifierSuffix: String) -> [String: Any] {
        [
            "CFBundleIdentifier": "com.leaf.reposhell.quickaction.\(identifierSuffix)",
            "NSServices": [
                [
                    "NSBackgroundColorName": "background",
                    "NSIconName": "workflowCustomImage",
                    "NSMenuItem": [
                        "default": serviceTitle
                    ],
                    "NSMessage": "runWorkflowAsService",
                    "NSRequiredContext": [
                        "NSApplicationIdentifier": "com.apple.finder"
                    ],
                    "NSSendFileTypes": [
                        "public.item"
                    ]
                ]
            ]
        ]
    }

    private func buildDocumentWorkflow(action: MenuAction) -> [String: Any] {
        let acceptFiles = action.acceptsSelectedFiles ? "1" : "0"
        let escapedRunner = runnerScriptPath.replacingOccurrences(of: "\"", with: "\\\"")
        let scriptCommand = """
        export ACTION_KEY="\(action.rawValue)"
        export ACCEPT_FILES="\(acceptFiles)"
        "\(escapedRunner)" "$@"
        """

        return [
            "AMApplicationBuild": "523",
            "AMApplicationVersion": "2.10",
            "AMDocumentVersion": "2",
            "actions": [
                [
                    "action": [
                        "AMAccepts": [
                            "Container": "List",
                            "Optional": true,
                            "Types": ["com.apple.cocoa.string"]
                        ],
                        "AMActionVersion": "2.0.3",
                        "AMApplication": ["Automator"],
                        "AMParameterProperties": [
                            "COMMAND_STRING": [:],
                            "CheckedForUserDefaultShell": [:],
                            "inputMethod": [:],
                            "shell": [:],
                            "source": [:]
                        ],
                        "AMProvides": [
                            "Container": "List",
                            "Types": ["com.apple.cocoa.string"]
                        ],
                        "ActionBundlePath": "/System/Library/Automator/Run Shell Script.action",
                        "ActionName": "Run Shell Script",
                        "ActionParameters": [
                            "COMMAND_STRING": scriptCommand,
                            "CheckedForUserDefaultShell": true,
                            "inputMethod": 1,
                            "shell": "/bin/zsh",
                            "source": ""
                        ],
                        "BundleIdentifier": "com.apple.RunShellScript",
                        "CFBundleVersion": "2.0.3",
                        "CanShowSelectedItemsWhenRun": false,
                        "CanShowWhenRun": true,
                        "Category": ["AMCategoryUtilities"],
                        "Class Name": "RunShellScriptAction",
                        "InputUUID": "D4865164-4F36-4F76-B8EE-359C4DCA6BE1",
                        "Keywords": ["Shell", "Script", "Command", "Run", "Unix"],
                        "OutputUUID": "DC8ABCB0-55EE-4543-948D-2D97FB67153E",
                        "UUID": "D960AC21-C35F-4493-9EA5-41207CCF7533",
                        "UnlocalizedApplications": ["Automator"],
                        "isViewVisible": 1
                    ],
                    "isViewVisible": 1
                ]
            ],
            "connectors": [:],
            "workflowMetaData": [
                "applicationBundleID": "com.apple.finder",
                "applicationBundleIDsByPath": [
                    "/System/Library/CoreServices/Finder.app": "com.apple.finder"
                ],
                "applicationPath": "/System/Library/CoreServices/Finder.app",
                "applicationPaths": ["/System/Library/CoreServices/Finder.app"],
                "inputTypeIdentifier": "com.apple.Automator.fileSystemObject",
                "outputTypeIdentifier": "com.apple.Automator.nothing",
                "presentationMode": 15,
                "processesInput": 0,
                "serviceApplicationBundleID": "com.apple.finder",
                "serviceApplicationPath": "/System/Library/CoreServices/Finder.app",
                "serviceInputTypeIdentifier": "com.apple.Automator.fileSystemObject",
                "serviceOutputTypeIdentifier": "com.apple.Automator.nothing",
                "serviceProcessesInput": 0,
                "systemImageName": "NSActionTemplate",
                "useAutomaticInputType": 0,
                "workflowTypeIdentifier": "com.apple.Automator.servicesMenu"
            ]
        ]
    }

    private func menuKey(for action: MenuAction) -> String {
        switch action {
        case .gitCommit: return "menu.gitCommit"
        case .gitPull: return "menu.gitPull"
        case .gitFetch: return "menu.gitFetch"
        case .gitPush: return "menu.gitPush"
        case .showLog: return "menu.showLog"
        case .checkForModifications: return "menu.checkModifications"
        case .browseReferences: return "menu.browseReferences"
        case .stashPush: return "menu.stashPush"
        case .stashList: return "menu.stashList"
        case .repoBrowser: return "menu.repoBrowser"
        case .revert: return "menu.revert"
        case .checkout: return "menu.checkout"
        case .createBranch: return "menu.createBranch"
        case .createTag: return "menu.createTag"
        case .merge: return "menu.merge"
        case .diff: return "menu.diff"
        case .diffPrevious: return "menu.diffPrev"
        case .add: return "menu.add"
        case .blame: return "menu.blame"
        case .repoInfo: return "menu.repoInfo"
        default: return action.rawValue
        }
    }
}
