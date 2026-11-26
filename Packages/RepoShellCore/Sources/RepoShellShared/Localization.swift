import Foundation

public struct Localization: Sendable {
    public let language: AppLanguage

    public init(language: AppLanguage = .system) {
        self.language = language
    }

    private var isChinese: Bool {
        switch language {
        case .zhHans:
            return true
        case .en:
            return false
        case .system:
            let preferred = Locale.preferredLanguages.first ?? "en"
            return preferred.hasPrefix("zh")
        }
    }

    public func string(_ key: String) -> String {
        if let bundleString = lookupInBundle(key: key) {
            return bundleString
        }
        let table = isChinese ? Self.zhHansStrings : Self.enStrings
        return table[key] ?? Self.enStrings[key] ?? key
    }

    private func lookupInBundle(key: String) -> String? {
        let langCode: String? = switch language {
        case .en: "en"
        case .zhHans: "zh-Hans"
        case .system: nil
        }
        if let code = langCode,
           let path = Bundle.main.path(forResource: code, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            let value = bundle.localizedString(forKey: key, value: "__MISSING__", table: nil)
            if value != "__MISSING__" {
                return value
            }
        }
        let value = Bundle.main.localizedString(forKey: key, value: "__MISSING__", table: nil)
        return value == "__MISSING__" ? nil : value
    }

    private static let enStrings: [String: String] = [
        "menu.showApp": "Show RepoShell",
        "menu.addRepository": "Add Repository…",
        "menu.excludeRepository": "Exclude Repository…",
        "menu.refresh": "Refresh",
        "menu.gitClone": "Git Clone…",
        "menu.gitInit": "Create Git Repository Here…",
        "menu.gitCommit": "Git Commit…",
        "menu.gitCommitBranch": "Git Commit -> \"%@\"…",
        "menu.gitPull": "Git Pull…",
        "menu.gitFetch": "Git Fetch…",
        "menu.gitPush": "Git Push…",
        "menu.showLog": "Show Log",
        "menu.checkModifications": "Check for Modifications",
        "menu.browseReferences": "Browse References",
        "menu.showRefLog": "Show RefLog",
        "menu.repoBrowser": "Repo-browser",
        "menu.resolve": "Resolve…",
        "menu.abortMerge": "Abort Merge",
        "menu.revert": "Revert…",
        "menu.add": "Add",
        "menu.addToIgnore": "Add to Ignore List…",
        "menu.delete": "Delete",
        "menu.deleteKeepLocal": "Delete (Keep Local)",
        "menu.rename": "Rename…",
        "menu.blame": "Blame…",
        "menu.checkout": "Checkout / Switch…",
        "menu.createBranch": "Create Branch…",
        "menu.createTag": "Create Tag…",
        "menu.merge": "Merge…",
        "menu.rebase": "Rebase…",
        "menu.cherryPick": "Cherry-Pick…",
        "menu.reset": "Reset…",
        "menu.stashPush": "Stash Save…",
        "menu.stashList": "Stash List",
        "menu.compareRevisions": "Compare Revisions…",
        "menu.export": "Export…",
        "menu.submodules": "Submodules",
        "menu.submoduleAdd": "Add Submodule…",
        "menu.submoduleUpdate": "Update Submodules…",
        "menu.submoduleManage": "Manage Submodules…",
        "menu.repoInfo": "Repo Info",
        "menu.cleanup": "Cleanup (git gc)",
        "menu.diff": "Diff",
        "menu.diffPrev": "Diff with Previous Version",
        "menu.diffLater": "Diff Later",
        "menu.diffWithLater": "Diff with \"%@\"",
        "menu.svnCommit": "SVN Commit…",
        "menu.svnCommitBranch": "SVN Commit -> \"%@\"…",
        "menu.svnCheckout": "SVN Checkout…",
        "menu.svnCreateRepo": "Create SVN Repository Here…",
        "menu.svnImport": "SVN Import…",
        "menu.svnUpdate": "SVN Update…",
        "menu.svnUpdateToRevision": "Update to Revision…",
        "menu.svnBranchTag": "Branch / Tag…",
        "menu.svnSwitch": "Switch…",
        "menu.svnMerge": "SVN Merge…",
        "menu.svnMove": "Move…",
        "menu.svnCleanup": "Clean up…",
        "menu.svnInfo": "SVN Info",
        "menu.svnUpgrade": "Upgrade Working Copy…",
        "menu.svnLock": "Get Lock…",
        "menu.svnUnlock": "Release Lock…",
        "menu.svnProperties": "Properties…",
        "menu.svnRelocate": "Relocate…",
        "menu.svnCreatePatch": "Create Patch…",
        "menu.svnApplyPatch": "Apply Patch…",
        "status.normal": "Normal",
        "status.modified": "Modified",
        "status.added": "Added",
        "status.deleted": "Deleted",
        "status.renamed": "Renamed",
        "status.copied": "Copied",
        "status.typeChanged": "Type Changed",
        "status.unmerged": "Conflict",
        "status.untracked": "Untracked",
        "status.ignored": "Ignored",
        "status.external": "External",
        "status.locked": "Locked",
        "status.missing": "Missing",
        "status.obstructed": "Obstructed",
        "status.replaced": "Replaced",
        "status.readOnly": "Read-Only"
    ]

    private static let zhHansStrings: [String: String] = [
        "menu.showApp": "显示 RepoShell",
        "menu.addRepository": "添加版本库…",
        "menu.excludeRepository": "排除版本库…",
        "menu.refresh": "刷新",
        "menu.gitClone": "Git 克隆…",
        "menu.gitInit": "在此处创建 Git 版本库…",
        "menu.gitCommit": "Git 提交…",
        "menu.gitCommitBranch": "Git 提交 -> \"%@\"…",
        "menu.gitPull": "Git 拉取…",
        "menu.gitFetch": "Git 获取…",
        "menu.gitPush": "Git 推送…",
        "menu.showLog": "显示日志",
        "menu.checkModifications": "检测改动",
        "menu.browseReferences": "浏览引用",
        "menu.showRefLog": "显示操作日志 (RefLog)",
        "menu.repoBrowser": "版本库浏览器",
        "menu.resolve": "解决冲突…",
        "menu.abortMerge": "放弃合并",
        "menu.revert": "复原…",
        "menu.add": "添加",
        "menu.addToIgnore": "添加到忽略清单…",
        "menu.delete": "删除",
        "menu.deleteKeepLocal": "删除（保留本地拷贝）",
        "menu.rename": "重命名…",
        "menu.blame": "追溯…",
        "menu.checkout": "签出 / 切换…",
        "menu.createBranch": "创建分支…",
        "menu.createTag": "创建标签…",
        "menu.merge": "合并…",
        "menu.rebase": "变基 (Rebase)…",
        "menu.cherryPick": "摘取 (Cherry-Pick)…",
        "menu.reset": "重置 (Reset)…",
        "menu.stashPush": "储藏…",
        "menu.stashList": "储藏列表",
        "menu.compareRevisions": "比较版本…",
        "menu.export": "导出…",
        "menu.submodules": "子模块",
        "menu.submoduleAdd": "新增子模块…",
        "menu.submoduleUpdate": "更新子模块…",
        "menu.submoduleManage": "管理子模块…",
        "menu.repoInfo": "版本库信息",
        "menu.cleanup": "清理 (git gc)",
        "menu.diff": "对比",
        "menu.diffPrev": "和前一版本对比",
        "menu.diffLater": "稍后对比",
        "menu.diffWithLater": "与“%@”对比",
        "menu.svnCommit": "SVN 提交…",
        "menu.svnCommitBranch": "SVN 提交 -> \"%@\"…",
        "menu.svnCheckout": "SVN 签出…",
        "menu.svnCreateRepo": "在此处创建 SVN 版本库…",
        "menu.svnImport": "SVN 导入…",
        "menu.svnUpdate": "SVN 更新…",
        "menu.svnUpdateToRevision": "更新至指定版本…",
        "menu.svnBranchTag": "分支 / 标签…",
        "menu.svnSwitch": "切换 (Switch)…",
        "menu.svnMerge": "SVN 合并…",
        "menu.svnMove": "移动…",
        "menu.svnCleanup": "清理 (Clean up)…",
        "menu.svnInfo": "SVN 信息",
        "menu.svnUpgrade": "升级工作副本…",
        "menu.svnLock": "获取锁 (Lock)…",
        "menu.svnUnlock": "释放锁 (Unlock)…",
        "menu.svnProperties": "属性 (Properties)…",
        "menu.svnRelocate": "重定位 (Relocate)…",
        "menu.svnCreatePatch": "创建补丁…",
        "menu.svnApplyPatch": "应用补丁…",
        "status.normal": "正常",
        "status.modified": "已修改",
        "status.added": "已添加",
        "status.deleted": "已删除",
        "status.renamed": "已重命名",
        "status.copied": "已拷贝",
        "status.typeChanged": "类型改变",
        "status.unmerged": "冲突",
        "status.untracked": "未跟踪",
        "status.ignored": "已忽略",
        "status.external": "外部项",
        "status.locked": "已锁定",
        "status.missing": "丢失",
        "status.obstructed": "阻碍",
        "status.replaced": "已替换",
        "status.readOnly": "只读"
    ]
}
