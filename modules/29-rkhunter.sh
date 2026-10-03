# shellcheck shell=bash
# modules/29-rkhunter.sh — rootkit hunter with baseline of the current system.

mod_rkhunter_plan() {
	cat <<'PLAN'
Install rkhunter; update signature DBs; baseline current file properties
(--propupd) so the first scheduled scan doesn't false-positive on fresh files
Daily scan via /etc/cron.daily/rkhunter (CRON_DAILY_RUN=yes)
PLAN
}

mod_rkhunter_check() { [ -d /var/lib/rkhunter/db ]; }

mod_rkhunter_run() {
	vf_pkg_install rkhunter
	rkhunter --update >/dev/null 2>&1 || ui_warn "rkhunter DB update failed (offline?) — continuing"
	rkhunter --propupd >/dev/null 2>&1 || true
	if [ -f /etc/default/rkhunter ]; then
		vf_backup_file /etc/default/rkhunter
		sed -i 's/^CRON_DAILY_RUN=.*/CRON_DAILY_RUN="yes"/' /etc/default/rkhunter || true
	fi
	return 0
}
