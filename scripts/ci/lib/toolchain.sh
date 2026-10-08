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
# KERNEL_TUNE is an opt-in target tuning mode for the Snapdragon 8cx Gen 3
# (SC8280XP). The explicit profile aliases sc8280xp / 8cx-gen3 / 8cxgen3 select
# both the ISA and the microarchitecture:
#
#   KCFLAGS=-march=armv8.4-a+crypto -mtune=cortex-x1c
#
# -march=armv8.4-a+crypto is the ISA the SC8280XP clusters implement (Armv8.4-A
# with the crypto extension); -mtune=cortex-x1c is the microarchitecture the
# compiler schedules for (the Cortex-X1C prime core). The two are independent:
# -march chooses which instructions the compiler may emit, -mtune only affects
# instruction scheduling and never changes the emitted ISA. Any other
# KERNEL_TUNE value is treated as a bare CPU name and appends only
# KCFLAGS=-mtune=<cpu>, so a custom tuning keeps the portable armv8-a baseline.
# An unsupported value is rejected by the compiler probe below.
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
KERNEL_TUNE_FLAGS=""

# Map KERNEL_TUNE to a compiler CPU name (the -mtune value). Returns non-zero
# when unset so callers can distinguish "no tuning" from an explicit value.
kernel_tune_cpu() {
  case "${KERNEL_TUNE:-}" in
    "") return 1 ;;
    sc8280xp|8cx-gen3|8cxgen3) printf 'cortex-x1c\n' ;;
    *) printf '%s\n' "$KERNEL_TUNE" ;;
  esac
}

# Map KERNEL_TUNE to the full compiler flag string appended as KCFLAGS. The
# explicit SC8280XP profile selects both the ISA and the microarchitecture; any
# other value tunes scheduling only. Returns non-zero when unset.
kernel_tune_flags() {
  case "${KERNEL_TUNE:-}" in
    "") return 1 ;;
    sc8280xp|8cx-gen3|8cxgen3) printf '%s\n' '-march=armv8.4-a+crypto -mtune=cortex-x1c' ;;
    *) printf '%s\n' "-mtune=${KERNEL_TUNE}" ;;
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
    KERNEL_TUNE_FLAGS="$(kernel_tune_flags)"
    # Preserve any KCFLAGS the caller exported. A KCFLAGS= on the make command
    # line overrides the environment, so without this the caller's flags would
    # be silently dropped whenever KERNEL_TUNE is set.
    local extra_kcflags="${KCFLAGS:-}"
    if [[ -n "$extra_kcflags" ]]; then
      KERNEL_MAKE_ARGS+=("KCFLAGS=${KERNEL_TUNE_FLAGS} ${extra_kcflags}")
    else
      KERNEL_MAKE_ARGS+=("KCFLAGS=${KERNEL_TUNE_FLAGS}")
    fi
  else
    KERNEL_TUNE_CPU=""
    KERNEL_TUNE_FLAGS=""
  fi

  export KERNEL_TOOLCHAIN KERNEL_LTO KERNEL_TUNE KERNEL_TUNE_CPU KERNEL_TUNE_FLAGS
}

# Compile a trivial translation unit with the caller's compiler to prove it
# accepts the complete KERNEL_TUNE flag string before the kernel build starts.
# The probe mirrors the kernel's own constraint (-mgeneral-regs-only, which
# arm64 kernel C code is compiled with), so it exercises the exact ISA + tuning
# combination the build will use. The caller passes the compiler and any target
# flags, e.g.:
#   validate_kernel_tune clang --target=aarch64-linux-gnu
#   validate_kernel_tune "${CROSS_COMPILE}gcc"
# A no-op when KERNEL_TUNE is unset, so portable builds are unaffected.
validate_kernel_tune() {
  [[ -n "${KERNEL_TUNE:-}" ]] || return 0

  local flags="$KERNEL_TUNE_FLAGS"
  if [[ -z "$flags" ]]; then
    flags="$(kernel_tune_flags)" || return 0
  fi

  local -a flag_args
  read -r -a flag_args <<<"$flags"

  local tmp
  tmp="$(mktemp -d)"
  printf 'int gaokun3_tune_probe(void){return 0;}\n' >"$tmp/probe.c"
  if ! "$@" "${flag_args[@]}" -mgeneral-regs-only -x c -c -o "$tmp/probe.o" "$tmp/probe.c" 2>"$tmp/err"; then
    echo "ERROR: the compiler rejected '${flags}' (KERNEL_TUNE=$KERNEL_TUNE):" >&2
    sed 's/^/  /' "$tmp/err" >&2
    echo "Set KERNEL_TUNE to a supported CPU or profile, or unset it for a portable build." >&2
    rm -rf "$tmp"
    return 1
  fi
  rm -rf "$tmp"
  echo "kernel tune: '${flags}' accepted by the compiler"
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
