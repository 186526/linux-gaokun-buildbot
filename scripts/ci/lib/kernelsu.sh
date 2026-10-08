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

# Repository-carried source transformations for the pinned KernelSU checkout.
# Defaults to patches/kernelsu/ at the repository root, resolved from this
# file's location so a sourced integration does not depend on the caller's
# working directory.
KERNSU_PATCH_DIR="${KERNSU_PATCH_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/patches/kernelsu}"

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

# Apply the repository-carried source transformations to the pinned checkout.
# Each *.patch under KERNSU_PATCH_DIR is applied with `git apply`, which is
# strict about context and fails the build if a patch no longer matches the
# pinned revision. This is how the SELinux no-policy guard reaches the built
# kernel without vendoring KernelSU; see patches/kernelsu/PINNED_REVISION.md.
apply_kernelsu_source_patches() {
  local clone_dir="$1"
  local patch_dir="${KERNSU_PATCH_DIR:-}"
  local patch_file

  if [[ -z "$patch_dir" || ! -d "$patch_dir" ]]; then
    echo "KernelSU patch directory not found: ${patch_dir:-<unset>}" >&2
    return 1
  fi

  shopt -s nullglob
  for patch_file in "$patch_dir"/*.patch; do
    if ! git -C "$clone_dir" apply --whitespace=nowarn "$patch_file"; then
      echo "failed to apply KernelSU source patch $(basename "$patch_file")" >&2
      shopt -u nullglob
      return 1
    fi
  done
  shopt -u nullglob
}

# Fail the build if the transformed source no longer carries the SELinux
# no-policy guard. The patch apply above already fails on a mismatched hunk;
# this pins the guard to the transformed tree so a patch that applies but no
# longer protects the NULL-policy path cannot ship silently.
assert_kernelsu_source_guard() {
  local clone_dir="$1"
  local rules="$clone_dir/kernel/selinux/rules.c"

  if [[ ! -f "$rules" ]]; then
    echo "missing $rules, cannot verify the KernelSU SELinux guard" >&2
    return 1
  fi
  if ! grep -q 'no SELinux policy loaded, skipping SELinux rules' "$rules"; then
    echo "KernelSU SELinux no-policy guard is not present in $rules" >&2
    return 1
  fi
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

  local endmenu_line=""
  if ! file_has_trimmed_line "$kconfig" "$KERNSU_KCONFIG_LINE"; then
    endmenu_line="$(grep -n '^endmenu' "$kconfig" | tail -n1 | cut -d: -f1)"
    if [[ -z "$endmenu_line" ]]; then
      echo "no closing endmenu in $kconfig, cannot wire KernelSU into $src_dir" >&2
      return 1
    fi
  fi

  # Both insertion points are known to be valid now, so neither file is left
  # half-wired when the other would fail.
  if ! file_has_trimmed_line "$makefile" "$KERNSU_MAKEFILE_LINE"; then
    printf '\n%s\n' "$KERNSU_MAKEFILE_LINE" >>"$makefile"
  fi

  if [[ -n "$endmenu_line" ]]; then
    sed -i "${endmenu_line}i\\
${KERNSU_KCONFIG_LINE}" "$kconfig"
  fi
}

# Wire the pinned KernelSU into $src_dir and print a revision description for
# the build log. Every fallible step is checked before the kernel tree is
# touched, so a failed fetch or validation returns non-zero without leaving
# drivers/Makefile, drivers/Kconfig or drivers/kernelsu half-wired.
integrate_kernelsu() {
  local src_dir="$1"
  local clone_dir kernel_su_commit

  clone_dir="$(fetch_kernelsu)" || return 1
  kernel_su_commit="$(git -C "$clone_dir" rev-parse --short=12 HEAD)" || return 1

  # The source transformations must land before the driver is wired in and the
  # kernel is configured, so a failed apply stops the build here.
  apply_kernelsu_source_patches "$clone_dir" || return 1
  assert_kernelsu_source_guard "$clone_dir" || return 1

  wire_kernelsu_driver_symlink "$src_dir" "$clone_dir" || return 1
  wire_kernelsu_kbuild "$src_dir" || return 1

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
  "$src_dir"/scripts/config --file "$out_dir/.config" --enable KSU_DEBUG
}

assert_kernelsu_enabled() {
  local out_dir="$1"
  local symbol

  for symbol in CONFIG_KSU CONFIG_KSU_DEBUG CONFIG_KPROBES CONFIG_TRACEPOINTS; do
    if ! grep -qx "${symbol}=y" "$out_dir/.config"; then
      echo "KernelSU integration did not enable ${symbol}=y in $out_dir/.config" >&2
      return 1
    fi
  done
}
