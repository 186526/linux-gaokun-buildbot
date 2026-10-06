#!/usr/bin/env bash
# KernelSU integration for the gaokun3 kernel variants.
#
# KernelSU is cloned from upstream at the pinned revision recorded in
# patches/kernelsu/PINNED_REVISION.md, then wired into the kernel tree the
# same way upstream kernel/setup.sh does it, without the git stash / git pull
# / branch checkout that script performs.

KERNSU_URL="${KERNSU_URL:-https://github.com/tiann/KernelSU.git}"
KERNSU_REF="${KERNSU_REF:-v3.3.0}"
KERNSU_COMMIT="${KERNSU_COMMIT:-932014ab5b2c9b74a3d11e2ec4d17dd10fc9442e}"
KERNSU_SRC="${KERNSU_SRC:-}"

KERNSU_MAKEFILE_LINE='obj-$(CONFIG_KSU) += kernelsu/'
KERNSU_KCONFIG_LINE='source "drivers/kernelsu/Kconfig"'

# Resolve a clone directory inside the work directory so a build can reuse one
# clone across the standard and EL2 variants.
kernelsu_clone_dir() {
  : "${WORKDIR:?missing WORKDIR}"
  printf '%s\n' "${KERNSU_SRC:-$WORKDIR/kernelsu-src}"
}

fetch_kernelsu() {
  local clone_dir
  clone_dir="$(kernelsu_clone_dir)"

  rm -rf "$clone_dir"
  mkdir -p "$(dirname "$clone_dir")"

  if ! git clone --quiet "$KERNSU_URL" "$clone_dir"; then
    echo "failed to clone KernelSU from $KERNSU_URL" >&2
    return 1
  fi

  if ! git -C "$clone_dir" checkout --quiet "$KERNSU_COMMIT"; then
    echo "failed to check out KernelSU commit $KERNSU_COMMIT (ref $KERNSU_REF)" >&2
    return 1
  fi

  local resolved
  resolved="$(git -C "$clone_dir" rev-parse HEAD)"
  if [[ "$resolved" != "$KERNSU_COMMIT" ]]; then
    echo "KernelSU at $clone_dir resolved to $resolved, expected $KERNSU_COMMIT" >&2
    return 1
  fi

  if [[ ! -d "$clone_dir/kernel" ]]; then
    echo "KernelSU $KERNSU_COMMIT has no kernel/ directory at $clone_dir" >&2
    return 1
  fi

  echo "$clone_dir"
}

# True when $2 is a line of the file $1, compared with whitespace stripped.
file_has_trimmed_line() {
  local file="$1"
  local wanted="$2"

  [[ -f "$file" ]] || return 1
  grep -qFx "$wanted" <(sed 's/[[:space:]]*$//' "$file")
}

# Point drivers/kernelsu at the cloned kernel/ directory.
wire_kernelsu_driver_symlink() {
  local src_dir="$1"
  local kernel_su_dir="$2"
  local drivers_dir="$src_dir/drivers"

  if [[ ! -d "$drivers_dir" ]]; then
    echo "missing $drivers_dir, cannot wire KernelSU into $src_dir" >&2
    return 1
  fi

  if [[ ! -d "$kernel_su_dir/kernel" ]]; then
    echo "missing $kernel_su_dir/kernel, cannot wire KernelSU into $src_dir" >&2
    return 1
  fi

  local link="$drivers_dir/kernelsu"
  if [[ -e "$link" && ! -L "$link" ]]; then
    echo "$link exists and is not a symlink; remove it before wiring KernelSU" >&2
    return 1
  fi
  if [[ -L "$link" && "$(readlink -f "$link")" == "$(readlink -f "$kernel_su_dir/kernel")" ]]; then
    return 0
  fi

  ln -sfn "$(realpath --relative-to="$drivers_dir" "$kernel_su_dir/kernel")" "$link"
}

# Add the KernelSU objects to drivers/Makefile and the Kconfig source line to
# drivers/Kconfig, each only when it is not already there.
wire_kernelsu_kbuild() {
  local src_dir="$1"
  local drivers_dir="$src_dir/drivers"
  local makefile="$drivers_dir/Makefile"
  local kconfig="$drivers_dir/Kconfig"

  if [[ ! -f "$makefile" ]]; then
    echo "missing $makefile, cannot wire KernelSU into $src_dir" >&2
    return 1
  fi
  if [[ ! -f "$kconfig" ]]; then
    echo "missing $kconfig, cannot wire KernelSU into $src_dir" >&2
    return 1
  fi

  if ! file_has_trimmed_line "$makefile" "$KERNSU_MAKEFILE_LINE"; then
    printf '\n%s\n' "$KERNSU_MAKEFILE_LINE" >>"$makefile"
  fi

  if ! file_has_trimmed_line "$kconfig" "$KERNSU_KCONFIG_LINE"; then
    local endmenu_line
    endmenu_line="$(grep -n '^endmenu' "$kconfig" | tail -n1 | cut -d: -f1)"
    if [[ -z "$endmenu_line" ]]; then
      echo "no closing endmenu in $kconfig, cannot wire KernelSU into $src_dir" >&2
      return 1
    fi
    sed -i "${endmenu_line}i\\
${KERNSU_KCONFIG_LINE}" "$kconfig"
  fi
}

# Wire the pinned KernelSU into $src_dir and print the revision description the
# caller should record in the variant's temporary commit message.
integrate_kernelsu() {
  local src_dir="$1"
  local clone_dir kernel_su_commit

  clone_dir="$(fetch_kernelsu)"
  kernel_su_commit="$(git -C "$clone_dir" rev-parse --short=12 HEAD)"

  wire_kernelsu_driver_symlink "$src_dir" "$clone_dir"
  wire_kernelsu_kbuild "$src_dir"

  printf '%s\n' "KernelSU ${KERNSU_REF} ${kernel_su_commit}"
}

# KernelSU's kprobe integration also asks for KPROBES, and its syscall hook
# calls register_trace_prio_sys_enter() whenever CONFIG_HAVE_SYSCALL_TRACEPOINTS
# is set, which is true on arm64. That function only exists when tracepoints are
# enabled, so the build needs CONFIG_TRACEPOINTS too. gaokun3_defconfig disables
# tracing (# CONFIG_FTRACE is not set), and TRACEPOINTS/TRACING have no prompt,
# so enable the promptable CONFIG_FTRACE, which selects them.
#
# olddefconfig drops an unmet tristate without an error, so enable the set here
# and fail the build when the resolved configuration still lacks it.
configure_kernel_su() {
  local src_dir="$1"
  local out_dir="$2"

  "$src_dir"/scripts/config --file "$out_dir/.config" --enable KPROBES
  "$src_dir"/scripts/config --file "$out_dir/.config" --enable FTRACE
  "$src_dir"/scripts/config --file "$out_dir/.config" --enable KSU
}

assert_kernelsu_enabled() {
  local out_dir="$1"
  local symbol

  for symbol in CONFIG_KSU CONFIG_KPROBES CONFIG_TRACEPOINTS; do
    if ! grep -qx "${symbol}=y" "$out_dir/.config"; then
      echo "KernelSU integration did not enable ${symbol}=y in $out_dir/.config" >&2
      return 1
    fi
  done
}
