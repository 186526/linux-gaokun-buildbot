#!/usr/bin/env bash
# Shared package-release-tag derivation for the package and image workflows.
#
# The tag has to encode every input that changes the built payload, because the
# image workflows locate a package release purely by tag prefix: an input the
# prefix does not carry would let an image run pick up a package set built from
# a different combination (README "The package release tag encodes the
# combination"). The tag shape is:
#
#   gaokun3-<kind>-<kernel-tag>[-xanmod]-<profile>[-clang[-lto-none]]-<timestamp>
#
# where <profile> is std with -el2 and -ksu appended. The LTO mode is encoded
# only when a Clang build turns LTO off (`-lto-none`); GCC stays LTO-free and the
# Clang default (ThinLTO) keeps the historical `-clang` shape, so a release
# published before this helper existed still matches its prefix.
#
# The manifest also records KERNEL_TOOLCHAIN and the resolved KERNEL_LTO, but a
# tag prefix alone cannot read a manifest, so the LTO mode is encoded in the tag
# too and the image workflows re-check the manifest after download. Clang with
# ThinLTO and Clang with LTO off therefore never share a tag prefix.
#
# KERNEL_TOOLCHAIN and KERNEL_LTO are resolved through the same
# resolve_kernel_toolchain the build uses, so the tag cannot describe a different
# combination than the one the build will actually produce.
#
# Sourced by the package workflows (to publish) and the image workflows (to
# locate a matching release by prefix).

# shellcheck source=toolchain.sh
. "$(dirname "${BASH_SOURCE[0]}")/toolchain.sh"

# Map the resolved toolchain/LTO to the tag suffix that distinguishes it. Only a
# Clang build that turns LTO off needs a suffix: GCC and the Clang ThinLTO
# default keep their historical tag shapes, so an existing `-clang` prefix still
# resolves.
package_lto_suffix() {
  local toolchain="${1:-${KERNEL_TOOLCHAIN:-gcc}}"
  local lto="${2:-${KERNEL_LTO:-none}}"

  if [[ "$toolchain" == "clang" && "$lto" == "none" ]]; then
    printf '%s\n' "-lto-none"
  fi
}

# Render the package release tag. Callers supply the parts they already resolve
# (KERNEL_TAG, KERNEL_BASE, BUILD_EL2, BUILD_KERNELSU, PACKAGE_KIND); the
# timestamp is appended here so a rerun never overwrites an existing release.
render_package_release_tag() {
  local kind="${1:-${PACKAGE_KIND:?missing PACKAGE_KIND (debs or rpms)}}"
  local kernel_tag="${KERNEL_TAG:?missing KERNEL_TAG}"

  resolve_kernel_toolchain

  local safe_kernel_tag="${kernel_tag//\//-}"
  safe_kernel_tag="${safe_kernel_tag//[^A-Za-z0-9._-]/-}"

  local base_suffix=""
  if [[ "${KERNEL_BASE:-xanmod}" == "xanmod" ]]; then
    base_suffix="-xanmod"
  fi

  local profile="std"
  if [[ "${BUILD_EL2:-false}" == "true" ]]; then
    profile="${profile}-el2"
  fi
  if [[ "${BUILD_KERNELSU:-false}" == "true" ]]; then
    profile="${profile}-ksu"
  fi

  local toolchain_suffix=""
  if [[ "$KERNEL_TOOLCHAIN" == "clang" ]]; then
    toolchain_suffix="-clang"
  fi
  toolchain_suffix="${toolchain_suffix}$(package_lto_suffix "$KERNEL_TOOLCHAIN" "$KERNEL_LTO")"

  printf 'gaokun3-%s-%s%s-%s%s-%s\n' \
    "$kind" "$safe_kernel_tag" "$base_suffix" "$profile" "$toolchain_suffix" \
    "$(date -u +%Y%m%d%H%M%S)"
}

# Derive the release prefix a caller must match to find a package set built with
# the same inputs. This is the tag without its timestamp, so a lookup only has to
# append the 14-digit timestamp.
package_release_prefix() {
  local kind="${1:-${PACKAGE_KIND:?missing PACKAGE_KIND (debs or rpms)}}"
  local tag
  tag="$(render_package_release_tag "$kind")"
  printf '%s-\n' "${tag%-*}"
}
