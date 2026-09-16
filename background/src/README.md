# 参考源码

> `q8b-fan.c` 是本项目自己的 C 实现（MIT），放在这里只是为了和源码放一起。
> 下面三个 `.c` / `.dtsi` 是**未做任何修改**的上游副本（GPL-2.0-only）。

这里的文件来自 **radxa/kernel**，只是为了给 `NOTES.md` 里的分析提供出处，
请不要修改它们，需要的话请从上游重新拉取：

```
repo   : https://github.com/radxa/kernel
branch : linux-7.0.11
commit : 395349af3be0e89fe36011165d90f7a5061c5d84
```

| 文件 | 来源 | 作用 |
|---|---|---|
| `q8b-fan.c` | 本项目（MIT） | C 实现，等价的 CLI，`make` 编译成单文件二进制 |
| `radxa_svc_glink.c` | `drivers/platform/arm64/radxa_svc_glink.c` | 风扇服务的 Linux 驱动：hwmon (`pwm1` / `pwm1_enable`)、platform-profile、debugfs，以及和 ADSP 通信的 rpmsg 协议（opcode 定义都在里面） |
| `leds-qcom-lpg.c` | `drivers/leds/rgb/leds-qcom-lpg.c` | PMIC 的 LPG PWM 驱动，`qcom,pm8350c-pwm` 由它接管（`lpg_add_pwm()` 会注册 pwmchip）。这就是**不能在设备树里 enable 该节点**的原因：它会和 ADSP 固件抢同一个 PWM |
| `sc8280xp-pmics.dtsi` | `arch/arm64/boot/dts/qcom/sc8280xp-pmics.dtsi` | 里面定义了 `pmc8280c_lpg: pwm { ... status = "disabled"; }` |

## 许可

以上文件均为 **GPL-2.0-only**（文件头有 SPDX 标识），版权归其各自作者所有。
它们在这里仅作为参考副本分发；对它们的使用、修改、再分发须遵守 GPL-2.0。
本仓库根目录的 MIT 许可**不适用于** `src/` 目录下的这些上游文件。
