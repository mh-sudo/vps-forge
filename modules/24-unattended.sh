# shellcheck shell=bash
# modules/24-unattended.sh — unattended security upgrades + auto-clean.

mod_unattended_plan() {
	cat <<PLAN
Install unattended-upgrades; enable in 20auto-upgrades (daily checks + apply)
Write /etc/apt/apt.conf.d/51-vps-forge-unattended:
  security updates only, remove unused dependencies,
  Automatic-Reboot $(cfg_is_true ua.auto_reboot && echo 'true (04:00)' || echo 'false — manual reboots')
  APT::Periodic::AutocleanInterval 7
PLAN
}

mod_unattended_check() {
	systemctl is-enabled --quiet apt-daily-upgrade.timer 2>/dev/null &&
		[ -r /etc/apt/apt.conf.d/51-vps-forge-unattended ]
}

mod_unattended_run() {
	vf_pkg_install unattended-upgrades
	apt-get -qq install -y unattended-upgrades 2>/dev/null || true
	vf_write_file /etc/apt/apt.conf.d/20auto-upgrades 644 <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
	local reboot="false" reboottime=""
	if cfg_is_true ua.auto_reboot; then
		reboot="true"
		reboottime='Unattended-Upgrade::Automatic-Reboot-Time "04:00";'
	fi
	vf_write_file /etc/apt/apt.conf.d/51-vps-forge-unattended 644 <<EOF
// vps-forge unattended upgrade policy
Unattended-Upgrade::Allowed-Origins {
    "\${distro_id}:\${distro_codename}-security";
};
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "${reboot}";
${reboottime}
APT::Periodic::AutocleanInterval "7";
EOF
	systemctl enable --now apt-daily.timer apt-daily-upgrade.timer unattended-upgrades >/dev/null 2>&1 || true
	# smoke test config parses
	unattended-upgrade --dry-run --debug >/dev/null 2>&1 || true
	return 0
}
