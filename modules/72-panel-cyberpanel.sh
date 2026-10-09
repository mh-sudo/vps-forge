# shellcheck shell=bash
# modules/72-panel-cyberpanel.sh — CyberPanel (OpenLiteSpeed stack) with a LOUD security warning.
# Sources: https://cyberpanel.net/KnowledgeBase/home/install-cyberpanel · community.cyberpanel.net
#   installer: https://cyberpanel.net/install.sh (root only; non-interactive flags)
#   flags: -v ols (OpenLiteSpeed)  -p r (random admin pw)  -a (memcached+redis)
#   ports: 8090 panel, 80/443(+udp443) web, 7080 lsws admin, 21+40110-40210 ftp,
#          25/587/465/110/143/993 mail, 53 dns — we open ONLY 8090/80/443 by default.
# SECURITY HISTORY (actively exploited — this panel compromised servers before):
#   CVE-2024-51567, CVE-2024-51568, CVE-2024-51378 (all CVSS 10.0, CISA KEV;
#     PSAUX ransomware hit ~22,000 instances, Oct-Dec 2024)
#   CVE-2026-67614 (hard-coded JWT secret, <3.0.0), CVE-2026-88895 (2FA not
#     enforced on API endpoints, <3.0.5), CVE-2026-71965 (authenticated RCE) + more.

mod_panel_cyberpanel_plan() {
	cat <<'PLAN'
LOUD WARNING: CyberPanel has a history of actively-exploited critical CVEs
  (2024: CVE-2024-51567/51568/51378 — CVSS 10, PSAUX ransomware, ~22k servers;
   2026: CVE-2026-67614 hard-coded JWT secret, CVE-2026-88895 API-2FA bypass, ...)
Pre-checks: root, Ubuntu 22.04/24.04, 1 GB RAM, 10 GB disk, ports 80/443/8090 free
Install: official installer, non-interactive (-v ols -p r), latest version
After:    UFW opens ONLY 8090 (admin) + 80/443; FTP/mail/DNS/7080 stay CLOSED
          random admin password shown once + saved; extra hardening checklist printed
PLAN
}

mod_panel_cyberpanel_check() {
	[ -d /usr/local/CyberCP ] && systemctl is-active --quiet lsws 2>/dev/null
}

cyberpanel_precheck() {
	local ok=0
	vf_running_as_root || {
		ui_error "CyberPanel must be installed as real root"
		ok=1
	}
	vf_os_supported || {
		ui_error "CyberPanel needs Ubuntu 22.04/24.04"
		ok=1
	}
	[ "$(vf_total_mb)" -ge 900 ] || {
		ui_error "CyberPanel needs ~1 GB+ RAM (have $(vf_total_mb) MB)"
		ok=1
	}
	[ "$(vf_disk_free_gb)" -ge 10 ] || {
		ui_error "CyberPanel needs 10+ GB disk (have $(vf_disk_free_gb))"
		ok=1
	}
	local port
	for port in 80 443 8090 7080; do
		if ss -H -tln | awk '{print $4}' | grep -qE ":${port}\$"; then
			# a previous FAILED install of our own leaves lsws running — clear it and
			# resume; a FOREIGN service on these ports still blocks (fresh server rule)
			if ss -H -tlnp 2>/dev/null | grep -E ":${port} " | grep -qE "litespeed|lsws|nginx.*CyberCP|/usr/local/lsws"; then
				ui_warn "port $port held by a previous CyberPanel install attempt — stopping it to resume"
				systemctl stop lsws 2>/dev/null || pkill -f "/usr/local/lsws" 2>/dev/null || true
				sleep 2
			fi
			if ss -H -tln | awk '{print $4}' | grep -qE ":${port}\$"; then
				ui_error "port $port already in use — CyberPanel needs it (fresh server required)"
				ok=1
			fi
		fi
	done
	if [ "$ok" -ne 0 ]; then
		ui_error "CyberPanel requirements NOT met — install blocked"
		return 1
	fi
	return 0
}

mod_panel_cyberpanel_run() {
	# risk acceptance: interactive confirm, or explicit 'panel_cyberpanel.accept_risk: true'
	# in the config for scripted runs (the warning is ALWAYS displayed either way)
	local accepted=0
	if [ "$VF_NONINTERACTIVE" = "1" ] && cfg_is_true panel_cyberpanel.accept_risk; then
		accepted=1
		ui_warn "Risk accepted via config (panel_cyberpanel.accept_risk) — proceeding"
	fi
	if [ "$accepted" = "0" ]; then
		if ! ui_confirm "Install CyberPanel DESPITE its exploitation history? (see warning)" n; then
			ui_para "declined — CyberPanel not installed"
			return 0
		fi
	fi
	cyberpanel_precheck || return 1

	ui_box "READ THIS FIRST — CYBERPANEL RISK" \
		"CyberPanel has shipped multiple CRITICAL, actively-exploited vulnerabilities:
  2024: CVE-2024-51567 / CVE-2024-51568 / CVE-2024-51378 (CVSS 10.0) — pre-auth RCE,
        used by 'PSAUX' ransomware against ~22,000 servers (CISA KEV listed).
  2026: CVE-2026-67614 (hard-coded JWT secret), CVE-2026-88895 (API endpoints
        skip 2FA), CVE-2026-71965 (authenticated RCE).
Mandatory mitigations applied/required:
  - keep CyberPanel on the LATEST version (unattended-upgrades does NOT cover it —
    check for updates weekly)
  - port 8090 is opened RATE-LIMITED by this module — restrict it to your IP:
      ufw insert 1 allow from YOUR_IP to any port 8090 proto tcp
      ufw delete limit 8090/tcp
  - FTP/mail/DNS/7080 ports stay closed unless you use them
  - enable 2FA in the panel; strong admin password (we generate one)"

	local out="$VF_TMP_DIR/cyberpanel-install.log"
	# official non-interactive flags per the installer's own usage:
	#   sh <(curl cyberpanel.sh) -v ols -p r   (OpenLiteSpeed + random admin password)
	if ! ui_spin "Running CyberPanel installer (10-20 min)" -- \
		"bash -c 'sh <(curl -s https://cyberpanel.sh) -v ols -p r'"; then
		tail -30 "$out" >&2 || true
		ui_error "CyberPanel installer failed — see log"
		return 1
	fi
	# post-condition: the installer can exit 0 while printing usage — verify reality
	if [ ! -d /usr/local/CyberCP ]; then
		tail -15 "$VF_TMP_DIR/spin.last.log" 2>/dev/null >&2 || true
		ui_error "CyberPanel files absent after installer — install did not happen"
		return 1
	fi

	# grab the generated admin password from the installer output if present
	local pass
	pass="$(grep -aoE 'password[^A-Za-z0-9]*[A-Za-z0-9]{8,}' "$VF_TMP_DIR/spin.last.log" 2>/dev/null | tail -1 | grep -oE '[A-Za-z0-9]{8,}$' || true)"
	if [ -z "$pass" ]; then
		pass="$(vf_random_password 24)"
		vf_secret_register "$pass"
		# reset via the documented CLI when available
		local reset_ok=0
		if [ -f /usr/local/CyberCP/CLManager/adminPass.py ]; then
			if python3 /usr/local/CyberCP/CLManager/adminPass.py --password "$pass" >/dev/null 2>&1; then
				reset_ok=1
			fi
		fi
		if [ "$reset_ok" != "1" ]; then
			ui_warn "could not reset the admin password via CLI — the password shown below may
NOT be the panel's current one. Reset it inside the panel on first login."
		fi
	else
		vf_secret_register "$pass"
	fi
	vf_save_credential "cyberpanel-admin.txt" "CyberPanel admin URL https://$(hostname -I | awk '{print $1}'):8090 user=admin password=$pass
(RESET IT IN THE PANEL if the CLI reset above failed: no harm either way.)"

	# open ONLY what's needed: admin + web. FTP/mail/DNS/7080 remain closed.
	# NOTE: CyberPanel's installer REMOVES ufw (it manages firewalls itself) —
	# reinstall and re-apply our posture so 7080/ftp/mail stay closed.
	if ! command -v ufw >/dev/null 2>&1; then
		ui_warn "CyberPanel's installer removed ufw — reinstalling it and re-applying the firewall posture"
		vf_pkg_install ufw
	fi
	if ! vf_ufw_active; then
		vf_ufw_safe_enable || ui_warn "ufw could not be re-enabled — apply rules manually"
	fi
	if vf_ufw_active; then
		vf_ufw_allow_port 8090/tcp limit
		vf_ufw_allow_port 80/tcp allow
		vf_ufw_allow_port 443/tcp allow
	fi

	ui_box "CYBERPANEL INSTALLED — HARDEN IT" \
		"URL:      https://$(hostname -I | awk '{print $1}'):8090   user: admin
password: $pass  (shown once; also in $VF_CREDS_DIR/cyberpanel-admin.txt)
firewall: ONLY 8090(rate-limited)+80+443 open. 7080 (lsws admin), 21/40110-40210 (ftp),
          25/587/465/110/143/993 (mail), 53 (dns) are CLOSED — open individually if used.
CHECKLIST:
  [ ] enable 2FA in the panel NOW
  [ ] restrict 8090 to your IP:  ufw insert 1 allow from <YOUR_IP> to any port 8090 proto tcp
  [ ] schedule a WEEKLY version check (CyberPanel is not covered by apt security updates)
  [ ] consider putting 8090 behind Tailscale/WireGuard instead of the public internet
updates:  panel -> Settings -> Version Manager (or: sh <(curl -s https://cyberpanel.net/upgrade.sh))"
	return 0
}

panel_remove_cyberpanel() {
	# only when THIS vps-forge installed it (or CyberCP exists): the purge below
	# must never run on a server where CyberPanel came from elsewhere
	if ! mod_panel_cyberpanel_check &&
		[ ! -f "$VF_STATE_DIR/applied/panel_cyberpanel.done" ] &&
		[ ! -d /usr/local/CyberCP ]; then
		ui_info "CyberPanel not installed — nothing to remove"
		return 0
	fi
	ui_header "Removing CyberPanel (best-effort — a rebuild is the clean path)"
	ui_warn "Databases, mail and FTP stacks are NOT purged — their data may pre-date
vps-forge and deleting it is unrecoverable. Reinstall the OS for a truly clean
state (that is also CyberPanel's own official advice)."
	systemctl stop lsws 2>/dev/null || true
	systemctl disable --now lsws >/dev/null 2>&1 || true
	# CyberPanel-only packages: OpenLiteSpeed + its PHP builds. Generic stacks
	# (mysql/mariadb, postfix, pure-ftpd, powerdns, redis, memcached) stay.
	apt-get purge -y -qq 'openlitespeed*' 'lsphp*' >/dev/null 2>&1 || true
	rm -rf /usr/local/CyberCP /usr/local/lsws /usr/local/CyberCP/.clp /home/cyberpanel \
		/etc/cyberpanel /var/log/cyberpanel 2>/dev/null || true
	rm -f /etc/apt/sources.list.d/litespeed*.list /etc/apt/sources.list.d/*cyberpanel* 2>/dev/null || true
	for p in 80 443 8090; do
		ufw delete allow "$p/tcp" >/dev/null 2>&1 || true
		ufw delete limit "$p/tcp" >/dev/null 2>&1 || true
	done
	ui_warn "CyberPanel best-effort removed. MySQL/MariaDB, mail (postfix), FTP (pure-ftpd),
DNS (powerdns) and their data remain installed — remove them manually if unwanted."
}
