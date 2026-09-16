#!/bin/bash
# =====================================================================
#  q8b-fan-curve - installer for the custom Q8B fan curve service
#
#  用法：
#     sudo ./install.sh install     # 安装并启用（幂等）
#     sudo ./install.sh uninstall   # 卸载（交回固件自动曲线）
#     sudo ./install.sh status      # 查看状态
#     sudo ./install.sh apply       # 改完配置后重启服务
#
#  背景：Q8B 的风扇由 ADSP 上的 Radxa 固件服务驱动（PMC8280C LPG PWM，
#  channel 3，25kHz）。固件自带曲线比较激进（约 38°C 就 ~45% 转速）。
#  本服务不抢硬件，而是把固件切到 **手动模式** 并自己写占空比：
#      /sys/class/hwmon/hwmonN/pwm1_enable = 1     (手动)
#      /sys/class/hwmon/hwmonN/pwm1        = 0..255
#  pwm1 语义（实测）：0=停转，128≈50%，255=全速（固件已处理 MOS 反相）。
# =====================================================================
set -uo pipefail

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
SCRIPT=/usr/local/sbin/q8b-fan-curve
CONF=/etc/default/q8b-fan-curve
UNIT=/etc/systemd/system/q8b-fan-curve.service
SERVICE=q8b-fan-curve.service
BAKDIR=/root/q8b-fan-curve.backup
FW_ANDROID=0

die()  { echo "install.sh: $*" >&2; exit 1; }
need_root() { [ "$(id -u)" = 0 ] || die "请用 sudo 运行"; }

hwmon() {   # 打印 radxa_svc_glink 的 hwmon 路径
	local h
	for h in /sys/class/hwmon/hwmon*; do
		[ -r "$h/name" ] || continue
		[ "$(cat "$h/name")" = "radxa_svc_glink" ] && { echo "$h"; return 0; }
	done
	return 1
}

cmd_install() {
	need_root
	[ -f "$SELF_DIR/q8b-fan-curve" ] || die "缺少 q8b-fan-curve"
	command -v python3 >/dev/null || die "需要 python3（apt install python3）"

	install -m 0755 "$SELF_DIR/q8b-fan-curve" "$SCRIPT"
	if [ ! -f "$CONF" ]; then
		install -m 0644 "$SELF_DIR/q8b-fan-curve.default" "$CONF"
		echo "已写入默认配置 $CONF"
	else
		echo "保留已有配置 $CONF（如需重置：cp $SELF_DIR/q8b-fan-curve.default $CONF）"
	fi
	cat > "$UNIT" <<'EOF'
[Unit]
Description=Q8B fan curve (ADSP fan service in manual mode)
After=multi-user.target
ConditionPathExistsGlob=/sys/class/hwmon/hwmon*/pwm1

[Service]
Type=simple
EnvironmentFile=-/etc/default/q8b-fan-curve
ExecStart=/usr/local/sbin/q8b-fan-curve
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
	systemctl daemon-reload
	systemctl enable --now "$SERVICE" >/dev/null 2>&1
	sleep 5
	cmd_status
	echo
	echo "提示：当前曲线用于替换官方策略。温度输入/阈值/转速都在 $CONF 里，改完执行："
	echo "      sudo $SELF_DIR/install.sh apply"
}

cmd_uninstall() {
	need_root
	systemctl disable --now "$SERVICE" >/dev/null 2>&1 || true
	mkdir -p "$BAKDIR"
	[ -f "$CONF" ] && cp -a "$CONF" "$BAKDIR/q8b-fan-curve.conf.$(date +%Y%m%d-%H%M%S)" 2>/dev/null
	rm -f "$UNIT" "$SCRIPT"
	systemctl daemon-reload >/dev/null 2>&1 || true
	echo "已卸载（配置备份在 $BAKDIR）。风扇已交回固件自动曲线。"
}

cmd_apply() {
	need_root
	[ -f "$UNIT" ] || die "尚未安装，先运行：sudo $SELF_DIR/install.sh install"
	systemctl restart "$SERVICE"
	sleep 4
	cmd_status
}

cmd_status() {
	echo "服务      : $(systemctl is-enabled "$SERVICE" 2>&1) / $(systemctl is-active "$SERVICE" 2>&1)"
	if [ -f "$CONF" ]; then
		grep -hE '^Q8B_FAN_' "$CONF" | sed 's/^/  配置    : /'
	fi
	local h; h=$(hwmon) || {
		echo "  警告    : 未找到 radxa_svc_glink（ADSP 风扇服务未运行，需要先修好 DSP）"
		return 1
	}
	local pwm en t best=0 bestn=""
	for z in /sys/class/thermal/thermal_zone*; do
		[ -r "$z/type" ] || continue
		local n; n=$(cat "$z/type")
		case "$n" in cluster*|gpuss*|cpu*) ;; *) continue ;; esac
		local v; v=$(cat "$z/temp" 2>/dev/null) || continue
		[ "$v" -gt "$best" ] && { best=$v; bestn=$n; }
	done
	pwm=$(cat "$h/pwm1" 2>/dev/null); en=$(cat "$h/pwm1_enable" 2>/dev/null)
	printf '  状态      : pwm1_enable=%s (1=手动/本服务控制, 2=固件自动)  pwm1=%s\n' "$en" "$pwm"
	printf '  当前      : 最热 %s = %d.%d C  ->  风扇约 %d%%\n' \
		"$bestn" "$((best / 1000))" "$(((best % 1000) / 100))" "$((pwm * 100 / 255))"
	[ "$en" = "1" ] && echo "  ==> 自定义曲线生效中" || echo "  ==> 未接管（固件自动曲线）"
}

case "${1:-status}" in
	install)   cmd_install ;;
	uninstall) cmd_uninstall ;;
	apply)     cmd_apply ;;
	status)    cmd_status ;;
	*)         sed -n '2,20p' "$0" ;;
esac
