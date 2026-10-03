# shellcheck shell=bash
# modules/26-services.sh — disable unused services, blacklist uncommon filesystems.
# squashfs and vfat are deliberately NOT blacklisted (snap / UEFI compatibility).

mod_services_plan() {
	cat <<'PLAN'
Disable if present: apport.service, motd-news.timer, cups, bluetooth,
ModemManager, avahi-daemon (harmless no-ops when absent)
Blacklist filesystems in /etc/modprobe.d/vps-forge-blacklist.conf:
  cramfs freevxfs jffs2 hfs hfsplus udf $(cfg_is_true services.block_usb && echo '+ usb-storage')
PLAN
}

mod_services_check() { [ -r /etc/modprobe.d/vps-forge-blacklist.conf ]; }

mod_services_run() {
	local s
	for s in apport.service motd-news.timer cups.service cups-browsed.service \
		bluetooth.service ModemManager.service avahi-daemon.service avahi-daemon.socket; do
		systemctl disable --now "$s" >/dev/null 2>&1 || true
	done
	local usb="no"
	cfg_is_true services.block_usb && usb="yes"
	vf_write_file /etc/modprobe.d/vps-forge-blacklist.conf 644 <<EOF
# vps-forge: uncommon filesystems disabled (CIS-informed).
# squashfs and vfat intentionally NOT blacklisted (snap and UEFI need them).
blacklist cramfs
blacklist freevxfs
blacklist jffs2
blacklist hfs
blacklist hfsplus
blacklist udf
install cramfs /bin/true
install freevxfs /bin/true
install jffs2 /bin/true
install hfs /bin/true
install hfsplus /bin/true
install udf /bin/true
$([ "$usb" = "yes" ] && printf 'blacklist usb-storage\ninstall usb-storage /bin/true\n')
EOF
	return 0
}
