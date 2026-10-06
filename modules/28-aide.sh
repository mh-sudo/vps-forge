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
	# aideinit occasionally fails right after install (package postinst races);
	# retry once before giving up
	local attempt
	for attempt in 1 2; do
		if ui_spin "AIDE init — scanning filesystem (attempt $attempt)" -- aideinit --yes -y -f; then
			break
		fi
		[ "$attempt" = "2" ] && {
			ui_warn "aideinit failed twice — AIDE left unconfigured; re-run this module"
			return 1
		}
		ui_warn "aideinit failed — waiting 10s and retrying"
		sleep 10
	done
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
