#!/usr/bin/env bash
set -euo pipefail

# Builds a relocatable, macOS 13.0+ Universal (arm64 + x86_64) portable Git package from official source.
# Output directory defaults to ./third_party/portable-git, automatically picked up by scripts/bundle-git.sh.

GIT_VERSION="${GIT_VERSION:-2.47.1}"
DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="${ROOT_DIR}/third_party/src"
OUT_DIR="${REPOSHELL_PORTABLE_GIT_DIR:-${ROOT_DIR}/third_party/portable-git}"
TARBALL="git-${GIT_VERSION}.tar.xz"
URL="https://mirrors.edge.kernel.org/pub/software/scm/git/${TARBALL}"

mkdir -p "${WORK_DIR}" "${OUT_DIR}"

if [[ ! -f "${WORK_DIR}/${TARBALL}" ]]; then
  echo "Downloading Git ${GIT_VERSION}..."
  curl -fsSL "${URL}" -o "${WORK_DIR}/${TARBALL}"
fi

SRC_DIR="${WORK_DIR}/git-${GIT_VERSION}"
rm -rf "${SRC_DIR}"
tar -xf "${WORK_DIR}/${TARBALL}" -C "${WORK_DIR}"

cd "${SRC_DIR}"
JOBS="$(sysctl -n hw.ncpu)"

export MACOSX_DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET}"
export CFLAGS="-O2 -mmacosx-version-min=${DEPLOYMENT_TARGET} -arch arm64 -arch x86_64"
export LDFLAGS="-mmacosx-version-min=${DEPLOYMENT_TARGET} -arch arm64 -arch x86_64"

make -j"${JOBS}" \
  prefix=/ \
  RUNTIME_PREFIX=YesPlease \
  NO_GETTEXT=YesPlease \
  NO_TCLTK=YesPlease \
  NO_PERL=YesPlease \
  NO_PYTHON=YesPlease \
  DESTDIR="${OUT_DIR}" \
  install

echo "Portable Git ${GIT_VERSION} built successfully at ${OUT_DIR}"
