#!/usr/bin/env bash
set -euo pipefail

GAOKUN_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=build.env
. "$GAOKUN_DIR/build.env"
# shellcheck source=scripts/ci/lib/kernel_tree.sh
. "$GAOKUN_DIR/scripts/ci/lib/kernel_tree.sh"

case "${1:-help}" in
  kernel|debs|rpms) action="$1" ;;
  help|--help|-h)
    echo 'Usage: ./build.sh kernel|debs|rpms'
    echo 'Inputs: build.env; optional WORKDIR, KERNEL_SRC, BUILD_EL2=true,'
    echo '        KERNEL_TOOLCHAIN=gcc|clang, KERNEL_TUNE, BUILD_KERNELSU=true.'
    echo 'The kernel tree is the gaokun3 XanMod fork; this repository only'
    echo 'fetches it, builds it, and packages the result.'
    exit 0 ;;
  *) echo "Unknown action: $1" >&2; exit 2 ;;
esac
[[ $# -eq 1 ]] || { echo 'Expected one action; see --help.' >&2; exit 2; }

WORKDIR="${WORKDIR:-$GAOKUN_DIR/build}"
mkdir -p "$WORKDIR"
WORKDIR="$(cd "$WORKDIR" && pwd)"
BUILD_EL2="${BUILD_EL2:-false}"
KERN_SRC="${KERN_SRC:-$WORKDIR/linux}"
KERN_OUT="${KERN_OUT:-$WORKDIR/kernel-out}"
KERN_OUT_EL2="${KERN_OUT_EL2:-$WORKDIR/kernel-out-el2}"
ARTIFACT_DIR="${ARTIFACT_DIR:-$WORKDIR/artifacts}"

# KERNEL_SRC names an existing checkout to build instead of fetching. Without
# it the tree is fetched from KERNEL_REPOSITORY into KERN_SRC.
if [[ -z "${KERNEL_SRC:-}" && -d "$HOME/git/linux-xanmod-gaokun3/.git" ]]; then
  KERNEL_SRC="$HOME/git/linux-xanmod-gaokun3"
fi

if [[ -n "${KERNEL_SRC:-}" ]]; then
  KERN_SRC="$KERNEL_SRC"
  if [[ -n "$(git -C "$KERN_SRC" status --porcelain)" ]]; then
    echo "kernel checkout $KERN_SRC has local changes; commit or stash them first" >&2
    exit 1
  fi
  KERNEL_COMMIT="$(git -C "$KERN_SRC" rev-parse HEAD)"
else
  KERNEL_COMMIT="$(fetch_kernel_tree "$KERN_SRC")"
fi

# The EL2 variant is a separate branch, so every build fetches it into its own
# checkout instead of reusing the standard one.
if [[ "$BUILD_EL2" == "true" ]]; then
  KERN_SRC_EL2="${KERN_SRC_EL2:-$WORKDIR/linux-el2}"
  KERNEL_REF="$KERNEL_EL2_REF" fetch_kernel_tree "$KERN_SRC_EL2" >/dev/null
fi

read_kernel_manifest "$KERN_SRC"

export GAOKUN_DIR WORKDIR KERN_SRC KERN_SRC_EL2 KERN_OUT KERN_OUT_EL2 ARTIFACT_DIR
export BUILD_EL2 KERNEL_TAG KERNEL_REPOSITORY KERNEL_COMMIT KERNEL_EL2_REF KERNEL_EL2_COMMIT
export PACKAGE_RELEASE_TAG="${PACKAGE_RELEASE_TAG:-local-$KERNEL_TAG}"
bash "$GAOKUN_DIR/scripts/ci/20_build_kernel.sh"
case "$action" in
  debs) bash "$GAOKUN_DIR/scripts/ci/70_build_package_debs.sh" ;;
  rpms) bash "$GAOKUN_DIR/scripts/ci/70_build_package_rpms.sh" ;;
esac
