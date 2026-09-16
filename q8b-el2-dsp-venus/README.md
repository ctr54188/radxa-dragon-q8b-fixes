# q8b-el2-dsp-venus — Radxa Dragon Q8B：EL2(KVM) + DSP + 音频 + 硬件编解码

在 **BIOS 保持 `Hypervisor Override = Auto`** 的前提下，让 Q8B 运行在 EL2（获得 KVM），
同时 **DSP 正常 attach、固件风扇温控可用、音频可用、Venus 硬件编解码可用**。

一个脚本，在**全新安装的 Armbian** 上一键部署；所有东西都在本机编译，**不换内核、不刷固件**。

```bash
sudo ./install.sh install     # 预检 + 本机编译 + 部署（不改默认启动项）
sudo ./install.sh enable      # 让 EL2 成为常驻默认
sudo reboot

sudo ./install.sh report      # 重启后核对
```

## 解决了什么问题

Q8B 上 EL2 和 DSP 是互斥的，除非做点手脚：

| 模式 | KVM | DSP / 风扇温控 / 音频 / VPU |
|---|---|---|
| EL1（`Auto`/`Disabled`，无 `radxa,enable-kvm`） | ✗ | ✓ |
| **EL2（`Enabled`，或 `Auto` + DTB 里加 `radxa,enable-kvm`）** | ✓ | ✗ **除非修** |

原因：
1. 进入 EL2 后**引导链不再预加载 ADSP/CDSP**，而 Linux 自己 start 会超时
   （`qcom_q6v5_pas: start timed out`）→ 依赖 ADSP 的固件风扇服务、音频全部失效。
2. 厂商内核的 VPU 驱动走 **iris + Gen2 固件**配对，Q8B 需要 **venus(HFI6) + Gen1 固件**
   （否则 `qcom-iris: error -22 initializing firmware vpu20_p4_gen2_s6.mbn`）。

## 原理 / 它做了什么

```
① DTB: 系统 DTB + /chosen/radxa,enable-kvm = <1>
       → BIOS 保持 Auto，固件自行判定 EL2 并打上自己的 EL2 补丁
         (qcom,shm-bridge-vmid / SMMU okay / zap-shader)   ← 不用手工改这些

② UEFI: qebspilaa64.efi 在 ExitBootServices 阶段预加载 ADSP/CDSP，
         Linux 只需 attach（自编译，upstream stephan-gh/qebspil @8e4d9e6）
   由 q8b-launcher-venus.efi 拉起；一次性 flag 控制，健康启动后由 systemd 单元重建

③ 内核模块（本机编译，ABI 已与运行内核逐符号 CRC 校验）：
     qcom_q6v5_pas.ko   = 他的 .attach + 我们的 use_tzmem(EL2+Q8B) 补丁
     venus-core/dec/enc.ko = HFI6 支持恢复 + 配 Gen1 固件 vpu20_p4.mbn
     （venus 的改动同时作用到 EL1：系统 DTB + module_blacklist=qcom_iris）

④ GRUB: 两条项 + 一次性交接
     index 4 "Q8B EL2 direct"        —— 真正启动 EL2 的项
     index 5 "Q8B EL2 + DSP preload" —— 默认项：预加载 DSP 后把 next_entry=4 交给第二级 grub
```

启动链（EL2 常驻时）：

```
默认项(5) → set next_entry=4; chainloader launcher.efi
   → launcher：删除 dsp-once.flag → 启动 qebspil（预加载 DSP）→ 链式启动系统 grub 副本
      → 按 next_entry=4 启动 "EL2 direct" → EL2 + 已预加载的 DSP → Linux attach + venus 接管 VPU
         → 启动完成后 q8b-el2fan-rearm 重建 flag，供下次开机
```

## 环境要求

| 项目 | 要求 |
|---|---|
| 板卡 | Radxa Dragon Q8B（SC8280XP） |
| 系统 | Armbian 26.8.x（Debian 13 trixie 或 Ubuntu），vendor 内核 `7.0.11-vendor-sc8280xp` |
| 内核头文件 | `linux-headers-vendor-sc8280xp`（**版本需与运行内核一致**，用于编译模块） |
| 构建工具 | `gcc make device-tree-compiler python3`（缺少时脚本会提示 apt 命令） |
| ESP | `/boot/efi` 已挂载（vfat） |
| BIOS | `Hypervisor Override = Auto`（**不需要**改成 Enabled；脚本也不改 BIOS） |

## 安装（全新系统）

```bash
# 1) 依赖
sudo apt-get update
sudo apt-get install -y gcc make device-tree-compiler python3 linux-headers-vendor-sc8280xp

# 2) 部署（幂等；不改默认启动项，先安全落地）
sudo ./install.sh install

# 3) 让 EL2 成为常驻默认，然后重启
sudo ./install.sh enable
sudo reboot

# 4) 核对
sudo ./install.sh report
```

只想先试一次、不想改默认项：`sudo ./install.sh arm`（一次性进 EL2 并重启；
之后直接重启就回到原来的 EL1）。

## 命令

| 命令 | 说明 |
|---|---|
| `install [--force]` | 预检 + 本机编译 + 部署（不改默认启动项）。`--force` 用于系统看起来已打过补丁时 |
| `build` | 只重新编译（模块 + UEFI 载荷），日志在 `/tmp/{pas,venus,qeb}-build.log` |
| `enable` / `disable` | 把 EL2 设为常驻默认 / 恢复原默认项（修复内容保留） |
| `arm` | 一次性进 EL2（自动重建 flag + `next_entry` + 重启） |
| `status` | 简短状态（EL / 默认项 / 模块 / DTB / GRUB 项） |
| `report` | 详细状态（DSP、venus、风扇、音频、ESP 上的 launcher 日志） |
| `uninstall` | 全部还原（模块 / DTB / GRUB / ESP / pd-mapper / rearm） |

## 安装了什么

```
payload/
├── pas-attach-fix-src.tgz   qcom_q6v5_pas 模块源码（含 .attach + use_tzmem 两处补丁）
├── venus-el2-src.tgz        venus 模块源码（HFI6 补丁，外部模块工程）
├── qebspil-src.tgz          qebspil（UEFI DSP 预加载驱动）+ 两个 launcher 源码
├── qebspilaa64.efi          预编译 EFI（源码编译失败时兜底）
└── q8b-launcher-venus.efi   预编译 launcher

目标位置：
  /lib/modules/<kver>/kernel/drivers/remoteproc/qcom_q6v5_pas.ko
  /lib/modules/<kver>/kernel/drivers/media/platform/qcom/venus/venus-{core,dec,enc}.ko
  /boot/armbian-dtb-<kver>            (+ venus 修复)
  /boot/armbian-dtb-<kver>-el2kvm     (+ venus 修复 + radxa,enable-kvm)
  /boot/efi/EFI/q8b-test-20260909/    {qebspilaa64.efi, q8b-launcher-venus.efi, grub-venus.efi, dsp-once.flag}
  /boot/efi/firmware/qcom/sc8280xp/…  qcadsp8280.mbn / qccdsp8280.mbn
  /etc/grub.d/43_q8b_el2fan           两条 GRUB 项
  /usr/local/sbin/q8b-el2fan-rearm + /etc/systemd/system/q8b-el2fan-rearm.service
  /root/q8b-el2-dsp-venus/backup/     所有原始文件备份（供 uninstall 还原）
```

## 实测结果（Armbian 26.8.1 trixie / vendor 7.0.11 / BIOS 0825）

```
EL2 ✔            /dev/kvm 可打开，KVM_GET_API_VERSION=12
DSP ✔            adsp attached / cdsp attached
                 remoteproc0: remote processor adsp is now attached
VPU ✔            qcom-venus aa00000.video-codec: non legacy binding
                 /dev/video0 /dev/video1 /dev/video-decN /dev/video-encN
风扇 ✔           radxa_svc_glink 存在（可再由 q8b-fan-curve 项目换成自定义曲线）
音频 ✔           sound cards 1
失败服务 ✔       0
自愈 ✔           rearm 单元日志：re-armed DSP preload flag (adsp=attached)
硬件编解码 ✔     GStreamer 1920x1080@60：HEVC 硬编/硬解 rc=0，亮度与软解逐字节一致；
                 色度仅采样位置差异（2x2 块平均后最大 3.25/255）；H.264 硬编/硬解 rc=0
```

## 失效模式与恢复（都已在文档中验证）

| 情况 | 行为 | 恢复 |
|---|---|---|
| `dsp-once.flag` 缺失 | 仍进 EL2，但 DSP 不 attach（风扇 100%、无音频）；**板子照常起来、SSH 可达** | 该次启动的 rearm 会重建 flag；或 `sudo ./install.sh arm` |
| 预加载链失败 | 预加载项里的 `if chainloader...; then boot; fi; configfile` 回落到正常配置，**不会卡菜单** | 直接重启 |
| 想临时进 EL1 | `sudo grub-editenv /boot/grub/grubenv set next_entry=0 && sudo reboot` | — |
| 想彻底回 EL1 默认 | `sudo ./install.sh disable`（修复保留）/ `uninstall`（全清） | — |
| 内核升级 | `armbian-dtb-*` 与模块被覆盖 → 重新 `install`（幂等，会重编模块） | 必要时先装匹配的 headers |

## 已知遗留

- 系统 **ffmpeg 7.1.5 的 V4L2 M2M 路径有兼容问题**（HEVC MP4 坏帧 / H.264 少帧 / NV12 硬编崩溃）
  → 优先用 GStreamer；本方案不改 ffmpeg
- 未验证：4K 长时负载 / Main10 / HDR / 具体串流与 VNC 应用 / Windows 来宾
- HW 解码输出高度按 **1088 行对齐**（每帧多 8 行填充），逐字节比对必须按可见区域
- `enable` 之后每次开机都走预加载链；若连续多次失败，可用 `disable` 退回 EL1

## 卸载

```bash
sudo ./install.sh uninstall
sudo reboot
```
会用 `/root/q8b-el2-dsp-venus/backup/` 里的原始文件还原模块、DTB、GRUB、ESP、pd-mapper、rearm。

## 许可 / 致谢

- 本脚本与打包：MIT（见 LICENSE）
- `payload/qebspil-src.tgz`：来自 [stephan-gh/qebspil](https://github.com/stephan-gh/qebspil)（GPL-2.0-only），
  内含作者针对 Q8B 的补丁（launcher / 预加载时序）
- `pas-attach-fix`、`venus-el2` 源码：派生自 [radxa/kernel](https://github.com/radxa/kernel)（GPL-2.0-only），
  补丁思路与实现参考了社区整理好的 Q8B EL2 修复包（qebspil + .attach + venus HFI6）
- 固件（`.mbn`）不随本项目分发，脚本直接复用系统 `armbian-firmware` 提供的文件
- 本项目**不修改 BIOS**，也不写 SPI NOR；所有改动集中在 rootfs / ESP / GRUB

## 踩坑清单（供后人省事）

1. 本系统 `feature_menuentry_id` 未置 `y` → `menuentry ... $menuentry_id_option 'id'` 的 id **无效**，
   `grub-reboot <id>` 会**静默回落默认项**；必须用**下标** + `grub-editenv /boot/grub/grubenv set next_entry=<n>`。
2. 数下标必须把**缩进的 menuentry**（`UEFI Firmware Settings`，在 `if` 块里）算进去，否则 off-by-one。
3. `grub-editenv - set x=y` 会把 `-` 当文件名 → **必须显式写 `/boot/grub/grubenv`**。
4. 手工构造的"EL2 DTB"（自己塞 `qcom,shm-bridge-vmid` / SMMU / zap-shader）**在 EL1 下会挂死板子**；
   正确做法是系统 DTB + 一行 `radxa,enable-kvm`，其余交给固件。
5. 只做 `use_tzmem=true` 的内核补丁**不够**：EL2 下 Linux 自己 start DSP 会 `start timed out`，
   **必须让 UEFI 预加载**（qebspil）。
6. `grub-mkstandalone` 造第二级 grub 在本机**不生效**（会去加载系统 grub.cfg）
   → 用**系统 grub 的副本** + `next_entry` 传递。
7. `compatible` 可能是 `"a", "b"` 多字符串形式；替换时要把 iris 去掉，否则 iris 抢先绑定。
8. Armbian 生成的条目 cmdline **不读** `/etc/default/grub` 的 `GRUB_CMDLINE_LINUX_DEFAULT`，
   真正生效的是 **`/etc/default/grub.d/98-armbian.cfg`**。
9. 板子 RTC 偏差可能很大，journal 时间线会跳变，排查时别被误导。
10. `/tmp` 在重启时会被清理 —— 项目要放在持久目录（如 `/root`）里再运行。
