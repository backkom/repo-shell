#!/usr/bin/env bash
set -euo pipefail

# Xcode Build Phase script to embed a relocatable Git distribution into RepoShell.app/Contents/Resources/git
DEST_DIR="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/git"
mkdir -p "${DEST_DIR}"

if [[ -n "${REPOSHELL_PORTABLE_GIT_DIR:-}" && -x "${REPOSHELL_PORTABLE_GIT_DIR}/bin/git" ]]; then
  SOURCE_GIT_DIR="${REPOSHELL_PORTABLE_GIT_DIR}"
elif [[ -x "${SRCROOT}/third_party/portable-git/bin/git" ]]; then
  SOURCE_GIT_DIR="${SRCROOT}/third_party/portable-git"
else
  # Fallback for local builds: assemble relocatable git tree from Xcode / CLT toolchain
  SOURCE_GIT_DIR=""
  for candidate in \
    "/Applications/Xcode.app/Contents/Developer/usr" \
    "/Library/Developer/CommandLineTools/usr" \
    "/opt/homebrew"; do
    if [[ -x "${candidate}/bin/git" && -d "${candidate}/libexec/git-core" ]]; then
      SOURCE_GIT_DIR="${candidate}"
      break
    fi
  done
fi

if [[ -z "${SOURCE_GIT_DIR}" ]]; then
  echo "warning: No source git installation found to bundle; runtime will fallback to system git."
  exit 0
fi

echo "Bundling git from: ${SOURCE_GIT_DIR} -> ${DEST_DIR}"

rm -rf "${DEST_DIR}/bin" "${DEST_DIR}/libexec" "${DEST_DIR}/share"
mkdir -p "${DEST_DIR}/bin" "${DEST_DIR}/libexec" "${DEST_DIR}/share/git-core"

cp -a "${SOURCE_GIT_DIR}/bin/git" "${DEST_DIR}/bin/git"
for extra_bin in git-shell scalar git-receive-pack git-upload-pack git-upload-archive; do
  if [[ -e "${SOURCE_GIT_DIR}/bin/${extra_bin}" ]]; then
    cp -a "${SOURCE_GIT_DIR}/bin/${extra_bin}" "${DEST_DIR}/bin/${extra_bin}"
  fi
done

if [[ -d "${SOURCE_GIT_DIR}/libexec/git-core" ]]; then
  rsync -a --links "${SOURCE_GIT_DIR}/libexec/git-core/" "${DEST_DIR}/libexec/git-core/"
fi

if [[ -d "${SOURCE_GIT_DIR}/share/git-core/templates" ]]; then
  rsync -a --links "${SOURCE_GIT_DIR}/share/git-core/templates/" "${DEST_DIR}/share/git-core/templates/"
fi

# Remove any dangling symlinks so strict codesign verification passes cleanly
find "${DEST_DIR}" -type l ! -exec test -e {} \; -delete

# Re-sign non-symlink Mach-O binaries inside the bundled git folder when CODE_SIGNING_ALLOWED=YES
if [[ "${CODE_SIGNING_ALLOWED:-NO}" == "YES" && -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
  echo "Signing bundled git binaries with ${EXPANDED_CODE_SIGN_IDENTITY}..."
  find "${DEST_DIR}" -type f ! -type l -perm +111 | while IFS= read -r binfile; do
    if file -b "${binfile}" | grep -q "Mach-O"; then
      /usr/bin/codesign --force --options runtime --sign "${EXPANDED_CODE_SIGN_IDENTITY}" --timestamp=none "${binfile}"
    fi
  done
fi
