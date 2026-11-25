# RepoShell

**RepoShell** 是一款面向 macOS (13.0 Ventura+) 的原生版本控制图形客户端与 Finder 集成工具，复刻自 SnailGit 与 SnailSVN 的经典 Tortoise 风格交互体验。

- **V1**：完整支持 **Git**（全部基础工作流 + 进阶功能：交互式 Rebase、Cherry-Pick、RefLog、Repo-browser、版本对比、Blame、Submodules、Changelists、隐藏文件规则、Commit Notes、内置图片对比、20+ 外部 Diff/Merge 工具、每仓库认证管理、Finder 标签着色与 Quick Actions）。
- **V2（预留架构）**：基于统一 `VcsProvider` 抽象层无缝接入 **SVN**。

详细架构与功能规格请参阅 [docs/DESIGN.md](docs/DESIGN.md)。

## 目录结构

- `docs/DESIGN.md` — 详尽架构与设计文档（含 V2 SVN 扩展设计）
- `Packages/RepoShellCore/` — 核心 Swift Package（`RepoShellShared`、`RepoShellVcs`、`RepoShellServices` 与单元测试/集成测试）
- `Targets/RepoShellApp/` — macOS 主应用（AppKit + SwiftUI 混合多窗口界面）
- `Targets/RepoShellFinderSync/` — Finder Sync 扩展（状态角标 + 右键/工具栏上下文菜单）
- `Targets/Helpers/` — `git-credential-reposhell` 与 `reposhell-askpass` 辅助程序
- `Resources/` — 本地化文案（`en`、`zh-Hans`）、脚本与图标资源
- `scripts/` — Xcode 工程生成、内置 Git 打包与便携 Git 编译脚本

## 构建与运行

```bash
# 1. 运行核心包单元测试与 Git 集成测试
cd Packages/RepoShellCore && swift test

# 2. 生成 RepoShell.xcodeproj
python3 scripts/generate_xcodeproj.py

# 3. 编译并签名 RepoShell.app
xcodebuild -project RepoShell.xcodeproj -scheme RepoShell -configuration Debug -derivedDataPath build/DerivedData build
```

> **注意**：macOS 要求 Finder Sync 扩展必须签名且启用 App Sandbox，因此构建默认使用本机可用的 `Apple Development` 证书签名。首次运行后可在「系统设置 → 扩展 → 添加的扩展 / 访达扩展」中启用 **RepoShellFinderSync**。
