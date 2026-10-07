# 开机花屏排查（更新于 2026-09-22）

实机反馈：用户报告 PLL 测试版本看起来已解决花屏，TTY 可切换；仍有服务启动及 nmtui 问题，转入 rootfs 排查。这不是全部显示功能、休眠或其他机型的验收结论。

用户报告开机约 1–2 秒后花屏，横屏看是下半屏；禁用触摸和关闭 DSC 两项测试均无效，回忆 7.2.3 正常。以下检查针对候选内核 `1ab894b42deae74cc72cc89f2cb436534260faed`、stable 基线 `d396b05e7e39b0ed6f6d5553fbaf174228e18bdf`。尚未收到故障机日志、实际内核 SHA 或最后正常内核的构建来源，不能确认根因。此前 CI 成功只代表构建成功，该候选不能视为显示已验收。

## 7.2.3 到 7.2.6：已找到匹配的回归候选

通过 gregkh/linux 精确 tag 的文件 blob SHA 核对：7.2.3、7.2.4、7.2.5 的 `dsi_phy.h` 均为 `21a59d66e8dc5568cbb66eca4fea787228360d74`，`dsi_phy_7nm.c` 均为 `984a66085dfbf86c99292a9a26685bc7db02a5c8`。7.2.6 分别变成 `f5d3e806f8fd5146601e2a46fd38992c0ff1e21b` 和 `5d805a797abdb1e0930e79d978a1e4c4ebb94058`。

该变化来自 stable 回移植 [5de981b7db1f](https://github.com/gregkh/linux/commit/5de981b7db1f509dfafe8e205b4d342436306e87)，对应下表中的上游 revert。主线撤回发生在 7 月，但进入此 stable 分支是在 7.2.6；不能用主线提交日期推断 7.2.3 已包含它。

Gaokun3 的原生竖屏由双 DSI 分区驱动，旋转后其中一部分可能表现为上下半屏。固定半屏故障与单链路异常相符，但没有日志或寄存器证据，不能确定是哪一个控制器。

独立测试分支 `test/gaokun3-pll-7.2.6` 仅在 `1ab894b42` 上重用 Neil Armstrong 的原上游 `93c97bc8d85d`。两个文件的 blob SHA 恢复为上述 7.2.3–7.2.5 的值，未引入新的驱动逻辑。原补丁作者和签署记录保留，提交附加本次排查依据；没有新增代签。

本地验证：`dsi_phy_7nm.o` AArch64 `W=1` 编译通过，无警告；checkpatch 为 0 errors / 0 warnings；文件内容与旧 stable 的 blob SHA 一致。尚未实机复现或确认修复。完整 RPM/镜像验证由独立测试分支构建，正式候选 `gaokun3-next` / buildbot `next` 不因该试验自动更新。

测试此镜像时恢复原始启动参数，去掉上轮临时禁用触摸、关闭 DSC 的参数，以便只对比 PLL 补丁。原补丁有已知单 DSI 回归，因此此分支只用于 Gaokun3 A/B 测试，不推广到其他机型。

## 已核对的上游和第三方改动

| 改动 | 当前源码状态 | 排查意义 |
| --- | --- | --- |
| [93c97bc8d85d：修复 bonded DSI PLL 初始化](https://github.com/torvalds/linux/commit/93c97bc8d85d5742d6f000d8bf3eeeb705bc6082) | 修复效果已被后续 revert 撤销 | Gaokun3 的 DSI1 使用 DSI0 的 PLL，属于该提交讨论的双链路拓扑，是回归候选，尚非根因结论 |
| [44784327815b：撤回上述修复](https://github.com/torvalds/linux/commit/44784327815b2a1ad8bb56b9236770cb538c7c27) | 当前 PHY 源码与撤回后的逻辑一致 | 上游因单 DSI 时钟分频回归撤回；不能将被撤回的补丁当成无风险的通用修复。若实机证据指向此处，单独恢复原补丁做 A/B 测试 |
| [6cd33b6f4155：字节时钟取整](https://github.com/torvalds/linux/commit/6cd33b6f4155efc20485929fd0b56bb704641db9) | 已有 | 避免运行中 DCS 命令反复触发 PLL 重锁，不重复导入 |
| [2028280686f4：在 PLL 重新选父时钟后取整](https://github.com/torvalds/linux/commit/2028280686f4fa78e2f1f6dede4b6c1fd782b9e3) | 缺少；原始代码差异通过 apply --check | 同时从取整后的字节时钟派生接口时钟。上游报告主要涉及 DSI 6G v2.9，不能仅凭该报告认定修复 Gaokun3；可作为独立 backport 候选 |
| [06b7ba206561：删除 dev_pm_opp_set_rate(0)](https://github.com/torvalds/linux/commit/06b7ba206561619bb34116f49e0ef26b867ce3aa) | 已有；disable 路径没有该调用 | 不是当前缺失补丁 |
| right recommended 0014：视频期间避免链路时钟切换 | 已有 `a94e1788b` | 已覆盖 [right PR #7](https://github.com/right-0903/linux-gaokun/pull/7) 的亮度花屏修复，不重复叠加 |
| right recommended 0010：DSC 宽度向上取整 | 当前使用另一种计算式 | 按本机 slice_width=800、slice_count=1、8 bpp、8 bpc 计算，当前 DPU、right 0010、DSI host 都为 267；当前没有发现此处的 266/267 差异 |

right 仓库核对版本为 `7463df37160bdecc3f2609d72f9a69cfa2b390e4`。试验只恢复上述 PLL 补丁，没有同时加入 `20282806` 或替换 DSC/触摸实现。可应用和可编译不代表实机有效。

## 同时排除触摸初始化干扰

HX83121A 是触摸/显示集成芯片。[right 的讨论](https://github.com/right-0903/linux-gaokun/pull/2#issuecomment-4132507944)明确要求触摸跟随面板电源时序。当前驱动已有 panel follower，但会在 panel enabled 后延迟 300 ms 执行 chip detect、sense-off 和固件初始化。时间先后与花屏的关系必须由日志或禁用触摸对照验证；不能直接把触摸认定为根因。触摸 reset 使用 GPIO99，显示 reset 使用 GPIO38，不能说两者共用同一根复位线。

## 不重刷镜像的对照测试

在 systemd-boot 菜单选中测试项按 `e`，临时编辑内核命令行。每次从原始命令行开始，只做一项测试，不将这些选项永久写入镜像。若有 Secure Boot 等限制不允许编辑，可使用已有的备用启动项收集日志。

1. **仅禁用触摸模块**：追加 `module_blacklist=himax_hx83121a_spi`。这次没有触摸输入，使用键盘。如果不再花屏，优先检查触摸与面板时序，并参考 right 的现有传输/生命周期修复；不能因此认定 DSC 无问题。
2. **仅关闭 DSC**：追加 `panel_himax_hx83121a.enable_dsc=0`。驱动已提供此参数，使用非 DSC 的 60 Hz 模式。如果恢复正常，只能将范围缩到 DSC 模式相关的时序/时钟/面板初始化，不能唯一定位宽度计算。
3. **必要时阻止 MSM 接管**：追加 `module_blacklist=msm`。若保留固件 framebuffer 后不再花屏，说明与原生显示接管相关；此模式无正常 MSM 图形加速，仅用于诊断。

若原始命令行已有 `module_blacklist=`，在其逗号列表中追加模块，不重复设置该参数。各轮记录是否出现最初正常画面、花屏时间、全屏还是半屏、是否仍能通过 SSH 登录。禁用模块后可用 `lsmod` 确认它未加载；不要在面板已花屏时在线卸载驱动替代冷启动测试。

## 收集证据

故障启动可临时去掉 `quiet rhgb`，追加 `drm.debug=0x1ff log_buf_len=4M`。进入系统后（可通过 SSH）保存完整日志，不只截取含 error 的行：

```bash
uname -a > gaokun-display-system.txt
cat /proc/cmdline >> gaokun-display-system.txt
lsmod >> gaokun-display-system.txt
sudo journalctl -b -k -o short-monotonic > gaokun-display-boot.log
```

从备用内核启动后，若上次故障启动日志已持久保存，改用 `journalctl -b -1 -k -o short-monotonic`。`uname -a` 的 `7.2.6-gaokun3+` 不能区分所有候选，还需记录下载的 Actions run / package-manifest.json 中的内核 SHA。

最少需要：故障内核来源、最后正常的内核版本、花屏照片或视频、以上日志，以及禁用触摸/关闭 DSC 两次独立测试结果。得到结果后选择一个已有补丁测试，并保留原候选供回退；在此之前不宣称已修复。
