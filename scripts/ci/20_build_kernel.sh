#!/usr/bin/env bash
set -euo pipefail

: "${GAOKUN_DIR:?missing GAOKUN_DIR}"
: "${WORKDIR:?missing WORKDIR}"
: "${KERN_SRC:?missing KERN_SRC}"

# shellcheck source=lib/kernel_tree.sh
. "$GAOKUN_DIR/scripts/ci/lib/kernel_tree.sh"
# shellcheck source=lib/kernelsu.sh
. "$GAOKUN_DIR/scripts/ci/lib/kernelsu.sh"
# shellcheck source=lib/toolchain.sh
. "$GAOKUN_DIR/scripts/ci/lib/toolchain.sh"

read_kernel_manifest "$KERN_SRC"
resolve_kernel_toolchain

KERN_OUT="${KERN_OUT:-$WORKDIR/kernel-out}"
KERN_OUT_EL2="${KERN_OUT_EL2:-$WORKDIR/kernel-out-el2}"
BUILD_EL2="${BUILD_EL2:-false}"
# Opt-in: when true, every requested variant is built with the pinned KernelSU
# integration applied before its kernel is configured.
BUILD_KERNELSU="${BUILD_KERNELSU:-false}"

if [[ "$(uname -m)" == "aarch64" ]]; then
  CROSS_COMPILE="${CROSS_COMPILE:-}"
else
  CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
fi

# Confirm the compiler accepts the requested microarchitecture tuning before any
# variant is configured, so an unsupported CPU name fails immediately instead of
# deep inside the build. Portable builds (KERNEL_TUNE unset) skip this.
if [[ -n "$KERNEL_TUNE" ]]; then
  if [[ "$KERNEL_TOOLCHAIN" == "clang" ]]; then
    validate_kernel_tune clang --target=aarch64-linux-gnu
  else
    validate_kernel_tune "${CROSS_COMPILE}gcc"
  fi
fi

export ARCH=arm64
export CCACHE_DIR="${CCACHE_DIR:-$HOME/.ccache}"
export CCACHE_BASEDIR="${CCACHE_BASEDIR:-$WORKDIR}"
export CCACHE_NOHASHDIR="${CCACHE_NOHASHDIR:-true}"
export CCACHE_COMPILERCHECK="${CCACHE_COMPILERCHECK:-content}"
export PATH="/usr/lib/ccache:$PATH"

# The kernel checkout is not the buildbot repository, so it carries no
# committer identity of its own. CI runners and fresh containers have none
# configured, yet the KernelSU integration commit needs one, so set a local
# identity in the target repo when it is missing.
configure_git_identity() {
  local repo_dir="$1"
  if [[ -z "$(git -C "$repo_dir" config user.name || true)" ]]; then
    git -C "$repo_dir" config user.name "gaokun3 buildbot"
  fi
  if [[ -z "$(git -C "$repo_dir" config user.email || true)" ]]; then
    git -C "$repo_dir" config user.email "buildbot@gaokun3.invalid"
  fi
}

build_variant() {
  local src_dir="$1"
  local out_dir="$2"
  local dtb="$3"
  local kernelsu="${4:-false}"

  mkdir -p "$out_dir"

  unset KCONFIG_CONFIG
  make -C "$src_dir" O="$out_dir" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" "${KERNEL_MAKE_ARGS[@]}" "$KERNEL_DEFCONFIG"

  # Toolchain-dependent Kconfig (Clang ThinLTO) and KernelSU must both be set in
  # the generated .config before olddefconfig resolves the unmet dependencies.
  apply_kernel_toolchain_config "$src_dir" "$out_dir"
  if [[ "$kernelsu" == "true" ]]; then
    configure_kernel_su "$src_dir" "$out_dir"
  fi

  make -C "$src_dir" O="$out_dir" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" "${KERNEL_MAKE_ARGS[@]}" olddefconfig

  assert_kernel_toolchain_config "$out_dir"
  if [[ "$kernelsu" == "true" ]]; then
    assert_kernelsu_enabled "$out_dir"
  fi

  make -C "$src_dir" O="$out_dir" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" "${KERNEL_MAKE_ARGS[@]}" -j"$(nproc)"
  # The manifest names the DTB by file name, while the qcom Makefile exposes it
  # as a target relative to arch/arm64/boot/dts/.
  make -C "$src_dir" O="$out_dir" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" "${KERNEL_MAKE_ARGS[@]}" "qcom/$dtb"
  make -C "$src_dir" O="$out_dir" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" "${KERNEL_MAKE_ARGS[@]}" modules_prepare
}

# The tree is a working checkout during a local build and a fetched detached
# checkout in CI. KernelSU integration edits files, so refuse to start from a
# dirty tree rather than mixing the integration into unrelated local edits.
if [[ -n "$(git -C "$KERN_SRC" status --porcelain)" ]]; then
  echo "kernel checkout $KERN_SRC has local changes; commit or stash them first" >&2
  exit 1
fi

if [[ "$BUILD_KERNELSU" == "true" ]]; then
  configure_git_identity "$KERN_SRC"
  echo "integrating KernelSU $KERNSU_REF ($KERNSU_COMMIT) into $KERN_SRC"
  if ! kernelsu_desc="$(integrate_kernelsu "$KERN_SRC")"; then
    echo "KernelSU integration failed for $KERN_SRC" >&2
    exit 1
  fi
  echo "KernelSU integration: $kernelsu_desc"
fi

ccache -z || true
build_variant "$KERN_SRC" "$KERN_OUT" "$KERNEL_DTB" "$BUILD_KERNELSU"
ccache -s || true

assert_kernel_output "$KERN_OUT" "$KERNEL_RELEASE" "$KERNEL_DTB"

if [[ "$BUILD_EL2" != "true" ]]; then
  exit 0
fi

# The EL2 variant is a separate branch of the kernel fork, so it is fetched
# into its own checkout instead of being patched into a copy of KERN_SRC.
KERN_SRC_EL2="${KERN_SRC_EL2:-$WORKDIR/linux-el2}"
if [[ "$(realpath -m "$KERN_SRC_EL2")" == "$(realpath -m "$KERN_SRC")" ]]; then
  echo "KERN_SRC_EL2 must differ from KERN_SRC for a separate EL2 checkout" >&2
  exit 1
fi
KERNEL_REF="${KERNEL_EL2_REF:?missing KERNEL_EL2_REF}" fetch_kernel_tree "$KERN_SRC_EL2"
read_kernel_manifest "$KERN_SRC_EL2"

if [[ "$BUILD_KERNELSU" == "true" ]]; then
  configure_git_identity "$KERN_SRC_EL2"
  if ! kernelsu_desc="$(integrate_kernelsu "$KERN_SRC_EL2")"; then
    echo "KernelSU integration failed for $KERN_SRC_EL2" >&2
    exit 1
  fi
  echo "KernelSU integration: $kernelsu_desc"
fi

ccache -z || true
build_variant "$KERN_SRC_EL2" "$KERN_OUT_EL2" "$KERNEL_DTB_EL2" "$BUILD_KERNELSU"
ccache -s || true

assert_kernel_output "$KERN_OUT_EL2" "$KERNEL_RELEASE_EL2" "$KERNEL_DTB_EL2"
