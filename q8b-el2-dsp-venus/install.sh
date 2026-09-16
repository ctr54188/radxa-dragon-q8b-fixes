#!/bin/bash
# =====================================================================
#  q8b-el2-dsp-venus - install script
#
#  Radxa Dragon Q8B: run at EL2 (for KVM) *and* keep the DSP, audio and the
#  hardware video codec working, with the BIOS staying on
#  "Hypervisor Override = Auto".
#
#  Why anything is needed at all:
#    * with Hypervisor=Enabled/Auto+enable-kvm the board boots at EL2, but then
#      the bootloader no longer preloads the ADSP/CDSP, so Linux fails to start
#      them ("start timed out") -> no firmware fan service, no audio.
#    * the VPU driver in the vendor kernel is built for iris/gen2 firmware
#      pairings; the Q8B needs the (older) venus HFI6 path + Gen1 firmware.
#
#  What this installs (nothing is downloaded, everything is in payload/):
#    * locally built  qcom_q6v5_pas.ko   (preloaded-DSP attach + tzmem at EL2)
#    * locally built  venus-core/dec/enc.ko  (HFI6 restored)
#    * locally built  qebspilaa64.efi + q8b-launcher-venus.efi  (UEFI: preload
#      the DSPs during ExitBootServices so Linux only has to attach)
#    * a test DTB  = system DTB + /chosen/radxa,enable-kvm   (Auto -> EL2)
#    * venus fix  on the system DTB as well, so EL1 also gets hardware video
#    * two GRUB entries + a one-shot handoff + a self-healing rearm unit
#
#  usage:  sudo ./install.sh {install|build|enable|disable|arm|status|report|uninstall}
#     install   - preflight, build, deploy (does not change the default boot)
#                 (--force: proceed even if the system looks already patched)
#     enable    - make EL2 the permanent default (+ rearm unit)
#     disable   - back to the old default entry (fixes stay applied)
#     arm       - one-shot: boot EL2 once (recreates the preload flag, reboots)
#     status    - short state summary
#     report    - detailed state (DSP, venus, fan, audio, launcher log)
#     uninstall - undo everything
#
#  Requires: Armbian 26.x for Q8B (vendor sc8280xp kernel), the matching
#  linux-headers-vendor-sc8280xp package, and /boot/efi mounted.
# =====================================================================
set -uo pipefail

VERSION="1.0.0"
FORCE=0
KVER=$(uname -r)
SELF_DIR=$(cd "$(dirname "$0")" && pwd)
PAYLOAD="$SELF_DIR/payload"
WORK=/root/q8b-el2-dsp-venus

BASE=/boot/armbian-dtb-$KVER
TESTDTB=$BASE-el2kvm
MODDIR=/lib/modules/$KVER/kernel/drivers/remoteproc
STOCK=$MODDIR/qcom_q6v5_pas.ko.zst
PAS_SRC=$WORK/src/pas-attach-fix
VENUS_SRC=$WORK/src/venus-el2
VENUS_DST=/lib/modules/$KVER/kernel/drivers/media/platform/qcom/venus
FW=/lib/firmware/qcom/vpu
BAK=$WORK/backup
ESP=/boot/efi
ESPDIR=$ESP/EFI/q8b-test-20260909
GRUBHOOK=/etc/grub.d/43_q8b_el2fan
CUSTOM=/boot/grub/custom.cfg
DEFAULT_GRUB=/etc/default/grub
ARMBIAN_GRUBD=/etc/default/grub.d/98-armbian.cfg
PDOVR=/etc/systemd/system/pd-mapper.service.d/override.conf
REARM_SCRIPT=/usr/local/sbin/q8b-el2fan-rearm
REARM_UNIT=/etc/systemd/system/q8b-el2fan-rearm.service

die()  { echo "q8b-el2: $*" >&2; exit 1; }
warn() { echo "q8b-el2[!] $*" >&2; }
need_root() { [ "$(id -u)" = 0 ] || die "run with sudo"; }
regen() { update-grub >/dev/null 2>&1 || grub-mkconfig -o /boot/grub/grub.cfg; }

# --------------------------------------------------------------- helpers
entry_index() {   # $1 = awk pattern matched against the menuentry title
	awk -v pat="$1" '/^[[:space:]]*menuentry[[:space:]]/{
		m=$0; if (m ~ pat) { print n; exit } n++
	}' /boot/grub/grub.cfg
}

# apply the venus/VPU edits to a DTB in place (idempotent)
venus_dtb_patch() {
	local f="$1"
	[ -f "$f" ] || return 1
	dtc -I dtb -O dts -o /tmp/vp.dts "$f" 2>/dev/null || return 1
	python3 - /tmp/vp.dts <<-'PY' || return 1
	import re, sys
	p = sys.argv[1]
	s = open(p).read()

	def match_brace(t, st):
	    d = 0
	    for i in range(st, len(t)):
	        if t[i] == '{':
	            d += 1
	        elif t[i] == '}':
	            d -= 1
	            if d == 0:
	                return i
	    raise ValueError('unbalanced')

	m = re.search(r'\n[ \t]*video-codec@aa00000[ \t]*\{', s)
	if not m:
	    sys.exit("video node not found")
	b = s.index('{', m.start()); e = match_brace(s, b)
	node = s[m.start():e + 1]
	if ('video-firmware' in node and 'qcom,sm8250-venus' in node
	        and 'vpu20_p4.mbn' in node):
	    print("      venus dt: already patched")
	    sys.exit(0)

	sm = re.search(r'\n[ \t]*iommu@15000000[ \t]*\{', s)
	if not sm:
	    sys.exit("apps_smmu node not found")
	sb = s.index('{', sm.start()); se = match_brace(s, sb)
	pm = re.search(r'phandle = <0x([0-9a-f]+)>;', s[sb:se])
	if not pm:
	    sys.exit("apps_smmu phandle not found")
	ph = int(pm.group(1), 16)

	new = re.sub(r'compatible = "[^"]*"(?:, "[^"]*")*;',
	             'compatible = "qcom,sm8250-venus";', node, count=1)
	new = re.sub(r'firmware-name = "[^"]*";',
	             'firmware-name = "qcom/vpu/vpu20_p4.mbn";', new, count=1)
	if 'compatible = "qcom,sm8250-venus";' not in new:
	    sys.exit("compatible not rewritten")
	if 'video-firmware' not in new:
	    indent = re.search(r'\n([ \t]*)', new).group(1)
	    close = new.rfind('\n')
	    new = (new[:close] + '\n\n' + indent + '\tvideo-firmware {\n'
	           + indent + '\t\tiommus = <0x%x 0x2a02 0x400>;\n' % ph
	           + indent + '\t};\n' + indent + new[close:])
	s = s.replace(node, new)
	open(p, 'w').write(s)
	print("      venus dt: compatible=qcom,sm8250-venus firmware=vpu20_p4.mbn"
	      " iommus=<0x%x 0x2a02 0x400>" % ph)
	PY
	dtc -I dts -O dtb -o "$f.new" /tmp/vp.dts 2>/dev/null || return 1
	mv -f "$f.new" "$f"
}

# add /chosen/radxa,enable-kvm = <1> so BIOS "Auto" picks EL2 (idempotent)
kvm_dtb_patch() {
	local f="$1"
	dtc -I dtb -O dts -o /tmp/kv.dts "$f" 2>/dev/null || return 1
	python3 - /tmp/kv.dts <<-'PY' || return 1
	import sys
	p = sys.argv[1]
	s = open(p).read()
	if 'radxa,enable-kvm' in s:
	    print("      kvm dt: already patched")
	    sys.exit(0)
	a = '\tchassis-type = "'
	i = s.index(a)
	eol = s.index('\n', i) + 1
	s = s[:eol] + '\n\tchosen {\n\t\tradxa,enable-kvm = <0x01>;\n\t};\n' + s[eol:]
	open(p, 'w').write(s)
	print("      kvm dt: /chosen/radxa,enable-kvm = <1>")
	PY
	dtc -I dts -O dtb -o "$f.new" /tmp/kv.dts 2>/dev/null || return 1
	mv -f "$f.new" "$f"
}

# venus fix for the EL1 (default) boot: system DTB + iris blacklist in the
# Armibian grub override file (that is what the generated entries really use)
el1_venus_fix() {
	local changed=0
	if ! dtc -I dtb -O dts -o - "$BASE" 2>/dev/null | grep -q 'video-firmware'; then
		[ -f "$BAK/armbian-dtb.orig" ] || cp -a "$BASE" "$BAK/armbian-dtb.orig"
		if venus_dtb_patch "$BASE"; then changed=1; else warn "EL1 DTB venus patch failed"; fi
	fi
	if [ -f "$ARMBIAN_GRUBD" ] && ! grep -q 'module_blacklist=qcom_iris' "$ARMBIAN_GRUBD"; then
		[ -f "$BAK/98-armbian.cfg.orig" ] || cp -a "$ARMBIAN_GRUBD" "$BAK/98-armbian.cfg.orig"
		sed -i 's|^\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)"|\1 module_blacklist=qcom_iris"|' "$ARMBIAN_GRUBD"
		grep -q 'module_blacklist=qcom_iris' "$ARMBIAN_GRUBD" && changed=1 || warn "could not add module_blacklist"
	fi
	[ "$changed" = 1 ] && echo "[deploy] EL1 entries: venus DTB fix + module_blacklist=qcom_iris"
	return 0
}

install_rearm() {
	cat > "$REARM_SCRIPT" <<-'EOF'
	#!/bin/bash
	# Re-arm the one-shot DSP preload flag so the NEXT boot preloads the DSPs.
	set -u
	D=/boot/efi/EFI/q8b-test-20260909
	[ -f "$D/q8b-launcher-venus.efi" ] || exit 0
	[ -e /dev/kvm ] || exit 0
	[ -f "$D/dsp-once.flag" ] && exit 0
	: > "$D/dsp-once.flag"
	sync
	st=$(cat /sys/class/remoteproc/remoteproc0/state 2>/dev/null || echo '?')
	logger -t q8b-el2fan-rearm "re-armed DSP preload flag (adsp=$st)"
	EOF
	chmod 0755 "$REARM_SCRIPT"
	cat > "$REARM_UNIT" <<-'EOF'
	[Unit]
	Description=Q8B: re-arm the one-shot DSP preload flag for the next EL2 boot
	After=multi-user.target
	ConditionPathExists=/boot/efi/EFI/q8b-test-20260909/q8b-launcher-venus.efi

	[Service]
	Type=oneshot
	ExecStart=/usr/local/sbin/q8b-el2fan-rearm

	[Install]
	WantedBy=multi-user.target
	EOF
	systemctl daemon-reload >/dev/null 2>&1 || true
}

# -------------------------------------------------------------- preflight
cmd_preflight() {
	need_root
	[ -e /proc/device-tree/compatible ] && tr -d '\0' < /proc/device-tree/compatible | grep -q 'radxa,dragon-q8b' \
		|| warn "this does not look like a Radxa Dragon Q8B"
	findmnt -no FSTYPE /boot/efi 2>/dev/null | grep -q vfat \
		|| die "/boot/efi is not a mounted vfat ESP - mount it first"
	[ -d "/lib/modules/$KVER/build" ] || die "missing kernel headers: sudo apt install linux-headers-vendor-sc8280xp (matching $KVER)"
	local missing=()
	for t in dtc python3 make gcc objcopy; do
		command -v "$t" >/dev/null 2>&1 || missing+=("$t")
	done
	if [ "${#missing[@]}" -gt 0 ]; then
		echo "缺少构建工具: ${missing[*]}"
		echo "建议: sudo apt-get update && sudo apt-get install -y device-tree-compiler python3 build-essential"
		die "install them and re-run"
	fi
	[ -f /lib/firmware/qcom/vpu/vpu20_p4.mbn ] \
		|| warn "Gen1 VPU firmware /lib/firmware/qcom/vpu/vpu20_p4.mbn is missing - venus may fail (armbian-firmware package?)"
	# refuse to "back up" an already patched system: that backup could not be
	# used to go back to the original firmware later.
	if [ ! -f "$STOCK" ] || [ -f "$MODDIR/qcom_q6v5_pas.ko" ]; then
		warn "系统已经处于已打补丁状态（$MODDIR 下没有 stock 的 qcom_q6v5_pas.ko.zst）"
		warn "如果这是同一个修复的旧版本，请先用它的 uninstall/revert 还原，再运行本脚本"
		if [ "$FORCE" != 1 ]; then
			die "已存在补丁；确认要继续请加 --force（备份将记录当前状态，不能用来还原到原始系统）"
		fi
		warn "--force：继续，备份将记录当前状态"
	fi
	echo "[preflight] ok  (kernel $KVER, headers present, ESP mounted)"
}

# ------------------------------------------------------------------ build
cmd_build() {
	need_root
	mkdir -p "$WORK"
	if [ ! -d "$PAS_SRC" ] || [ ! -d "$VENUS_SRC" ]; then
		echo "[build] extracting payload sources into $WORK/src"
		mkdir -p "$WORK/src"
		tar xzf "$PAYLOAD/pas-attach-fix-src.tgz" -C "$WORK/src"
		tar xzf "$PAYLOAD/venus-el2-src.tgz" -C "$WORK/src"
		tar xzf "$PAYLOAD/qebspil-src.tgz" -C "$WORK/src"
	fi

	local fails=0
	echo "[build] qcom_q6v5_pas.ko (preloaded-DSP attach + tzmem at EL2)"
	if make -C "/lib/modules/$KVER/build" M="$PAS_SRC" modules >/tmp/pas-build.log 2>&1; then
		echo "        ok: $(stat -c%s "$PAS_SRC/qcom_q6v5_pas.ko") B"
	else
		tail -8 /tmp/pas-build.log; die "PAS 模块编译失败（见 /tmp/pas-build.log）"
	fi

	echo "[build] venus modules (HFI6)"
	if make -C "/lib/modules/$KVER/build" M="$VENUS_SRC" modules >/tmp/venus-build.log 2>&1; then
		echo "        ok: $(ls "$VENUS_SRC"/*.ko | wc -l) modules"
	else
		tail -8 /tmp/venus-build.log; die "venus 模块编译失败（见 /tmp/venus-build.log）"
	fi

	echo "[build] qebspil + launcher (UEFI)"
	if make -C "$WORK/src/qebspil" -j"$(nproc)" QEBSPIL_ALWAYS_START=1 >/tmp/qeb-build.log 2>&1 \
	   && make -C "$WORK/src/qebspil" -j"$(nproc)" "$WORK/src/qebspil/out/q8b-launcher-venus.efi" >>/tmp/qeb-build.log 2>&1; then
		echo "        ok: $(stat -c%s "$WORK/src/qebspil/out/qebspilaa64.efi") B + launcher"
	else
		warn "qebspil build failed - falling back to the prebuilt EFI files in payload/"
		fails=$((fails + 1))
	fi
	[ "$fails" = 0 ] && echo "[build] all artifacts built on this board"
	return 0
}

# ----------------------------------------------------------------- deploy
cmd_install() {
	need_root
	cmd_preflight
	cmd_build
	mkdir -p "$BAK"

	# --- backups of everything we replace (an existing backup is NEVER overwritten) ---
	mkdir -p "$BAK"
	if [ ! -f "$BAK/qcom_q6v5_pas.ko.zst.orig" ]; then
		if [ -f "$STOCK" ]; then
			cp -a "$STOCK" "$BAK/qcom_q6v5_pas.ko.zst.orig"
		else
			warn "原始 qcom_q6v5_pas.ko.zst 已不存在，无法备份 -> uninstall 无法还原它"
			warn "（重复安装时请确认 $BAK 里已有正确的原始备份）"
		fi
	fi
	[ -f "$BAK/grub.cfg.orig" ] || cp -a /boot/grub/grub.cfg "$BAK/grub.cfg.orig"
	for m in venus-core venus-dec venus-enc; do
		if [ ! -f "$BAK/$m.ko.zst.orig" ]; then
			if [ -f "$VENUS_DST/$m.ko.zst" ]; then
				cp -a "$VENUS_DST/$m.ko.zst" "$BAK/$m.ko.zst.orig"
			else
				warn "原始 $m.ko.zst 已不存在，无法备份 -> uninstall 无法还原它"
			fi
		fi
	done

	# --- safety: never touch /lib/modules unless every artifact exists ---
	local art
	for art in "$PAS_SRC/qcom_q6v5_pas.ko" "$VENUS_SRC/venus-core.ko" \
	           "$VENUS_SRC/venus-dec.ko" "$VENUS_SRC/venus-enc.ko"; do
		[ -f "$art" ] || die "构建产物缺失: $art （先跑 '$0 build' 并查看 /tmp/*-build.log）"
	done
	[ -f "$ESPDIR/../q8b-test-20260909/qebspilaa64.efi" ] 2>/dev/null || true

	# --- locally built kernel modules (stock copies are kept) ---
	cp -f "$PAS_SRC/qcom_q6v5_pas.ko" "$MODDIR/qcom_q6v5_pas.ko"
	rm -f "$MODDIR/qcom_q6v5_pas.ko.zst"
	for m in venus-core venus-dec venus-enc; do
		cp -f "$VENUS_SRC/$m.ko" "$VENUS_DST/$m.ko"
		rm -f "$VENUS_DST/$m.ko.zst"
	done
	depmod -a "$KVER"
	echo "[deploy] modules installed (PAS + venus), stock copies in $BAK"

	# --- redundant user space pd-mapper (kernel has CONFIG_QCOM_PD_MAPPER) ---
	if systemctl list-unit-files pd-mapper.service >/dev/null 2>&1; then
		[ -f "$PDOVR" ] && [ ! -f "$BAK/pd-mapper.override.conf.orig" ] && cp -a "$PDOVR" "$BAK/pd-mapper.override.conf.orig"
		systemctl disable --now pd-mapper.service >/dev/null 2>&1 || true
		rm -f "$PDOVR"; rmdir "$(dirname "$PDOVR")" 2>/dev/null || true
		systemctl daemon-reload >/dev/null 2>&1 || true
		systemctl reset-failed pd-mapper.service >/dev/null 2>&1 || true
		echo "[deploy] redundant pd-mapper.service disabled"
	fi

	# --- DTBs ---
	el1_venus_fix
	cp -f "$BASE" "$TESTDTB"
	venus_dtb_patch "$TESTDTB"
	kvm_dtb_patch "$TESTDTB"

	# --- UEFI payload on the ESP ---
	local ROOTUUID ESPUUID
	ROOTUUID=$(findmnt -no UUID /); ESPUUID=$(blkid -s UUID -o value "$(findmnt -no SOURCE /boot/efi)")
	mkdir -p "$ESPDIR" "$ESP/firmware/qcom/sc8280xp/radxa/dragon-q8b"
	if [ -x "$WORK/src/qebspil/out/qebspilaa64.efi" ]; then
		cp -f "$WORK/src/qebspil/out/qebspilaa64.efi" "$WORK/src/qebspil/out/q8b-launcher-venus.efi" "$ESPDIR/"
	else
		cp -f "$PAYLOAD/qebspilaa64.efi" "$PAYLOAD/q8b-launcher-venus.efi" "$ESPDIR/"
	fi
	cp -f /lib/firmware/qcom/sc8280xp/radxa/dragon-q8b/qcadsp8280.mbn "$ESP/firmware/qcom/sc8280xp/radxa/dragon-q8b/"
	cp -f /lib/firmware/qcom/sc8280xp/qccdsp8280.mbn "$ESP/firmware/qcom/sc8280xp/"
	cp -f "$ESP/EFI/BOOT/BOOTAA64.EFI" "$ESPDIR/grub-venus.efi"
	: > "$ESPDIR/dsp-once.flag"
	sync
	echo "[deploy] ESP: $(ls "$ESPDIR" | tr '\n' ' ')"

	# --- GRUB entries ---
	rm -f "$CUSTOM"
	cat > "$GRUBHOOK" <<EOF
#!/bin/sh
exec tail -n +3 \$0
menuentry 'Q8B EL2 direct (no DSP preload)' \$menuentry_id_option 'q8b-el2-direct' {
	insmod gzio
	insmod part_gpt
	insmod ext2
	search --no-floppy --fs-uuid --set=root $ROOTUUID
	linux /boot/vmlinuz-$KVER root=UUID=$ROOTUUID ro clk_ignore_unused pd_ignore_unused arm64.nopauth efi=noruntime console=tty0 console=ttyMSM0 panic=30 module_blacklist=qcom_iris
	initrd /boot/initrd.img-$KVER
	devicetree $TESTDTB
}
menuentry 'Q8B EL2 + DSP preload (qebspil)' \$menuentry_id_option 'q8b-el2-preload' {
	insmod part_gpt
	insmod fat
	search --no-floppy --fs-uuid --set=root $ESPUUID
	set next_entry=4
	save_env next_entry
	if chainloader /EFI/q8b-test-20260909/q8b-launcher-venus.efi; then
		boot
	fi
	search --no-floppy --fs-uuid --set=root $ROOTUUID
	configfile (\$root)/boot/grub/grub.cfg
}
EOF
	chmod 0755 "$GRUBHOOK"
	regen
	local didx; didx=$(entry_index 'EL2 direct')
	[ "$didx" = "4" ] || die "direct entry at index $didx, expected 4 (another menuentry was added?)"
	install_rearm
	echo "[deploy] grub entries ok (direct=4, preload=$(entry_index 'DSP preload \\(qebspil\\)'))"
	echo
	echo "完成。接下来："
	echo "  sudo $SELF_DIR/install.sh enable   # 让 EL2 成为常驻默认（推荐）"
	echo "  sudo reboot"
	echo "或先一次性验证："
	echo "  sudo $SELF_DIR/install.sh arm      # 一次性进 EL2 并重启"
}

# ---------------------------------------------------------------- enable
cmd_enable() {
	need_root
	local idx el1
	idx=$(entry_index 'DSP preload \\(qebspil\\)')
	[ -n "$idx" ] || die "preload entry not found - run install first"
	el1=$(entry_index 'Armbian GNU/Linux')
	[ -f "$BAK/default-grub.orig" ] || cp -a "$DEFAULT_GRUB" "$BAK/default-grub.orig"
	sed -i "s|^GRUB_DEFAULT=.*|GRUB_DEFAULT=$idx|" "$DEFAULT_GRUB"
	regen
	install_rearm
	systemctl enable q8b-el2fan-rearm.service >/dev/null 2>&1 || warn "could not enable the rearm unit"
	[ -d "$ESPDIR" ] && : > "$ESPDIR/dsp-once.flag"
	sync
	echo "EL2 现在是常驻默认启动："
	echo "  $(grep -E '^GRUB_DEFAULT' "$DEFAULT_GRUB")   (index $idx = Q8B EL2 + DSP preload)"
	echo "  rearm 单元   : $(systemctl is-enabled q8b-el2fan-rearm.service 2>&1)  （每次健康 EL2 启动后重建 flag）"
	echo "  临时回 EL1   : sudo grub-editenv /boot/grub/grubenv set next_entry=${el1:-0} && sudo reboot"
	echo "  撤销常驻     : sudo $SELF_DIR/install.sh disable"
}

cmd_disable() {
	need_root
	sed -i "s|^GRUB_DEFAULT=.*|GRUB_DEFAULT=0|" "$DEFAULT_GRUB"
	systemctl disable --now q8b-el2fan-rearm.service >/dev/null 2>&1 || true
	regen
	echo "已恢复原默认项：$(grep -E '^GRUB_DEFAULT' "$DEFAULT_GRUB")（修复内容保留）"
}

cmd_arm() {
	need_root
	[ -d "$ESPDIR" ] || die "ESP payload missing - run install first"
	: > "$ESPDIR/dsp-once.flag"
	local idx; idx=$(entry_index 'DSP preload \\(qebspil\\)')
	[ -n "$idx" ] || die "preload entry not found"
	grub-editenv /boot/grub/grubenv set "next_entry=$idx" || die "grub-editenv failed"
	[ "$(grub-editenv /boot/grub/grubenv list)" = "next_entry=$idx" ] || die "grubenv write failed"
	echo "已武装一次性 EL2 启动 (next_entry=$idx)，3 秒后重启…"
	sync
	(sleep 3; reboot) &
}

# ---------------------------------------------------------------- report
cmd_report() {
	echo "=== this boot ==="
	echo "  boot    : $(uptime -s)   up $(uptime -p)"
	echo "  cmdline : $(cut -c1-150 /proc/cmdline)"
	echo "  EL      : $([ -e /dev/kvm ] && echo 'EL2 (KVM)' || echo 'EL1')"
	echo "  chosen  : $(ls /proc/device-tree/chosen/ 2>/dev/null | tr '\n' ' ')"
	echo "  smmu    : $(tr -d '\0' < /proc/device-tree/soc@0/iommu@14f80000/status 2>/dev/null)"
	echo
	echo "=== DSP ==="
	for r in /sys/class/remoteproc/remoteproc*; do
		printf "  %-6s %s\n" "$(cat "$r/name" 2>/dev/null)" "$(cat "$r/state" 2>/dev/null)"
	done
	dmesg | grep -iE "q6v5|attaching to|start timed out" | tail -4 | sed 's/^/      /'
	echo
	echo "=== VPU / venus ==="
	dmesg | grep -iE "qcom-venus|qcom-iris" | tail -3 | sed 's/^/      /'
	echo "  video nodes: $(ls /dev/video* 2>/dev/null | tr '\n' ' ')"
	echo
	echo "=== fan / audio ==="
	local H=""
	for h in /sys/class/hwmon/hwmon*; do
		[ "$(cat "$h/name" 2>/dev/null)" = radxa_svc_glink ] && H=$h
	done
	[ -n "$H" ] && echo "  radxa_svc_glink: $H pwm1=$(cat "$H/pwm1") enable=$(cat "$H/pwm1_enable")" \
	             || echo "  radxa_svc_glink: ABSENT (fan service not up)"
	echo "  sound cards: $(grep -c '^\s*[0-9]' /proc/asound/cards 2>/dev/null)   failed units: $(systemctl --failed --no-legend 2>/dev/null | wc -l)"
	echo
	echo "=== launcher log (ESP) ==="
	tail -6 "$ESPDIR/launcher.log" 2>/dev/null | sed 's/^/      /'
	echo "  dsp-once.flag: $(ls "$ESPDIR/dsp-once.flag" >/dev/null 2>&1 && echo present || echo consumed)"
}

cmd_status() {
	echo "version : $VERSION"
	echo "EL      : $([ -e /dev/kvm ] && echo EL2 || echo EL1)"
	echo "default : $(grep -E '^GRUB_DEFAULT' "$DEFAULT_GRUB" 2>/dev/null)  rearm: $(systemctl is-enabled q8b-el2fan-rearm.service 2>&1)"
	echo "flag    : $(ls "$ESPDIR/dsp-once.flag" >/dev/null 2>&1 && echo present || echo consumed)"
	echo "modules : pas=$(modinfo -F filename qcom_q6v5_pas 2>/dev/null | sed 's|.*/||')  venus_patched=$(ls "$VENUS_DST"/*.ko 2>/dev/null | wc -l)"
	echo "DTBs    : base venus=$(dtc -I dtb -O dts -o - "$BASE" 2>/dev/null | grep -c video-firmware)  test=$([ -f "$TESTDTB" ] && echo present || echo missing)"
	echo "grub    : hook=$([ -f "$GRUBHOOK" ] && echo present || echo missing)  entries: direct=$(entry_index 'EL2 direct') preload=$(entry_index 'DSP preload \\(qebspil\\)')"
}

# -------------------------------------------------------------- uninstall
cmd_uninstall() {
	need_root
	[ -f "$BAK/qcom_q6v5_pas.ko.zst.orig" ] && {
		rm -f "$MODDIR/qcom_q6v5_pas.ko"
		cp -a "$BAK/qcom_q6v5_pas.ko.zst.orig" "$STOCK"
	}
	for m in venus-core venus-dec venus-enc; do
		if [ -f "$BAK/$m.ko.zst.orig" ]; then
			rm -f "$VENUS_DST/$m.ko"
			cp -a "$BAK/$m.ko.zst.orig" "$VENUS_DST/$m.ko.zst"
		fi
	done
	depmod -a "$KVER"
	[ -f "$BAK/armbian-dtb.orig" ] && cp -a "$BAK/armbian-dtb.orig" "$BASE"
	[ -f "$BAK/default-grub.orig" ] && cp -a "$BAK/default-grub.orig" "$DEFAULT_GRUB"
	[ -f "$BAK/98-armbian.cfg.orig" ] && cp -a "$BAK/98-armbian.cfg.orig" "$ARMBIAN_GRUBD"
	if [ -f "$BAK/pd-mapper.override.conf.orig" ]; then
		mkdir -p /etc/systemd/system/pd-mapper.service.d
		cp -a "$BAK/pd-mapper.override.conf.orig" "$PDOVR"
	fi
	systemctl enable pd-mapper.service >/dev/null 2>&1 || true
	systemctl disable --now q8b-el2fan-rearm.service >/dev/null 2>&1 || true
	rm -f "$REARM_UNIT" "$REARM_SCRIPT" "$GRUBHOOK" "$CUSTOM" "$TESTDTB"
	rm -rf "$ESPDIR"
	rm -f "$ESP/firmware/qcom/sc8280xp/qccdsp8280.mbn"
	rm -rf "$ESP/firmware/qcom/sc8280xp/radxa"
	systemctl daemon-reload >/dev/null 2>&1 || true
	regen
	echo "已全部还原（模块/DTB/GRUB/ESP/pd-mapper/rearm）。重启后回到原始 EL1 配置。"
}

[ "${1:-}" = "--force" ] && { FORCE=1; shift; }
case "${1:-}" in
	install)   cmd_install ;;
	build)     cmd_build ;;
	enable)    cmd_enable ;;
	disable)   cmd_disable ;;
	arm)       cmd_arm ;;
	report)    cmd_report ;;
	status)    cmd_status ;;
	uninstall) cmd_uninstall ;;
	*) sed -n '2,34p' "$0" ;;
esac
