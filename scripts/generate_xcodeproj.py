#!/usr/bin/env python3
"""Generates RepoShell.xcodeproj with all targets, SwiftPM local package linkage, build phases, and shared scheme."""

import hashlib
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
XCODEPROJ = ROOT / "RepoShell.xcodeproj"
PBXPROJ = XCODEPROJ / "project.pbxproj"
SCHEME_DIR = XCODEPROJ / "xcshareddata" / "xcschemes"


def make_id(seed: str) -> str:
    return hashlib.sha1(seed.encode("utf-8")).hexdigest()[:24].upper()


def collect_swift_files(rel_dir: str) -> list[str]:
    base = ROOT / rel_dir
    files = sorted(str(p.relative_to(ROOT)) for p in base.rglob("*.swift"))
    return files


class PbxBuilder:
    def __init__(self):
        self.file_refs: dict[str, tuple[str, str, str, str]] = {}  # id -> (path, name, fileType, sourceTree)
        self.build_files: list[tuple[str, str, str, dict | None]] = []  # (id, fileRef, comment, settings)
        self.variant_groups: list[tuple[str, str, list[tuple[str, str]]]] = []
        self.groups: dict[str, tuple[str, list[str]]] = {}

    def add_file_ref(self, rel_path: str, file_type: str, source_tree: str = '"<group>"', name: str | None = None) -> str:
        fid = make_id(f"fileref:{rel_path}")
        disp_name = name or os.path.basename(rel_path)
        self.file_refs[fid] = (rel_path, disp_name, file_type, source_tree)
        return fid

    def add_build_file(self, ref_id: str, comment: str, tag: str, settings: dict | None = None) -> str:
        bid = make_id(f"buildfile:{tag}:{ref_id}")
        self.build_files.append((bid, ref_id, comment, settings))
        return bid

    def add_pkg_build_file(self, pkg_prod_id: str, comment: str, tag: str) -> str:
        bid = make_id(f"pkgbuildfile:{tag}:{pkg_prod_id}")
        self.build_files.append((bid, pkg_prod_id, comment, None))
        return bid


def main():
    b = PbxBuilder()

    app_swift_files = collect_swift_files("Targets/RepoShellApp")
    ext_swift_files = collect_swift_files("Targets/RepoShellFinderSync")
    cred_swift_files = ["Targets/Helpers/GitCredentialHelper/main.swift"]
    askpass_swift_files = ["Targets/Helpers/AskpassHelper/main.swift"]

    # File Refs
    app_src_refs = [(p, b.add_file_ref(p, "sourcecode.swift")) for p in app_swift_files]
    ext_src_refs = [(p, b.add_file_ref(p, "sourcecode.swift")) for p in ext_swift_files]
    cred_src_refs = [(p, b.add_file_ref(p, "sourcecode.swift")) for p in cred_swift_files]
    askpass_src_refs = [(p, b.add_file_ref(p, "sourcecode.swift")) for p in askpass_swift_files]

    app_info_plist_ref = b.add_file_ref("Targets/RepoShellApp/Info.plist", "text.plist.xml")
    ext_info_plist_ref = b.add_file_ref("Targets/RepoShellFinderSync/Info.plist", "text.plist.xml")
    ext_entitlements_ref = b.add_file_ref("Targets/RepoShellFinderSync/RepoShellFinderSync.entitlements", "text.plist.entitlements")
    app_icon_ref = b.add_file_ref("Resources/Assets/AppIcon.icns", "image.icns")

    loc_en_ref = b.add_file_ref("Resources/en.lproj/Localizable.strings", "text.plist.strings", name="en")
    loc_zh_ref = b.add_file_ref("Resources/zh-Hans.lproj/Localizable.strings", "text.plist.strings", name="zh-Hans")
    loc_variant_id = make_id("variant:Localizable.strings")
    b.variant_groups.append((loc_variant_id, "Localizable.strings", [(loc_en_ref, "en"), (loc_zh_ref, "zh-Hans")]))

    script_paths = [
        "Resources/Scripts/git-sequence-editor.sh",
        "Resources/Scripts/git-message-editor.sh",
        "Resources/Scripts/quickaction-runner.sh",
    ]
    script_refs = [(p, b.add_file_ref(p, "text.script.sh")) for p in script_paths]

    # Product File Refs
    prod_app_ref = b.add_file_ref("RepoShell.app", "wrapper.application", source_tree="BUILT_PRODUCTS_DIR")
    prod_ext_ref = b.add_file_ref("RepoShellFinderSync.appex", "wrapper.app-extension", source_tree="BUILT_PRODUCTS_DIR")
    prod_cred_ref = b.add_file_ref("git-credential-reposhell", "compiled.mach-o.executable", source_tree="BUILT_PRODUCTS_DIR")
    prod_askpass_ref = b.add_file_ref("reposhell-askpass", "compiled.mach-o.executable", source_tree="BUILT_PRODUCTS_DIR")

    # System Frameworks
    fw_findersync_ref = b.add_file_ref("System/Library/Frameworks/FinderSync.framework", "wrapper.framework", source_tree="SDKROOT")
    fw_cocoa_ref = b.add_file_ref("System/Library/Frameworks/Cocoa.framework", "wrapper.framework", source_tree="SDKROOT")

    # Local SwiftPM Package Reference & Product Dependencies
    local_pkg_ref_id = make_id("localpkg:Packages/RepoShellCore")
    pkg_shared_app_id = make_id("pkgprod:app:RepoShellShared")
    pkg_vcs_app_id = make_id("pkgprod:app:RepoShellVcs")
    pkg_services_app_id = make_id("pkgprod:app:RepoShellServices")
    pkg_shared_ext_id = make_id("pkgprod:ext:RepoShellShared")
    pkg_shared_cred_id = make_id("pkgprod:cred:RepoShellShared")
    pkg_shared_ask_id = make_id("pkgprod:ask:RepoShellShared")

    # Target IDs
    target_app_id = make_id("target:RepoShell")
    target_ext_id = make_id("target:RepoShellFinderSync")
    target_cred_id = make_id("target:git-credential-reposhell")
    target_ask_id = make_id("target:reposhell-askpass")
    project_id = make_id("project:RepoShell")

    # Build Files for RepoShell App
    app_source_bfs = [b.add_build_file(ref, f"{os.path.basename(p)} in Sources", "app-src") for p, ref in app_src_refs]
    app_res_bfs = [
        b.add_build_file(app_icon_ref, "AppIcon.icns in Resources", "app-res"),
        b.add_build_file(loc_variant_id, "Localizable.strings in Resources", "app-res"),
    ]
    app_fw_bfs = [
        b.add_build_file(fw_findersync_ref, "FinderSync.framework in Frameworks", "app-fw"),
        b.add_pkg_build_file(pkg_shared_app_id, "RepoShellShared in Frameworks", "app-fw"),
        b.add_pkg_build_file(pkg_vcs_app_id, "RepoShellVcs in Frameworks", "app-fw"),
        b.add_pkg_build_file(pkg_services_app_id, "RepoShellServices in Frameworks", "app-fw"),
    ]
    embed_ext_bf = b.add_build_file(
        prod_ext_ref,
        "RepoShellFinderSync.appex in Embed App Extensions",
        "embed-ext",
        settings={"ATTRIBUTES": ["RemoveHeadersOnCopy"]},
    )
    embed_helpers_bfs = [
        b.add_build_file(prod_cred_ref, "git-credential-reposhell in Embed Helpers", "embed-helpers", settings={"ATTRIBUTES": ["CodeSignOnCopy"]}),
        b.add_build_file(prod_askpass_ref, "reposhell-askpass in Embed Helpers", "embed-helpers", settings={"ATTRIBUTES": ["CodeSignOnCopy"]}),
    ]
    copy_scripts_bfs = [
        b.add_build_file(ref, f"{os.path.basename(p)} in Copy Scripts", "copy-scripts")
        for p, ref in script_refs
    ]

    # Build Files for RepoShellFinderSync Extension
    ext_source_bfs = [b.add_build_file(ref, f"{os.path.basename(p)} in Sources", "ext-src") for p, ref in ext_src_refs]
    ext_res_bfs = [b.add_build_file(loc_variant_id, "Localizable.strings in Resources", "ext-res")]
    ext_fw_bfs = [
        b.add_build_file(fw_findersync_ref, "FinderSync.framework in Frameworks", "ext-fw"),
        b.add_build_file(fw_cocoa_ref, "Cocoa.framework in Frameworks", "ext-fw"),
        b.add_pkg_build_file(pkg_shared_ext_id, "RepoShellShared in Frameworks", "ext-fw"),
    ]

    # Build Files for Helpers
    cred_source_bfs = [b.add_build_file(ref, "main.swift in Sources", "cred-src") for _, ref in cred_src_refs]
    cred_fw_bfs = [b.add_pkg_build_file(pkg_shared_cred_id, "RepoShellShared in Frameworks", "cred-fw")]

    ask_source_bfs = [b.add_build_file(ref, "main.swift in Sources", "ask-src") for _, ref in askpass_src_refs]
    ask_fw_bfs = [b.add_pkg_build_file(pkg_shared_ask_id, "RepoShellShared in Frameworks", "ask-fw")]

    # Build Phases IDs
    app_sources_phase = make_id("phase:app:sources")
    app_frameworks_phase = make_id("phase:app:frameworks")
    app_resources_phase = make_id("phase:app:resources")
    app_embed_ext_phase = make_id("phase:app:embed-ext")
    app_embed_helpers_phase = make_id("phase:app:embed-helpers")
    app_copy_scripts_phase = make_id("phase:app:copy-scripts")
    app_bundle_git_phase = make_id("phase:app:bundle-git")

    ext_sources_phase = make_id("phase:ext:sources")
    ext_frameworks_phase = make_id("phase:ext:frameworks")
    ext_resources_phase = make_id("phase:ext:resources")

    cred_sources_phase = make_id("phase:cred:sources")
    cred_frameworks_phase = make_id("phase:cred:frameworks")

    ask_sources_phase = make_id("phase:ask:sources")
    ask_frameworks_phase = make_id("phase:ask:frameworks")

    # Container proxies & Target dependencies
    def add_dep_pair(dep_target_id: str, name: str):
        proxy_id = make_id(f"proxy:{dep_target_id}")
        dep_id = make_id(f"dep:{dep_target_id}")
        return proxy_id, dep_id, name

    deps = [
        add_dep_pair(target_ext_id, "RepoShellFinderSync"),
        add_dep_pair(target_cred_id, "git-credential-reposhell"),
        add_dep_pair(target_ask_id, "reposhell-askpass"),
    ]

    # Groups
    main_group_id = make_id("group:main")
    targets_group_id = make_id("group:Targets")
    resources_group_id = make_id("group:Resources")
    frameworks_group_id = make_id("group:Frameworks")
    products_group_id = make_id("group:Products")

    # Build Config IDs
    proj_dbg_id = make_id("cfg:proj:Debug")
    proj_rel_id = make_id("cfg:proj:Release")
    proj_cfg_list_id = make_id("cfglist:proj")

    app_dbg_id = make_id("cfg:app:Debug")
    app_rel_id = make_id("cfg:app:Release")
    app_cfg_list_id = make_id("cfglist:app")

    ext_dbg_id = make_id("cfg:ext:Debug")
    ext_rel_id = make_id("cfg:ext:Release")
    ext_cfg_list_id = make_id("cfglist:ext")

    cred_dbg_id = make_id("cfg:cred:Debug")
    cred_rel_id = make_id("cfg:cred:Release")
    cred_cfg_list_id = make_id("cfglist:cred")

    ask_dbg_id = make_id("cfg:ask:Debug")
    ask_rel_id = make_id("cfg:ask:Release")
    ask_cfg_list_id = make_id("cfglist:ask")

    # Render helper functions
    pkg_prod_ids = {
        pkg_shared_app_id, pkg_vcs_app_id, pkg_services_app_id,
        pkg_shared_ext_id, pkg_shared_cred_id, pkg_shared_ask_id,
    }

    def format_build_file_entry(bf_id, ref_id, comment, settings):
        ref_key = "productRef" if ref_id in pkg_prod_ids else "fileRef"
        extra = ""
        if settings:
            attrs = " ".join(f"{a}, " for a in settings["ATTRIBUTES"])
            extra = f" settings = {{ATTRIBUTES = ({attrs}); }};"
        return f"\t\t{bf_id} /* {comment} */ = {{isa = PBXBuildFile; {ref_key} = {ref_id};{extra} }};"

    lines = [
        "// !$*UTF8*$!",
        "{",
        "\tarchiveVersion = 1;",
        "\tclasses = {",
        "\t};",
        "\tobjectVersion = 56;",
        "\tobjects = {",
        "",
        "/* Begin PBXBuildFile section */",
    ]

    for bf_id, ref_id, comment, settings in b.build_files:
        lines.append(format_build_file_entry(bf_id, ref_id, comment, settings))
    lines.append("/* End PBXBuildFile section */")
    lines.append("")

    lines.append("/* Begin PBXContainerItemProxy section */")
    for proxy_id, _, name in deps:
        dep_tid = make_id(f"target:{name}")
        lines.append(
            f"\t\t{proxy_id} /* PBXContainerItemProxy */ = {{"
            f"isa = PBXContainerItemProxy; containerPortal = {project_id}; proxyType = 1; "
            f"remoteGlobalIDString = {dep_tid}; remoteInfo = \"{name}\"; }};"
        )
    lines.append("/* End PBXContainerItemProxy section */")
    lines.append("")

    lines.append("/* Begin PBXCopyFilesBuildPhase section */")
    lines.append(f"""\t\t{app_embed_ext_phase} /* Embed App Extensions */ = {{
\t\t\tisa = PBXCopyFilesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tdstPath = "";
\t\t\tdstSubfolderSpec = 13;
\t\t\tfiles = (
\t\t\t\t{embed_ext_bf} /* RepoShellFinderSync.appex in Embed App Extensions */,
\t\t\t);
\t\t\tname = "Embed App Extensions";
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};""")
    lines.append(f"""\t\t{app_embed_helpers_phase} /* Embed Helpers */ = {{
\t\t\tisa = PBXCopyFilesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tdstPath = Contents/Helpers;
\t\t\tdstSubfolderSpec = 1;
\t\t\tfiles = (""")
    for bf in embed_helpers_bfs:
        lines.append(f"\t\t\t\t{bf},")
    lines.append("""\t\t\t);
\t\t\tname = "Embed Helpers";
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t};""")
    lines.append(f"""\t\t{app_copy_scripts_phase} /* Copy Scripts */ = {{
\t\t\tisa = PBXCopyFilesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tdstPath = Scripts;
\t\t\tdstSubfolderSpec = 7;
\t\t\tfiles = (""")
    for bf in copy_scripts_bfs:
        lines.append(f"\t\t\t\t{bf},")
    lines.append("""\t\t\t);
\t\t\tname = "Copy Scripts";
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t};""")
    lines.append("/* End PBXCopyFilesBuildPhase section */")
    lines.append("")

    lines.append("/* Begin PBXFileReference section */")
    for fid, (path, name, ftype, tree) in b.file_refs.items():
        explicit_name = f' name = "{name}";' if name != os.path.basename(path) else ""
        lines.append(f'\t\t{fid} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = {ftype};{explicit_name} path = "{path}"; sourceTree = {tree}; }};')
    lines.append("/* End PBXFileReference section */")
    lines.append("")

    lines.append("/* Begin PBXFrameworksBuildPhase section */")
    for pid, bfs, label in [
        (app_frameworks_phase, app_fw_bfs, "Frameworks"),
        (ext_frameworks_phase, ext_fw_bfs, "Frameworks"),
        (cred_frameworks_phase, cred_fw_bfs, "Frameworks"),
        (ask_frameworks_phase, ask_fw_bfs, "Frameworks"),
    ]:
        lines.append(f"\t\t{pid} /* {label} */ = {{\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (")
        for bf in bfs:
            lines.append(f"\t\t\t\t{bf},")
        lines.append("\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t};")
    lines.append("/* End PBXFrameworksBuildPhase section */")
    lines.append("")

    lines.append("/* Begin PBXGroup section */")
    target_children = (
        [r for _, r in app_src_refs]
        + [app_info_plist_ref]
        + [r for _, r in ext_src_refs]
        + [ext_info_plist_ref, ext_entitlements_ref]
        + [r for _, r in cred_src_refs]
        + [r for _, r in askpass_src_refs]
    )
    resource_children = [app_icon_ref, loc_variant_id] + [r for _, r in script_refs]
    lines.append(f"""\t\t{main_group_id} = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{targets_group_id} /* Targets */,
\t\t\t\t{resources_group_id} /* Resources */,
\t\t\t\t{frameworks_group_id} /* Frameworks */,
\t\t\t\t{products_group_id} /* Products */,
\t\t\t);
\t\t\tsourceTree = "<group>";
\t\t}};""")
    lines.append(f"\t\t{targets_group_id} /* Targets */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (")
    for cid in target_children:
        lines.append(f"\t\t\t\t{cid},")
    lines.append('\t\t\t);\n\t\t\tname = Targets;\n\t\t\tsourceTree = "<group>";\n\t\t};')

    lines.append(f"\t\t{resources_group_id} /* Resources */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (")
    for cid in resource_children:
        lines.append(f"\t\t\t\t{cid},")
    lines.append('\t\t\t);\n\t\t\tname = Resources;\n\t\t\tsourceTree = "<group>";\n\t\t};')

    lines.append(f"""\t\t{frameworks_group_id} /* Frameworks */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{fw_findersync_ref},
\t\t\t\t{fw_cocoa_ref},
\t\t\t);
\t\t\tname = Frameworks;
\t\t\tsourceTree = "<group>";
\t\t}};""")

    lines.append(f"""\t\t{products_group_id} /* Products */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{prod_app_ref},
\t\t\t\t{prod_ext_ref},
\t\t\t\t{prod_cred_ref},
\t\t\t\t{prod_askpass_ref},
\t\t\t);
\t\t\tname = Products;
\t\t\tsourceTree = "<group>";
\t\t}};""")
    lines.append("/* End PBXGroup section */")
    lines.append("")

    # Native Targets
    lines.append("/* Begin PBXNativeTarget section */")
    lines.append(f"""\t\t{target_app_id} /* RepoShell */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {app_cfg_list_id};
\t\t\tbuildPhases = (
\t\t\t\t{app_sources_phase} /* Sources */,
\t\t\t\t{app_frameworks_phase} /* Frameworks */,
\t\t\t\t{app_resources_phase} /* Resources */,
\t\t\t\t{app_embed_ext_phase} /* Embed App Extensions */,
\t\t\t\t{app_embed_helpers_phase} /* Embed Helpers */,
\t\t\t\t{app_copy_scripts_phase} /* Copy Scripts */,
\t\t\t\t{app_bundle_git_phase} /* Bundle Git */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t\t{deps[0][1]},
\t\t\t\t{deps[1][1]},
\t\t\t\t{deps[2][1]},
\t\t\t);
\t\t\tname = RepoShell;
\t\t\tpackageProductDependencies = (
\t\t\t\t{pkg_shared_app_id},
\t\t\t\t{pkg_vcs_app_id},
\t\t\t\t{pkg_services_app_id},
\t\t\t);
\t\t\tproductName = RepoShell;
\t\t\tproductReference = {prod_app_ref};
\t\t\tproductType = "com.apple.product-type.application";
\t\t}};""")

    lines.append(f"""\t\t{target_ext_id} /* RepoShellFinderSync */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {ext_cfg_list_id};
\t\t\tbuildPhases = (
\t\t\t\t{ext_sources_phase} /* Sources */,
\t\t\t\t{ext_frameworks_phase} /* Frameworks */,
\t\t\t\t{ext_resources_phase} /* Resources */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t);
\t\t\tname = RepoShellFinderSync;
\t\t\tpackageProductDependencies = (
\t\t\t\t{pkg_shared_ext_id},
\t\t\t);
\t\t\tproductName = RepoShellFinderSync;
\t\t\tproductReference = {prod_ext_ref};
\t\t\tproductType = "com.apple.product-type.app-extension";
\t\t}};""")

    lines.append(f"""\t\t{target_cred_id} /* git-credential-reposhell */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {cred_cfg_list_id};
\t\t\tbuildPhases = (
\t\t\t\t{cred_sources_phase} /* Sources */,
\t\t\t\t{cred_frameworks_phase} /* Frameworks */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t);
\t\t\tname = "git-credential-reposhell";
\t\t\tpackageProductDependencies = (
\t\t\t\t{pkg_shared_cred_id},
\t\t\t);
\t\t\tproductName = "git-credential-reposhell";
\t\t\tproductReference = {prod_cred_ref};
\t\t\tproductType = "com.apple.product-type.tool";
\t\t}};""")

    lines.append(f"""\t\t{target_ask_id} /* reposhell-askpass */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {ask_cfg_list_id};
\t\t\tbuildPhases = (
\t\t\t\t{ask_sources_phase} /* Sources */,
\t\t\t\t{ask_frameworks_phase} /* Frameworks */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t);
\t\t\tname = "reposhell-askpass";
\t\t\tpackageProductDependencies = (
\t\t\t\t{pkg_shared_ask_id},
\t\t\t);
\t\t\tproductName = "reposhell-askpass";
\t\t\tproductReference = {prod_askpass_ref};
\t\t\tproductType = "com.apple.product-type.tool";
\t\t}};""")
    lines.append("/* End PBXNativeTarget section */")
    lines.append("")

    # Project
    lines.append("/* Begin PBXProject section */")
    lines.append(f"""\t\t{project_id} /* Project object */ = {{
\t\t\tisa = PBXProject;
\t\t\tattributes = {{
\t\t\t\tBuildIndependentTargetsInParallel = 1;
\t\t\t\tLastSwiftUpdateCheck = 1500;
\t\t\t\tLastUpgradeCheck = 1500;
\t\t\t\tTargetAttributes = {{
\t\t\t\t\t{target_app_id} = {{ CreatedOnToolsVersion = 15.0; }};
\t\t\t\t\t{target_ext_id} = {{ CreatedOnToolsVersion = 15.0; }};
\t\t\t\t\t{target_cred_id} = {{ CreatedOnToolsVersion = 15.0; }};
\t\t\t\t\t{target_ask_id} = {{ CreatedOnToolsVersion = 15.0; }};
\t\t\t\t}};
\t\t\t}};
\t\t\tbuildConfigurationList = {proj_cfg_list_id};
\t\t\tcompatibilityVersion = "Xcode 14.0";
\t\t\tdevelopmentRegion = en;
\t\t\thasScannedForEncodings = 0;
\t\t\tknownRegions = (
\t\t\t\ten,
\t\t\t\tBase,
\t\t\t\t"zh-Hans",
\t\t\t);
\t\t\tmainGroup = {main_group_id};
\t\t\tpackageReferences = (
\t\t\t\t{local_pkg_ref_id} /* XCLocalSwiftPackageReference "Packages/RepoShellCore" */,
\t\t\t);
\t\t\tproductRefGroup = {products_group_id};
\t\t\tprojectDirPath = "";
\t\t\tprojectRoot = "";
\t\t\ttargets = (
\t\t\t\t{target_app_id} /* RepoShell */,
\t\t\t\t{target_ext_id} /* RepoShellFinderSync */,
\t\t\t\t{target_cred_id} /* git-credential-reposhell */,
\t\t\t\t{target_ask_id} /* reposhell-askpass */,
\t\t\t);
\t\t}};""")
    lines.append("/* End PBXProject section */")
    lines.append("")

    # Resources Build Phases
    lines.append("/* Begin PBXResourcesBuildPhase section */")
    for pid, bfs in [(app_resources_phase, app_res_bfs), (ext_resources_phase, ext_res_bfs)]:
        lines.append(f"\t\t{pid} /* Resources */ = {{\n\t\t\tisa = PBXResourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (")
        for bf in bfs:
            lines.append(f"\t\t\t\t{bf},")
        lines.append("\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t};")
    lines.append("/* End PBXResourcesBuildPhase section */")
    lines.append("")

    # Shell Script Phase (bundle-git.sh)
    lines.append("/* Begin PBXShellScriptBuildPhase section */")
    lines.append(f"""\t\t{app_bundle_git_phase} /* Bundle Git */ = {{
\t\t\tisa = PBXShellScriptBuildPhase;
\t\t\talwaysOutOfDate = 1;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\tinputPaths = (
\t\t\t);
\t\t\tname = "Bundle Git";
\t\t\toutputPaths = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t\tshellPath = /bin/bash;
\t\t\tshellScript = "bash \\"${{SRCROOT}}/scripts/bundle-git.sh\\"";
\t\t}};""")
    lines.append("/* End PBXShellScriptBuildPhase section */")
    lines.append("")

    # Sources Build Phases
    lines.append("/* Begin PBXSourcesBuildPhase section */")
    for pid, bfs in [
        (app_sources_phase, app_source_bfs),
        (ext_sources_phase, ext_source_bfs),
        (cred_sources_phase, cred_source_bfs),
        (ask_sources_phase, ask_source_bfs),
    ]:
        lines.append(f"\t\t{pid} /* Sources */ = {{\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (")
        for bf in bfs:
            lines.append(f"\t\t\t\t{bf},")
        lines.append("\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t};")
    lines.append("/* End PBXSourcesBuildPhase section */")
    lines.append("")

    # Target Dependencies
    lines.append("/* Begin PBXTargetDependency section */")
    for proxy_id, dep_id, name in deps:
        dep_tid = make_id(f"target:{name}")
        lines.append(f"\t\t{dep_id} /* PBXTargetDependency */ = {{isa = PBXTargetDependency; target = {dep_tid}; targetProxy = {proxy_id}; }};")
    lines.append("/* End PBXTargetDependency section */")
    lines.append("")

    # Variant Groups
    lines.append("/* Begin PBXVariantGroup section */")
    for vg_id, vg_name, children in b.variant_groups:
        lines.append(f"\t\t{vg_id} /* {vg_name} */ = {{\n\t\t\tisa = PBXVariantGroup;\n\t\t\tchildren = (")
        for cid, cname in children:
            lines.append(f"\t\t\t\t{cid} /* {cname} */,")
        lines.append(f'\t\t\t);\n\t\t\tname = "{vg_name}";\n\t\t\tsourceTree = "<group>";\n\t\t}};')
    lines.append("/* End PBXVariantGroup section */")
    lines.append("")

    # Build Configurations
    common_proj_settings = """
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_MODULES = YES;
				CODE_SIGN_IDENTITY = "Apple Development";
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				DEVELOPMENT_TEAM = YM3PT5F5G4;
				ENABLE_DEBUG_DYLIB = NO;
				MACOSX_DEPLOYMENT_TARGET = 13.0;
				MARKETING_VERSION = 0.1.2;
				SDKROOT = macosx;
				SWIFT_VERSION = 5.0;"""

    lines.append("/* Begin XCBuildConfiguration section */")
    lines.append(f"""\t\t{proj_dbg_id} /* Debug */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{{common_proj_settings}
\t\t\t\tGCC_OPTIMIZATION_LEVEL = 0;
\t\t\t\tONLY_ACTIVE_ARCH = YES;
\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;
\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-Onone";
\t\t\t}};
\t\t\tname = Debug;
\t\t}};""")
    lines.append(f"""\t\t{proj_rel_id} /* Release */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{{common_proj_settings}
\t\t\t\tSWIFT_COMPILATION_MODE = wholemodule;
\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-O";
\t\t\t}};
\t\t\tname = Release;
\t\t}};""")

    for cfg_id, name in [(app_dbg_id, "Debug"), (app_rel_id, "Release")]:
        lines.append(f"""\t\t{cfg_id} /* {name} */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tCODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO;
\t\t\t\tCOMBINE_HIDPI_IMAGES = YES;
\t\t\t\tENABLE_APP_SANDBOX = NO;
\t\t\t\tENABLE_HARDENED_RUNTIME = YES;
\t\t\t\tINFOPLIST_FILE = "Targets/RepoShellApp/Info.plist";
\t\t\t\tLD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/../Frameworks";
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = "com.leaf.reposhell";
\t\t\t\tPRODUCT_NAME = RepoShell;
\t\t\t}};
\t\t\tname = {name};
\t\t}};""")

    for cfg_id, name in [(ext_dbg_id, "Debug"), (ext_rel_id, "Release")]:
        lines.append(f"""\t\t{cfg_id} /* {name} */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tCODE_SIGN_ENTITLEMENTS = "Targets/RepoShellFinderSync/RepoShellFinderSync.entitlements";
\t\t\t\tENABLE_APP_SANDBOX = YES;
\t\t\t\tINFOPLIST_FILE = "Targets/RepoShellFinderSync/Info.plist";
\t\t\t\tLD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/../Frameworks @executable_path/../../../../Frameworks";
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = "com.leaf.reposhell.FinderSync";
\t\t\t\tPRODUCT_NAME = RepoShellFinderSync;
\t\t\t\tSKIP_INSTALL = YES;
\t\t\t}};
\t\t\tname = {name};
\t\t}};""")

    for cfg_id, name in [(cred_dbg_id, "Debug"), (cred_rel_id, "Release")]:
        lines.append(f"""\t\t{cfg_id} /* {name} */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tPRODUCT_NAME = "git-credential-reposhell";
\t\t\t\tSKIP_INSTALL = YES;
\t\t\t}};
\t\t\tname = {name};
\t\t}};""")

    for cfg_id, name in [(ask_dbg_id, "Debug"), (ask_rel_id, "Release")]:
        lines.append(f"""\t\t{cfg_id} /* {name} */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tPRODUCT_NAME = "reposhell-askpass";
\t\t\t\tSKIP_INSTALL = YES;
\t\t\t}};
\t\t\tname = {name};
\t\t}};""")
    lines.append("/* End XCBuildConfiguration section */")
    lines.append("")

    # Configuration Lists
    lines.append("/* Begin XCConfigurationList section */")
    for list_id, dbg, rel, owner in [
        (proj_cfg_list_id, proj_dbg_id, proj_rel_id, "PBXProject"),
        (app_cfg_list_id, app_dbg_id, app_rel_id, "PBXNativeTarget RepoShell"),
        (ext_cfg_list_id, ext_dbg_id, ext_rel_id, "PBXNativeTarget RepoShellFinderSync"),
        (cred_cfg_list_id, cred_dbg_id, cred_rel_id, "PBXNativeTarget git-credential-reposhell"),
        (ask_cfg_list_id, ask_dbg_id, ask_rel_id, "PBXNativeTarget reposhell-askpass"),
    ]:
        lines.append(f"""\t\t{list_id} /* Build configuration list for {owner} */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{dbg} /* Debug */,
\t\t\t\t{rel} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};""")
    lines.append("/* End XCConfigurationList section */")
    lines.append("")

    # XCLocalSwiftPackageReference & XCSwiftPackageProductDependency
    lines.append("/* Begin XCLocalSwiftPackageReference section */")
    lines.append(f"""\t\t{local_pkg_ref_id} /* XCLocalSwiftPackageReference "Packages/RepoShellCore" */ = {{
\t\t\tisa = XCLocalSwiftPackageReference;
\t\t\trelativePath = Packages/RepoShellCore;
\t\t}};""")
    lines.append("/* End XCLocalSwiftPackageReference section */")
    lines.append("")

    lines.append("/* Begin XCSwiftPackageProductDependency section */")
    for pid, pname in [
        (pkg_shared_app_id, "RepoShellShared"),
        (pkg_vcs_app_id, "RepoShellVcs"),
        (pkg_services_app_id, "RepoShellServices"),
        (pkg_shared_ext_id, "RepoShellShared"),
        (pkg_shared_cred_id, "RepoShellShared"),
        (pkg_shared_ask_id, "RepoShellShared"),
    ]:
        lines.append(f"""\t\t{pid} /* {pname} */ = {{
\t\t\tisa = XCSwiftPackageProductDependency;
\t\t\tpackage = {local_pkg_ref_id};
\t\t\tproductName = {pname};
\t\t}};""")
    lines.append("/* End XCSwiftPackageProductDependency section */")
    lines.append("")

    lines.append("\t};")
    lines.append(f"\trootObject = {project_id} /* Project object */;")
    lines.append("}")

    XCODEPROJ.mkdir(parents=True, exist_ok=True)
    SCHEME_DIR.mkdir(parents=True, exist_ok=True)
    PBXPROJ.write_text("\n".join(lines) + "\n", encoding="utf-8")

    # Write shared RepoShell.xcscheme
    scheme_xml = f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1500"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{target_app_id}"
               BuildableName = "RepoShell.app"
               BlueprintName = "RepoShell"
               ReferencedContainer = "container:RepoShell.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{target_app_id}"
            BuildableName = "RepoShell.app"
            BlueprintName = "RepoShell"
            ReferencedContainer = "container:RepoShell.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""
    (SCHEME_DIR / "RepoShell.xcscheme").write_text(scheme_xml, encoding="utf-8")
    print(f"Generated {XCODEPROJ}")


if __name__ == "__main__":
    main()
