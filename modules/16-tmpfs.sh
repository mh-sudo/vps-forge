# shellcheck shell=bash
# modules/16-tmpfs.sh — optional tmpfs /tmp (RAM-backed, wiped on boot).

mod_tmpfs_plan() {
	cat <<'PLAN'
Add fstab entry: tmpfs /tmp tmpfs rw,nosuid,nodev,noatime,size=1G,mode=1777 0 0
Mount /tmp as tmpfs. WARNING: /tmp contents are wiped on every boot and
consume RAM (size cap = 1 GB by default).
PLAN
}

mod_tmpfs_ask() {
	if [ "$VF_NONINTERACTIVE" != "1" ]; then
		if vf_ask_bool perf.tmpfs_tmp "Mount /tmp as tmpfs (faster, wiped on boot)?" n; then cfg_set perf.tmpfs_tmp y; else cfg_set perf.tmpfs_tmp n; fi
	fi
}

mod_tmpfs_check() { [ "$(findmnt -n -o FSTYPE /tmp 2>/dev/null)" = "tmpfs" ]; }

mod_tmpfs_run() {
	if ! cfg_is_true perf.tmpfs_tmp && [ "$VF_NONINTERACTIVE" = "1" ]; then return 0; fi
	ui_warn "/tmp will be RAM-backed and WIPED ON REBOOT (up to $(cfg_get perf.tmpfs_size 1G) of RAM when full). Files currently in /tmp become hidden until the next reboot."
	if ! grep -qE '^\s*[^#].*\s/tmp\s+tmpfs' /etc/fstab; then
		vf_backup_file /etc/fstab
		printf 'tmpfs /tmp tmpfs rw,nosuid,nodev,noatime,size=%s,mode=1777 0 0\n' "$(cfg_get perf.tmpfs_size 1G)" >>/etc/fstab
	fi
	mount /tmp 2>/dev/null || mount -a 2>/dev/null || true
	mod_tmpfs_check || ui_warn "/tmp did not mount as tmpfs — will apply at next boot"
	return 0
}
