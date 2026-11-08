#!/usr/bin/env bash
# Kernel-tree source preparation and build-product lookup shared by build.sh,
# the package scripts, and the image scripts.
#
# The device tree, defconfig, drivers, and EL2 kernel changes live in the
# gaokun3 XanMod fork (KERNEL_REPOSITORY in build.env), not in this repository.
# This helper only fetches that tree at a requested ref and reads the product
# manifest the tree carries at its root, so no script here needs to know which
# DTB or defconfig name the tree uses.

# Fetch KERNEL_TAG (or KERNEL_REF when set) from KERNEL_REPOSITORY into
# <destination> and check it out detached. An existing directory is reused only
# when it is clean and already at the requested commit; it is never reset.
# Prints the resolved commit on stdout.
fetch_kernel_tree() {
  local destination="$1"
  local repository="${KERNEL_REPOSITORY:?missing KERNEL_REPOSITORY}"
  local ref="${KERNEL_REF:-${KERNEL_TAG:?missing KERNEL_TAG}}"
  local remote_url="https://gitlab.com/${repository}.git"
  local commit

  if [[ ! -d "$destination/.git" ]]; then
    mkdir -p "$destination"
    git -C "$destination" init -q
    git -C "$destination" remote add origin "$remote_url"
  fi

  if [[ -n "$(git -C "$destination" status --porcelain --untracked-files=normal)" ]]; then
    echo "kernel checkout contains local edits: $destination" >&2
    return 1
  fi

  git -C "$destination" fetch --quiet --depth=1 origin "$ref" || return 1
  commit="$(git -C "$destination" rev-parse FETCH_HEAD)"
  if [[ -n "${KERNEL_COMMIT:-}" && "$commit" != "$KERNEL_COMMIT" ]]; then
    echo "kernel ref $ref resolves to $commit, but build.env pins $KERNEL_COMMIT" >&2
    return 1
  fi
  git -C "$destination" checkout --quiet --detach "$commit"
  printf '%s\n' "$commit"
}

# Read the manifest the kernel tree ships at its root and export the product
# names every downstream script uses:
#   KERNEL_RELEASE, KERNEL_RELEASE_EL2, KERNEL_DEFCONFIG, KERNEL_DTB, KERNEL_DTB_EL2
read_kernel_manifest() {
  local tree="$1"
  local manifest="$tree/gaokun3-manifest.json"

  if [[ ! -f "$manifest" ]]; then
    echo "kernel tree $tree has no gaokun3-manifest.json" >&2
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required to read $manifest" >&2
    return 1
  fi

  KERNEL_RELEASE="$(jq -er '.kernel_release' "$manifest")"
  KERNEL_RELEASE_EL2="$(jq -er '.kernel_release_el2' "$manifest")"
  KERNEL_DEFCONFIG="$(jq -er '.defconfig' "$manifest")"
  KERNEL_DTB="$(jq -er '.dtb' "$manifest")"
  KERNEL_DTB_EL2="$(jq -er '.dtb_el2' "$manifest")"
  export KERNEL_RELEASE KERNEL_RELEASE_EL2 KERNEL_DEFCONFIG KERNEL_DTB KERNEL_DTB_EL2
}

# Fail when a build output directory does not hold the product the manifest
# names, so a stale or foreign output tree is never packaged.
assert_kernel_output() {
  local out_dir="$1"
  local release="$2"
  local dtb="$3"

  local file
  for file in arch/arm64/boot/Image System.map .config \
              "arch/arm64/boot/dts/qcom/$dtb"; do
    if [[ ! -f "$out_dir/$file" ]]; then
      echo "kernel output $out_dir is missing $file" >&2
      return 1
    fi
  done
  if [[ "$(cat "$out_dir/include/config/kernel.release")" != "$release" ]]; then
    echo "kernel output $out_dir reports release $(cat "$out_dir/include/config/kernel.release"), manifest says $release" >&2
    return 1
  fi
}
