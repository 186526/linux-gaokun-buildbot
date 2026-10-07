# 内核重启审计（更新于 2026-09-21）

目标是维护可解释的下游 Git 提交，不恢复 buildbot 中的补丁、驱动或 DTS 副本。`gaokun3-next` 是当前 Iris/GSI 审查分支；`gaokun3` 保留上一版候选，两个分支都未通过实机验收。构建使用精确 SHA。

2026-09-21：用户报告开机约 1–2 秒后花屏，实际故障内核来源和日志待确认。已针对当前候选核对上游 DSI/PLL 变更及 right 补丁，见[开机花屏排查](display-debug.md)。构建通过不能视为显示已验收。

## 固定审计输入

- stable 基线：`d396b05e7e39b0ed6f6d5553fbaf174228e18bdf`（v7.2.6）。
- 上一版候选：`716c79802092955347a41975b8f6e14020321478`。
- right-0903 main：`7463df37160bdecc3f2609d72f9a69cfa2b390e4`。
- right-0903 ts/caidj0：`5c868c89d36992bf98e48e3c37f525716b6c74d1`（2026-03-31）。
- vahiru/gaokun-android：`823585fee8f2b820cdafd0fdc24a6bcd864e0dd8`。已按原作者导入 0038、0040，保留现有驱动结构和默认参数。

## 当前决定与证据

| 对象 | 处理 | 依据 / 剩余工作 |
| --- | --- | --- |
| 原 6 个 Venus 提交及板级启用提交 | 从 next 提交栈去除 | 改用 stable 已有 Iris 驱动和上游 SC8280XP DTS backport |
| Iris 节点 `3a52eef16b979617156fa6e2ead24ca4d1336f0b` | 已移植 | 保留作者和原始提交标识；仅解决 stable 多出的 SCM include 上下文差异 |
| 内存排序 `53275adfb07d416a32004612227265939d0df00d` | 不重复移植 | 基线 GPU reserved-memory 已在 CDSP0 之后；反向应用检查通过。原规划“需两个 backport”不适用于此基线 |
| X13s Iris 启用提交 | 不移植 | Gaokun3 使用自己的板级节点和 Huawei 固件路径 |
| Iris 驱动匹配 | 已核对 | DTS 同时声明 `qcom,sc8280xp-iris`、`qcom,sm8250-venus`；stable Iris 通过后者匹配 `sm8250_data`。不需要凭空新增平台驱动 |
| force-GSI `fb123793bfdc5a58f94aaf54ae06b47c9c797b7e` | 已移植 | 修复 DTS 已声明但 SPI 驱动未读取属性的问题；来自 right 当前 recommended |
| 旧 PDC mapping 补丁 | 不恢复 | 基线已有所需映射；触摸 IRQ 的独立 workaround 仍保留 |
| right recommended 0005、0012、0014、0015、0018、0019、0020、0022、0023 | 已覆盖 | 在 next 上逐个反向应用检查通过；不重复导入 |
| right recommended 0016、0021 | 已导入同一补丁 | 导入提交的 stable patch-id 与 right 当前补丁一致；后续上下文变化导致反向检查失败，不需重复导入 |
| right recommended 0002 | 语义已覆盖 | 归一化 `0x0` / `0` 后 patch-id 一致；audio PD 内存与 VMID 改动相同 |
| right recommended 0010 | 保留现有 DSC 替代实现 | 两种宽度计算并不等价，见下一项 |
| DSC width | 暂保留现有实现 | 当前由 `dce_bytes_per_line` 推导，right 0010 使用整数 bpp。不是同一实现，不能仅因来源更新而覆盖 |
| DSC 默认启用、backlight regulator | 保留并待实机评估 | 基线 DSC 默认 false；基线供电列表无 bl，而板级 DTS 使用 GPIO0 的 bl-supply。不能按“panel 已上游”直接删除这两个行为差异 |
| EC / UCSI | 主线实现为本体 | EC DTS 保留 GPIO 103 / PDC 215；旧 UCSI、q6apm 删除项仍需语义审查 |
| HI846 4 个提交及 camera DTS | 待拆到可选功能 | 当前仍在候选中；尚未完成最小普通内核的拆分 |
| EL2 | 独立推进、默认关闭 | 没有已验证的 EL2 SHA，不能发布为普通内核功能 |
| 旧 touchscreen tuner | 待算法选择后决定 | 不能在旧算法仍在使用时直接删除对应工具 |

## 触摸屏：已吸收两项独立修复，整体替换仍待评估

right main 的传输/生命周期改动包括 `0bbd872`（burst 模式）、`accd3ec`（启停顺序）以及 4 月的坐标缩放和固件处理。`ts/caidj0` 停在 3 月，包含多点追踪、panel follower 串行化和重新加载逻辑，不能当成包含 main 后续修复的整份最新版。

已从 vahiru 固定版本中吸收两项改动，保留 Vahiru 作者，简化注释并明确本项目默认值：

- `c78899cdd8bd`：SPI 读取的 TX/RX 共用缓冲区，每次重试前重建命令；为读头预留 3 字节，使 5132 字节事件栈一次读取完成。
- `4b44e0cdac8d`：跳点检测使用预测位置偏差，避免连续快滑反复重建触点。本项目的 `track_jump_dist2` 仍默认关闭，并非原 fork 的 6400 预设。
- `302b44468fcc`：修正两个已有 kernel-doc 注释，使 Himax 对象 `W=1` 构建无警告。

软件回归使用实际 C 函数：模拟 RX 覆写共享缓冲区后失败，原版后续重试均失败，修复后可在一次/两次失败后恢复，连续三次失败仍返回 EIO；别名输出缓冲区也通过。完整事件栈从两次传输变为一次。追踪测试用 120 帧、80/81 单位每帧，分别开关平滑：修复后均在两帧 debounce 后报告 118 帧；真正横向跳点仍释放旧 slot。默认关闭跳点检测时结果不变。测试没有验证 SPI 硬件或触摸手感。

没有导入 Android 专用调参、调试接口或 zone 淘汰策略；后者可能在掌触区域占满列表时挤掉手指，需要单独验证。

后续独立审查 main 传输层与 caidj0 tracking 的差异。迁移时必须一起检查 DTS 坐标范围（现有 2560×1600，right 为 25600×16000）、坐标变换、GPIO174 的模式选择、reset/panel follower 顺序、IRQ 和固件版本。编译通过不能代替多指、快速滑动、掌触和休眠恢复实测。

## 验证边界

上一版 `716c798` 已通过完整内核编译及 DEB/RPM 打包（[Actions 35481647905](https://github.com/gaokun3/buildbot/actions/runs/35481647905)）；该结果验证双仓库构建流程，不能替代新 Iris 候选验证。

Iris/GSI 候选 `3a9f5e6c` 已通过完整内核与 DEB/RPM 打包，见 [Actions 35495246617](https://github.com/gaokun3/buildbot/actions/runs/35495246617)，触摸修复后的 `4a73e255` 也已通过 [完整内核与 DEB/RPM 构建](https://github.com/gaokun3/buildbot/actions/runs/35495880873)。

Iris/GSI 候选已通过 defconfig、Gaokun3 DTB、Iris 全目录对象及 `qcom-iris.o` 链接、SPI GENI 对象交叉编译。反编译 DTB 已确认 Iris compatible、Huawei firmware-name 和启用状态。设备探测、硬件解码或编码尚未实测。

正式替换 gaokun3 前，审查 `git range-diff`，完成完整构建和实机测试；发布后使用不可变 tag，并记录上游 base SHA。CI 不自动 rebase 或 force-push。

## 发行版策略

共享 defconfig 同时编入 SELinux 和 AppArmor，但 `CONFIG_LSM` 默认只有 AppArmor。新建 Fedora/Ubuntu 镜像在内核命令行中显式使用 `lsm=` 选择对应策略。Fedora 显式安装 targeted policy 和 policycoreutils，并在镜像组装末尾用 setfiles 为新建文件打标签；该步骤已通过完整 Fedora 镜像 CI，启动后的策略加载仍需实机确认。已有系统升级沿用用户的命令行，不能据此认为旧镜像已修复；实机验收应检查 `/sys/kernel/security/lsm`，Fedora 还需确认策略加载与文件标签。

## EC 探测错误返回

新增 `1ab894b42dea`：获取 enable GPIO 返回错误时立即返回 `dev_err_probe()`，避免吞掉 `-EPROBE_DEFER` 后继续注册设备。此问题来自导入的 EC enable pin 补丁。实际 probe 前段的主机故障注入已确认原版吞掉 `-EPROBE_DEFER` / `-EIO`，修复后正确返回；可选 GPIO 不存在时仍继续。EC 对象 `W=1` 构建和 checkpatch 均无警告，新 SHA 已通过 [完整内核与 DEB/RPM CI](https://github.com/gaokun3/buildbot/actions/runs/35512150744)。

Fedora 镜像流程先使用已通过打包的 `4a73e255` 做集成验证（[Actions 35511937857](https://github.com/gaokun3/buildbot/actions/runs/35511937857)）；这次镜像尚不包含上述 EC 修复。

最终 `1ab894b42` 已通过 [Fedora 44 镜像构建](https://github.com/gaokun3/buildbot/actions/runs/35512617654)，包含上述 EC 修复，产物保存在 Actions artifacts 中。软件构建验证完成，实机测试仍按 [验收清单](hardware-checklist.md) 进行。
