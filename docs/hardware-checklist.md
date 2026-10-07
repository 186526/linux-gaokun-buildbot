# Gaokun3 实机验收

CI 只证明编译、打包和镜像组装。每次升级先保留已知可用的启动项，按下表记录实际结果；未测试的项目写“未测”，不要由构建成功推断硬件可用。

记录：设备/面板型号、发行版、内核 SHA、buildbot SHA、测试日期。两项 SHA 从此次 Actions 输入和 package-manifest.json 取得。

## 启动后收集

```bash
uname -a
cat /etc/os-release
cat /etc/kernel/entry-token
cat /proc/cmdline
cat /sys/kernel/security/lsm
bootctl list
sudo journalctl -b -k > kernel-boot.log
v4l2-ctl --list-devices
```

Fedora 应使用 `fedora` token、加载 SELinux 策略；Ubuntu 应使用 `ubuntu` token 和 AppArmor。现有安装升级会沿用原有命令行，不能仅因新包安装成功就认为策略已经切换。

| 项目 | 操作与判定 | 结果 |
| --- | --- | --- |
| 启动 | 冷启动、重启；确认运行的是目标内核 | 未测 |
| 引导条目 | 名称以 fedora/ubuntu 开头，内核、initrd、DTB 路径存在 | 未测 |
| 显示 | 分别切换 60/120 Hz，观察花屏、闪烁和亮度调节 | 未测 |
| 触摸 | 慢划、快划、双指及多指；观察断触、跳点、幽灵触点 | 未测 |
| 触摸恢复 | 反复熄屏/亮屏、挂起/恢复，再测试多指；记录循环次数 | 未测 |
| EC / 电池 | 合盖、开盖、电量、插拔充电器；检查异常日志 | 未测 |
| USB-C / UCSI | 外设、供电及热插拔，记录测试过的端口和设备 | 未测 |
| 无线 | Wi-Fi、蓝牙连接，挂起后重新确认 | 未测 |
| 音频 | 扬声器、麦克风及实际使用的输出路径 | 未测 |
| 挂起 | 确认进入并退出 s2idle；记录唤醒方式及异常 | 未测 |
| Iris 解码 | 对已知格式/分辨率的视频运行实际 V4L2 解码，保留程序和内核日志 | 未测 |
| Iris 编码 | 单独检查暴露的能力并测试；不能由解码成功推断编码可用 | 未测 |
| 升级与回退 | 安装下一候选后，从启动菜单分别进入新旧内核 | 未测 |

Iris 节点出现、固件加载或 `/dev/video*` 存在，都不足以证明实际编解码工作正常。camera、EL2 另行测试，不计入普通候选已验证功能。

若出现问题，记录失败步骤、此前可用的内核 SHA 和对应 `kernel-boot.log`。由维护者判断是否发布，并为通过验收的源码建立不可变 tag；CI 不自动修改下游提交栈。
