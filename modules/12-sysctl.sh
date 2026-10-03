# shellcheck shell=bash
# modules/12-sysctl.sh — kernel/sysctl hardening (CIS-informed; Docker-safe).
# Deliberately does NOT touch net.ipv4.ip_forward (Docker requires it = 1).

VF_SYSCTL_CONF=/etc/sysctl.d/60-vps-forge.conf

mod_sysctl_plan() {
	cat <<'PLAN'
Write $VF_SYSCTL_CONF (kernel + network hardening):
  rp_filter, syncookies, tcp_rfc1337, block redirects/source-routing (v4+v6),
  log_martians, randomize_va_space=2, kptr_restrict=2, dmesg_restrict=1,
  perf_event_paranoid=3, kexec_load_disabled, suid_dumpable=0,
  protected hardlinks/symlinks/fifos/regular, bpf_jit_harden, yama ptrace,
  vm.swappiness=10, vfs_cache_pressure=50
Apply with: sysctl --system
NOTE: ip_forward is intentionally NOT modified (Docker needs it enabled).
PLAN
}

mod_sysctl_check() {
	[ -r "$VF_SYSCTL_CONF" ] || return 1
	local k
	for k in kernel.kptr_restrict kernel.dmesg_restrict net.ipv4.tcp_syncookies kernel.randomize_va_space; do
		sysctl -n "$k" 2>/dev/null | grep -qx "$(grep "^$k" "$VF_SYSCTL_CONF" 2>/dev/null | cut -d= -f2 | tr -d ' ')" || return 1
	done
}

mod_sysctl_run() {
	vf_write_file "$VF_SYSCTL_CONF" 644 <<'EOF'
## vps-forge kernel hardening (CIS Ubuntu benchmark informed)
## Docker-safe: net.ipv4.ip_forward intentionally not set here.

# network
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_rfc1337 = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0

# kernel
kernel.randomize_va_space = 2
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.perf_event_paranoid = 3
kernel.kexec_load_disabled = 1
kernel.yama.ptrace_scope = 1
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 2

# filesystem
fs.suid_dumpable = 0
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2

# vm
vm.swappiness = 10
vm.vfs_cache_pressure = 50
EOF
	if ! sysctl --system >"$VF_TMP_DIR/sysctl.log" 2>&1; then
		tail -10 "$VF_TMP_DIR/sysctl.log" >&2 || true
		ui_warn "some sysctl keys failed to apply (often keys unavailable on KVM) — see log"
	fi
	return 0
}
