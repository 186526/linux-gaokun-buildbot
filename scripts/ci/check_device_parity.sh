#!/usr/bin/env bash
set -euo pipefail

# Guard against the XanMod device build silently diverging from the pinned
# gaokun3/linux tree. The XanMod kernel is assembled by replaying
# patches/{upstream,others,media,0099} on top of 7.2.9-xanmod1; when one of the
# device fixes below is not carried by that series the prepared tree builds and
# boots, but the hardware silently degrades. The parity inventory (M42) found
# four such gaps against the pinned commit 730335640:
#
#   G1 audio speaker gain ceiling
#      sound/soc/qcom/sc8280xp.c, "huawei,gaokun3" branch:
#        snd_soc_limit_volume(card, "WSA_RX0 Digital Volume", 84);
#        snd_soc_limit_volume(card, "SpkrLeft PA Volume", 29);
#      Without them the WSA_CODEC_DMA_RX_0/1 path falls through to the upstream
#      -3 dB / 0 dB limit and the speakers are capped well below the tuned level.
#
#   G2 touchscreen SPI mode-select
#      arch/arm64/boot/dts/qcom/sc8280xp-huawei-gaokun3.dts, ts0-default-state:
#        mode-select-pins { pins = "gpio174"; ...; output-low; };
#      Without it the touchscreen SPI mode is never selected before the driver
#      releases reset, so the panel reports no touches.
#
#   G3 touchscreen read retry / header accounting / predicted distance
#      drivers/input/touchscreen/himax-spi-core.c: the read command must be
#      rebuilt on every retry ("RX overwrites TX, including the command") and
#      the transfer buffer must reserve the 3-byte read header:
#        ts->spi_xfer_max_sz = HIMAX_HX83121A_FULL_STACK_SZ + HIMAX_BUS_R_HLEN;
#      drivers/input/touchscreen/hx-algo.c: jump detection must compare against
#      the predicted position (m->dist2), not a fresh raw displacement.
#
#   G4 EC enable-GPIO error propagation
#      drivers/platform/arm64/huawei-gaokun-ec.c: a failed enable-gpios lookup
#      must propagate the error:
#        return dev_err_probe(dev, PTR_ERR(ec->enable_gpio), ...);
#      Without the "return" probe continues with a bogus GPIO and the EC appears
#      to probe successfully while the enable line is wrong.
#
#   G5 rear camera binding
#      arch/arm64/boot/dts/qcom/sc8280xp-huawei-gaokun3-camera.dtsi: the rear
#      node must be the OV13B10 the board actually carries, not the s5k3l6 it
#      was originally written for:
#        camera_rear: camera@36 { compatible = "ovti,ov13b10"; ... };
#      drivers/media/i2c/ov13b10.c must match it from device tree and answer
#      get_selection:
#        .of_match_table = ov13b10_of_ids,
#        .get_selection = ov13b10_get_selection,
#      drivers/clk/qcom/camcc-sc8280xp.c must park camnoc_axi/slow_ahb/fast_ahb
#      on XO when unused (clk_rcg2_shared_ops). A wired-but-unbindable rear
#      sensor blocks the whole v4l2-async notifier (camss.c iterates endpoints
#      without an availability check), so the front camera loses its subdevs too.
#
# The G5 anchors are xanmod-only. They reach the XanMod tree through
# patches/0099 and patches/others/*, neither of which the pinned mainline tree
# replays; the pinned commit 730335640 has neither the OV13B10 binding nor the
# driver changes, so requiring them on that base would fail a tree that cannot
# carry them. The required set is chosen from the kernel base: G1-G4 always,
# G5 only for xanmod. Base defaults to mainline, matching select_base.sh, and
# the build passes the real value.
#
# Usage:
#   check_device_parity.sh <patched-kernel-tree> [mainline|xanmod]
#   KERN_SRC=<patched-kernel-tree> KERNEL_BASE=xanmod check_device_parity.sh
#   check_device_parity.sh --series [mainline|xanmod]
#
# The tree form is authoritative: it asserts the final source anchors in the
# kernel tree that is about to be built and is what
# scripts/ci/20_build_kernel_variants.sh runs after the patch series is applied
# and before any variant is configured.
#
# With --series the repository is scanned instead (no kernel checkout needed)
# and each feature is reported present/pending according to whether some file
# under patches/ carries the final anchor. That is a preflight inventory only:
# a patch grep is NOT full validation (a patch can carry the anchor and still
# fail to apply, or apply and be reverted later), so it never fails the build.
# Only the tree form decides pass/fail.
#
# Exit status: 0 when the check passes, 1 otherwise. Nothing is modified.

# --- final source anchors --------------------------------------------------

# G1 audio
audio_file='sound/soc/qcom/sc8280xp.c'
audio_ok_rx0='snd_soc_limit_volume(card, "WSA_RX0 Digital Volume", 84);'
audio_ok_pa29='snd_soc_limit_volume(card, "SpkrLeft PA Volume", 29);'

# G2 touchscreen mode-select
dts_file='arch/arm64/boot/dts/qcom/sc8280xp-huawei-gaokun3.dts'
dts_ok_node='mode-select-pins'
dts_ok_pins='pins = "gpio174";'
dts_ok_level='output-low;'

# G3 touchscreen driver
himax_file='drivers/input/touchscreen/himax-spi-core.c'
himax_ok_retry='RX overwrites TX, including the command, on each attempt.'
himax_ok_size='ts->spi_xfer_max_sz = HIMAX_HX83121A_FULL_STACK_SZ + HIMAX_BUS_R_HLEN;'
himax_stale_size='ts->spi_xfer_max_sz = HIMAX_HX83121A_FULL_STACK_SZ;'
algo_file='drivers/input/touchscreen/hx-algo.c'
algo_ok_predicted='m->dist2 > algo->track_jump_dist2'
algo_stale_actual='actual_d2 > algo->track_jump_dist2'

# G4 EC enable GPIO
ec_file='drivers/platform/arm64/huawei-gaokun-ec.c'
ec_ok_return='return dev_err_probe(dev, PTR_ERR(ec->enable_gpio),'
ec_bare_probe='dev_err_probe(dev, PTR_ERR(ec->enable_gpio),'

# G5 rear camera binding (xanmod-only)
camera_dtsi_file='arch/arm64/boot/dts/qcom/sc8280xp-huawei-gaokun3-camera.dtsi'
camera_ok_node='camera_rear: camera@36 {'
camera_ok_compat='compatible = "ovti,ov13b10";'
camera_ok_ep='ov13b10_ep: endpoint {'
camera_stale_node='camera_rear: camera@10 {'
camera_stale_compat='compatible = "samsung,s5k3l6xx";'
ov13b10_file='drivers/media/i2c/ov13b10.c'
ov13b10_ok_of='.of_match_table = ov13b10_of_ids,'
ov13b10_ok_sel='.get_selection = ov13b10_get_selection,'
camcc_file='drivers/clk/qcom/camcc-sc8280xp.c'
camcc_ok_shared='.ops = &clk_rcg2_shared_ops,'

# --- base awareness --------------------------------------------------------

# Which anchor groups apply to a given kernel base. The pinned mainline tree
# does not replay patches/0099 or patches/others/*, so the G5 camera binding is
# only required for xanmod; requiring it on mainline would fail a tree that has
# no way to carry it.
required_groups() {
  local base="${1:-mainline}"
  case "$base" in
    xanmod) printf '%s\n' g1 g2 g3 g4 g5 ;;
    mainline|"") printf '%s\n' g1 g2 g3 g4 ;;
    *) echo "unknown kernel base '$base': expected 'mainline' or 'xanmod'" >&2; return 1 ;;
  esac
}

group_required() {
  local base="$1" group="$2" g
  while IFS= read -r g; do
    [[ "$g" == "$group" ]] && return 0
  done < <(required_groups "$base")
  return 1
}

# --- helpers ---------------------------------------------------------------

require_file() {
  local file="$1" label="$2"
  if [[ -f "$file" ]]; then
    return 0
  fi
  echo "FAIL: $label: source file not found: $file" >&2
  echo "      -> the feature is not present in this kernel tree at all" >&2
  return 1
}

require_fixed() {
  local file="$1" needle="$2" label="$3"
  if grep -qF -- "$needle" "$file"; then
    echo "OK: $label"
    return 0
  fi
  echo "FAIL: $label" >&2
  echo "      expected in $file:" >&2
  echo "        $needle" >&2
  return 1
}

forbid_fixed() {
  local file="$1" needle="$2" label="$3"
  if grep -qF -- "$needle" "$file"; then
    echo "FAIL: $label" >&2
    echo "      stale anchor still present in $file:" >&2
    echo "        $needle" >&2
    return 1
  fi
  echo "OK: $label"
  return 0
}

# --- authoritative tree check ---------------------------------------------

check_tree() {
  local root="$1"
  local base="${2:-mainline}"
  local status=0 f

  required_groups "$base" >/dev/null || return 1

  echo "== G1 audio speaker gain ceiling =="
  f="$root/$audio_file"
  if require_file "$f" "audio"; then
    require_fixed "$f" "$audio_ok_rx0" "audio: WSA_RX0 digital volume ceiling 84" || status=1
    require_fixed "$f" "$audio_ok_pa29" "audio: SpkrLeft PA volume ceiling 29" || status=1
  else
    status=1
  fi

  echo "== G2 touchscreen SPI mode-select =="
  f="$root/$dts_file"
  if require_file "$f" "dts"; then
    require_fixed "$f" "$dts_ok_node" "dts: mode-select-pins node present" || status=1
    require_fixed "$f" "$dts_ok_pins" "dts: mode-select drives gpio174" || status=1
    require_fixed "$f" "$dts_ok_level" "dts: mode-select output-low" || status=1
  else
    status=1
  fi

  echo "== G3 touchscreen retry / header / predicted distance =="
  f="$root/$himax_file"
  if require_file "$f" "touchscreen retry"; then
    require_fixed "$f" "$himax_ok_retry" "touch: read command rebuilt on every retry" || status=1
    require_fixed "$f" "$himax_ok_size" "touch: transfer buffer reserves the read header" || status=1
    forbid_fixed "$f" "$himax_stale_size" "touch: header-less transfer size removed" || status=1
  else
    status=1
  fi
  f="$root/$algo_file"
  if require_file "$f" "touchscreen tracker"; then
    require_fixed "$f" "$algo_ok_predicted" "touch: jump detection uses predicted distance" || status=1
    forbid_fixed "$f" "$algo_stale_actual" "touch: raw-displacement jump check removed" || status=1
  else
    status=1
  fi

  echo "== G4 EC enable-GPIO error propagation =="
  f="$root/$ec_file"
  if require_file "$f" "ec"; then
    local total returns
    total="$(grep -cF -- "$ec_bare_probe" "$f" || true)"
    returns="$(grep -cF -- "$ec_ok_return" "$f" || true)"
    if [[ "$returns" -ge 1 && "$total" -eq "$returns" ]]; then
      echo "OK: ec: enable-gpios lookup errors are returned ($returns/$total)"
    else
      echo "FAIL: ec: enable-gpios lookup error is not propagated" >&2
      echo "      expected in $f:" >&2
      echo "        $ec_ok_return" >&2
      echo "      found $returns returned of $total dev_err_probe calls" >&2
      status=1
    fi
  else
    status=1
  fi

  if group_required "$base" g5; then
    echo "== G5 rear camera OV13B10 binding =="
    f="$root/$camera_dtsi_file"
    if require_file "$f" "camera dtsi"; then
      require_fixed "$f" "$camera_ok_node" "camera: rear node is camera@36" || status=1
      require_fixed "$f" "$camera_ok_compat" "camera: rear sensor is ovti,ov13b10" || status=1
      require_fixed "$f" "$camera_ok_ep" "camera: rear endpoint is ov13b10_ep" || status=1
      forbid_fixed "$f" "$camera_stale_node" "camera: stale s5k3l6 camera@10 node removed" || status=1
      forbid_fixed "$f" "$camera_stale_compat" "camera: stale samsung,s5k3l6xx removed" || status=1
    else
      status=1
    fi
    f="$root/$ov13b10_file"
    if require_file "$f" "ov13b10 driver"; then
      require_fixed "$f" "$ov13b10_ok_of" "camera: ov13b10 matches from device tree" || status=1
      require_fixed "$f" "$ov13b10_ok_sel" "camera: ov13b10 provides get_selection" || status=1
    else
      status=1
    fi
    f="$root/$camcc_file"
    if require_file "$f" "camcc driver"; then
      require_fixed "$f" "$camcc_ok_shared" "camera: camcc RCGs park on XO when unused" || status=1
    else
      status=1
    fi
  fi

  if [[ "$status" -eq 0 ]]; then
    echo "PASS: prepared device parity intact in $root"
  else
    echo "FAIL: prepared device parity regression in $root" >&2
    echo "The kernel was patched but a pinned gaokun3 device fix is missing." >&2
    echo "Compare the XanMod series against the pinned commit 730335640 and add" >&2
    echo "the missing hunk to patches/ before building:" >&2
    echo "  G1 sound/soc/qcom/sc8280xp.c         audio gain ceiling 84/29" >&2
    echo "  G2 arch/arm64/.../sc8280xp-huawei-gaokun3.dts  gpio174 output-low" >&2
    echo "  G3 drivers/input/touchscreen/{himax-spi-core,hx-algo}.c  retry/header/predicted" >&2
    echo "  G4 drivers/platform/arm64/huawei-gaokun-ec.c  return dev_err_probe" >&2
    if group_required "$base" g5; then
      echo "  G5 camera: camera.dtsi ovti,ov13b10 @0x36; ov13b10 OF match +" >&2
      echo "     get_selection; camcc camnoc_axi/slow_ahb/fast_ahb shared ops" >&2
    fi
  fi

  return "$status"
}

# --- non-authoritative series preflight ------------------------------------

check_series() {
  local repo_dir="$1"
  local base="${2:-mainline}"
  local entry label needle

  required_groups "$base" >/dev/null || return 1

  echo "NOTE: series preflight only - patch grep is not full validation."
  echo "      The authoritative check runs against the prepared kernel tree"
  echo "      in scripts/ci/20_build_kernel_variants.sh before any build."
  echo

  local entries=(
    "G1 audio gain ceiling 84|$audio_ok_rx0"
    "G1 audio gain ceiling 29|$audio_ok_pa29"
    "G2 dts mode-select gpio174|$dts_ok_pins"
    "G3 touchscreen read header|$himax_ok_size"
    "G3 touchscreen predicted distance|$algo_ok_predicted"
    "G4 EC return dev_err_probe|$ec_ok_return"
  )
  if group_required "$base" g5; then
    entries+=(
      "G5 camera ov13b10 node|$camera_ok_node"
      "G5 camera ov13b10 compatible|$camera_ok_compat"
      "G5 camera ov13b10 OF match|$ov13b10_ok_of"
      "G5 camera ov13b10 get_selection|$ov13b10_ok_sel"
      "G5 camera camcc shared RCG|$camcc_ok_shared"
    )
  fi

  for entry in "${entries[@]}"; do
    label="${entry%%|*}"
    needle="${entry#*|}"
    if grep -rqF -- "$needle" "$repo_dir/patches" 2>/dev/null; then
      echo "OK: $label (anchor present in patches/)"
    else
      echo "PENDING: $label (no patch under patches/ carries it yet)"
    fi
  done

  echo
  echo "PREFLIGHT DONE: pending features are validated against the kernel tree"
  echo "                at build time, not here."
  return 0
}

# --- entry point -----------------------------------------------------------

if [[ "${1:-}" == "--series" ]]; then
  repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
  check_series "$repo_dir" "${2:-${KERNEL_BASE:-mainline}}"
  exit 0
fi

KERN_SRC="${1:-${KERN_SRC:-}}"
: "${KERN_SRC:?usage: check_device_parity.sh <patched-kernel-tree>|--series}"
KERNEL_BASE_ARG="${2:-${KERNEL_BASE:-mainline}}"

if [[ ! -d "$KERN_SRC" ]]; then
  echo "ERROR: kernel tree not found: $KERN_SRC" >&2
  exit 1
fi

if check_tree "$KERN_SRC" "$KERNEL_BASE_ARG"; then
  exit 0
else
  exit 1
fi
