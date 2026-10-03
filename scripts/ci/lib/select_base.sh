#!/usr/bin/env bash
set -euo pipefail

resolve_kernel_base() {
  local base="${KERNEL_BASE:-mainline}"
  local tag="${KERNEL_TAG:?missing KERNEL_TAG}"

  case "$base" in
    mainline|"")
      KERNEL_BASE="mainline"
      KERNEL_BASE_URL="${KERNEL_BASE_URL_OVERRIDE:-https://github.com/torvalds/linux}"
      KERNEL_BASE_REF="$tag"
      KERNEL_PATCH_DIR="$GAOKUN_DIR/patches"
      ;;
    xanmod)
      KERNEL_BASE="xanmod"
      KERNEL_BASE_URL="${KERNEL_BASE_URL_OVERRIDE:-https://gitlab.com/xanmod/linux.git}"
      KERNEL_BASE_REF="$tag"
      KERNEL_PATCH_DIR="$GAOKUN_DIR/patches/xanmod"
      ;;
    *)
      echo "unknown KERNEL_BASE '${base}': expected 'mainline' or 'xanmod'" >&2
      return 1
      ;;
  esac

  export KERNEL_BASE KERNEL_BASE_URL KERNEL_BASE_REF KERNEL_PATCH_DIR
}

# The tag may already be part of the base tree (for example a stable fix that
# landed upstream after the pinned mainline tag); such patches are skipped.
patch_is_already_applied() {
  local repo_dir="$1"
  local patch_file="$2"
  git -C "$repo_dir" apply --reverse --check "$patch_file" >/dev/null 2>&1
}

# A base-local override replaces the shared patch of the same file name.
patch_resolution_for() {
  local series_name="$1"
  local patch_file="$2"
  local override="$KERNEL_PATCH_DIR/$series_name/$(basename "$patch_file")"

  if [[ -f "$override" ]]; then
    printf '%s\n' "$override"
  else
    printf '%s\n' "$patch_file"
  fi
}
