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

# Some base trees carry a change in different text than the shared patch, so
# the reverse check cannot see it. Each known case names the file the patch
# touches and fixed-string anchors that must all be present there before the
# change counts as applied, so a rewritten or partial hunk cannot match by
# accident and silently drop the patch. Only the xanmod base is consulted.
xanmod_change_is_present() {
  local repo_dir="$1"
  local patch_base="$2"
  local target_file anchors=() anchor

  case "$patch_base" in
    0011-drm-msm-dpu-restore-dsc-interface-data-width.patch)
      target_file="drivers/gpu/drm/msm/disp/dpu1/dpu_encoder_phys_vid.c"
      anchors+=('#include <drm/display/drm_dsc_helper.h>')
      anchors+=('timing->width = timing->width * drm_dsc_get_bpp_int(dsc) /')
      ;;
    *)
      return 1
      ;;
  esac

  [[ -f "$repo_dir/$target_file" ]] || return 1

  for anchor in "${anchors[@]}"; do
    grep -qF -- "$anchor" "$repo_dir/$target_file" || return 1
  done
}

# The tag may already be part of the base tree (for example a stable fix that
# landed upstream after the pinned mainline tag); such patches are skipped.
patch_is_already_applied() {
  local repo_dir="$1"
  local patch_file="$2"

  if git -C "$repo_dir" apply --reverse --check "$patch_file" >/dev/null 2>&1; then
    return 0
  fi

  [[ "${KERNEL_BASE:-}" == "xanmod" ]] || return 1
  xanmod_change_is_present "$repo_dir" "$(basename "$patch_file")"
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

# List the patch files to apply for one series, in apply order: every shared
# patch in shared_dir, with a same-name base override substituted in place,
# followed by base-local patches that have no shared counterpart of the same
# file name. Such patches exist only for the xanmod base.
patch_series_files() {
  local series_name="$1"
  local shared_dir="$2"
  local patch_file override_dir override

  for patch_file in "$shared_dir"/*.patch; do
    [[ -e "$patch_file" ]] || continue
    patch_resolution_for "$series_name" "$patch_file"
  done

  if [[ "${KERNEL_BASE:-}" != "xanmod" ]]; then
    return 0
  fi

  override_dir="$KERNEL_PATCH_DIR/$series_name"
  for override in "$override_dir"/*.patch; do
    [[ -e "$override" ]] || continue
    if [[ -f "$shared_dir/$(basename "$override")" ]]; then
      continue
    fi
    printf '%s\n' "$override"
  done
}
