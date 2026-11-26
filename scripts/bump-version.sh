#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

APP_PLIST="Targets/RepoShellApp/Info.plist"
EXT_PLIST="Targets/RepoShellFinderSync/Info.plist"
APP_CONSTANTS="Packages/RepoShellCore/Sources/RepoShellShared/AppConstants.swift"
SERVICES_TESTS="Packages/RepoShellCore/Tests/RepoShellCoreTests/ServicesTests.swift"
README_FILE="README.md"
GEN_XCODEPROJ="scripts/generate_xcodeproj.py"
PBXPROJ_FILE="RepoShell.xcodeproj/project.pbxproj"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/bump-version.sh <version|patch|minor|major> [--build <number>] [--commit] [--tag]

Examples:
  ./scripts/bump-version.sh 0.1.2
  ./scripts/bump-version.sh patch
  ./scripts/bump-version.sh 0.2.0 --build 1 --commit --tag

Options:
  --build <n>   Also update CFBundleVersion / CURRENT_PROJECT_VERSION / defaultBuildNumber
  --commit      Commit the updated version files
  --tag         Create git tag v<version> (implies --commit if there are staged version changes)
  -h, --help    Show this help message
EOF
}

if [[ $# -eq 0 ]]; then
  usage
  exit 1
fi

TARGET_ARG=""
BUILD_NUMBER=""
DO_COMMIT=0
DO_TAG=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --build)
      if [[ $# -lt 2 ]]; then
        echo "Error: --build requires a value" >&2
        exit 1
      fi
      BUILD_NUMBER="$2"
      shift 2
      ;;
    --commit)
      DO_COMMIT=1
      shift
      ;;
    --tag)
      DO_TAG=1
      DO_COMMIT=1
      shift
      ;;
    -*)
      echo "Error: Unknown option '$1'" >&2
      usage
      exit 1
      ;;
    *)
      if [[ -z "${TARGET_ARG}" ]]; then
        TARGET_ARG="$1"
      else
        echo "Error: Unexpected argument '$1'" >&2
        usage
        exit 1
      fi
      shift
      ;;
  esac
done

if [[ -z "${TARGET_ARG}" ]]; then
  echo "Error: Missing version argument" >&2
  usage
  exit 1
fi

CURRENT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP_PLIST}")"

resolve_version() {
  local input="${1#v}"
  if [[ "${input}" == "patch" || "${input}" == "minor" || "${input}" == "major" ]]; then
    if [[ ! "${CURRENT_VERSION}" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then
      echo "Error: Current version '${CURRENT_VERSION}' is not X.Y.Z; cannot auto-increment" >&2
      exit 1
    fi
    local major="${BASH_REMATCH[1]}"
    local minor="${BASH_REMATCH[2]}"
    local patch="${BASH_REMATCH[3]}"
    case "${input}" in
      patch) echo "${major}.${minor}.$((patch + 1))" ;;
      minor) echo "${major}.$((minor + 1)).0" ;;
      major) echo "$((major + 1)).0.0" ;;
    esac
  else
    echo "${input}"
  fi
}

NEW_VERSION="$(resolve_version "${TARGET_ARG}")"

if [[ ! "${NEW_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
  echo "Error: Invalid version '${NEW_VERSION}'. Expected semantic version like 0.1.2" >&2
  exit 1
fi

if [[ -n "${BUILD_NUMBER}" && ! "${BUILD_NUMBER}" =~ ^[0-9]+$ ]]; then
  echo "Error: Invalid build number '${BUILD_NUMBER}'. Expected positive integer." >&2
  exit 1
fi

echo "Updating version: ${CURRENT_VERSION} -> ${NEW_VERSION}${BUILD_NUMBER:+ (build ${BUILD_NUMBER})}"

python3 - "${NEW_VERSION}" "${BUILD_NUMBER}" \
  "${APP_PLIST}" "${EXT_PLIST}" \
  "${APP_CONSTANTS}" "${SERVICES_TESTS}" "${README_FILE}" "${GEN_XCODEPROJ}" <<'PY'
import re
import sys
from pathlib import Path

new_ver, build_num, app_plist, ext_plist, app_constants, services_tests, readme_file, gen_xcodeproj = sys.argv[1:9]

def replace_exact(path_str: str, pattern: str, replacement: str) -> None:
    path = Path(path_str)
    content = path.read_text(encoding="utf-8")
    updated, count = re.subn(pattern, replacement, content, flags=re.MULTILINE)
    if count == 0:
        raise SystemExit(f"Error: pattern not found in {path_str}: {pattern}")
    path.write_text(updated, encoding="utf-8")

for plist in (app_plist, ext_plist):
    replace_exact(
        plist,
        r'(<key>CFBundleShortVersionString</key>\s*<string>)[^<]+(</string>)',
        rf'\g<1>{new_ver}\g<2>',
    )
    if build_num:
        replace_exact(
            plist,
            r'(<key>CFBundleVersion</key>\s*<string>)[^<]+(</string>)',
            rf'\g<1>{build_num}\g<2>',
        )

replace_exact(
    app_constants,
    r'(public static let defaultVersion = ")[^"]+(")',
    rf'\g<1>{new_ver}\g<2>',
)
if build_num:
    replace_exact(
        app_constants,
        r'(public static let defaultBuildNumber = ")[^"]+(")',
        rf'\g<1>{build_num}\g<2>',
    )

replace_exact(
    services_tests,
    r'(XCTAssertEqual\(AppConstants\.defaultVersion, ")[^"]+("\))',
    rf'\g<1>{new_ver}\g<2>',
)

replace_exact(
    readme_file,
    r'^(- \*\*当前版本\*\*：`)(?:[^`]+)(`)$',
    rf'\g<1>{new_ver}\g<2>',
)

replace_exact(
    gen_xcodeproj,
    r'(MARKETING_VERSION = )[^;]+(;)',
    rf'\g<1>{new_ver}\g<2>',
)
if build_num:
    replace_exact(
        gen_xcodeproj,
        r'(CURRENT_PROJECT_VERSION = )[^;]+(;)',
        rf'\g<1>{build_num}\g<2>',
    )
PY

python3 "${GEN_XCODEPROJ}"

echo "Updated files:"
echo "  - ${APP_PLIST}"
echo "  - ${EXT_PLIST}"
echo "  - ${APP_CONSTANTS}"
echo "  - ${SERVICES_TESTS}"
echo "  - ${README_FILE}"
echo "  - ${GEN_XCODEPROJ}"
echo "  - ${PBXPROJ_FILE}"

if [[ ${DO_COMMIT} -eq 1 ]]; then
  git add "${APP_PLIST}" "${EXT_PLIST}" "${APP_CONSTANTS}" "${SERVICES_TESTS}" "${README_FILE}" "${GEN_XCODEPROJ}" "${PBXPROJ_FILE}"
  if ! git diff --cached --quiet; then
    git commit -m "bump version to ${NEW_VERSION}"
  fi
fi

if [[ ${DO_TAG} -eq 1 ]]; then
  TAG_NAME="v${NEW_VERSION}"
  if git rev-parse "${TAG_NAME}" >/dev/null 2>&1; then
    echo "Error: Tag '${TAG_NAME}' already exists" >&2
    exit 1
  fi
  git tag "${TAG_NAME}"
  echo "Created tag ${TAG_NAME}"
fi
