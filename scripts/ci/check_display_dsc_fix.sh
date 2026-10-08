#!/usr/bin/env bash
set -euo pipefail

# Guard against a silently dropped DSC timing-width fix in the XanMod display
# series. The XanMod 7.2.9 base computes the DPU interface timing width with a
# truncating integer division:
#
#   timing->width = timing->width * drm_dsc_get_bpp_int(dsc) /
#                   (dsc->bits_per_component * 3);
#
# patches/others/0005-drm-msm-dpu-fix-DSC-timing-width-truncation.patch followed
# by patches/others/0011-drm-msm-dpu-restore-dsc-interface-data-width.patch
# replace it with a rounded form:
#
#   timing->width = DIV_ROUND_UP(timing->width * drm_dsc_get_bpp_int(dsc),
#                                dsc->bits_per_component * 3);
#
# If 0005 is absent, 0011 no longer applies (its context is the 0005 post-image)
# and the XanMod base's truncating form survives. That truncated width feeds the
# DPU/DSI timing, corrupts the command-mode panel timing, and makes the
# secondary-DSI backlight DCS write time out at boot:
#
#   msm_dsi ae96000.dsi: [drm:dsi_cmds2buf_tx [msm]] *ERROR* wait for video done timed out
#   dsi_cmds2buf_tx: cmd dma tx failed, type=0x39, data0=0x51, len=8, ret=-110
#
# Usage:
#   check_display_dsc_fix.sh <patched-kernel-tree>
#   KERN_SRC=<patched-kernel-tree> check_display_dsc_fix.sh
#   check_display_dsc_fix.sh --series
#
# With --series the repository itself is checked (no kernel checkout needed):
# that 0005 is present, that 0011's post-image is the rounded form, and that the
# select_base.sh anchor for 0011 is that same rounded post-image rather than the
# XanMod base's truncating form. That is the CI-runnable form; a patched kernel
# tree is only available on the build runners.
#
# Exit status: 0 when the check passes, 1 otherwise. Nothing is modified.

# The rounded post-image both patches converge on.
rounded='timing->width = DIV_ROUND_UP(timing->width * drm_dsc_get_bpp_int(dsc),'
# The XanMod base's truncating form the fix must remove.
truncating='timing->width = timing->width * drm_dsc_get_bpp_int(dsc) /'

check_series() {
  local repo_dir="$1"
  local patch_0005="$repo_dir/patches/others/0005-drm-msm-dpu-fix-DSC-timing-width-truncation.patch"
  local patch_0011="$repo_dir/patches/others/0011-drm-msm-dpu-restore-dsc-interface-data-width.patch"
  local select_base="$repo_dir/scripts/ci/lib/select_base.sh"
  local status=0

  if [[ -f "$patch_0005" ]]; then
    echo "OK: 0005 DSC timing-width patch present"
  else
    echo "FAIL: missing $patch_0005" >&2
    echo "      -> 0011 cannot apply and its DSC fix is silently skipped" >&2
    status=1
  fi

  if [[ -f "$patch_0011" ]] && grep -qF -- "$rounded" "$patch_0011"; then
    echo "OK: 0011 post-image is the rounded DSC timing width"
  else
    echo "FAIL: 0011 does not carry the rounded DSC timing width" >&2
    status=1
  fi

  if [[ -f "$select_base" ]] && grep -qF -- "anchors+=('$rounded')" "$select_base"; then
    echo "OK: select_base.sh anchors 0011 on the rounded post-image"
  else
    echo "FAIL: select_base.sh does not anchor 0011 on the rounded post-image" >&2
    status=1
  fi

  if [[ -f "$select_base" ]] && grep -qF -- "anchors+=('$truncating')" "$select_base"; then
    echo "FAIL: select_base.sh still anchors 0011 on the base's truncating form" >&2
    echo "      -> 0011 would match the XanMod base and be skipped silently" >&2
    status=1
  else
    echo "OK: select_base.sh has no truncating-form anchor"
  fi

  # The fix only holds when 0005 is applied before 0011; both sort before it.
  if [[ -f "$patch_0005" && -f "$patch_0011" ]] && \
      [[ "$(basename "$patch_0005")" < "$(basename "$patch_0011")" ]]; then
    echo "OK: 0005 sorts before 0011 in the series"
  else
    echo "FAIL: 0005 does not sort before 0011 in the series" >&2
    status=1
  fi

  if [[ "$status" -eq 0 ]]; then
    echo "PASS: DSC timing-width patch chain intact"
  else
    echo "FAIL: DSC timing-width patch chain broken" >&2
    echo "Expected runtime criterion after a good build (counts must be zero):" >&2
    echo "  grep -c 'wait for video done timed out'        <boot-dmesg>" >&2
    echo "  grep -c 'cmd dma tx failed'                     <boot-dmesg>" >&2
  fi

  return "$status"
}

if [[ "${1:-}" == "--series" ]]; then
  repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
  if check_series "$repo_dir"; then
    exit 0
  else
    exit 1
  fi
fi

KERN_SRC="${1:-${KERN_SRC:-}}"
: "${KERN_SRC:?usage: check_display_dsc_fix.sh <patched-kernel-tree>|--series}"

target="$KERN_SRC/drivers/gpu/drm/msm/disp/dpu1/dpu_encoder_phys_vid.c"
if [[ ! -f "$target" ]]; then
  echo "ERROR: display source not found: $target" >&2
  exit 1
fi

status=0
if grep -qF -- "$rounded" "$target"; then
  echo "OK: rounded DSC timing width present"
else
  echo "FAIL: rounded DSC timing width missing (expected: $rounded)" >&2
  status=1
fi

if grep -qF -- "$truncating" "$target"; then
  echo "FAIL: truncating DSC timing width still present ($truncating)" >&2
  echo "      -> patches/others/0005 is likely missing, so 0011 was skipped" >&2
  status=1
else
  echo "OK: truncating DSC timing width absent"
fi

if [[ "$status" -eq 0 ]]; then
  echo "PASS: DSC timing-width fix applied in $KERN_SRC"
else
  echo "FAIL: DSC timing-width regression in $KERN_SRC" >&2
  echo "Expected runtime criterion after a good build (counts must be zero):" >&2
  echo "  grep -c 'wait for video done timed out'        <boot-dmesg>" >&2
  echo "  grep -c 'cmd dma tx failed'                     <boot-dmesg>" >&2
fi

exit "$status"
