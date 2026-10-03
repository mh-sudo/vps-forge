# shellcheck shell=bash
# modules/15-zram.sh — optional zram swap via systemd-zram-generator.

mod_zram_plan() {
	cat <<'PLAN'
Install systemd-zram-generator; write /etc/systemd/zram-generator.conf
  [zram0] zram-size = min(ram / 2, 4096), swap-priority = 100
Start zram0. (Coexists with the swap file; zram is used first.)
PLAN
}

mod_zram_ask() {
	if [ "$VF_NONINTERACTIVE" != "1" ]; then
		if vf_ask_bool perf.zram "Enable zram swap (compressed RAM swap)?" n; then cfg_set perf.zram y; else cfg_set perf.zram n; fi
	fi
}

mod_zram_check() { [ -e /dev/zram0 ]; }

mod_zram_run() {
	if ! cfg_is_true perf.zram && [ "$VF_NONINTERACTIVE" = "1" ]; then
		return 0
	fi
	if ! vf_pkg_install systemd-zram-generator; then
		ui_error "systemd-zram-generator is not available on this OS — skipping zram"
		return 0
	fi
	vf_write_file /etc/systemd/zram-generator.conf 644 <<'EOF'
[zram0]
zram-size = min(ram / 2, 4096)
swap-priority = 100
EOF
	systemctl daemon-reload || true
	systemctl start systemd-zram-setup@zram0 2>/dev/null || true
	if [ ! -e /dev/zram0 ]; then
		ui_warn "zram0 did not activate — it will activate after reboot"
	fi
	return 0
}
