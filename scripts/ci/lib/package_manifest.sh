#!/usr/bin/env bash
# Read kernel releases from a package manifest, so the image scripts never
# depend on a kernel build that happened in the same workspace.
#
# The package scripts write package-manifest.json next to the packages; the
# image workflows download that manifest together with the packages. The
# release strings in it are what the installed package names and the BLS
# entries are built from.
#
# Sets KREL and, when BUILD_EL2=true, KREL_EL2.

read_package_releases() {
  local package_dir="$1"
  local manifest="$package_dir/package-manifest.json"

  if [[ ! -f "$manifest" ]]; then
    echo "missing package manifest: $manifest" >&2
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required to read $manifest" >&2
    return 1
  fi

  KREL="$(jq -er '.kernels.standard.release' "$manifest")"
  KREL_EL2=""
  if [[ "${BUILD_EL2:-false}" == "true" ]]; then
    KREL_EL2="$(jq -er '.kernels.el2.release' "$manifest")"
  fi
  export KREL KREL_EL2
}
