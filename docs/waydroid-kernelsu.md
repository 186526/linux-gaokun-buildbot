# Waydroid KernelSU 修复记录

本文记录 Gaokun3 Linux 上 Waydroid 使用 KernelSU Manager 时，`libksud.so` 被 seccomp 终止的问题及修复方法。

## 环境

目标机为 `real186@192.168.2.231`。以下为最初排查 seccomp 问题时的运行环境快照：

```text
Kernel:       7.2.9-gaokun3-el2-xanmod1
Architecture: aarch64
Waydroid:     Android 16 / SDK 36
Manager:      me.weishu.kernelsu v3.3.0
```

> 快照时间说明：上面的 `Kernel` 行是 2026-10-07 排查时的运行内核。2026-10-08 的只读复核（见“远端只读验证（2026-10-08）”）显示，目标机当前实际运行的是标准内核 `7.2.9-gaokun3-xanmod1` 的旧构建。标准与 EL2 变体共用同一 `gaokun3_defconfig`，因此本节的 KernelSU 配置项与 `/proc/kallsyms` 符号结论对两者同样成立。

当前内核已经内建 KernelSU：

```text
CONFIG_KSU=y
CONFIG_KPROBES=y
CONFIG_HAVE_KPROBES=y
CONFIG_KPROBE_EVENTS=y
```

运行时还能在 `/proc/kallsyms` 中找到以下符号：

```text
kernelsu_init
ksu_supercall_handle_ioctl
ksu_seccomp_allow_cache
```

因此本问题不属于 KernelSU 内核代码未编译或 `.ko` 模块未加载。

## 故障现象

Waydroid 启动 KernelSU Manager 后，内核日志出现：

```text
comm="libksud.so"
sig=31
arch=c00000b7
syscall=142
```

进程路径为：

```text
/data/app/.../me.weishu.kernelsu/.../lib/arm64/libksud.so
```

arm64 的 syscall `142` 是 `reboot`。KernelSU 用户态通过带 KernelSU 魔数的 `reboot()` 请求内核创建 `[ksu_driver]` 文件描述符，然后通过 ioctl 与内核通信。该调用不是要真正重启主机。

## 根因

Waydroid 使用 LXC 容器级 seccomp 配置：

```text
/var/lib/waydroid/lxc/waydroid/config
```

其中指定了：

```text
lxc.seccomp.profile = /var/lib/waydroid/lxc/waydroid/waydroid.seccomp
```

Waydroid 的 seccomp 文件原本包含：

```text
2
blacklist
...
reboot
...
```

该规则在 KernelSU 的内核 kprobe 之前拦截 `reboot()`，导致 `libksud.so` 收到 `SIGSYS`，KernelSU 无法取得驱动 fd。

需要同时区分两层过滤：

- Waydroid LXC seccomp 作用于整个容器，原始故障由这一层造成。
- Android 应用自身的 seccomp 过滤器由 Android 进程安装，KernelSU 内核代码包含对应的 seccomp allow-cache 支持。

仅将 KernelSU Manager 改为特权应用不能绕过 LXC 容器级 seccomp。

## 修复步骤

修改前应备份模板文件和当前容器文件：

```bash
stamp=$(date +%Y%m%d-%H%M%S)

sudo cp -a \
  /usr/lib/waydroid/data/configs/waydroid.seccomp \
  "/usr/lib/waydroid/data/configs/waydroid.seccomp.bak-$stamp"

sudo cp -a \
  /var/lib/waydroid/lxc/waydroid/waydroid.seccomp \
  "/var/lib/waydroid/lxc/waydroid/waydroid.seccomp.bak-$stamp"
```

只删除单独的 `reboot` 行：

```bash
sudo sed -i '/^reboot$/d' \
  /usr/lib/waydroid/data/configs/waydroid.seccomp

sudo sed -i '/^reboot$/d' \
  /var/lib/waydroid/lxc/waydroid/waydroid.seccomp
```

确认两份文件都不再包含该规则：

```bash
grep -n '^reboot$' \
  /usr/lib/waydroid/data/configs/waydroid.seccomp \
  /var/lib/waydroid/lxc/waydroid/waydroid.seccomp
```

命令无输出即表示修改完成。

重新创建容器进程，使新的 seccomp 配置生效：

```bash
sudo systemctl restart waydroid-container.service
sudo waydroid container stop || true
sudo waydroid container start
```

启动 Waydroid session 后再启动 KernelSU Manager：

```bash
waydroid session start
waydroid app launch me.weishu.kernelsu
```

## 验证结果

修复后重新启动 Waydroid session，内核日志不再出现新的：

```text
comm="libksud.so"
sig=31
syscall=142
```

这证明原先的 LXC seccomp 拦截路径已不再产生同样的 `SIGSYS`。它不能单独证明 KernelSU Manager 已经取得 `[ksu_driver]` 文件描述符或已经成功提供 root；完整验收还需要确认 Manager 状态、`ksud` 进程和实际 `su` 请求。

KernelSU Manager v3.3.0 发布早于 KernelSU 官方 SIGSYS 降级修复。更换包含该修复的 Manager 只能避免 `libksud.so` 因 SIGSYS 直接终止，不能替代放行 LXC `reboot` 规则，也不能单独恢复 root。

## Waydroid Manager 未识别的限制

本次目标机还确认了第二个独立问题。原运行内核的配置为：

```text
CONFIG_KSU=y
# CONFIG_KSU_DEBUG is not set
```

Manager 启动后能够加载 `libksud.so`，但内核日志仍出现：

```text
KernelSU: ksu ioctl: permission denied for cmd=0x4b01 uid=10147
```

`0x4b01` 是 `GRANT_ROOT`。这表示 `me.weishu.kernelsu` 的 appid `10147` 尚未成为 KernelSU manager，不能执行 root 操作。原运行内核没有 `ksu_debug_manager_appid` 参数，因此不能通过运行时文件权限或重装 APK 修复这个状态。

本仓库的 `scripts/ci/lib/kernelsu.sh` 和 `scripts/local/build_kernel.sh` 已经同时启用并检查：

```text
CONFIG_KSU_DEBUG=y
```

本次本地最终构建使用以下内核版本：

```text
standard: 7.2.9-gaokun3-xanmod1
EL2:      7.2.9-gaokun3-el2-ksu-dsi-fix-xanmod1
```

最终 EL2 构建已包含并编译验证以下修复链：

- XanMod `0018-drm-msm-dsi-fix-PLL-init-in-bonded-mode.patch`；
- media Venus 的 SC8280XP resource 使用修复；
- HI846、DSC interface data width 和面板方向修复；
- EL2 remoteproc `0006`、`0009`、`0010`、`0016`，以及补齐 `qcom_q6v5_read_smp2p_state()` 的 Qualcomm detached-state 前置补丁；
- `CONFIG_KSU=y`、`CONFIG_KSU_DEBUG=y`、`CONFIG_KPROBES=y`、`CONFIG_TRACEPOINTS=y`、`CONFIG_FTRACE=y`。

DEB 已在本地生成，manifest 标记为 `build_el2=true` 和 `build_kernelsu=true`。为与目标机已有同名包隔离，本次构建把 EL2 的 `LOCALVERSION` 覆盖为独立后缀，得到 release `7.2.9-gaokun3-el2-ksu-waydroidtest-xanmod1`；`scripts/ci/20_build_kernel_variants.sh` 因此新增 `KERN_LOCALVERSION_EL2` 变量，默认值保持 `-gaokun3-el2`。

该隔离 EL2 内核已安装并启动，实测结果：

- 内核配置含 `CONFIG_KSU_DEBUG=y`；`/sys/module/kernelsu/parameters/ksu_debug_manager_appid` 存在。
- 用 `lxc-attach -u <manager-appid>` 以管理器自身 UID 运行 `libksud.so debug info`，返回 `flags: 0x2`（`MANAGER` 位），说明内核已承认调用方为管理器。
- 以同一 UID 运行 `libksud.so debug su`（无参数，交互式），通过标准输入执行 `id`，输出 `uid=0(root) gid=0(root)`，内核日志同时出现 `KernelSU: allow root for: <manager-appid>`。

`debug su` 必须由管理器 UID 调用。内核 `is_manager()` 判断的是 `uid % 100000 == manager_appid`，因此以 uid 0 直接调用会被拒绝，这是 KernelSU 的正常判定，不代表失败。

管理器的图形界面在本次 Waydroid 中仍无法通过 `am start` 拉起：`Activity` 无法解析，包状态为 `stopped=true`、`notLaunched=true`，解析表内组件存在但查询无结果。该现象属于 Waydroid 侧的应用安装/包扫描状态问题，与内核 KernelSU 的识别和 root 授权是两件事，故本次以 CLI 证据作为内核能力验收。

管理器 UID 会随 APK 重装变化。使用容器命令读取，目标机的 Waydroid Python CLI 会把部分 Android 短参数错误解析为自身参数，因此使用 `lxc-attach`：

```bash
sudo lxc-attach -P /var/lib/waydroid/lxc -n waydroid -- \
  /system/bin/sh -c 'grep me.weishu.kernelsu /data/system/packages.list'
sudo cat /sys/module/kernelsu/parameters/ksu_debug_manager_appid
```

将包列表中的 appid 写入参数并重启 Manager：

```bash
sudo sh -c 'printf 10147 > /sys/module/kernelsu/parameters/ksu_debug_manager_appid'
sudo lxc-attach -P /var/lib/waydroid/lxc -n waydroid -- \
  /system/bin/am force-stop me.weishu.kernelsu
waydroid app launch me.weishu.kernelsu
```

以管理器 UID 运行 CLI，验证内核识别与实际 root：

```bash
sudo lxc-attach -P /var/lib/waydroid/lxc -n waydroid -u "$appid" -- \
  /system/bin/sh -c "$libksud debug info"
sudo lxc-attach -P /var/lib/waydroid/lxc -n waydroid -u "$appid" -- \
  /system/bin/sh -c "echo id | $libksud debug su"
```

其中 `$appid` 来自 `packages.list`，`$libksud` 是容器内 `me.weishu.kernelsu` 的 `lib/arm64/libksud.so` 绝对路径。验收标准是 `debug info` 的 `flags` 含 `0x2`，且 `debug su` 输出 `uid=0(root)`。只把 `am force-stop` 与 `waydroid app launch` 作为尝试重建管理器进程的手段；若 `Activity` 无法解析，改用上面的 CLI 直接验证内核能力，不要据此判定 KernelSU 失败。

验证内核仍然包含 KernelSU：

```bash
zcat /proc/config.gz | grep CONFIG_KSU      # 运行内核内嵌配置
grep -E 'ksu_supercall|ksu_seccomp|kernelsu_init' /proc/kallsyms
```

`/proc/config.gz` 反映的是运行内核自身的配置；若只需确认磁盘上安装的配置，也可用 `grep CONFIG_KSU /boot/config-$(uname -r)`，但 `/boot/config-*` 可能已被更新的构建覆盖，不代表当前运行内核。

本次修复使用的备份后缀为：

```text
20261007-130449
```

修复后曾出现一次 `waydroid app launch` 返回 `-1`，并且 session 状态变为 `Container: FROZEN`。该现象没有伴随新的 `libksud.so` 或 syscall `142` 日志，属于 Waydroid 图形 session 或应用启动状态问题，与原始 KernelSU seccomp 拦截问题分开处理。

## 标准内核编译了 KernelSU 却不可用

目标机保留的标准内核 `7.2.9-gaokun3-xanmod1` 确实编入了 KernelSU，但不可用，原因是构建时间早于开启调试配置的提交：

```text
CONFIG_KSU=y
CONFIG_KPROBES=y
CONFIG_TRACEPOINTS=y
# CONFIG_KSU_DEBUG is not set
```

- 该包内 `config` 文件时间为 `2026-10-07 04:03`，而本仓库给 `scripts/ci/lib/kernelsu.sh` 打开 `CONFIG_KSU_DEBUG=y` 的提交 `1aa0b47` 时间为 `2026-10-07 14:51`。因此该内核是用“只开 `KSU`+`KPROBES`+`FTRACE`、未开 `KSU_DEBUG`”的旧配置构建的。
- 没有 `CONFIG_KSU_DEBUG` 时，`/sys/module/kernelsu/parameters/` 不存在，无法设置 `ksu_debug_manager_appid`；同时 `allow_shell` 编译期为 false，`on_post_fs_data` 触发的管理器自动加冕在这台机上从未出现（启动日志无 `Searching manager`、`Crowning manager`、`Found new base.apk`）。任何 `GRANT_ROOT`（`0x4b01`）都会返回 `permission denied`，管理器因此显示未安装，容器内也没有 `su`。

结论：这是构建配置问题，不是内核代码缺陷。用当前仓库脚本以 `BUILD_KERNELSU=true` 重新构建标准内核即可带上 `CONFIG_KSU_DEBUG=y`，再写入 `ksu_debug_manager_appid` 即可让标准内核同样识别并使用管理器。当前 `scripts/ci/lib/kernelsu.sh` 的 `configure_kernel_su` 已经会启用并断言 `CONFIG_KSU_DEBUG=y`。

需要澄清：`CONFIG_KSU_DEBUG` 只恢复了“手动”路径。自动加冕（`on_post_fs_data` 触发的管理器发现与 `execve` 钩子）的根因是缺少 `CONFIG_KALLSYMS_ALL`，见下一节。

## 自动加冕失效的根因：缺少 CONFIG_KALLSYMS_ALL

上一节记录的 `CONFIG_KSU_DEBUG=y` 重构建只解决手动路径。它没有恢复“自动加冕”——`on_post_fs_data` 触发的管理器发现与 `execve` 钩子在这台标准内核上从未运行。根因是内核配置缺少 `CONFIG_KALLSYMS_ALL`。

### 关键证据

当时运行的标准内核 `7.2.9-gaokun3-xanmod1` 内嵌配置（`/proc/config.gz`，即运行内核自身携带的配置）只有 `CONFIG_KALLSYMS=y`，没有 `CONFIG_KALLSYMS_ALL`：

```text
CONFIG_KALLSYMS=y
# CONFIG_KALLSYMS_ALL is not set
```

需要区分两处配置来源：运行内核的配置是 `/proc/config.gz`；磁盘上的 `/boot/config-*` 会在重新构建安装后被覆盖，因此 `/boot/config-*` 不能代表运行内核。2026-10-08 的复核中 `/boot/config-7.2.9-gaokun3-xanmod1` 已含 `CONFIG_KALLSYMS_ALL=y`，而运行内核内嵌的 `/proc/config.gz` 仍为 `# CONFIG_KALLSYMS_ALL is not set`，两者不一致正说明运行内核是旧构建，详见“远端只读验证（2026-10-08）”。

因此 `/proc/kallsyms` 中检索不到数据段符号，`sys_call_table` 和 `jiffies` 均出现 0 次：

```text
sys_call_table   0
jiffies          0
```

启动日志显示 KernelSU 尝试解析 syscall 表但失败：

```text
KernelSU: sys_call_table=0x0
KernelSU: (syscall hook 注册)
```

并且缺少以下自动加冕链路日志：

```text
dispatcher installed at slot ...
exec zygote, /data prepared, ...
on_post_fs_data!
Searching manager...
Crowning manager: ...
Found new base.apk at path: ..., is_manager: ...
```

### 机制

`CONFIG_KALLSYMS_ALL` 决定链接期 `scripts/link-vmlinux.sh` 是否给 `scripts/kallsyms` 传入 `--all-symbols`：

```sh
if is_enabled CONFIG_KALLSYMS_ALL; then
    kallsymopt="${kallsymopt} --all-symbols"
fi
```

不带 `--all-symbols` 时，`scripts/kallsyms.c` 的 `symbol_valid()` 会丢弃所有不在 `.text`/`.init.text` 范围内的符号，只保留函数符号。`sys_call_table`（`arch/arm64/kernel/sys.c` 中数据段的函数指针数组）与 `jiffies`（`include/linux/jiffies.h` 声明的数据段变量）都不在 text 范围，因此不进入 `kallsyms`，`kallsyms_lookup_name()` 也查不到。

KernelSU v3.3.0（pin `932014ab`）依赖这些符号：

- `kernel/infra/symbol_resolver.c` 用 `kallsyms_lookup_name()` / `kallsyms_on_each_match_symbol()` 解析符号；
- `kernel/hook/arm64/syscall_hook.c` 的 `ksu_syscall_hook_init()` 解析 `sys_call_table`，失败时打印 `sys_call_table=0x0` 并直接 `return`，于是不会调用 `ksu_syscall_table_hook()`，也就没有 `dispatcher installed at slot`；
- `dispatcher` 与 `execve` 钩子（`kernel/hook/syscall_event_bridge.c`）都注册在这个 syscall 表槽位上；
- 没有 `execve` 钩子，就不会在 zygote 启动时命中 `kernel/runtime/ksud_integration.c` 的 `exec zygote` 分支，也就不会调用 `on_post_fs_data()`；
- `on_post_fs_data()`（`kernel/runtime/boot_event.c`）才是 `ksu_observer_init()` 与 `ksu_throne_tracker_init()` 的触发点，缺它就没有 `Searching manager` / `Crowning manager` / `Found new base.apk`。

这是一条从“符号不可见”到“自动加冕不发生”的完整因果链：缺少 `CONFIG_KALLSYMS_ALL` 导致 `sys_call_table` 解析失败，`execve` 钩子未安装，`on_post_fs_data` 不触发，管理器永远不会被自动加冕。

### 修复

在权威配置来源中启用以下三项：

```text
CONFIG_KALLSYMS=y
# CONFIG_KALLSYMS_SELFTEST is not set
CONFIG_KALLSYMS_ALL=y
```

`KALLSYMS_ALL` 依赖 `DEBUG_KERNEL && KALLSYMS`；本 defconfig 已有 `CONFIG_DEBUG_KERNEL=y`，因此需将 `KALLSYMS` 与 `KALLSYMS_ALL` 一并写入，并放在内核生成的规范顺序中（`CONFIG_SYSFS_SYSCALL=y` 之后、`CONFIG_PROFILING=y` 之前）。`CONFIG_KALLSYMS_SELFTEST` 显式关闭，保持与内核 `olddefconfig` 输出一致。

需要同步的三处：

- `patches/xanmod/0099-arm64-gaokun3-import-local-dts-and-defconfig.patch`（XanMod 构建实际使用，同名 override 优先）；
- `patches/0099-arm64-gaokun3-import-local-dts-and-defconfig.patch`（mainline 一致性）；
- `defconfig/gaokun3_defconfig`（镜像文件，与 patch 内容保持字节一致）。

标准与 EL2 变体共用同一 `gaokun3_defconfig`，因此该修复对两者同时生效。

### CONFIG_KSU_DEBUG 的定位

`CONFIG_KSU_DEBUG` 只是调试兜底，不是交付前提：

- 它在 `kernel/manager/apk_sign.c` 下暴露 `ksu_debug_manager_appid` 参数，并让 `allow_shell`（`kernel/core/init.c`）默认为 true；
- 写入 appid 后，`GRANT_ROOT`（`0x4b01`）的手动路径可用；
- 它不修复 `sys_call_table` 解析，因此不会恢复自动加冕。

把 `CONFIG_KSU_DEBUG=y` 当作根因修复会掩盖真正的符号可见性问题。根因修复是启用 `CONFIG_KALLSYMS_ALL=y`；`CONFIG_KSU_DEBUG=y` 仅在需要手动指定管理器 appid 时作为调试手段保留。

本节的“关键证据”来自标准内核 `7.2.9-gaokun3-xanmod1` 运行时的内嵌配置 `/proc/config.gz`、`/proc/kallsyms` 与启动日志，以及 KernelSU pin 版源码。截至本次只读验证，带 `CONFIG_KALLSYMS_ALL=y` 的修复内核已在目标机上构建并曾短暂启动一次，实测 `sys_call_table` 解析成功且 dispatcher 安装成功，但该次启动未运行 Waydroid，自动加冕尚未实测；详见下一节“远端只读验证（2026-10-08）”。

## 远端只读验证（2026-10-08）

本次在目标机 `real186@192.168.2.231` 上以只读方式核对 KernelSU/Waydroid 状态，未切换内核、未重启、未修改远端任何文件。所有结论均来自 `uname`、`/proc/config.gz`、`/proc/kallsyms`、`journalctl`、`/boot` 与 Waydroid 配置文件。

### 运行内核仍是旧构建

`uname -r` 为 `7.2.9-gaokun3-xanmod1`，但 `/proc/version` 显示构建者为 `real186@net186-laptop2.sunoaki.net`、时间为 `Wed Oct 7 04:00:42 CST 2026`。该时间早于打开 `CONFIG_KALLSYMS_ALL` 的修复提交，因此当前运行内核仍缺少该配置。运行内核内嵌配置（`/proc/config.gz`）为：

```text
CONFIG_KALLSYMS=y
# CONFIG_KALLSYMS_ALL is not set
CONFIG_KSU=y
# CONFIG_KSU_DEBUG is not set
```

启动日志与配置一致，syscall 表仍未解析：

```text
KernelSU: sys_call_table=0x0
```

本次启动日志中没有 `dispatcher installed at slot`、没有 `on_post_fs_data!`、没有 `Searching manager` / `Crowning manager` / `Found new base.apk`。`/sys/module/kernelsu/parameters/` 不存在，无法读取或写入 `ksu_debug_manager_appid`。`/proc/kallsyms` 中 `sys_call_table` 与 `jiffies` 命中数均为 0（数据段符号不可见），`kernelsu_init`、`ksu_supercall_*`、`ksu_seccomp_*` 等 text 符号存在。

结论：**当前运行内核上自动加冕与手动指定 appid 两条路径都不可用，KernelSU Manager 仍不会被识别。** 这与本文前面记录的根因结论一致，未出现新的失败模式。

### 磁盘上的新内核已包含修复

`/boot/config-7.2.9-gaokun3-xanmod1` 与 `/boot/config-7.2.9-gaokun3-el2-xanmod1`（均为 2026-10-08 07:55/07:59 生成）已包含：

```text
CONFIG_KALLSYMS_ALL=y
CONFIG_KSU=y
CONFIG_KSU_DEBUG=y
```

即 `CONFIG_KALLSYMS_ALL=y` 修复已进入构建产物，只是尚未成为运行内核。运行内核来自 `/boot/efi/loader/entries/8077114821394d74b1f4278d58fb1e5c-7.2.9-gaokun3-xanmod1.conf`（`loader.conf` 的 `default`），其 EFI 内核构建于 2026-10-07 04:00；磁盘上另有 2026-10-08 生成的 `debian-7.2.9-gaokun3-*.conf` 指向 CI 构建的新内核，尚未被默认选中。

### 修复内核曾被短暂启动，自动加冕尚未实测

journal 的 boot `-2`（2026-10-08 09:56:36）使用 CI 构建的内核（`/proc/version` 构建者 `runner@runnervmy3dvn`，Ubuntu gcc 13.3.0）。该次启动的 KernelSU 日志显示符号解析与 dispatcher 安装成功：

```text
KernelSU: sys_call_table=0xffffb27c0e8f0d00
KernelSU: patch syscall 18, 0xffffb27c0dad1fb8 -> 0xffffb27c0e680330
KernelSU: dispatcher installed at slot 18
```

这实测打通了本文预测的因果链第一环：`CONFIG_KALLSYMS_ALL=y` 使 `sys_call_table` 解析成功，syscall 表槽位 hook（dispatcher）已安装。

但该次启动仅持续约两分钟（墙钟 09:56:36–09:58:39；末条日志单调时间戳约 128 秒），期间 Waydroid 容器处于 `STOPPED`，没有 zygote/`on_post_fs_data` 触发，因此日志中没有 `on_post_fs_data!` / `Searching manager` / `Crowning manager`。**“自动加冕是否恢复”在修复内核上尚未实测。**

### Waydroid 侧状态

- `waydroid status`：`Session: STOPPED`，`Vendor type: MAINLINE`；`waydroid-container.service` 为 `active`，但容器 `lxc-info` 为 `STOPPED`。
- 两份 seccomp 文件（`/var/lib/waydroid/lxc/waydroid/waydroid.seccomp` 与 `/usr/lib/waydroid/data/configs/waydroid.seccomp`，均为 339 字节、时间 2026-10-07 13:04）已不含单独的 `reboot` 行，说明本文记录的 LXC seccomp 修复仍在生效。
- 容器未运行，无法读取 `/data/system/packages.list`，因此本次无法读取 Manager appid，也无法用 `libksud debug info` / `debug su` 复核 `flags` 与 root。

### 结论与未决阻塞

- **已证据支撑**：修复内核（CI 构建）能让 `sys_call_table` 解析并安装 dispatcher；seccomp `reboot` 修复仍在生效；磁盘上标准与 EL2 内核均已带 `CONFIG_KALLSYMS_ALL=y` 与 `CONFIG_KSU_DEBUG=y`。
- **仍阻塞**：运行内核是旧构建，尚未切到修复内核；修复内核上一次启动未运行 Waydroid，自动加冕链路（`on_post_fs_data` → `Crowning manager`）与 Manager 识别尚未实测。
- **下一步（需操作者执行，非本次只读范围）**：切到修复内核并保持 Waydroid 会话运行，再复核 `dispatcher installed at slot`、`on_post_fs_data!`、`Crowning manager`、`ksu_debug_manager_appid` 与 `libksud debug info/su`。

## 回滚

使用实际备份后缀恢复两份文件：

```bash
stamp=20261007-130449

sudo cp -a \
  "/usr/lib/waydroid/data/configs/waydroid.seccomp.bak-$stamp" \
  /usr/lib/waydroid/data/configs/waydroid.seccomp

sudo cp -a \
  "/var/lib/waydroid/lxc/waydroid/waydroid.seccomp.bak-$stamp" \
  /var/lib/waydroid/lxc/waydroid/waydroid.seccomp

sudo systemctl restart waydroid-container.service
```

不要删除整个 seccomp 文件，也不要修改 Android 镜像中的 `/system/etc/seccomp_policy`。本次故障来自宿主机 LXC 配置中的单独 `reboot` 黑名单项。

## 参考资料

- [KernelSU `ksucalls.rs`](https://github.com/tiann/KernelSU/blob/main/userspace/ksud/src/ksucalls.rs)：用户态使用 `SYS_reboot` 获取 KernelSU 驱动 fd。
- [KernelSU `supercall.c`](https://github.com/tiann/KernelSU/blob/main/kernel/supercall/supercall.c)：内核侧处理 supercall。
- [KernelSU `setuid_hook.c`](https://github.com/tiann/KernelSU/blob/main/kernel/hook/setuid_hook.c)：Android seccomp allow-cache 处理。
- [Waydroid `waydroid.seccomp`](https://github.com/waydroid/waydroid/blob/main/data/configs/waydroid.seccomp)：Waydroid 默认 LXC seccomp 配置。
- [AOSP 原生崩溃诊断](https://source.android.com/docs/core/tests/debug/native-crash)：`SIGSYS` 和 seccomp 拦截的判定方法。
