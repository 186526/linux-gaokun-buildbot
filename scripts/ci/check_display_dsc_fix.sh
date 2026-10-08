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
#
# Exit status: 0 when the rounded fix is present and the truncating form is
# absent, 1 otherwise. The tree is only read, never modified.

KERN_SRC="${1:-${KERN_SRC:-}}"
: "${KERN_SRC:?usage: check_display_dsc_fix.sh <patched-kernel-tree>}"

target="$KERN_SRC/drivers/gpu/drm/msm/disp/dpu1/dpu_encoder_phys_vid.c"
if [[ ! -f "$target" ]]; then
  echo "ERROR: display source not found: $target" >&2
  exit 1
fi

# The rounded post-image both patches converge on.
rounded='timing->width = DIV_ROUND_UP(timing->width * drm_dsc_get_bpp_int(dsc),'
# The XanMod base's truncating form the fix must remove.
truncating='timing->width = timing->width * drm_dsc_get_bpp_int(dsc) /'

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
