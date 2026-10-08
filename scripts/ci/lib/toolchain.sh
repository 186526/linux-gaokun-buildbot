#!/usr/bin/env bash
# Shared kernel-toolchain selection for the standard and EL2 kernel builds.
#
# GCC stays the default, so every existing build keeps its exact behaviour.
# Setting KERNEL_TOOLCHAIN=clang switches the build to the Clang/LLVM toolchain
# and turns on ThinLTO, the LLVM configuration the arm64 kernel supports:
#
#   LLVM=1       make the kernel build system use clang, ld.lld, llvm-ar,
#                llvm-nm, llvm-objcopy, ... from one release. Passing the whole
#                family through LLVM=1 (rather than a bare CC=clang) is what
#                keeps the assembler, linker, and binutils in step and is what
#                arch/arm64 expects for a Clang build.
#   LLVM_IAS=1   use clang's integrated assembler instead of GNU as, so no
#                aarch64 binutils cross package is needed for assembly.
#   LD=ld.lld    pin the linker explicitly. LLVM=1 already selects ld.lld, but
#                ThinLTO (CONFIG_LTO_CLANG_THIN) hard-depends on LD_IS_LLD, so
#                the linker is named here instead of left implicit.
#
# The same argument list must be appended to every `make` invocation for a
# variant (defconfig, olddefconfig, the build, modules_prepare), because mixing
# toolchains within one output tree silently produces an unusable kernel.
#
# KERNEL_LTO selects the link-time optimizer:
#   thin   (default when KERNEL_TOOLCHAIN=clang)  CONFIG_LTO_CLANG_THIN=y
#   none                                          leave LTO disabled
# It is rejected in GCC mode, where LTO_CLANG is unavailable.
#
# KERNEL_TUNE is an opt-in microarchitecture tuning mode for the Snapdragon
# 8cx Gen 3 (SC8280XP). When set, the build appends KCFLAGS=-mtune=<cpu>. Only
# -mtune (instruction scheduling) is used, never -march: -mtune keeps the
# armv8-a ISA baseline and the kernel ABI, so externally built modules stay
# compatible, while -march would let the compiler emit instructions the target
# may not support on every cluster and break that ABI. KERNEL_TUNE accepts a
# CPU name (for example cortex-x1 or cortex-a78) or the alias sc8280xp, which
# selects the Cortex-X1 prime core. It is rejected when the compiler does not
# accept the value.
#
# Sourced by scripts/ci/20_build_kernel_variants.sh, the package scripts under
# scripts/ci/, and scripts/local/build_kernel.sh. After resolve_kernel_toolchain,
# callers append "${KERNEL_MAKE_ARGS[@]}" to their make command lines.

# Global state set by resolve_kernel_toolchain. Declared here so `set -u`
# callers can expand the array even before the resolver runs.
KERNEL_MAKE_ARGS=()
KERNEL_TOOLCHAIN="${KERNEL_TOOLCHAIN:-gcc}"
KERNEL_LTO="${KERNEL_LTO:-}"
KERNEL_TUNE="${KERNEL_TUNE:-}"
KERNEL_TUNE_CPU=""

# Map KERNEL_TUNE to a compiler CPU name. Returns non-zero when unset so callers
# can distinguish "no tuning" from an explicit value.
kernel_tune_cpu() {
  case "${KERNEL_TUNE:-}" in
    "") return 1 ;;
    sc8280xp|8cx-gen3|8cxgen3) printf 'cortex-x1\n' ;;
    *) printf '%s\n' "$KERNEL_TUNE" ;;
  esac
}

resolve_kernel_toolchain() {
  case "${KERNEL_TOOLCHAIN:-gcc}" in
    gcc|"")
      KERNEL_TOOLCHAIN="gcc"
      if [[ -n "${KERNEL_LTO:-}" && "$KERNEL_LTO" != "none" ]]; then
        echo "KERNEL_LTO='${KERNEL_LTO}' is not valid with KERNEL_TOOLCHAIN=gcc;" >&2
        echo "Clang ThinLTO needs the Clang toolchain. Use KERNEL_TOOLCHAIN=clang." >&2
        return 1
      fi
      KERNEL_LTO="none"
      KERNEL_MAKE_ARGS=()
      ;;
    clang|llvm)
      KERNEL_TOOLCHAIN="clang"
      KERNEL_LTO="${KERNEL_LTO:-thin}"
      KERNEL_MAKE_ARGS=(LLVM=1 LLVM_IAS=1 "LD=${LD:-ld.lld}")
      ;;
    *)
      echo "unknown KERNEL_TOOLCHAIN '${KERNEL_TOOLCHAIN}': expected 'gcc' or 'clang'" >&2
      return 1
      ;;
  esac

  case "$KERNEL_LTO" in
    none|thin) ;;
    *)
      echo "unknown KERNEL_LTO '${KERNEL_LTO}': expected 'none' or 'thin'" >&2
      return 1
      ;;
  esac

  if [[ -n "$KERNEL_TUNE" ]]; then
    if ! KERNEL_TUNE_CPU="$(kernel_tune_cpu)"; then
      echo "unknown KERNEL_TUNE '${KERNEL_TUNE}'" >&2
      return 1
    fi
    KERNEL_MAKE_ARGS+=("KCFLAGS=-mtune=${KERNEL_TUNE_CPU}")
  else
    KERNEL_TUNE_CPU=""
  fi

  export KERNEL_TOOLCHAIN KERNEL_LTO KERNEL_TUNE KERNEL_TUNE_CPU
}

# Compile a trivial translation unit with the caller's compiler to prove it
# accepts -mtune=<cpu> before the kernel build starts. The caller passes the
# compiler and any target flags, e.g.:
#   validate_kernel_tune clang --target=aarch64-linux-gnu
#   validate_kernel_tune "${CROSS_COMPILE}gcc"
# A no-op when KERNEL_TUNE is unset, so portable builds are unaffected.
validate_kernel_tune() {
  [[ -n "${KERNEL_TUNE:-}" ]] || return 0

  local cpu="$KERNEL_TUNE_CPU"
  if [[ -z "$cpu" ]]; then
    cpu="$(kernel_tune_cpu)" || return 0
  fi

  local tmp
  tmp="$(mktemp -d)"
  printf 'int gaokun3_tune_probe(void){return 0;}\n' >"$tmp/probe.c"
  if ! "$@" -mtune="$cpu" -x c -c -o "$tmp/probe.o" "$tmp/probe.c" 2>"$tmp/err"; then
    echo "ERROR: the compiler rejected -mtune=$cpu (KERNEL_TUNE=$KERNEL_TUNE):" >&2
    sed 's/^/  /' "$tmp/err" >&2
    echo "Set KERNEL_TUNE to a supported CPU, or unset it for a portable build." >&2
    rm -rf "$tmp"
    return 1
  fi
  rm -rf "$tmp"
  echo "kernel tune: -mtune=$cpu accepted by the compiler"
}

# True when the variant's generated .config exposes the ThinLTO choice symbol,
# so a kernel tree that predates Clang ThinLTO fails with a clear message
# instead of a silent no-op.
kernel_lto_symbol_present() {
  local out_dir="$1"
  grep -qE '^(# )?CONFIG_LTO_CLANG_THIN([= ]|$)' "$out_dir/.config"
}

# Enable the toolchain-dependent Kconfig options in one variant's generated
# .config, before olddefconfig resolves the choice. GCC mode is a no-op.
apply_kernel_toolchain_config() {
  local src_dir="$1"
  local out_dir="$2"

  [[ "$KERNEL_TOOLCHAIN" == "clang" ]] || return 0
  [[ "$KERNEL_LTO" == "thin" ]] || return 0

  if ! kernel_lto_symbol_present "$out_dir"; then
    echo "ERROR: KERNEL_TOOLCHAIN=clang KERNEL_LTO=thin, but $out_dir/.config does not" >&2
    echo "expose CONFIG_LTO_CLANG_THIN; the pinned kernel tree does not support Clang ThinLTO." >&2
    return 1
  fi

  "$src_dir"/scripts/config --file "$out_dir/.config" --enable LTO_CLANG_THIN
  # ThinLTO and Full LTO share a Kconfig choice; clear the sibling so a stale
  # Full LTO selection cannot win over the ThinLTO request.
  if grep -qE '^(# )?CONFIG_LTO_CLANG_FULL([= ]|$)' "$out_dir/.config"; then
    "$src_dir"/scripts/config --file "$out_dir/.config" --disable LTO_CLANG_FULL
  fi
}

# Fail loudly when the configured compiler or LTO mode is not what the caller
# asked for. A mismatch means the toolchain arguments did not reach make (for
# example a make call that forgot "${KERNEL_MAKE_ARGS[@]}"), or ld.lld is
# missing, so ThinLTO was silently dropped by olddefconfig.
assert_kernel_toolchain_config() {
  local out_dir="$1"

  if [[ "$KERNEL_TOOLCHAIN" == "clang" ]]; then
    if ! grep -qx 'CONFIG_CC_IS_CLANG=y' "$out_dir/.config"; then
      echo "ERROR: KERNEL_TOOLCHAIN=clang but $out_dir/.config lacks CONFIG_CC_IS_CLANG=y." >&2
      echo "The kernel was not configured with Clang; confirm '${KERNEL_MAKE_ARGS[*]}' reached every make call." >&2
      return 1
    fi
    if [[ "$KERNEL_LTO" == "thin" ]] && ! grep -qx 'CONFIG_LTO_CLANG_THIN=y' "$out_dir/.config"; then
      echo "ERROR: KERNEL_LTO=thin but $out_dir/.config lacks CONFIG_LTO_CLANG_THIN=y." >&2
      echo "ThinLTO requires LD_IS_LLD; confirm ld.lld is installed and selected as LD." >&2
      return 1
    fi
  elif ! grep -qx 'CONFIG_CC_IS_GCC=y' "$out_dir/.config"; then
    echo "ERROR: KERNEL_TOOLCHAIN=gcc but $out_dir/.config lacks CONFIG_CC_IS_GCC=y." >&2
    echo "The default GCC toolchain was not used; check the KERNEL_MAKE_ARGS passed to make." >&2
    return 1
  fi
}
