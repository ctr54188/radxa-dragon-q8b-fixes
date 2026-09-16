# Radxa Dragon Q8B 修复集（EL2/KVM + DSP + 音频 + 硬件编解码 + 自定义风扇曲线）

Q8B（Qualcomm SC8280XP）在 **BIOS 保持 `Hypervisor Override = Auto`** 的前提下，
既能跑 EL2（用上 KVM），又能保住 **DSP / 固件风扇温控 / 音频 / Venus 硬件编解码**；
并把官方偏激进的**风扇曲线换成自己的**。

两个互相独立的项目，各自一键部署（全部本机编译，**不换内核、不刷 BIOS、不写 SPI NOR**）：

```bash
# 依赖
sudo apt-get install -y gcc make device-tree-compiler python3 linux-headers-vendor-sc8280xp

# 项目 A：EL2(KVM) + DSP 预加载 + 音频 + 硬解
cd q8b-el2-dsp-venus
sudo ./install.sh install && sudo ./install.sh enable && sudo reboot
sudo ./install.sh report          # 核对

# 项目 B：自定义风扇曲线
cd ../q8b-fan-curve
sudo ./install.sh install
sudo ./install.sh status
```

## 目录

| 路径 | 内容 |
|---|---|
| [`q8b-el2-dsp-venus/`](q8b-el2-dsp-venus/) | **EL2 + DSP + 音频 + Venus 硬件编解码**：本机编译内核模块（`qcom_q6v5_pas` 的 attach+tzmem、venus 的 HFI6）、自编 UEFI 预加载驱动（qebspil）+ launcher、DTB 一行属性让固件选 EL2、两条 GRUB 项 + 一次性交接 + 自愈 rearm 单元；同时修好 EL1 下的硬解 |
| [`q8b-fan-curve/`](q8b-fan-curve/) | **自定义风扇曲线**：通过固件**手动模式**接管转速（不抢 LPG 硬件），`<35°C 停转 / 35°C 40% / 50°C 50% / 60°C 66% / 70°C 82% / 80°C 96%`，带滞回、超温钳制与失败安全 |
| [`background/`](background/) | 背景资料：为什么这块板子的风扇其实由 **ADSP 固件服务**驱动（`radxa_svc_glink` → PMIC LPG PWM ch3 → 反相 MOS → J6）、相关内核源码副本、以及一个读 hwmon 的小工具 |

## 为什么需要这些修复

| 模式 | KVM | DSP / 风扇温控 / 音频 / VPU |
|---|---|---|
| EL1（`Auto`，DTB 里没有 `radxa,enable-kvm`） | ✗ | ✓ |
| **EL2（`Enabled`，或 `Auto` + DTB 里加 `radxa,enable-kvm`）** | ✓ | ✗ **除非修** |

1. 进 EL2 后**引导链不再预加载 ADSP/CDSP**，Linux 自己 start 会 `qcom_q6v5_pas: start timed out`
   → 依赖 ADSP 的固件风扇服务、音频全失效（只做 `use_tzmem` 之类内核补丁**不够**，
   必须让 UEFI 预加载 DSP）。
2. 厂商内核的 VPU 走 **iris + Gen2 固件**配对，Q8B 需要 **venus(HFI6) + Gen1 固件**。

项目 A 的做法：DTB 里加一行 `/chosen/radxa,enable-kvm`（固件自行判定 EL2 并打自己的补丁）+
自编 qebspil 在 `ExitBootServices` 预加载 DSP + 本机编译的 `attach/tzmem` 模块 + venus 修复。
项目 B 的做法：不动硬件，把固件切到手动模式后自己写占空比。

## 环境基线（实测通过）

| 项目 | 值 |
|---|---|
| 板卡 | Radxa Dragon Q8B（SC8280XP，BIOS `6.0.260825.BOOT.MXF.1.1.c1-00167-MAKENA-1`） |
| 系统 | Armbian 26.8.1（Debian 13 trixie），vendor 内核 `7.0.11-vendor-sc8280xp` |
| BIOS 设置 | `Hypervisor Override = Auto`（不需要改成 Enabled） |
| 其它 | `linux-headers-vendor-sc8280xp`（与运行内核一致）、`/boot/efi` 已挂载 |

## 实测结果

```
EL2 ✔            /dev/kvm 可用（KVM_GET_API_VERSION=12）
DSP ✔            adsp attached / cdsp attached（remoteproc 是 attach，不是 start）
VPU ✔            qcom-venus aa00000.video-codec: non legacy binding
                 /dev/video0 /dev/video1 /dev/video-decN /dev/video-encN
风扇 ✔           固件风扇服务在 EL2 下可用；再由项目 B 换成自定义曲线
音频 ✔           sound cards 1
失败服务 ✔       0
自愈 ✔           rearm 单元日志：re-armed DSP preload flag (adsp=attached)
硬件编解码 ✔     GStreamer 1080p60：HEVC 硬编/硬解 rc=0，亮度与软解逐字节一致，
                 色度仅采样位置差异（2×2 块平均后最大 3.25/255）；H.264 硬编/硬解 rc=0
```

## 安全与恢复

两个项目都是**幂等**的，并且都提供 `uninstall`（用安装时保存的原始文件还原模块 / DTB / GRUB / ESP）。
`q8b-el2-dsp-venus` 还有：

- **一次性交接 + 自愈**：默认项先预加载 DSP，再把 `next_entry` 交给真正的 EL2 项；
  健康启动后由 systemd 单元重建 `dsp-once.flag`。flag 缺失时仍能进 EL2（只是没有 DSP），**板子照常可达**；
- **链路失败回落**：`if chainloader ...; then boot; fi; configfile` —— 不会卡在 GRUB 菜单；
- **临时回 EL1**：`sudo grub-editenv /boot/grub/grubenv set next_entry=0 && sudo reboot`；
- **构建守卫**：四个构建产物缺任何一个就终止，**绝不修改 `/lib/modules`**。

各项目的 README 里有完整的失效模式表与踩坑清单。

## 许可与致谢

- 本仓库自己的脚本：MIT（见 [LICENSE](LICENSE)）
- `q8b-el2-dsp-venus/payload/` 下的源码派生自 **GPL-2.0-only** 项目：
  [stephan-gh/qebspil](https://github.com/stephan-gh/qebspil) 与 [radxa/kernel](https://github.com/radxa/kernel)；
  随附的预编译 EFI 由这些源码在本机编译，源码一并提供
- **不分发任何固件（`.mbn`）**：脚本直接复用系统 `armbian-firmware` 提供的文件
- 不修改 BIOS、不写 SPI NOR；所有改动都在 rootfs / ESP / GRUB

## 免责声明

修改引导用的 DTB / GRUB / 内核模块存在风险（虽然脚本做了校验、备份与失败回落）。
请先确认你能进 grub 菜单或已有系统备份，作者不对设备损坏或数据丢失负责。

---

## English summary

Two independent, idempotent installers for the **Radxa Dragon Q8B** (SC8280XP):

* **`q8b-el2-dsp-venus`** — run at **EL2 (KVM)** while keeping the ADSP, audio and the
  hardware video codec alive, with the BIOS left on `Hypervisor Override = Auto`.
  It builds the needed kernel modules locally, ships a locally built UEFI DSP preloader
  (qebspil) plus a launcher, adds `radxa,enable-kvm` to the device tree, and wires up a
  one-shot, self-healing GRUB handoff. EL1 also gets the venus/HFI6 video fix.
* **`q8b-fan-curve`** — replace the aggressive firmware fan curve with your own by driving
  the ADSP fan service's *manual mode* (no fighting over the PMIC LPG hardware).
  Default: off below 35 °C, then 40/50/66/82/96 % at 35/50/60/70/80 °C.

Both were verified end-to-end on a Q8B (Armbian 26.8.1, vendor kernel 7.0.11).
See each project's README for requirements, failure modes and the full pitfall list.
