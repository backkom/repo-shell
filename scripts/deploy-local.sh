#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

PROJECT_FILE="RepoShell.xcodeproj"
SCHEME="RepoShell"
DERIVED_DATA="${ROOT_DIR}/build/DerivedData"
CONFIG="Release"
DEST_DIR="/Applications"
SKIP_BUILD=0
UNIVERSAL=0
OPEN_AFTER_DEPLOY=0
TEAM_ID=""
SIGN_IDENTITY=""

usage() {
  cat <<'EOF'
Usage:
  ./scripts/deploy-local.sh [options]

Build RepoShell.app and deploy it to /Applications (or a custom directory).

Options:
  -c, --config <Debug|Release>   Build configuration (default: Release)
  -d, --dest <dir>               Destination directory (default: /Applications)
  --skip-build                   Deploy existing build product without rebuilding
  --universal                    Build universal binary (arm64 + x86_64)
  --team <id>                    Use Automatic signing with the specified Team ID
  --identity <name>              Use Manual signing with the specified identity (default: ad-hoc "-")
  --open                         Launch RepoShell.app after deployment
  -h, --help                     Show this help message

Examples:
  ./scripts/deploy-local.sh
  ./scripts/deploy-local.sh --config Debug --open
  ./scripts/deploy-local.sh --universal --open
  ./scripts/deploy-local.sh --skip-build
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    -c|--config)
      [[ $# -ge 2 ]] || { echo "Error: --config requires a value" >&2; exit 1; }
      CONFIG="$2"
      shift 2
      ;;
    -d|--dest)
      [[ $# -ge 2 ]] || { echo "Error: --dest requires a value" >&2; exit 1; }
      DEST_DIR="$2"
      shift 2
      ;;
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    --universal)
      UNIVERSAL=1
      shift
      ;;
    --team)
      [[ $# -ge 2 ]] || { echo "Error: --team requires a value" >&2; exit 1; }
      TEAM_ID="$2"
      shift 2
      ;;
    --identity)
      [[ $# -ge 2 ]] || { echo "Error: --identity requires a value" >&2; exit 1; }
      SIGN_IDENTITY="$2"
      shift 2
      ;;
    --open)
      OPEN_AFTER_DEPLOY=1
      shift
      ;;
    *)
      echo "Error: Unknown option '$1'" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ "${CONFIG}" != "Debug" && "${CONFIG}" != "Release" ]]; then
  echo "Error: Invalid config '${CONFIG}'. Expected Debug or Release." >&2
  exit 1
fi

if [[ ! -d "${PROJECT_FILE}" ]]; then
  echo "Generating ${PROJECT_FILE}..."
  python3 scripts/generate_xcodeproj.py
fi

if [[ ${SKIP_BUILD} -eq 0 ]]; then
  XCODEBUILD_ARGS=(
    -project "${PROJECT_FILE}"
    -scheme "${SCHEME}"
    -configuration "${CONFIG}"
    -derivedDataPath "${DERIVED_DATA}"
  )

  if [[ ${UNIVERSAL} -eq 1 ]]; then
    XCODEBUILD_ARGS+=(ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO)
  else
    XCODEBUILD_ARGS+=(ONLY_ACTIVE_ARCH=YES)
  fi

  if [[ -n "${SIGN_IDENTITY}" ]]; then
    XCODEBUILD_ARGS+=(
      CODE_SIGN_IDENTITY="${SIGN_IDENTITY}"
      CODE_SIGN_STYLE=Manual
      DEVELOPMENT_TEAM="${TEAM_ID}"
    )
  elif [[ -n "${TEAM_ID}" ]]; then
    XCODEBUILD_ARGS+=(
      CODE_SIGN_IDENTITY="Apple Development"
      CODE_SIGN_STYLE=Automatic
      DEVELOPMENT_TEAM="${TEAM_ID}"
    )
  else
    XCODEBUILD_ARGS+=(
      CODE_SIGN_IDENTITY="-"
      CODE_SIGN_STYLE=Manual
      DEVELOPMENT_TEAM=""
    )
  fi

  echo "Building ${SCHEME} (${CONFIG})..."
  xcodebuild "${XCODEBUILD_ARGS[@]}" build
fi

SRC_APP="${DERIVED_DATA}/Build/Products/${CONFIG}/RepoShell.app"
DEST_APP="${DEST_DIR%/}/RepoShell.app"

if [[ ! -d "${SRC_APP}" ]]; then
  echo "Error: Build product not found at '${SRC_APP}'." >&2
  echo "Run without --skip-build or check --config." >&2
  exit 1
fi

if [[ ! -d "${DEST_DIR}" ]]; then
  echo "Error: Destination directory '${DEST_DIR}' does not exist." >&2
  exit 1
fi

if [[ ! -w "${DEST_DIR}" ]] || { [[ -e "${DEST_APP}" ]] && [[ ! -w "${DEST_APP}" ]]; }; then
  echo "Error: No write permission for '${DEST_APP}'. Try running with sufficient permissions." >&2
  exit 1
fi

# Stop running app and FinderSync extension before replacing bundle
if pgrep -x "RepoShell" >/dev/null 2>&1; then
  echo "Stopping running RepoShell..."
  osascript -e 'tell application "RepoShell" to quit' >/dev/null 2>&1 || true
  for _ in {1..20}; do
    pgrep -x "RepoShell" >/dev/null 2>&1 || break
    sleep 0.2
  done
  if pgrep -x "RepoShell" >/dev/null 2>&1; then
    pkill -x "RepoShell" >/dev/null 2>&1 || true
    sleep 0.3
  fi
fi

if pgrep -x "RepoShellFinderSync" >/dev/null 2>&1; then
  pkill -x "RepoShellFinderSync" >/dev/null 2>&1 || true
  sleep 0.2
fi

echo "Deploying ${SRC_APP} -> ${DEST_APP}..."
STAGED_APP="$(mktemp -d "${DEST_DIR%/}/.RepoShell.deploy.XXXXXX")/RepoShell.app"
cleanup() {
  rm -rf "$(dirname "${STAGED_APP}")"
}
trap cleanup EXIT

ditto "${SRC_APP}" "${STAGED_APP}"
xattr -cr "${STAGED_APP}" 2>/dev/null || true

rm -rf "${DEST_APP}"
mv "${STAGED_APP}" "${DEST_APP}"

echo "Verifying code signature..."
codesign --verify --deep --strict "${DEST_APP}"

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
SRC_APPEX="${SRC_APP}/Contents/PlugIns/RepoShellFinderSync.appex"
DEST_APPEX="${DEST_APP}/Contents/PlugIns/RepoShellFinderSync.appex"

# Prevent the DerivedData build product from shadowing the deployed /Applications bundle
if [[ -d "${SRC_APPEX}" ]]; then
  pluginkit -r "${SRC_APPEX}" >/dev/null 2>&1 || true
fi
if [[ -x "${LSREGISTER}" ]]; then
  "${LSREGISTER}" -u "${SRC_APP}" >/dev/null 2>&1 || true
  "${LSREGISTER}" -f -R -trusted "${DEST_APP}" >/dev/null 2>&1 || true
fi
if [[ -d "${DEST_APPEX}" ]]; then
  pluginkit -a "${DEST_APPEX}" >/dev/null 2>&1 || true
fi

APP_VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${DEST_APP}/Contents/Info.plist" 2>/dev/null || echo "unknown")"
APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${DEST_APP}/Contents/Info.plist" 2>/dev/null || echo "unknown")"

echo "Deployed RepoShell ${APP_VER} (${APP_BUILD}) to ${DEST_APP}"

if [[ ${OPEN_AFTER_DEPLOY} -eq 1 ]]; then
  echo "Launching ${DEST_APP}..."
  open "${DEST_APP}"
fi
