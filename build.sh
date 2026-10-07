#!/usr/bin/env bash
set -euo pipefail

GAOKUN_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# A caller-provided KERNEL_TAG (for example the real XanMod tag) is the naming
# label the packages and manifest must carry, so it has to survive sourcing
# build.env, whose KERNEL_TAG is only the local-build default. Without this the
# local manifest would label a XanMod build "gaokun3", the same mismatch the CI
# package workflow used to produce.
requested_kernel_tag="${KERNEL_TAG:-}"
# shellcheck source=build.env
. "$GAOKUN_DIR/build.env"
if [[ -n "$requested_kernel_tag" ]]; then
  KERNEL_TAG="$requested_kernel_tag"
fi
# shellcheck source=scripts/lib/kernel_source.sh
. "$GAOKUN_DIR/scripts/lib/kernel_source.sh"

case "${1:-help}" in
  kernel|debs|rpms) action="$1" ;;
  help|--help|-h)
    echo 'Usage: ./build.sh kernel|debs|rpms'
    echo 'Inputs: build.env; optional WORKDIR, KERN_SRC, BUILD_EL2=true.'
    echo 'debs/rpms build the kernel and packages using the host toolchain.'
    echo 'Image assembly currently runs through the Fedora/Ubuntu workflows.'
    exit 0 ;;
  *) echo "Unknown action: $1" >&2; exit 2 ;;
esac
[[ $# -eq 1 ]] || { echo 'Expected one action; see --help.' >&2; exit 2; }

WORKDIR="${WORKDIR:-$GAOKUN_DIR/build}"
mkdir -p "$WORKDIR"
WORKDIR="$(cd "$WORKDIR" && pwd)"
KERN_SRC="${KERN_SRC:-$WORKDIR/linux}"
if [[ "${BUILD_EL2:-false}" == true ]]; then
  # EL2 is patch-based: scripts/ci/20_build_kernel_variants.sh applies
  # patches/el2 on top of the prepared KERN_SRC tree once the standard variant
  # has been built and snapshotted. There is no separate EL2 commit to prepare,
  # so the EL2 variant reuses KERN_SRC, and KERN_SRC_BASE defaults to a distinct
  # snapshot so the standard packages keep their pre-EL2 headers tree.
  KERN_SRC_BASE="${KERN_SRC_BASE:-$WORKDIR/linux-base}"
  KERN_SRC_EL2="$KERN_SRC"
else
  # Without EL2 the EL2 paths are unused; KERN_SRC_BASE stays a no-op snapshot
  # of KERN_SRC so the package scripts can read the standard source tree.
  KERN_SRC_BASE="${KERN_SRC_BASE:-$KERN_SRC}"
  KERN_SRC_EL2="${KERN_SRC_EL2:-$WORKDIR/linux-el2}"
fi
KERN_OUT="${KERN_OUT:-$WORKDIR/kernel-out}"
KERN_OUT_EL2="${KERN_OUT_EL2:-$WORKDIR/kernel-out-el2}"
ARTIFACT_DIR="${ARTIFACT_DIR:-$WORKDIR/artifacts}"
BUILD_EL2="${BUILD_EL2:-false}"

prepare_kernel_source "$KERN_SRC" "$KERNEL_COMMIT"

export GAOKUN_DIR WORKDIR KERN_SRC KERN_SRC_BASE KERN_SRC_EL2 KERN_OUT KERN_OUT_EL2
export ARTIFACT_DIR BUILD_EL2 KERNEL_TAG KERNEL_REPOSITORY KERNEL_COMMIT KERNEL_EL2_COMMIT
export PACKAGE_RELEASE_TAG="${PACKAGE_RELEASE_TAG:-local-$KERNEL_TAG}"
bash "$GAOKUN_DIR/scripts/ci/20_build_kernel_variants.sh"
case "$action" in
  debs) bash "$GAOKUN_DIR/scripts/ci/70_build_package_debs.sh" ;;
  rpms) bash "$GAOKUN_DIR/scripts/ci/70_build_package_rpms.sh" ;;
esac
