# shellcheck shell=bash
# modules/22-ufw.sh — UFW: default deny incoming, rate-limited SSH, IPv6 consistent.

mod_ufw_plan() {
	local extra
	extra="$(cfg_get fw.open_ports "")"
	cat <<PLAN
Install/enable UFW:
  - allow (rate-limited) SSH on current port(s): $(vf_current_ssh_ports)
  - default DENY incoming / allow outgoing (IPv4 + IPv6)
$([ -n "$extra" ] && echo "  - extra open ports: $extra")
  - logging low
Enable is guarded by an auto-revert timer + confirmation from a NEW session.
PLAN
}

mod_ufw_check() {
	vf_ufw_active || return 1
	local p
	for p in $(vf_current_ssh_ports); do
		ufw status | grep -q "$p/tcp" && return 0
	done
	return 1
}

mod_ufw_ask() {
	if [ "$VF_NONINTERACTIVE" != "1" ]; then
		cfg_set fw.open_ports "$(vf_ask fw.open_ports "Extra ports to open now (e.g. '80,443' — empty for none)" "")"
	fi
}

mod_ufw_run() {
	vf_pkg_install ufw

	# never lock out: allow every port sshd is listening on + configured port
	local p ports
	ports="$(vf_current_ssh_ports)"
	[ -z "$ports" ] && ports="22"
	for p in $ports; do vf_ufw_allow_port "$p/tcp" limit; done
	local cfgport
	cfgport="$(cfg_get ssh.port keep)"
	case "$cfgport" in *[0-9]*) vf_ufw_allow_port "$cfgport/tcp" limit ;; esac

	# extra ports requested
	local extra
	extra="$(cfg_get fw.open_ports "")"
	if [ -n "$extra" ]; then
		local e
		IFS=',' read -ra e <<<"$extra"
		for p in "${e[@]}"; do
			p="$(printf '%s' "$p" | tr -d '[:space:]')"
			[ -z "$p" ] && continue
			case "$p" in */tcp | */udp) : ;; *) p="$p/tcp" ;; esac
			vf_ufw_allow_port "$p" allow
		done
	fi

	# IPv6 handled consistently with IPv4 policies
	vf_backup_file /etc/default/ufw
	sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
	grep -q '^IPV6=yes' /etc/default/ufw || echo 'IPV6=yes' >>/etc/default/ufw

	ufw logging low >/dev/null 2>&1 || true
	vf_ufw_safe_enable || return 1

	# fail-open change: the ufw status check (in vf_confirm_new_session) proved
	# the ssh port is allowed, so the guarded enable is confirmed automatically
	# in non-interactive runs
	if ! vf_confirm_new_session "SSH still reachable with the firewall on" "failopen"; then
		ui_warn "not confirmed — the auto-revert guard will disable UFW shortly"
		return 1
	fi
	if ! vf_guard_cancel ufw; then
		ui_error "the auto-revert guard already fired — UFW was disabled; re-run this module"
		return 1
	fi
	if ! vf_ufw_active; then
		ui_error "ufw is not active after confirmation — treating as failure"
		return 1
	fi
	ufw status verbose | sed 's/^/  /' >&2 || true
	return 0
}
