# Radxa Dragon Q8B 风扇控制 - 实现源码与原理笔记

结论先行：**这块板子的风扇不由 Linux 控制，而是由跑在 ADSP 上的 Radxa 固件服务控制。**
Linux 侧唯一的接口是 `radxa_svc_glink` 驱动暴露出来的 hwmon。

```
BIOS: Radxa Platform Configuration -> Hypervisor Settings = Auto (或 Disabled/Close，不能 Enable)
  └─ UEFI 启动 ADSP（soc@0/remoteproc@3000000, qcom,sc8280xp-adsp-pas）
       └─ ADSP 上运行 Radxa SVC 固件
            └─ GLINK/rpmsg 服务 "RADXA_SVC_ADSP_APPS"
                 ├─ 自己读 46 路 tsens 温度
                 ├─ 自己跑风扇控制环（CPU/GPU 温度 -> 目标占空比）
                 └─ 自己驱动 PMIC(PMC8280C) 的 LPG 硬件 PWM，channel 3，25kHz
                       └─ PMIC GPIO_08 = EDP_BL_PWM -> R410(22R) -> Q20(CJ3134K)
                             -> J6 pin3 -> 风扇

Linux: radxa_svc_glink.ko  ← 只做"窗口"，不参与控制
         /sys/class/hwmon/hwmonN/{pwm1,pwm1_enable}
         /sys/class/platform-profile/platform-profile-0/{profile,choices}
         /sys/kernel/debug/radxa_svc_glink/*
```

---

## 1. 文件清单

| 文件 | 来源 | 说明 |
|---|---|---|
| `../q8b-fan` | 本仓库自写 | 控制小工具（Mac 上和板子 `/usr/local/sbin/q8b-fan` 完全一致，md5 `42fbe20f…`） |
| `src/radxa_svc_glink.c` | `radxa/kernel` `drivers/platform/arm64/radxa_svc_glink.c` | 风扇服务的 Linux 驱动（**核心**） |
| `src/leds-qcom-lpg.c` | `radxa/kernel` `drivers/leds/rgb/leds-qcom-lpg.c` | PMIC LPG PWM 驱动。`qcom,pm8350c-pwm` 就是它接管的 —— 也是**千万不能在 DTB 里 enable 的原因** |
| `src/sc8280xp-pmics.dtsi` | `radxa/kernel` `arch/arm64/boot/dts/qcom/sc8280xp-pmics.dtsi` | 里面 `pmc8280c_lpg: pwm { ... status = "disabled"; }` |

上游引用：

```
repo   : https://github.com/radxa/kernel
branch : linux-7.0.11
commit : 395349af3be0e89fe36011165d90f7a5061c5d84
系统   : Armbian 26.8.1 trixie / vendor 内核 7.0.11-vendor-sc8280xp (BOARDFAMILY=sc8280xp)
原理图 : radxa_dragon_q8b_schematic_v1.30.pdf (sheet 5 = SoC, 29 = PMIC+风扇, 37 = 40PIN)
```

---

## 2. 硬件链路（原理图 v1.30）

```
                         +5V (VCC_5V_S)
                              │
                           R451 0R
                              │
   PMIC PMC8280C              ├──────── J6 pin2 (+5V)
   GPIO_08 (U29F pin62)       │
        │  = EDP_BL_PWM    R452 10K
        │                      │
        └─[R410 22R 有料]──┬───┴──── J6 pin3 (PWM)
                           │
   SoC GPIO_119 (N6) ──[R473 22R 未贴料]──┘   ← 这条路是断的！
                           │
                        G  Q20  CJ3134K (N-MOSFET)
                        S ── GND
```

J6（CONM_1X3，丝印 `PWM 5V GND`，方形焊盘/三角标记是 pin1）：

| 引脚 | 信号 |
|---|---|
| 1 | GND |
| 2 | +5V |
| 3 | PWM（开漏，MOS 关断时被 R452 拉到 5V） |
| 4、5 | 固定脚，接 GND |

关键点：

1. **原理图标注是错的**（Radxa 官方确认）：实际 **R410 有贴料、R473 未贴料，这才是正确设计**。
   所以 `FAN_PWM`/`GPIO119` 那条支路是断的，风扇实际由 `EDP_BL_PWM` 驱动。
2. MOS 反相一次：栅极高 -> pin3 = 0V -> 风扇 0%；栅极低 -> pin3 = 5V -> 风扇 100%。
   即 **风扇占空比 = 1 − PWM 占空比**（固件内部已经处理好了，`pwm1` 就是风扇占空比）。
3. PMIC GPIO8 在板子上被固件切到 **func1 = LPG PWM 输出**，其余 PMIC GPIO 是普通 GPIO
   （GPIO6 还是 USB3_HOST_EN），所以只有 channel 3 生效（见下 debugfs `supported_mask: 0x8`）。

---

## 3. rpmsg 协议（来自 `src/radxa_svc_glink.c`）

消息头 `RADXA_SVC_MAGIC = 0x58444152 ("RADX")`，版本 1，单次请求 5 秒超时，所有请求由
`svc->xfer_lock` 互斥串行化。

```c
RADXA_SVC_OP_PING             0x01   RADXA_SVC_OP_TSENS_GET_COUNT   0x30
RADXA_SVC_OP_GET_VERSION      0x02   RADXA_SVC_OP_TSENS_GET_TEMP    0x31
RADXA_SVC_OP_SET_PROFILE      0x10   RADXA_SVC_OP_TSENS_GET_MAX     0x32
RADXA_SVC_OP_GET_PROFILE      0x11   RADXA_SVC_OP_TSENS_GET_ALL     0x33  ← 固件未实现，必超时
RADXA_SVC_OP_GET_LOG          0x20   RADXA_SVC_OP_PWM_GET_INFO      0x40
                                     RADXA_SVC_OP_PWM_APPLY         0x41
RADXA_SVC_OP_FAN_GET_STATE    0x50   RADXA_SVC_OP_PWM_GET_STATE     0x42
RADXA_SVC_OP_FAN_SET_CONTROL  0x51   RADXA_SVC_OP_SENSOR_LIST       0x60
RADXA_SVC_OP_FAN_GET_CONTROL  0x52   RADXA_SVC_OP_SENSOR_READ       0x61

RADXA_SVC_PROFILE_QUIET = 0        RADXA_SVC_FAN_CONTROL_FULL_SPEED = 0
RADXA_SVC_PROFILE_PERFORMANCE = 1  RADXA_SVC_FAN_CONTROL_MANUAL     = 1
                                   RADXA_SVC_FAN_CONTROL_AUTO       = 2
RADXA_SVC_PWM_DEFAULT_CHANNEL = 3  RADXA_SVC_FAN_PWM_MAX            = 255
```

能力位（`caps`，实测 `0x7f` 全支持）：
`PING|PROFILE|LOG|TSENS|PWM|FANCTL|FANCTL_CTRL`。

---

## 4. 用户接口

### hwmon（`/sys/class/hwmon/hwmonN`，`name = radxa_svc_glink`）

| 属性 | 读写 | 语义 |
|---|---|---|
| `pwm1` | rw 0..255 | 风扇占空比。**只有在 manual 模式下才可写**，否则返回 `-EINVAL` |
| `pwm1_enable` | rw | `0` = 强制全速；`1` = 手动（会把当前转速冻结为手动值）；`2` = 自动（固件温控） |

⚠️ `hwmonN` 编号每次启动会变，脚本里一律按 `name` 查找。

### platform profile

```
/sys/class/platform-profile/platform-profile-0/choices   -> quiet performance
echo quiet > .../profile                                  # 切换固件里的两套风扇曲线
```

### debugfs（`/sys/kernel/debug/radxa_svc_glink/`）

`ping version profile log tsens_count tsens_temp tsens_max tsens_all pwm_info pwm_apply pwm_state fan_state stats`

**每个文件的一次读 = 一次 rpmsg 往返**，别高频轮询。

实测快照：

```
version   : major 1 / minor 5 / caps 0x7f
pwm_info  : channel_count 4 / supported_mask 0x8 / default_channel 3
            min_period_ns 3282 / max_period_ns 4294967295
pwm_state : channel 3 / enabled 1 / period_ns 40000 / duty_ns 20580
            actual_period_ns 39375 / actual_duty_ns 20000
fan_state : profile performance / running 1 / emergency 0
            cpu_temp_c 39.1 / gpu_temp_c 38.2
            current_duty_ns 20580 / target_duty_ns 21000
            pwm_channel 3 / pwm_period_ns 40000 / loop_count 335 / fault_count 0
            control_mode 2 / manual_pwm 96
tsens     : num_sensors 46
```

---

## 5. 走过的弯路（**别重犯**）

| 方案 | 结论 |
|---|---|
| 在 SoC **GPIO_119** 上做软件 PWM（`pwm-gpio`）+ `pwm-fan` + thermal zone | ❌ 无效。R473 未贴料，GPIO_119 到 Q20 栅极本来就是断路。 |
| 在 DTB 里把 `pmc8280c_lpg` (`qcom,pm8350c-pwm`) 的 `status` 改成 `okay` | ❌❌ **有害**。这个 PMIC LPG 硬件正是 ADSP 固件在驱动的那一个；`leds-qcom-lpg` 一接管就把输出拉停，MOS 关断，**风扇卡死在 100%**。`ls /sys/class/pwm/` 必须是空的。 |
| 40-pin 排针（GPIO_114/115 = `PWM1_CON`/`PWM2_CON`）外接第二个风扇 | ⚠️ 那两个脚的"PWM"复用功能只是 GCC 的 `gcc_gp2/gcc_gp3` 时钟（占空比恒 50%，不可调），要真调占空比只能当普通 GPIO 做软件 PWM + 外部 N-MOS。 |

### 事故记录：ADSP 服务被压崩过一次

```
01:42:45  第一版工具上板（一次 status 会发 9 个 rpmsg 请求，含 6 次 fan_state）
01:42:53  PDM: service 'charger_process' crash:
          'EX:charger_process:0x3:radxa_svc_glink:0xb4:PC=0x6003'
01:43:10  radxa_svc_glink: error -ETIMEDOUT: failed to read service version
          -> hwmon / debugfs 全部消失
01:44:10  reboot，服务恢复
```

崩溃 PD 名字是 `charger_process`（充电/PD 服务与 radxa_svc 同在 ADSP 镜像里），
不能 100% 断定是被我压崩的，但时间点太巧。**因此工具改成了省请求的写法**
（`status` 只发 4 个请求、`fan_state` 只读 1 次、弃用未实现的 `TSENS_GET_ALL`、
`watch` 的温度从内核 thermal zone 取）。

服务挂掉的自救：**直接重启**（ADSP 会重新起来，服务自动恢复）。

---

## 6. BIOS 开关原理

`Radxa Platform Configuration -> Hypervisor Settings`：

| 取值 | 结果 |
|---|---|
| **Auto** | ✅ 正常。固件按 OS 决定，Linux 拿到 ADSP，SVC 服务可用 |
| **Disabled / Close** | ✅ 正常。hypervisor 完全不介入，ADSP 归 OS |
| **Enable** | ❌ 风扇服务起不来。EL2 那层 hypervisor 接管/中转 ADSP 与 PMIC 资源，Radxa 的 SVC 服务传不出来 -> Linux 没有 hwmon，PMIC LPG 停在复位态 -> 风扇恒速全转 |

---

## 7. 工具用法

```bash
sudo q8b-fan status            # 占空比/模式/曲线档 + 温度（默认命令）
sudo q8b-fan auto              # 交回固件温控 (pwm1_enable=2)
sudo q8b-fan full              # 强制全速 (pwm1_enable=0)
sudo q8b-fan manual 30         # 手动 30%（不带参数 = 冻结当前转速）
sudo q8b-fan profile [quiet|performance]
sudo q8b-fan watch 2           # 实时 duty/模式/cluster0 温度
sudo q8b-fan info              # 固件版本 / PWM 信息 / 链路统计
sudo q8b-fan temps [0..45]     # 固件侧 tsens（一次一路）
sudo q8b-fan log              # 固件日志
```

手写等价命令（注意 `pwm1` 必须先切手动）：

```bash
H=$(for h in /sys/class/hwmon/hwmon*; do [ "$(cat $h/name)" = radxa_svc_glink ] && echo $h; done)
echo 1   > $H/pwm1_enable     # 先切手动
echo 128 > $H/pwm1            # 再写占空比
echo 2   > $H/pwm1_enable     # 交回固件
```
