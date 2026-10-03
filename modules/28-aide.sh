# shellcheck shell=bash
# modules/28-aide.sh — AIDE file-integrity baseline.

mod_aide_plan() {
	cat <<'PLAN'
Install AIDE and build the integrity database (aideinit) — takes a few minutes
Daily check via the packaged cron job (/etc/cron.daily/aide)
NOTE: baseline reflects state at install time; re-run 'aideinit' after major
changes (e.g. a panel install) to re-baseline.
PLAN
}

mod_aide_check() { [ -e /var/lib/aide/aide.db ] || [ -e /var/lib/aide/aide.db.new ]; }

mod_aide_run() {
	vf_pkg_install aide aide-common
	if mod_aide_check; then
		ui_para "AIDE database already present — keeping existing baseline"
		return 0
	fi
	ui_para "Building AIDE baseline (this can take a few minutes)..."
	if ! ui_spin "AIDE init — scanning filesystem" -- aideinit --yes -y -f; then
		ui_warn "aideinit failed — AIDE left unconfigured; re-run this module"
		return 1
	fi
	[ -e /var/lib/aide/aide.db ] || {
		ui_warn "AIDE db not created"
		return 1
	}
	# daily run via cron (packaged); make sure it is enabled
	if [ -f /etc/default/aide ]; then
		vf_backup_file /etc/default/aide
		sed -i 's/^COPYNEWDB=.*/COPYNEWDB=no/' /etc/default/aide || true
	fi
	return 0
}
