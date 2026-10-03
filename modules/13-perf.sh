# shellcheck shell=bash
# modules/13-perf.sh — file descriptor limits + TCP BBR congestion control.

mod_perf_plan() {
	cat <<'PLAN'
Write /etc/security/limits.d/99-vps-forge.conf (nofile 65536/1048576)
Write /etc/systemd/system.conf.d/99-vps-forge.conf (DefaultLimitNOFILE)
Enable BBR: sysctl default_qdisc=fq, tcp_congestion_control=bbr
PLAN
}

mod_perf_check() {
	[ -r /etc/security/limits.d/99-vps-forge.conf ] &&
		[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = "bbr" ]
}

mod_perf_run() {
	vf_write_file /etc/security/limits.d/99-vps-forge.conf 644 <<'EOF'
# vps-forge: sane file descriptor limits
*     soft  nofile  65536
*     hard  nofile  1048576
root  soft  nofile  1048576
root  hard  nofile  1048576
EOF
	mkdir -p /etc/systemd/system.conf.d
	vf_write_file /etc/systemd/system.conf.d/99-vps-forge.conf 644 <<'EOF'
[Manager]
DefaultLimitNOFILE=65536:1048576
EOF
	systemctl daemon-reload || true

	vf_write_file /etc/sysctl.d/61-vps-forge-bbr.conf 644 <<'EOF'
## vps-forge: BBR congestion control
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
	sysctl --system >"$VF_TMP_DIR/sysctl.log" 2>&1 || true
	if [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" != "bbr" ]; then
		ui_warn "BBR not active on this kernel — skipped gracefully"
		return 0
	fi
	return 0
}
