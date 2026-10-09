# shellcheck shell=bash
# modules/71-panel-cloudpanel.sh — CloudPanel v2 (nginx/MySQL stack, no Docker).
# Sources: https://www.cloudpanel.io/docs/v2/requirements · /docs/v2/getting-started/other
#   installer: https://installer.cloudpanel.io/ce/v2/install.sh (checksum-pinnable via cfg)
#   needs: Ubuntu 22.04/24.04, >=2 GB RAM, >=10 GB disk (installer enforces >=6 GB free /),
#          FRESH server: ports 80/443/3306 must be free; existing mysql packages get purged
#   panel: https://IP:8443 (self-signed) — admin created in browser (bot race — do it NOW)

mod_panel_cloudpanel_plan() {
	cat <<PLAN
Pre-checks: Ubuntu 22.04/24.04, 2 GB RAM, 10 GB disk, ports 80/443/3306 FREE,
            no reverse-proxy module, nothing else on 80/443, no mysql packages
Install: official installer (DB_ENGINE=$(cfg_get cloudpanel.db_engine auto)) — checksum recorded
After:    UFW opens ONLY 8443 (panel) + 80/443 (web); mail/ftp stay closed
Admin:    you create it in the browser at once (bots scan for open registrations)
Stack:    nginx + MySQL/MariaDB + PHP + ProFTPD + Postfix (CloudPanel-managed)
PLAN
}

mod_panel_cloudpanel_check() { dpkg-query -W -f='${Status}' cloudpanel 2>/dev/null | grep -q 'install ok installed'; }

mod_panel_cloudpanel_ask() {
	if [ "$VF_NONINTERACTIVE" != "1" ]; then
		local defdb="MYSQL_8.4"
		[ "$(vf_os_version_id)" = "22.04" ] && defdb="MYSQL_8.0"
		cfg_set cloudpanel.db_engine "$(vf_ask cloudpanel.db_engine "Database engine" "$defdb" "$defdb" "MARIADB_11.8" "MARIADB_11.4")"
	fi
}

cloudpanel_precheck() {
	local ok=0
	vf_os_supported || {
		ui_error "CloudPanel needs Ubuntu 22.04/24.04"
		ok=1
	}
	local ram
	ram="$(vf_total_mb)"
	if [ "$ram" -lt 1900 ]; then
		ui_error "CloudPanel needs 2 GB+ RAM (have ${ram} MB) — blocked"
		ok=1
	elif [ "$ram" -lt 2048 ]; then
		ui_warn "RAM is ${ram} MB (slightly under the 2 GB docs minimum) — proceeding, but a 2 GB instance is recommended."
	fi
	[ "$(vf_disk_free_gb)" -ge 10 ] || {
		ui_error "CloudPanel needs 10+ GB disk (have $(vf_disk_free_gb))"
		ok=1
	}
	local port
	for port in 80 443 3306; do
		if ss -H -tln | awk '{print $4}' | grep -qE ":${port}\$"; then
			ui_error "port $port is already in use — CloudPanel demands a FRESH server (stop caddy/nginx/mysql or pick another panel)"
			ok=1
		fi
	done
	if systemctl is-active --quiet caddy 2>/dev/null || systemctl is-active --quiet nginx 2>/dev/null; then
		ui_error "the reverse-proxy module is active on 80/443 — incompatible with CloudPanel"
		ok=1
	fi
	if dpkg-query -W -f='${Status}' mysql-server 2>/dev/null | grep -q installed; then
		ui_warn "an existing mysql-server will be PURGED by CloudPanel's installer."
	fi
	if [ "$ok" -ne 0 ]; then
		ui_error "CloudPanel requirements NOT met — install blocked"
		return 1
	fi
	return 0
}

mod_panel_cloudpanel_run() {
	cloudpanel_precheck || return 1

	local db
	db="$(cfg_get cloudpanel.db_engine auto)"
	case "$db" in auto) [ "$(vf_os_version_id)" = "22.04" ] && db="MYSQL_8.0" || db="MYSQL_8.4" ;; esac

	# extra swap by cloudpanel is redundant if our swap module ran
	local swapenv=""
	swapon --show=NAME --noheadings 2>/dev/null | grep -q . && swapenv="SWAP=false"

	vf_curl "https://installer.cloudpanel.io/ce/v2/install.sh" -o "$VF_TMP_DIR/cloudpanel-install.sh"
	local sha
	sha="$(vf_sha256 "$VF_TMP_DIR/cloudpanel-install.sh")"
	local want
	want="$(cfg_get cloudpanel.sha256 "")"
	if [ -n "$want" ] && [ "$sha" != "$want" ]; then
		ui_error "installer checksum mismatch (cfg cloudpanel.sha256=$want, got $sha) — blocked"
		return 1
	fi
	ui_para "installer sha256: $sha  (recorded; pin it via cfg cloudpanel.sha256 to enforce)"
	vf_save_credential "cloudpanel-installer.sha256" "$sha"

	# hostname must resolve in /etc/hosts (installer requirement)
	if ! grep -qE "127\.0\.1\.1.*$(hostname)" /etc/hosts; then
		vf_backup_file /etc/hosts
		printf '127.0.1.1\t%s\n' "$(hostname)" >>/etc/hosts
	fi

	if ! ui_spin "Running CloudPanel installer (10-20 min typically)" -- \
		"env DB_ENGINE=$db $swapenv bash $VF_TMP_DIR/cloudpanel-install.sh"; then
		ui_error "CloudPanel installer failed — see log"
		return 1
	fi

	# only the ports that are actually needed
	vf_ufw_active && {
		vf_ufw_allow_port 8443/tcp allow
		vf_ufw_allow_port 80/tcp allow
		vf_ufw_allow_port 443/tcp allow
	}

	ui_box "CLOUDPANEL INSTALLED" \
		"URL:       https://$(hostname -I | awk '{print $1}'):8443   (self-signed cert — accept the warning)
FIRST RUN:  CREATE THE ADMIN USER IN THE BROWSER IMMEDIATELY — open registrations are
           scanned by bots; whoever registers first owns the panel.
firewall:  8443 (panel) + 80/443 (web) open; mail (25/587/993), FTP, MySQL stay CLOSED.
           Open them in UFW only if you use those features.
stack:     nginx $([ "$db" = MYSQL_8.4 ] && echo '+ Percona MySQL 8.4' || echo "+ $db") + PHP + ProFTPD + Postfix (cloudpanel-managed)
upgrade:   apt update && apt install cloudpanel   (CloudPanel ships package updates via apt)"
	return 0
}

panel_remove_cloudpanel() {
	# only when THIS vps-forge installed it (or the package is present): the
	# purge below must never run on a server where CloudPanel came from elsewhere
	if ! mod_panel_cloudpanel_check &&
		[ ! -f "$VF_STATE_DIR/applied/panel_cloudpanel.done" ]; then
		ui_info "CloudPanel not installed — nothing to remove"
		return 0
	fi
	ui_header "Removing CloudPanel (best-effort — a rebuild is the clean path)"
	ui_warn "Sites, databases and the nginx/PHP/MySQL stack are NOT touched — they may
pre-date vps-forge and deleting them is unrecoverable. Reinstall the OS for a
truly clean state before re-running a panel install."
	systemctl stop cloudpanel-utils nginx proftpd mysql mariadb 2>/dev/null || true
	apt-get purge -y -qq cloudpanel cloudpanel-core cloudpanel-libs >/dev/null 2>&1 || true
	# the cloudpanel package's prerm calls sudo/su on a nologin user and FAILS
	# (upstream bug — cf. cloudpanel-io/cloudpanel-ce discussion #87), which then
	# blocks every future apt transaction. Neuter its maintainer scripts and purge.
	if dpkg-query -W -f='${db:Status-Abbrev}' cloudpanel 2>/dev/null | grep -qE '^i[ iUHF]|^h|^r'; then
		ui_warn "cloudpanel package prerm is broken (known upstream bug) — neutering scripts and force-purging"
		for scr in prerm postrm preinst postinst; do
			[ -f "/var/lib/dpkg/info/cloudpanel.$scr" ] && printf '#!/bin/sh\nexit 0\n' >"/var/lib/dpkg/info/cloudpanel.$scr"
		done
		dpkg --purge cloudpanel >/dev/null 2>&1 || dpkg --purge --force-all cloudpanel >/dev/null 2>&1 || true
	fi
	dpkg --configure -a >/dev/null 2>&1 || true
	# CloudPanel's OWN files only — never /var/www, never /home/clp (site data)
	rm -rf /etc/cloudpanel /var/lib/cloudpanel /root/.cloudpanel /etc/apt/sources.list.d/cloudpanel.list /etc/apt/preferences.d/00packages.cloudpanel.io.pref 2>/dev/null || true
	rm -f /etc/update-motd.d/10-cloudpanel 2>/dev/null || true
	for p in 80 443 8443; do ufw delete allow "$p/tcp" >/dev/null 2>&1 || true; done
	ui_warn "CloudPanel removed. The web stack (nginx/PHP/MySQL/ProFTPD) and all sites in
/home/clp remain installed and running — remove them manually if unwanted."
}
