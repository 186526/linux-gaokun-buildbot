#!/usr/bin/env bash
set -euo pipefail

KERNEL_TAG="${KERNEL_TAG:-v7.2-rc2}"
KERNEL_BASE="${KERNEL_BASE:-mainline}"
GAOKUN_DIR="${GAOKUN_DIR:-$HOME/gaokun/linux-gaokun-buildbot}"
KERN_SRC="${KERN_SRC:-$HOME/gaokun/mainline-linux}"
KERN_OUT="${KERN_OUT:-$HOME/gaokun/kernel-out}"
KERN_OUT_EL2="${KERN_OUT_EL2:-$HOME/gaokun/kernel-out-el2}"
# KernelSU is opt-in. Empty means "ask interactively"; the prompt defaults to
# yes (a local UX default, separate from the CI default of false).
BUILD_KERNELSU="${BUILD_KERNELSU:-}"
# Non-interactive overrides. Leave any of these unset to be prompted for it.
INSTALL_DEPS="${INSTALL_DEPS:-}"
PULL_KERNEL="${PULL_KERNEL:-}"
USE_MIRROR="${USE_MIRROR:-}"
EL2_CHOICE="${EL2_CHOICE:-}"
INSTALL_KERNEL="${INSTALL_KERNEL:-}"
# KernelSU integration inputs, kept identical to scripts/ci/lib/kernelsu.sh and
# the pinned revision recorded in patches/kernelsu/PINNED_REVISION.md.
WORKDIR="${WORKDIR:-$HOME/gaokun}"
KERNSU_URL="${KERNSU_URL:-https://github.com/tiann/KernelSU.git}"
KERNSU_REF="${KERNSU_REF:-v3.3.0}"
KERNSU_COMMIT="${KERNSU_COMMIT:-932014ab5b2c9b74a3d11e2ec4d17dd10fc9442e}"
KERNSU_SRC="${KERNSU_SRC:-$WORKDIR/kernelsu-src}"

# Answer yes/no/other prompts. `read` under `set -e` aborts at EOF, which makes
# the script unusable from a non-interactive shell; the fallback keeps the
# documented defaults when no override is set and stdin is closed.
#   $1 variable holding an explicit answer ("" means ask)
#   $2 prompt text
#   $3 default answer used when stdin is not a terminal or is at EOF
#   $4 optional regex matching an answer that is neither yes nor no (e.g. "both")
# On success the answer is written back to the variable named by $1.
prompt_answer() {
    local -n out="$1"
    local prompt="$2" default="$3" extra="${4:-}" answer

    # ${out:-} guards the nameref when the caller's variable is still unset
    # (set -u would otherwise abort before the prompt can run).
    if [[ -n "${out:-}" ]]; then
        return 0
    fi

    if [[ ! -t 0 ]]; then
        out="$default"
        echo "$prompt$default (non-interactive default)"
        return 0
    fi

    if read -r -p "$prompt" answer; then
        out="${answer:-$default}"
    else
        out="$default"
        echo "$prompt$default (no input; using default)"
    fi

    if [[ -n "$extra" && "$out" =~ $extra ]]; then
        return 0
    fi
    if [[ "$out" =~ ^([yY][eE][sS]|[yY])$ ]]; then
        out="yes"
    elif [[ "$out" =~ ^([nN][oO]|[nN])$ ]]; then
        out="no"
    else
        out="$default"
    fi
}

# Normalise a boolean-ish value to true/false; prints the error and returns
# non-zero on an unrecognised value. It must not exit on its own: most callers
# read the result through a command substitution, where an exit would only end
# the subshell and let the caller carry on with an empty value.
normalize_bool() {
    local value="$1" name="$2"
    case "${value,,}" in
        1|true|yes|y|on) printf 'true\n' ;;
        0|false|no|n|off|"") printf 'false\n' ;;
        *)
            echo "Invalid $name value: $value (expected true or false). Exiting." >&2
            return 1
            ;;
    esac
}

# Read a boolean-ish value for a caller that consumes it inside a command
# substitution. The caller must invoke this as `var="$(require_bool ...)"`:
# `exit` inside the substitution still only ends the subshell, so the caller
# appends `|| exit 1` at the assignment to propagate a failure (see the call
# sites below).
require_bool() {
    local value="$1" name="$2"
    normalize_bool "$value" "$name" || return 1
}

if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    DISTRO="$ID"
else
    echo "Cannot determine OS distribution. Exiting."
    exit 1
fi

if [[ "$DISTRO" != "ubuntu" && "$DISTRO" != "fedora" ]]; then
    echo "Unsupported distribution: $DISTRO. Only ubuntu and fedora are supported. Exiting."
    exit 1
fi

# The INSTALL_DEPS override must be mapped before the toolchain prompt below.
install_deps=""
if [[ -n "$INSTALL_DEPS" ]]; then
    install_deps_bool="$(require_bool "$INSTALL_DEPS" INSTALL_DEPS)" || exit 1
    [[ "$install_deps_bool" == "true" ]] && install_deps="yes" || install_deps="no"
fi

prompt_answer install_deps "Install necessary minimal kernel build toolchain? [y/N] [default: n]: " no
if [[ "$install_deps" == "yes" ]]; then
    echo "Installing build dependencies for $DISTRO..."
    if [[ "$DISTRO" == "ubuntu" ]]; then
        sudo apt-get update
        sudo apt-get install -y gcc make bison flex bc libssl-dev libelf-dev dwarves git ccache curl
    else
        sudo dnf install -y gcc make bison flex bc openssl-devel elfutils-libelf-devel ncurses-devel dwarves git ccache curl
    fi
fi

export CCACHE_DIR="${CCACHE_DIR:-$HOME/gaokun/.ccache}"
export CCACHE_BASEDIR="${CCACHE_BASEDIR:-$HOME/gaokun}"
export CCACHE_NOHASHDIR="${CCACHE_NOHASHDIR:-true}"
export CCACHE_COMPILERCHECK="${CCACHE_COMPILERCHECK:-content}"

if [[ -d /usr/lib64/ccache ]]; then
    export PATH="/usr/lib64/ccache:$PATH"
elif [[ -d /usr/lib/ccache ]]; then
    export PATH="/usr/lib/ccache:$PATH"
fi

if [[ "$(uname -m)" == "aarch64" ]]; then
    CROSS_COMPILE="${CROSS_COMPILE:-}"
else
    CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
fi

# EL2 selection. EL2_CHOICE accepts y/n/both to select standard, EL2, or both
# without prompting; BUILD_EL2=true is a convenience alias for both. The
# interactive prompt and its "n" default are preserved when neither is set.
if [[ -n "$EL2_CHOICE" ]]; then
    el2_choice="$EL2_CHOICE"
else
    build_el2="$(require_bool "${BUILD_EL2:-false}" BUILD_EL2)" || exit 1
    if [[ "$build_el2" == "true" ]]; then
        el2_choice="both"
    else
        prompt_answer el2_choice "Build EL2 kernel? (Y: only EL2, n: only standard, both: build both) [default: n]: " n '^(both|el2|std|standard)$'
        el2_choice="$el2_choice"
    fi
fi
case "${el2_choice,,}" in
    both) el2_choice="both" ;;
    y|yes|el2) el2_choice="yes" ;;
    n|no|std|standard|"") el2_choice="no" ;;
    *)
        echo "Invalid EL2_CHOICE value: $el2_choice (expected y, n, or both). Exiting." >&2
        exit 1
        ;;
esac

# KernelSU: prompt defaults to yes; the value is normalised to true/false.
if [[ -z "$BUILD_KERNELSU" ]]; then
    prompt_answer BUILD_KERNELSU "Build KernelSU into the kernel? [Y/n] [default: Y]: " yes
fi
BUILD_KERNELSU="$(require_bool "$BUILD_KERNELSU" BUILD_KERNELSU)" || exit 1
echo "KernelSU build: $BUILD_KERNELSU"

# Map the boolean non-interactive overrides onto the internal answer variables.
# An unset override leaves the variable empty, so the prompt still runs. The
# `|| exit 1` sits on the assignment, not inside the substitution, so an
# invalid value ends the script instead of just the subshell.
pull_answer=""
mirror_choice=""
install_kernel_answer=""
if [[ -n "$PULL_KERNEL" ]]; then
    pull_answer="$(require_bool "$PULL_KERNEL" PULL_KERNEL)" || exit 1
    [[ "$pull_answer" == "true" ]] && pull_answer="yes" || pull_answer="no"
fi
if [[ -n "$USE_MIRROR" ]]; then
    mirror_choice="$(require_bool "$USE_MIRROR" USE_MIRROR)" || exit 1
    [[ "$mirror_choice" == "true" ]] && mirror_choice="yes" || mirror_choice="no"
fi
if [[ -n "$INSTALL_KERNEL" ]]; then
    install_kernel_answer="$(require_bool "$INSTALL_KERNEL" INSTALL_KERNEL)" || exit 1
    [[ "$install_kernel_answer" == "true" ]] && install_kernel_answer="yes" || install_kernel_answer="no"
fi

configure_git_identity() {
    if [[ -z "$(git -C "$KERN_SRC" config user.name || true)" ]]; then
        git -C "$KERN_SRC" config user.name "local builder"
    fi
    if [[ -z "$(git -C "$KERN_SRC" config user.email || true)" ]]; then
        git -C "$KERN_SRC" config user.email "builder@example.com"
    fi
}

apply_patch() {
    local resolution="$1"
    if patch_is_already_applied "$KERN_SRC" "$resolution"; then
        echo "skip already-applied patch: $resolution"
        return 0
    fi
    git -C "$KERN_SRC" am "$resolution"
}

# Patch-series helpers (patch_series_files, patch_resolution_for,
# patch_is_already_applied, resolve_kernel_base) live in the shared CI library
# so local and CI builds select base-local overrides by the same rules. The
# loader is idempotent because ensure_source_tree can return before sourcing it
# and apply_kernelsu still needs it for an already-prepared tree.
load_patch_helpers() {
    if declare -F patch_series_files >/dev/null 2>&1; then
        return 0
    fi

    local helpers="$GAOKUN_DIR/scripts/ci/lib/select_base.sh"
    if [[ ! -f "$helpers" ]]; then
        echo "ERROR: shared patch helpers not found: $helpers" >&2
        echo "Set GAOKUN_DIR to the linux-gaokun-buildbot checkout." >&2
        exit 1
    fi

    # shellcheck source=../ci/lib/select_base.sh
    . "$helpers"
}

# Apply one series using the shared patch-resolution helpers, so base-local
# overrides and XanMod-only patches follow the same rules as the CI pipeline.
apply_series() {
    local series_name="$1"
    local shared_dir="$2"
    local patch_file

    while IFS= read -r patch_file; do
        apply_patch "$patch_file"
    done < <(patch_series_files "$series_name" "$shared_dir")
}

# KernelSU is an opt-in integration. It is not vendored: the pinned upstream
# tree is cloned and wired into the kernel the same way upstream
# kernel/setup.sh does it (drivers/kernelsu symlink, drivers/Makefile object
# line, drivers/Kconfig source line). These functions mirror
# scripts/ci/lib/kernelsu.sh so a local build and CI produce the same result.
kernelsu_clone_dir() {
    printf '%s\n' "${KERNSU_SRC:-$WORKDIR/kernelsu-src}"
}

kernelsu_driver_link() {
    printf '%s\n' "$KERN_SRC/drivers/kernelsu"
}

# The relative symlink target wire_kernelsu writes for the pinned clone.
# realpath -m still computes it once the clone directory is gone, so an
# unwire on a stale tree can tell KernelSU's link from an unrelated symlink.
kernelsu_expected_link_target() {
    realpath -m --relative-to="$KERN_SRC/drivers" "$(kernelsu_clone_dir)/kernel"
}

# Delete the lines that are exactly $2 from file $1, leaving every other line
# untouched. An exact whole-line match means an unrelated edit is preserved
# rather than reverted, unlike `git checkout --`.
kernelsu_remove_exact_line() {
    local file="$1" wanted="$2" mode tmp
    [[ -f "$file" ]] || return 0
    tmp="$(mktemp)"
    awk -v skip="$wanted" '$0 != skip' "$file" >"$tmp"
    if ! cmp -s "$file" "$tmp"; then
        # Replace the file (new inode) rather than rewriting it in place. A
        # truncate-and-write can leave the index's cached stat entry looking
        # "racily clean" when the size is unchanged within the same second, so
        # a later `git apply --index` would reject the file as not matching the
        # index. rename(2) always gives a new inode, whose ctime the index
        # notices. `cp` cannot be used here: GNU cp keeps the inode.
        mode="$(stat -c '%a' "$file")"
        chmod "$mode" "$tmp"
        mv -f "$tmp" "$file"
    else
        rm -f "$tmp"
    fi
}

# Drop the single trailing blank line wire_kernelsu inserts before its Makefile
# addition, without touching blank lines elsewhere in the file.
kernelsu_strip_trailing_blank_line() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    sed -i '${/^$/d;}' "$file"
}

# True when $2 is a line of the file $1, compared with trailing whitespace
# stripped.
kernelsu_file_has_line() {
    local file="$1" wanted="$2"
    [[ -f "$file" ]] || return 1
    grep -qFx "$wanted" <(sed 's/[[:space:]]*$//' "$file")
}

fetch_kernelsu() {
    local clone_dir
    clone_dir="$(kernelsu_clone_dir)"

    # Reuse an existing clone at the pinned commit so "both" mode clones once.
    if [[ -d "$clone_dir/.git" ]] && \
        [[ "$(git -C "$clone_dir" rev-parse HEAD 2>/dev/null || true)" == "$KERNSU_COMMIT" ]]; then
        echo "KernelSU source: $clone_dir @ $KERNSU_COMMIT (reused)"
        return 0
    fi

    rm -rf "$clone_dir"
    mkdir -p "$(dirname "$clone_dir")"

    if ! git clone --quiet "$KERNSU_URL" "$clone_dir"; then
        echo "ERROR: failed to clone KernelSU from $KERNSU_URL" >&2
        echo "A KernelSU build needs network access to github.com." >&2
        echo "Set KERNSU_URL to a reachable mirror, or BUILD_KERNELSU=false to skip it." >&2
        exit 1
    fi

    if ! git -C "$clone_dir" checkout --quiet "$KERNSU_COMMIT"; then
        echo "ERROR: failed to check out KernelSU commit $KERNSU_COMMIT (ref $KERNSU_REF)" >&2
        exit 1
    fi

    local resolved
    resolved="$(git -C "$clone_dir" rev-parse HEAD)"
    if [[ "$resolved" != "$KERNSU_COMMIT" ]]; then
        echo "ERROR: KernelSU at $clone_dir resolved to $resolved, expected $KERNSU_COMMIT" >&2
        exit 1
    fi

    if [[ ! -d "$clone_dir/kernel" ]]; then
        echo "ERROR: KernelSU $KERNSU_COMMIT has no kernel/ directory at $clone_dir" >&2
        exit 1
    fi

    echo "KernelSU source: $clone_dir @ $resolved"
}

wire_kernelsu() {
    local clone_dir="$1"
    local link drivers_dir makefile kconfig endmenu_line=""
    link="$(kernelsu_driver_link)"
    drivers_dir="$KERN_SRC/drivers"
    makefile="$drivers_dir/Makefile"
    kconfig="$drivers_dir/Kconfig"

    if [[ ! -d "$drivers_dir" ]]; then
        echo "ERROR: missing $drivers_dir, cannot wire KernelSU" >&2
        exit 1
    fi

    if [[ -e "$link" && ! -L "$link" ]]; then
        echo "ERROR: $link exists and is not a symlink; remove it before wiring KernelSU" >&2
        exit 1
    fi

    # Resolve the drivers/Kconfig insertion point before writing anything, so a
    # missing endmenu fails cleanly instead of leaving the tree half-wired. The
    # `|| true` keeps pipefail from aborting on grep's non-zero "no match"
    # status before the explicit error below can print.
    if ! kernelsu_file_has_line "$kconfig" 'source "drivers/kernelsu/Kconfig"'; then
        endmenu_line="$(grep -n '^endmenu' "$kconfig" | tail -n1 | cut -d: -f1 || true)"
        if [[ -z "$endmenu_line" ]]; then
            echo "ERROR: no closing endmenu in $kconfig, cannot wire KernelSU" >&2
            echo "The kernel tree is unchanged; fix the Kconfig or set BUILD_KERNELSU=false." >&2
            exit 1
        fi
    fi

    if [[ -L "$link" && "$(readlink -f "$link")" == "$(readlink -f "$clone_dir/kernel")" ]]; then
        echo "KernelSU driver symlink already present."
    else
        ln -sfn "$(realpath --relative-to="$drivers_dir" "$clone_dir/kernel")" "$link"
    fi

    # Both insertion points are known to be valid here, so neither file is left
    # half-wired when the other would fail.
    if ! kernelsu_file_has_line "$makefile" 'obj-$(CONFIG_KSU) += kernelsu/'; then
        printf '\n%s\n' 'obj-$(CONFIG_KSU) += kernelsu/' >>"$makefile"
    fi

    if [[ -n "$endmenu_line" ]]; then
        sed -i "${endmenu_line}i\\
source \"drivers/kernelsu/Kconfig\"" "$kconfig"
    fi

    echo "KernelSU wired into $KERN_SRC."
}

# Clone and wire KernelSU into the kernel source tree. Idempotent: the symlink
# and Kbuild lines are skipped when already present, and a clone is reused
# across the standard and EL2 variants.
apply_kernelsu() {
    if [[ "$BUILD_KERNELSU" != "true" ]]; then
        echo "KernelSU build disabled; skipping KernelSU integration."
        # Clean any wiring a previous run left uncommitted, including on the
        # standard-only path where no EL2 transition would otherwise unwire it.
        unwire_kernelsu
        return 0
    fi

    fetch_kernelsu
    wire_kernelsu "$(kernelsu_clone_dir)"
}

# Remove KernelSU's own wiring from the source tree, leaving every unrelated
# change intact. The clone under WORKDIR is left in place for reuse. This is
# needed before the EL2 transition: `git apply --index` (and `git reset --hard`)
# only touch tracked paths, so the untracked symlink would otherwise be left
# behind.
#
# Unconditional on purpose: a previous run may have left the wiring uncommitted
# even when this run is not building KernelSU, and that stale wiring would break
# the staged EL2 apply or a later `gaokun3_defconfig` once the clone is gone.
# It removes only KernelSU's exact lines rather than reverting the two files, so
# unrelated local edits survive; a symlink that is not KernelSU's is left alone
# and reported instead of deleted.
unwire_kernelsu() {
    local link expected_target actual_target
    link="$(kernelsu_driver_link)"
    expected_target="$(kernelsu_expected_link_target)"

    if [[ -L "$link" ]]; then
        actual_target="$(readlink "$link")"
        if [[ "$actual_target" == "$expected_target" ]]; then
            rm -f "$link"
        else
            echo "ERROR: $link is a symlink to '$actual_target', not the expected KernelSU target '$expected_target'." >&2
            echo "Refusing to remove it; delete or move it yourself if it is stale." >&2
            exit 1
        fi
    fi

    kernelsu_remove_exact_line "$KERN_SRC/drivers/Kconfig" 'source "drivers/kernelsu/Kconfig"'
    if kernelsu_file_has_line "$KERN_SRC/drivers/Makefile" 'obj-$(CONFIG_KSU) += kernelsu/'; then
        kernelsu_remove_exact_line "$KERN_SRC/drivers/Makefile" 'obj-$(CONFIG_KSU) += kernelsu/'
        kernelsu_strip_trailing_blank_line "$KERN_SRC/drivers/Makefile"
    fi

    # Rewriting the tracked files above does not update the index's cached stat
    # data, which would make a later `git apply --index` reject them as not
    # matching the index. Refresh the index so the files match HEAD (only
    # KernelSU's own lines were removed); `|| true` tolerates files that still
    # differ from HEAD, which are legitimate local edits the caller keeps.
    git -C "$KERN_SRC" update-index --refresh >/dev/null 2>&1 || true
}

# Enable KernelSU's configuration in one variant's generated .config. KSU
# depends on KPROBES and its syscall hook needs TRACEPOINTS (selected by
# FTRACE); the gaokun3 defconfig disables tracing. olddefconfig drops an unmet
# tristate silently, so the symbols are enabled here and verified afterwards.
configure_kernelsu_config() {
    local out_dir="$1"

    if [[ "$BUILD_KERNELSU" != "true" ]]; then
        return 0
    fi

    "$KERN_SRC"/scripts/config --file "$out_dir/.config" --enable KPROBES
    "$KERN_SRC"/scripts/config --file "$out_dir/.config" --enable FTRACE
    "$KERN_SRC"/scripts/config --file "$out_dir/.config" --enable KSU
}

assert_kernelsu_enabled() {
    local out_dir="$1"
    local symbol

    if [[ "$BUILD_KERNELSU" != "true" ]]; then
        return 0
    fi

    for symbol in CONFIG_KSU CONFIG_KPROBES CONFIG_TRACEPOINTS; do
        if ! grep -qx "${symbol}=y" "$out_dir/.config"; then
            echo "ERROR: KernelSU integration did not enable ${symbol}=y in $out_dir/.config" >&2
            exit 1
        fi
    done
}

ensure_source_tree() {
    if [[ -f "$KERN_SRC/arch/arm64/configs/gaokun3_defconfig" ]]; then
        return 0
    fi

    prompt_answer pull_answer "gaokun3_defconfig not found in kernel directory. Pull kernel and apply patches? [y/N] [default: N]: " no
    if [[ "$pull_answer" != "yes" ]]; then
        echo "Exiting."
        exit 1
    fi

    if [[ ! -d "$GAOKUN_DIR" ]]; then
        echo "linux-gaokun-buildbot not found. Cloning..."
        mkdir -p "$HOME/gaokun"
        git clone https://github.com/KawaiiHachimi/linux-gaokun-buildbot "$GAOKUN_DIR"
    fi

    # Shared base resolution and patch selection (KERNEL_PATCH_DIR, overrides,
    # XanMod-only patches). Sourced after the repository is guaranteed present.
    load_patch_helpers
    resolve_kernel_base

    if [[ "$KERNEL_BASE" == "xanmod" ]]; then
        KERNEL_URL="${KERNEL_URL:-https://gitlab.com/xanmod/linux.git}"
    else
        prompt_answer mirror_choice "Use Chinese mirror (mirrors.bfsu.edu.cn) for Linux kernel? [Y/n] [default: Y]: " yes
        if [[ "$mirror_choice" == "no" ]]; then
            KERNEL_URL="https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git"
        else
            KERNEL_URL="https://mirrors.bfsu.edu.cn/git/linux.git"
        fi
    fi

    rm -rf "$KERN_SRC"
    git clone --depth=1 "$KERNEL_URL" "$KERN_SRC" -b "$KERNEL_TAG"
    configure_git_identity

    echo "Applying standard gaokun3 patches (base: $KERNEL_BASE)..."
    for series in upstream others media; do
        apply_series "$series" "$GAOKUN_DIR/patches/$series"
    done

    apply_patch "$(patch_resolution_for . "$GAOKUN_DIR/patches/0099-arm64-gaokun3-import-local-dts-and-defconfig.patch")"
}

el2_state() {
    if git -C "$KERN_SRC" log -1 --pretty=%B 2>/dev/null | grep -q "^Apply EL2 patches$"; then
        printf 'el2\n'
        return 0
    fi

    if git -C "$KERN_SRC" apply --reverse --check "$GAOKUN_DIR"/patches/el2/*.patch >/dev/null 2>&1; then
        printf 'el2-mixed\n'
        return 0
    fi

    printf 'standard\n'
}

ensure_ubuntu_initramfs_firmware_hook() {
    sudo mkdir -p /etc/initramfs-tools/hooks
    sudo tee /etc/initramfs-tools/hooks/gaokun3-firmware >/dev/null <<'EOF'
#!/bin/sh
set -e

. /usr/share/initramfs-tools/hook-functions

copy_fw() {
    copy_file firmware "$1" || [ "$?" -eq 1 ]
}

copy_fw /lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qcadsp8280.mbn
copy_fw /lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qccdsp8280.mbn
copy_fw /lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qcslpi8280.mbn
copy_fw /lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/audioreach-tplg.bin
copy_fw /lib/firmware/qcom/a660_gmu.bin
copy_fw /lib/firmware/qcom/a660_sqe.fw
copy_fw /lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qcdxkmsuc8280.mbn
EOF
    sudo chmod 0755 /etc/initramfs-tools/hooks/gaokun3-firmware
}

build_kernel() {
    local mode="$1"
    local out_dir
    local dtb_name
    local cmdline
    local conf_root
    local temp_kernel_conf_root=""
    local restore_kernel_conf=0
    local current_state
    # Per-variant install answer, so "both" mode asks about each kernel.
    local do_install=""

    cd "$KERN_SRC"
    current_state="$(el2_state)"

    if [[ "$mode" == "el2" ]]; then
        out_dir="$KERN_OUT_EL2"
        dtb_name="sc8280xp-huawei-gaokun3-el2.dtb"

        echo -e "\n=== Preparing Source Tree for EL2 Kernel ==="
        case "$current_state" in
            standard)
                echo "Applying EL2 patches to source tree..."
                # The KernelSU wiring is untracked and would break the staged
                # apply, so remove it first and re-apply it after the commit.
                unwire_kernelsu
                if ! git apply --index "$GAOKUN_DIR"/patches/el2/*.patch; then
                    echo "ERROR: failed to apply the EL2 patch series." >&2
                    echo "Restore the source tree to a clean standard-patched state and retry." >&2
                    exit 1
                fi
                git commit -m "Apply EL2 patches"
                ;;
            el2)
                echo "Source tree is already patched for EL2."
                ;;
            *)
                echo "Source tree already contains EL2 changes, but the last commit is not the expected temporary EL2 commit." >&2
                echo "Please restore the tree to a clean standard-patched state before using this helper." >&2
                exit 1
                ;;
        esac

        # Wired after the EL2 commit so the KernelSU wiring is not part of the
        # temporary "Apply EL2 patches" commit and stays uncommitted, leaving
        # el2_state()'s top-commit check intact.
        apply_kernelsu

        mkdir -p "$out_dir"
        make O="$out_dir" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" gaokun3_defconfig
        "$KERN_SRC"/scripts/config --file "$out_dir/.config" --set-str LOCALVERSION "-gaokun3-el2"
    else
        out_dir="$KERN_OUT"
        dtb_name="sc8280xp-huawei-gaokun3.dtb"

        echo -e "\n=== Preparing Source Tree for Standard Kernel ==="
        case "$current_state" in
            el2)
                echo "Reverting EL2 patches to restore standard source tree..."
                # Drop the untracked KernelSU wiring before resetting so no
                # stale symlink or Kbuild lines survive the revert.
                unwire_kernelsu
                git reset --hard HEAD~1
                ;;
            standard)
                echo "Source tree is already in standard state."
                ;;
            *)
                echo "Source tree looks EL2-patched, but the last commit is not the expected temporary EL2 commit." >&2
                echo "Refusing to run git reset --hard HEAD~1 on an unexpected history shape." >&2
                exit 1
                ;;
        esac

        # Wire KernelSU into the (now standard) tree. The untracked wiring was
        # already removed by unwire_kernelsu before the reset, so this re-creates
        # it rather than relying on a stale leftover.
        apply_kernelsu

        mkdir -p "$out_dir"
        make O="$out_dir" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" gaokun3_defconfig
    fi

    # KernelSU has to be enabled in this variant's .config before olddefconfig
    # resolves the unmet KPROBES dependency.
    configure_kernelsu_config "$out_dir"

    echo "Starting build..."
    make O="$out_dir" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" olddefconfig
    assert_kernelsu_enabled "$out_dir"
    make O="$out_dir" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" -j"$(nproc)"
    make O="$out_dir" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" modules_prepare

    local krel
    krel="$(<"$out_dir/include/config/kernel.release")"
    echo "KREL ($mode): $krel"

    # The INSTALL_KERNEL override applies to every variant; otherwise each
    # variant prompts (do_install is function-local and starts empty).
    if [[ -n "$install_kernel_answer" ]]; then
        do_install="$install_kernel_answer"
    fi
    prompt_answer do_install "Compilation of $mode kernel finished. Install this kernel ($krel)? [Y/n] [default: Y]: " yes
    if [[ "$do_install" != "yes" ]]; then
        echo "Skipping installation for $mode kernel."
        return 0
    fi

    local initrd_src
    local dtb_inst_dir
    local dtb_boot_dir

    if [[ "$DISTRO" == "ubuntu" ]]; then
        initrd_src="initrd.img-$krel"
        dtb_inst_dir="/usr/lib/linux-image-$krel/qcom"
        dtb_boot_dir="/boot"
    else
        initrd_src="initramfs-$krel.img"
        dtb_inst_dir="/usr/lib/modules/$krel/dtb/qcom"
        dtb_boot_dir="/boot/dtb-$krel/qcom"
    fi

    sudo make O="$out_dir" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" INSTALL_MOD_PATH=/ modules_install
    sudo rm -f /lib/modules/"$krel"/{build,source}

    sudo cp "$out_dir"/arch/arm64/boot/Image /boot/vmlinuz-"$krel"
    sudo mkdir -p "$dtb_inst_dir"
    sudo cp "$out_dir"/arch/arm64/boot/dts/qcom/"$dtb_name" "$dtb_inst_dir"/"$dtb_name"
    if [[ "$DISTRO" == "ubuntu" ]]; then
        sudo cp "$out_dir"/arch/arm64/boot/dts/qcom/"$dtb_name" "$dtb_boot_dir"/dtb-"$krel"
    else
        sudo mkdir -p "$dtb_boot_dir"
        sudo cp "$out_dir"/arch/arm64/boot/dts/qcom/"$dtb_name" "$dtb_boot_dir"/"$dtb_name"
    fi

    if ! sudo test -f "$dtb_inst_dir/$dtb_name"; then
        echo "ERROR: DTB was not installed where kernel-install expects it:" >&2
        echo "  expected: $dtb_inst_dir/$dtb_name" >&2
        echo "  source:   $out_dir/arch/arm64/boot/dts/qcom/$dtb_name" >&2
        sudo ls -ld "$dtb_inst_dir" 2>/dev/null || true
        sudo find "$(dirname "$dtb_inst_dir")" -maxdepth 3 -type f 2>/dev/null | sort || true
        exit 1
    fi

    if [[ -f /etc/kernel/cmdline ]]; then
        cmdline="$(tr -s '[:space:]' ' ' </etc/kernel/cmdline)"
    else
        cmdline="$(tr ' ' '\n' </proc/cmdline | grep -ve '^BOOT_IMAGE=' -e '^initrd=' | tr '\n' ' ')"
    fi
    cmdline="${cmdline%" "}"

    if [[ "$mode" == "el2" && "$cmdline" != *"modprobe.blacklist=simpledrm"* ]]; then
        cmdline="${cmdline} modprobe.blacklist=simpledrm"
        cmdline="${cmdline#" "}"
    fi

    # Keep automatic initramfs hooks and explicit kernel-install calls aligned.
    sudo install -d /etc/kernel
    printf '%s\n' "$DISTRO" | sudo tee /etc/kernel/entry-token >/dev/null

    conf_root="$(mktemp -d)"
    trap 'rm -rf "$conf_root"' RETURN

    printf 'layout=bls\n' >"$conf_root/install.conf"
    printf '%s\n' "$cmdline" >"$conf_root/cmdline"
    printf 'qcom/%s\n' "$dtb_name" >"$conf_root/devicetree"

    if [[ "$DISTRO" == "ubuntu" ]]; then
        temp_kernel_conf_root="$(mktemp -d)"
        restore_kernel_conf=1

        for name in install.conf cmdline devicetree; do
            if sudo test -f "/etc/kernel/$name"; then
                sudo cp "/etc/kernel/$name" "$temp_kernel_conf_root/$name.orig"
            fi
        done

        printf 'layout=bls\n' | sudo tee /etc/kernel/install.conf >/dev/null
        printf '%s\n' "$cmdline" | sudo tee /etc/kernel/cmdline >/dev/null
        printf 'qcom/%s\n' "$dtb_name" | sudo tee /etc/kernel/devicetree >/dev/null
    fi

    if [[ "$DISTRO" == "ubuntu" ]]; then
        ensure_ubuntu_initramfs_firmware_hook
        sudo update-initramfs -c -k "$krel"
    else
        sudo dracut --force --kver "$krel"
    fi

    echo "kernel-install inputs:"
    echo "  kernel release: $krel"
    echo "  kernel image:   /boot/vmlinuz-$krel"
    echo "  initrd:         /boot/$initrd_src"
    echo "  devicetree:     qcom/$dtb_name"
    echo "  dtb source:     $dtb_inst_dir/$dtb_name"

    {
        sudo kernel-install --entry-token=os-id remove "$krel" >/dev/null 2>&1 || true
        if [[ "$DISTRO" == "fedora" ]]; then
            sudo env KERNEL_INSTALL_CONF_ROOT="$conf_root" \
                kernel-install --verbose --make-entry-directory=yes --entry-token=os-id add \
                "$krel" "/boot/vmlinuz-$krel"
        else
            sudo env KERNEL_INSTALL_CONF_ROOT="$conf_root" \
                kernel-install --verbose --make-entry-directory=yes --entry-token=os-id add \
                "$krel" "/boot/vmlinuz-$krel" "/boot/$initrd_src"
        fi
    } || {
        if [[ "$restore_kernel_conf" -eq 1 ]]; then
            for name in install.conf cmdline devicetree; do
                if [[ -f "$temp_kernel_conf_root/$name.orig" ]]; then
                    sudo cp "$temp_kernel_conf_root/$name.orig" "/etc/kernel/$name"
                else
                    sudo rm -f "/etc/kernel/$name"
                fi
            done
            rm -rf "$temp_kernel_conf_root"
        fi
        rm -rf "$conf_root"
        trap - RETURN
        return 1
    }

    if [[ "$restore_kernel_conf" -eq 1 ]]; then
        for name in install.conf cmdline devicetree; do
            if [[ -f "$temp_kernel_conf_root/$name.orig" ]]; then
                sudo cp "$temp_kernel_conf_root/$name.orig" "/etc/kernel/$name"
            else
                sudo rm -f "/etc/kernel/$name"
            fi
        done
        rm -rf "$temp_kernel_conf_root"
    fi

    rm -rf "$conf_root"
    trap - RETURN
}


if command -v ccache >/dev/null 2>&1; then
    echo "Resetting ccache statistics..."
    ccache -z
fi

if [[ "$el2_choice" == "both" ]]; then
    build_kernel "std"
    build_kernel "el2"
elif [[ "$el2_choice" =~ ^([yY][eE][sS]|[yY])$ ]]; then
    build_kernel "el2"
else
    build_kernel "std"
fi

if command -v ccache >/dev/null 2>&1; then
    echo -e "\n----------------------------------------"
    echo "Ccache statistics for this build:"
    ccache -s
    echo "----------------------------------------"
fi

echo -e "\nDone! Kernel update script finished."
