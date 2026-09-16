# q8b-fan-curve — Radxa Dragon Q8B 自定义风扇曲线

把 Q8B 官方的（偏激进的）风扇温控曲线换成自己的曲线，**不碰硬件、不抢驱动**。

## 背景：风扇为什么能被"软件接管"

Q8B 的风扇由 **ADSP 上的 Radxa 固件服务**驱动（PMC8280C LPG PWM，channel 3，25 kHz，
经反相 MOS 管到 J6 第 3 脚）。该服务通过 `radxa_svc_glink` 驱动暴露：

```
/sys/class/hwmon/hwmonN/pwm1          风扇转速 0..255
/sys/class/hwmon/hwmonN/pwm1_enable   0=全速 1=手动 2=自动(固件曲线)
```

`pwm1` 的语义实测是**风扇转速**（0=停转，128≈50%，255=全速）——固件内部已经把 MOS 反相处理好了。

本服务把固件切到**手动模式**（`pwm1_enable=1`）然后按自己的曲线写 `pwm1`。
这样固件仍然独占 LPG/PWM 硬件，**不会与 ADSP 抢资源**（这一点很关键：直接用 Linux 的
`pwm-qcom-lpg`/`leds-qcom-lpg` 去接管 LPG 会和固件冲突，导致风扇卡死）。

## 曲线

| 温度（`cluster*`/`gpuss*` 的最大值） | 风扇 |
|---|---|
| < 35 °C | **停转** |
| ≥ 35 °C | 25% |
| ≥ 40 °C | 35% |
| ≥ 50 °C | 50% |
| ≥ 60 °C | 66% |
| ≥ 70 °C | 82% |
| ≥ 80 °C | 96% |
| ≥ `Q8B_FAN_SAFETY_TEMP`（默认 85 °C） | 钳到 100%（**仍由本服务掌控**，降温后自动回到曲线） |

滞回 2 °C，采样 3 s；服务退出/被杀时会把 `pwm1_enable` 交回 `2`（固件自动曲线），
**绝不会把风扇留在低速。**

## 安装 / 使用

```bash
sudo ./install.sh install     # 安装并启用（幂等，保留已有配置）
sudo ./install.sh status      # 查看状态（服务、配置、当前温度与转速）
sudo ./install.sh apply       # 改完配置后重启服务
sudo ./install.sh uninstall   # 卸载（交回固件自动曲线；配置备份到 /root/q8b-fan-curve.backup）
```

## 配置

`/etc/default/q8b-fan-curve`：

| 变量 | 说明 |
|---|---|
| `Q8B_FAN_TRIPS` | 温度阈值（°C，升序） |
| `Q8B_FAN_DUTIES` | 每个阈值对应的转速（%，与 TRIPS 等长升序）；低于第一个阈值即停转 |
| `Q8B_FAN_INTERVAL` | 采样间隔（秒） |
| `Q8B_FAN_HYSTERESIS` | 滞回（°C），避免阈值附近反复变速 |
| `Q8B_FAN_SAFETY_TEMP` | 超温钳制阈值（°C） |
| `Q8B_FAN_SENSOR_PREFIXES` | 温度输入：thermal zone `type` 的前缀，取最大值 |

例：想"更早停转"，把第一档阈值提高（`Q8B_FAN_TRIPS="45 50 60 70 80"`）；
想更保守（风扇更积极），把 `cpu` 加进 `Q8B_FAN_SENSOR_PREFIXES`。

```bash
sudo sed -i 's/^Q8B_FAN_SENSOR_PREFIXES=.*/Q8B_FAN_SENSOR_PREFIXES="cluster cpu gpuss"/' /etc/default/q8b-fan-curve
sudo ./install.sh apply
```

## 几个实测结论（供参考/调参）

- **温度输入为什么默认只取 `cluster`+`gpuss`**：per-core 的 `cpuN-1-thermal` 空闲就比
  cluster 高约 12 °C（实测 `cpu4-1` 空闲 50 °C），纳入后"低温停转"几乎无法触发；
  固件自身用的也是 cluster 级温度（`fan_state: cpu_temp_c ≈ 38`）。
- 默认曲线下**空闲约 42-43 °C、风扇 35%**（官方曲线空闲约 50% 转速、温度 34-38 °C）。
- 8 核满载：61.7 °C → 66%，撤载后逐级回落。
- 8 核满载时 per-core `cpuN-1` 可到 **90 °C+**（未纳入输入）；内核 DTS 的 critical trip
  （105 °C）仍提供兜底保护。

## 依赖与兼容

- 需要 `/sys/class/hwmon/*/name == radxa_svc_glink` 存在，即 **ADSP 风扇服务正在运行**：
  - BIOS `Hypervisor Override = Auto/Disabled`（EL1）→ 固件直接接管风扇 ✓
  - EL2（KVM）→ 需要先修好 DSP 预加载（见另一个项目 `q8b-el2-dsp-venus`）✓
- 纯 Python3 + systemd，无第三方依赖。

## 许可

MIT
