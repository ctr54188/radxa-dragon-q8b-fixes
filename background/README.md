# Radxa Dragon Q8B 风扇控制

Q8B 的散热风扇**不由 Linux 控制**，而是由跑在 **ADSP** 上的 Radxa 固件服务驱动的。
Linux 侧只有一个"窗口"（`radxa_svc_glink` 驱动的 hwmon）。所以：

- 内核里没有 fan/pwm 节点、`/sys/class/pwm` 是空的 → **这是正常的**，不是驱动缺失；
- 真正决定风扇能不能温控的，是 BIOS 的一个开关。

## 一句话结论：风扇一直全速怎么办

进 BIOS（开机按 `F2`）：

```
Radxa Platform Configuration -> Hypervisor Settings
```

改成 **`Auto`**（或 `Disabled` / `Close`）—— **绝对不要设成 `Enable`**。

| 取值 | 结果 |
|---|---|
| **Auto** | ✅ 正常，风扇由 ADSP 固件自动温控 |
| **Disabled / Close** | ✅ 正常 |
| **Enable** | ❌ ADSP 上的风扇服务起不来 → 风扇恒速全转 |

改完之后会出现：

```bash
/sys/class/hwmon/hwmonN/           # name = radxa_svc_glink
    pwm1          # 当前占空比 0..255
    pwm1_enable   # 0=全速 1=手动 2=自动(固件温控)
```

> `hwmonN` 的编号每次启动都会变，请按 `name` 查找，不要写死。

## 快速开始

```bash
sudo curl -fsSL https://raw.githubusercontent.com/ctr54188/radxa-dragon-q8b-fan/main/q8b-fan \
     -o /usr/local/sbin/q8b-fan
sudo chmod +x /usr/local/sbin/q8b-fan

sudo q8b-fan status
```

```
== fan ==
  device       : /sys/class/hwmon/hwmon56
  duty         : 129/255  (~51%)
  mode         : 2 -> automatic (firmware thermal control)
  profile      : performance
  firmware     : v1.5  cpu 45.8 C / gpu 38.9 C  loop 2391  faults 0
  duty now/tgt : 19725 ns / 19725 ns   (ch 3, period 40000 ns)

== kernel thermal sensors ==
  cluster0-thermal   39.2 C
  ...
```

## 命令

| 命令 | 说明 |
|---|---|
| `status` | 占空比 / 模式 / 曲线档 + 温度（默认命令，只读） |
| `auto` | 交回固件温控（`pwm1_enable=2`） |
| `full` | 强制全速（`pwm1_enable=0`） |
| `manual [0-100]` | 手动转速；不带参数 = 冻结当前转速 |
| `profile [quiet\|performance]` | 查看 / 切换固件里的两套风扇曲线 |
| `watch [秒]` | 实时看 duty / 模式 / cluster0 温度 |
| `info` | 固件版本、PWM 信息、rpmsg 链路统计 |
| `temps [0..45]` | 固件侧 tsens 温度（一次一路） |
| `log` | 固件日志 |

注意 `pwm1` **只有在手动模式下才可写**，所以手写时要先切模式：

```bash
H=$(for h in /sys/class/hwmon/hwmon*; do [ "$(cat $h/name)" = radxa_svc_glink ] && echo $h; done)
echo 1   > $H/pwm1_enable     # 先切手动
echo 128 > $H/pwm1            # 再写占空比（0..255）
echo 2   > $H/pwm1_enable     # 交回固件
```

## 原理（简版）

```
BIOS: Hypervisor = Auto (或 Disabled)
  └─ UEFI 启动 ADSP（soc@0/remoteproc@3000000）
       └─ ADSP 上运行 Radxa SVC 固件
            └─ GLINK/rpmsg 服务 "RADXA_SVC_ADSP_APPS"
                 ├─ 自己读 46 路 tsens 温度
                 ├─ 自己跑风扇控制环
                 └─ 自己驱动 PMIC(PMC8280C) LPG 硬件 PWM，channel 3，25 kHz
                       └─ PMIC GPIO_08 = EDP_BL_PWM -> R410 -> Q20 -> J6 pin3 -> 风扇

Linux: radxa_svc_glink.ko 只提供窗口，不参与控制
         hwmon / platform-profile / debugfs
```

完整分析（rpmsg 协议表、寄存器、接口语义、实测数据、踩坑记录）见 **[NOTES.md](NOTES.md)**。

## ⚠️ 不要做的事

1. **不要在设备树里把 `pmc8280c_lpg`（`qcom,pm8350c-pwm`）的 `status` 改成 `okay`。**
   这个 PMIC LPG 硬件正是 ADSP 固件用来控风扇的那一个；Linux 的 `leds-qcom-lpg`
   一接管就会把输出拉停，MOS 关断，**风扇卡死在 100%**。
   自检：`ls /sys/class/pwm/` 必须是空的。

2. **不要在 SoC GPIO_119 上做 PWM。** 原理图 v1.30 标错了：实际 **R410（接 EDP_BL_PWM）
   有贴料、R473（接 GPIO_119）未贴料，这才是正确设计**。GPIO_119 到 MOSFET 栅极是断路的。

3. **不要高频轮询本项目里的 `/sys/kernel/debug/radxa_svc_glink/*`。**
   每个文件的读都是一次 rpmsg 往返（5 秒超时），压太狠会让 ADSP 服务挂掉。
   服务挂掉的表现是 hwmon 消失、`dmesg` 出现 `radxa_svc_glink ... ETIMEDOUT`，
   **重启即可恢复**。本工具已经为此做了省请求的设计（`status` 只发 4 个请求）。

## 编译成二进制（可选）

`q8b-fan` 本体是**纯 bash 脚本，不需要编译**，`curl` 下来就能用。
仓库里另外提供了一份**等价的 C 实现**（[`src/q8b-fan.c`](src/q8b-fan.c)，同样的命令、同样的输出），
编译出来是一个**单文件、静态链接、零依赖**的可执行文件 —— 适合拷到别的板子上直接跑。

两种实现行为一致，选一个用就行：

| 形式 | 产物 | 运行时依赖 | 体积 |
|---|---|---|---|
| bash 脚本（默认） | `q8b-fan` | `bash` + `awk` | 13 KB |
| C 二进制（动态） | `build/q8b-fan` | glibc | ~20 KB |
| **C 二进制（静态）** | `build/q8b-fan` | **无** | ~780 KB |
| shc 包装 | `build/q8b-fan-shc` | `bash` | ~15 KB |

### 方式 1：直接下载预编译二进制（最省事）

推 `v*` tag 时 CI 会自动编译 aarch64 / x86_64 静态二进制并附到 Release：

```bash
curl -fL -o q8b-fan \
  https://github.com/ctr54188/radxa-dragon-q8b-fan/releases/latest/download/q8b-fan-aarch64
sudo install -m 0755 q8b-fan /usr/local/sbin/q8b-fan
sudo q8b-fan status
```

每次 push / PR 也都会构建，可以在仓库 **Actions** 页面的 artifact 里下载。

### 方式 2：在 Q8B 本机编译

```bash
sudo apt update && sudo apt install -y gcc make

git clone https://github.com/ctr54188/radxa-dragon-q8b-fan.git
cd radxa-dragon-q8b-fan

make                  # -> build/q8b-fan（动态链接）
make STATIC=1         # -> build/q8b-fan（静态，可拷到任何 aarch64 Linux）
file build/q8b-fan

sudo make install     # -> /usr/local/sbin/q8b-fan
sudo make uninstall   # 卸载
make clean
```

`make` 只调用 `$(CC)` 编译一个 `.c` 文件，没有别的依赖。

### 方式 3：交叉编译（在 x86_64 Linux 上编出 aarch64）

```bash
sudo apt install -y gcc-aarch64-linux-gnu libc6-dev-arm64-cross
make CROSS_COMPILE=aarch64-linux-gnu- STATIC=1
file build/q8b-fan
# build/q8b-fan: ELF 64-bit LSB executable, ARM aarch64, statically linked
```

> 如果报 `fatal error: bits/wordsize.h: No such file or directory`，说明该发行版的
> 交叉工具链 sysroot 不全（Debian/Ubuntu 上补装 `libc6-dev-arm64-cross` 即可），
> 否则用方式 4。

### 方式 4：用 Docker（任意平台，含 macOS）

```bash
# 在 arm64 机器（Apple Silicon）上出 aarch64 静态二进制，原生速度
docker run --rm -v "$PWD":/w -w /w --platform linux/arm64 gcc:13 make STATIC=1

# 在 x86_64 机器上出 aarch64
docker run --rm -v "$PWD":/w -w /w gcc:13 \
  sh -c 'apt-get update -qq && apt-get install -y -qq gcc-aarch64-linux-gnu libc6-dev-arm64-cross \
         && make CROSS_COMPILE=aarch64-linux-gnu- STATIC=1'
```

### 方式 5：把 bash 脚本“编译”成 ELF（shc）

```bash
sudo apt install -y shc        # macOS: brew install shc
make shc                       # -> build/q8b-fan-shc
file build/q8b-fan-shc         # ELF，但运行时仍然需要 /bin/bash
```

`shc` 只是把脚本加密后嵌进一个 ELF 壳，**不是真正的独立二进制**；
要真正零依赖请用方式 2/3/4。

### CI（`.github/workflows/build.yml`）

- 在 GitHub 原生的 **`ubuntu-24.04-arm`** 和 `ubuntu-latest` runner 上**本机编译**
  （不用交叉工具链，规避 sysroot 问题）；
- `push` / `PR` / 手动触发 → 上传 `q8b-fan-aarch64`、`q8b-fan-x86_64` 两个 artifact；
- 推 `v*` tag → 自动发 Release 并附带这两个二进制。

```bash
git tag v1.1.0 && git push origin v1.1.0     # 一键出二进制 + Release
```

## 目录结构

```
q8b-fan                  # 控制工具（纯 bash，免编译）
Makefile                 # 编译 C 实现 / shc 包装
.github/workflows/       # CI：构建 aarch64 + x86_64 静态二进制并发布 Release
NOTES.md                 # 完整技术笔记：原理 / 协议 / 接口 / 实测 / 踩坑
src/q8b-fan.c            # 等价的 C 实现（make 编译成单文件二进制）
src/radxa_svc_glink.c    # 上游参考源码（见 src/README.md）
src/leds-qcom-lpg.c
src/sc8280xp-pmics.dtsi
```

## 参考源码

`src/` 里的文件是**未修改**的上游副本，仅作参考：

```
repo   : https://github.com/radxa/kernel
branch : linux-7.0.11
commit : 395349af3be0e89fe36011165d90f7a5061c5d84
```

- `radxa_svc_glink.c` —— 风扇服务的 Linux 驱动（本工具操作的所有接口都由它提供）
- `leds-qcom-lpg.c` —— PMIC LPG PWM 驱动（「不要做的事 1」的原因）
- `sc8280xp-pmics.dtsi` —— `pmc8280c_lpg` 节点定义（`status = "disabled"`）

它们是 **GPL-2.0-only**，版权归各自作者所有，见 `src/README.md`。

## 已验证环境

```
Radxa Dragon Q8B (SC8280XP, 原理图 v1.30)
Armbian 26.8.1 trixie / vendor 内核 7.0.11-vendor-sc8280xp
固件服务版本 v1.5 (caps 0x7f)
```

## License

`q8b-fan` 与 `NOTES.md`：MIT（见 [LICENSE](LICENSE)）。
`src/` 下的内核源码：GPL-2.0-only。

---

## English summary

The fan of the Radxa Dragon Q8B (SC8280XP) **is not controlled by Linux** — it is
driven by a Radxa firmware service running on the **ADSP**, which Linux only sees
through the `radxa_svc_glink` hwmon window.

If your fan always runs at full speed no matter what, fix the BIOS setting:

```
Radxa Platform Configuration -> Hypervisor Settings -> Auto (or Disabled)
```

**Do not use `Enable`** — the hypervisor takes over the ADSP and the fan service
never comes up.

`q8b-fan` is a small bash tool to inspect and control the fan through the hwmon
attributes (`pwm1`, `pwm1_enable`), the platform profile and the firmware's
debugfs interface. The full mechanism (GLINK/rpmsg protocol, PMIC LPG PWM channel 3
→ GPIO_08 → EDP_BL_PWM → Q20 → J6 pin3), measured data and the pitfalls are
documented in [NOTES.md](NOTES.md) (Chinese).
