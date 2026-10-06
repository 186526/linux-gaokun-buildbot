#!/usr/bin/env bash
set -euo pipefail

KERNEL_TAG="${KERNEL_TAG:-v7.2-rc2}"
KERNEL_BASE="${KERNEL_BASE:-mainline}"
GAOKUN_DIR="${GAOKUN_DIR:-$HOME/gaokun/linux-gaokun-buildbot}"
KERN_SRC="${KERN_SRC:-$HOME/gaokun/mainline-linux}"
KERN_OUT="${KERN_OUT:-$HOME/gaokun/kernel-out}"
KERN_OUT_EL2="${KERN_OUT_EL2:-$HOME/gaokun/kernel-out-el2}"
# Empty means "ask interactively"; the prompt defaults to yes.
BUILD_KERNELSU="${BUILD_KERNELSU:-}"

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

read -r -p "Install necessary minimal kernel build toolchain? [y/N] [default: n]: " install_deps
install_deps="${install_deps:-n}"
if [[ "$install_deps" =~ ^([yY][eE][sS]|[yY])$ ]]; then
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

# EL2 selection: BUILD_EL2=true forces "both" (standard + EL2) for the
# non-interactive, CI-style invocation documented in the guides; otherwise the
# helper asks, preserving the original standard/EL2/both prompt and default.
if [[ "${BUILD_EL2:-}" == "true" ]]; then
    el2_choice="both"
    echo "BUILD_EL2=true: building both the standard and EL2 kernels."
else
    read -r -p "Build EL2 kernel? (Y: only EL2, n: only standard, both: build both) [default: n]: " el2_choice
    el2_choice="${el2_choice:-n}"
fi

# KernelSU defaults to enabled for the local helper (the shared public contract
# is BUILD_KERNELSU; CI workflow inputs default to false unless requested).
# Set BUILD_KERNELSU=false (or answer n) to build a plain kernel.
if [[ -z "$BUILD_KERNELSU" ]]; then
    read -r -p "Build KernelSU into the kernel? [Y/n] [default: Y]: " kernelsu_choice
    kernelsu_choice="${kernelsu_choice:-Y}"
    if [[ "$kernelsu_choice" =~ ^([nN][oO]|[nN])$ ]]; then
        BUILD_KERNELSU="false"
    else
        BUILD_KERNELSU="true"
    fi
fi

case "${BUILD_KERNELSU,,}" in
    1|true|yes|y|on) BUILD_KERNELSU="true" ;;
    0|false|no|n|off|"") BUILD_KERNELSU="false" ;;
    *)
        echo "Invalid BUILD_KERNELSU value: $BUILD_KERNELSU (expected true or false). Exiting." >&2
        exit 1
        ;;
esac
echo "KernelSU build: $BUILD_KERNELSU"

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

# KernelSU is an optional, default-enabled integration. It must be applied
# before each variant's kernel configuration step so its Kconfig entries and
# hooks are present when gaokun3_defconfig/olddefconfig run. It is applied to
# the shared kernel source tree, so both the standard and the EL2 output
# directories (built from that same tree) inherit it.
kernelsu_source_dir() {
    printf '%s\n' "$GAOKUN_DIR/patches/kernelsu"
}

kernelsu_patches_present() {
    local series_dir
    series_dir="$(kernelsu_source_dir)"

    [[ -d "$series_dir" ]] || return 1
    compgen -G "$series_dir/*.patch" >/dev/null 2>&1
}

apply_kernelsu() {
    local series_dir
    local patch_file

    if [[ "$BUILD_KERNELSU" != "true" ]]; then
        echo "KernelSU build disabled; skipping KernelSU integration."
        return 0
    fi

    # The source tree may already be prepared, in which case ensure_source_tree
    # returned early without sourcing the shared helpers.
    load_patch_helpers
    resolve_kernel_base

    series_dir="$(kernelsu_source_dir)"

    if ! kernelsu_patches_present; then
        echo "ERROR: BUILD_KERNELSU=true but no KernelSU patch series was found at:" >&2
        echo "  $series_dir" >&2
        echo "Expected one or more *.patch files (for example 0001-...patch)." >&2
        echo "Re-run with BUILD_KERNELSU=false to build without KernelSU." >&2
        exit 1
    fi

    # KernelSU changes are applied to the working tree only and never committed.
    # The EL2 state machine identifies its temporary commit by the exact message
    # "Apply EL2 patches" and reverts it with `git reset --hard HEAD~1`; a
    # KernelSU commit on top would hide that commit from el2_state() and make a
    # later standard build refuse to reset. Applying with `git apply` (rather
    # than `git am`) keeps KernelSU uncommitted, leaves the EL2 commit as the
    # tree's top commit, and lets the reset discard KernelSU cleanly.
    echo "Applying KernelSU patches from $series_dir..."
    while IFS= read -r patch_file; do
        # Idempotent: "both" mode calls this once per variant, and a tree may
        # already carry KernelSU from a previous run.
        if git -C "$KERN_SRC" apply --reverse --check "$patch_file" >/dev/null 2>&1; then
            echo "skip already-applied patch: $patch_file"
            continue
        fi
        if ! git -C "$KERN_SRC" apply "$patch_file"; then
            echo "ERROR: failed to apply KernelSU patch: $patch_file" >&2
            echo "The kernel source tree is likely left in a partially patched state." >&2
            echo "Restore it to a clean standard-patched tree (or set BUILD_KERNELSU=false) and retry." >&2
            exit 1
        fi
    done < <(patch_series_files kernelsu "$series_dir")

    echo "KernelSU integration applied."
}

ensure_source_tree() {
    if [[ -f "$KERN_SRC/arch/arm64/configs/gaokun3_defconfig" ]]; then
        return 0
    fi

    read -r -p "gaokun3_defconfig not found in kernel directory. Pull kernel and apply patches? [y/N] [default: N]: " response
    response="${response:-N}"
    if [[ ! "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
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
        read -r -p "Use Chinese mirror (mirrors.bfsu.edu.cn) for Linux kernel? [Y/n] [default: Y]: " mirror_choice
        mirror_choice="${mirror_choice:-Y}"
        if [[ "$mirror_choice" =~ ^([nN][oO]|[nN])$ ]]; then
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

    cd "$KERN_SRC"
    current_state="$(el2_state)"

    if [[ "$mode" == "el2" ]]; then
        out_dir="$KERN_OUT_EL2"
        dtb_name="sc8280xp-huawei-gaokun3-el2.dtb"

        echo -e "\n=== Preparing Source Tree for EL2 Kernel ==="
        case "$current_state" in
            standard)
                echo "Applying EL2 patches to source tree..."
                git apply --index "$GAOKUN_DIR"/patches/el2/*.patch
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

        # Applied after the EL2 patches so KernelSU lands on top of the EL2
        # changes, while leaving the "Apply EL2 patches" commit as the tree's
        # top commit (see apply_kernelsu for why KernelSU is not committed).
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

        # Applied after the EL2 revert: that reset discards any working-tree
        # KernelSU changes, so a fresh standard config needs KernelSU applied
        # again (see apply_kernelsu for why KernelSU is never committed).
        apply_kernelsu

        mkdir -p "$out_dir"
        make O="$out_dir" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" gaokun3_defconfig
    fi

    echo "Starting build..."
    make O="$out_dir" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" olddefconfig
    make O="$out_dir" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" -j"$(nproc)"
    make O="$out_dir" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" modules_prepare

    local krel
    krel="$(<"$out_dir/include/config/kernel.release")"
    echo "KREL ($mode): $krel"

    read -r -p "Compilation of $mode kernel finished. Install this kernel ($krel)? [Y/n] [default: Y]: " do_install
    do_install="${do_install:-Y}"
    if [[ ! "$do_install" =~ ^([yY][eE][sS]|[yY])$ ]]; then
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
        sudo kernel-install --entry-token=machine-id remove "$krel" >/dev/null 2>&1 || true
        if [[ "$DISTRO" == "fedora" ]]; then
            sudo env KERNEL_INSTALL_CONF_ROOT="$conf_root" \
                kernel-install --verbose --make-entry-directory=yes --entry-token=machine-id add \
                "$krel" "/boot/vmlinuz-$krel"
        else
            sudo env KERNEL_INSTALL_CONF_ROOT="$conf_root" \
                kernel-install --verbose --make-entry-directory=yes --entry-token=machine-id add \
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

ensure_source_tree
configure_git_identity

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
