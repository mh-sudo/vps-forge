# shellcheck shell=bash
# modules/23-fail2ban.sh — fail2ban sshd jail (systemd backend, nftables bans).

mod_fail2ban_plan() {
	cat <<PLAN
Install fail2ban; write /etc/fail2ban/jail.d/vps-forge.local:
  [DEFAULT] bantime 1h, findtime 10m, maxretry 5, backend=systemd
            banaction=nftables-multiport (coexists with UFW/Docker on iptables-nft)
  [sshd] enabled, port=$(vf_current_ssh_ports | tr ' ' ',')
Works alongside UFW: bans are separate nft rules, not UFW edits.
PLAN
}

mod_fail2ban_check() {
	systemctl is-active --quiet fail2ban 2>/dev/null && fail2ban-client status sshd >/dev/null 2>&1
}

mod_fail2ban_run() {
	vf_pkg_install fail2ban
	local ports
	ports="$(vf_current_ssh_ports | tr ' ' ',')"
	[ -z "$ports" ] && ports="22"
	vf_write_file /etc/fail2ban/jail.d/vps-forge.local 644 <<EOF
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd
banaction = nftables-multiport
banaction_allports = nftables-allports

[sshd]
enabled = true
port    = ${ports}
EOF
	systemctl enable --now fail2ban >/dev/null 2>&1 || systemctl restart fail2ban >/dev/null 2>&1
	sleep 2
	if ! fail2ban-client status sshd >/dev/null 2>&1; then
		ui_warn "fail2ban sshd jail did not come up cleanly — check: fail2ban-client status"
		return 1
	fi
	fail2ban-client status sshd 2>/dev/null | sed 's/^/  /' >&2 || true
}
