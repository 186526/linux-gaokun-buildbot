# Waydroid KernelSU 修复记录

本文记录 Gaokun3 Linux 上 Waydroid 使用 KernelSU Manager 时，`libksud.so` 被 seccomp 终止的问题及修复方法。

## 环境

目标机为 `real186@192.168.2.231`，已确认运行环境如下：

```text
Kernel:       7.2.9-gaokun3-el2-xanmod1
Architecture: aarch64
Waydroid:     Android 16 / SDK 36
Manager:      me.weishu.kernelsu v3.3.0
```

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

验证内核仍然包含 KernelSU：

```bash
grep CONFIG_KSU /boot/config-$(uname -r)
grep -E 'ksu_supercall|ksu_seccomp|kernelsu_init' /proc/kallsyms
```

本次修复使用的备份后缀为：

```text
20261007-130449
```

修复后曾出现一次 `waydroid app launch` 返回 `-1`，并且 session 状态变为 `Container: FROZEN`。该现象没有伴随新的 `libksud.so` 或 syscall `142` 日志，属于 Waydroid 图形 session 或应用启动状态问题，与原始 KernelSU seccomp 拦截问题分开处理。

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
