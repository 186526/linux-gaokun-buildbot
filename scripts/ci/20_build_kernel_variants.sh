#!/usr/bin/env bash
set -euo pipefail

: "${GAOKUN_DIR:?missing GAOKUN_DIR}"
: "${WORKDIR:?missing WORKDIR}"
: "${KERN_SRC:?missing KERN_SRC}"

# shellcheck source=lib/select_base.sh
. "$GAOKUN_DIR/scripts/ci/lib/select_base.sh"
resolve_kernel_base

# shellcheck source=lib/kernelsu.sh
. "$GAOKUN_DIR/scripts/ci/lib/kernelsu.sh"

KERN_OUT="${KERN_OUT:-$WORKDIR/kernel-out}"
KERN_SRC_BASE="${KERN_SRC_BASE:-$KERN_SRC}"
KERN_SRC_EL2="${KERN_SRC_EL2:-$WORKDIR/linux-el2}"
KERN_OUT_EL2="${KERN_OUT_EL2:-}"
BUILD_EL2="${BUILD_EL2:-false}"
# Opt-in: when true, every requested variant is built with the pinned KernelSU
# integration applied before its kernel is configured.
BUILD_KERNELSU="${BUILD_KERNELSU:-false}"

if [[ "$(uname -m)" == "aarch64" ]]; then
  CROSS_COMPILE="${CROSS_COMPILE:-}"
else
  CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
fi

export ARCH=arm64
export CCACHE_DIR="${CCACHE_DIR:-$HOME/.ccache}"
export CCACHE_BASEDIR="${CCACHE_BASEDIR:-$WORKDIR}"
export CCACHE_NOHASHDIR="${CCACHE_NOHASHDIR:-true}"
export CCACHE_COMPILERCHECK="${CCACHE_COMPILERCHECK:-content}"
export PATH="/usr/lib/ccache:$PATH"

# The kernel checkout is not the buildbot repository, so it carries no
# committer identity of its own. CI runners and fresh containers have none
# configured, yet `git am` (apply_series) and the EL2 commit below both need
# one, so set a local identity in the target repo when it is missing. This
# replaces the helper that used to live only in scripts/local/build_kernel.sh.
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
  local localversion="${3:-}"
  local kernelsu="${4:-false}"

  mkdir -p "$out_dir"

  unset KCONFIG_CONFIG
  make -C "$src_dir" O="$out_dir" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" gaokun3_defconfig

  if [[ -n "$localversion" ]]; then
    "$src_dir"/scripts/config --file "$out_dir/.config" --set-str LOCALVERSION "$localversion"
  fi

  # KernelSU has to be enabled in the generated .config before olddefconfig
  # resolves the unmet KPROBES dependency.
  if [[ "$kernelsu" == "true" ]]; then
    configure_kernel_su "$src_dir" "$out_dir"
  fi

  make -C "$src_dir" O="$out_dir" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" olddefconfig

  if [[ "$kernelsu" == "true" ]]; then
    assert_kernelsu_enabled "$out_dir"
  fi

  make -C "$src_dir" O="$out_dir" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" -j"$(nproc)"
  make -C "$src_dir" O="$out_dir" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" modules_prepare
}

snapshot_tree() {
  local src_dir="$1"
  local dst_dir="$2"

  # Callers may legitimately point KERN_SRC_BASE at KERN_SRC itself (build.sh
  # does). Nothing has to be copied in that case, and recursing would have
  # deleted the live source tree, so treat src == dst as a no-op.
  if [[ "$(realpath -m "$src_dir")" == "$(realpath -m "$dst_dir")" ]]; then
    echo "snapshot_tree: source and destination are the same ($src_dir); skipping"
    return 0
  fi

  # Refuse to destroy a mismatched source: a snapshot must be taken from an
  # existing directory, so a typo or an unset KERN_SRC never wipes a checkout.
  if [[ ! -d "$src_dir" ]]; then
    echo "snapshot_tree: source $src_dir is not a directory" >&2
    return 1
  fi

  rm -rf "$dst_dir"
  mkdir -p "$dst_dir"
  cp -a "$src_dir"/. "$dst_dir"/
}

apply_patch() {
  local resolution="$1"

  if patch_is_already_applied "$KERN_SRC" "$resolution"; then
    echo "skip already-applied patch: $resolution"
    return 0
  fi

  git -C "$KERN_SRC" am "$resolution"
}

apply_series() {
  local series_name="$1"
  local shared_dir="$2"
  local patch_file

  while IFS= read -r patch_file; do
    apply_patch "$patch_file"
  done < <(patch_series_files "$series_name" "$shared_dir")
}

apply_el2_series() {
  local patch_file
  local patches=()

  while IFS= read -r patch_file; do
    if [[ "$patch_file" != "$GAOKUN_DIR/patches/el2/$(basename "$patch_file")" ]]; then
      echo "using base override: $patch_file"
    fi
    patches+=("$patch_file")
  done < <(patch_series_files el2 "$GAOKUN_DIR/patches/el2")

  git -C "$KERN_SRC_EL2" apply "${patches[@]}"
}

mkdir -p "$WORKDIR"

configure_git_identity "$KERN_SRC"
if [[ "$KERNEL_BASE" == "xanmod" ]]; then
  apply_series upstream "$GAOKUN_DIR"/patches/upstream
  apply_series others "$GAOKUN_DIR"/patches/others
  apply_series media "$GAOKUN_DIR"/patches/media
  apply_patch "$(patch_resolution_for . "$GAOKUN_DIR/patches/0099-arm64-gaokun3-import-local-dts-and-defconfig.patch")"
else
  test -f "$KERN_SRC/arch/arm64/configs/gaokun3_defconfig"
fi

# Wire the pinned KernelSU into the patched source tree before the variant is
# configured. Both the standard and the EL2 variant below are built from this
# wired tree.
if [[ "$BUILD_KERNELSU" == "true" ]]; then
  echo "integrating KernelSU $KERNSU_REF ($KERNSU_COMMIT) into $KERN_SRC"
  if ! kernelsu_desc="$(integrate_kernelsu "$KERN_SRC")"; then
    echo "KernelSU integration failed for $KERN_SRC" >&2
    exit 1
  fi
  echo "KernelSU integration: $kernelsu_desc"
fi

ccache -z || true
build_variant "$KERN_SRC" "$KERN_OUT" "" "$BUILD_KERNELSU"
ccache -s || true

BASE_KREL="$(cat "$KERN_OUT/include/config/kernel.release")"
echo "$BASE_KREL" > "$WORKDIR/kernel-release.txt"

snapshot_tree "$KERN_SRC" "$KERN_SRC_BASE"

if [[ "$BUILD_EL2" != "true" ]]; then
  exit 0
fi

# No standard rebuild here: the standard variant was already built above and
# its release recorded in kernel-release.txt. Re-running build_variant would
# rebuild the same tree/output and overwrite that file.
rm -f "$WORKDIR/kernel-release-el2.txt"

configure_git_identity "$KERN_SRC_EL2"
rm -rf "$KERN_OUT_EL2"
make -C "$KERN_SRC_EL2" O="$KERN_OUT_EL2" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" clean
apply_el2_series
if [[ "$BUILD_KERNELSU" == "true" ]]; then
  if ! kernelsu_desc="$(integrate_kernelsu "$KERN_SRC_EL2")"; then
    echo "KernelSU integration failed for $KERN_SRC_EL2" >&2
    exit 1
  fi
  echo "KernelSU integration: $kernelsu_desc"
fi
git -C "$KERN_SRC_EL2" add -A
git -C "$KERN_SRC_EL2" commit -m "Apply EL2 patches"

ccache -z || true
build_variant "$KERN_SRC_EL2" "$KERN_OUT_EL2" "-gaokun3-el2" "$BUILD_KERNELSU"
ccache -s || true

EL2_KREL="$(cat "$KERN_OUT_EL2/include/config/kernel.release")"
echo "$EL2_KREL" > "$WORKDIR/kernel-release-el2.txt"
