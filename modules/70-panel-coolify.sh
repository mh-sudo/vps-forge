# shellcheck shell=bash
# modules/70-panel-coolify.sh — Coolify (Docker-based PaaS).
# Sources: https://coolify.io/docs/installation (verified 2026-10)
#   installer: https://cdn.coollabs.io/coolify/install.sh (env-var driven, no prompts)
#   needs: 2 CPU, 2 GB RAM (docs recommend 30+ GB disk); refuses snap-docker
#   data: /data/coolify   ports: 8000 UI, 80/443 proxy, 6001/6002 realtime

mod_panel_coolify_plan() {
	cat <<PLAN
Pre-checks: 2 CPU, 2 GB RAM, disk (warn <30 GB), no snap docker, Docker + docker-fw modules first
Install via official script (env: ROOT_USERNAME/ROOT_USER_EMAIL/ROOT_USER_PASSWORD pre-created admin)
Re-apply hardened daemon.json keys after the installer touches it
Expose ONLY: 80, 443, 8000 (UI) + 6001/6002 (realtime) via UFW and DOCKER-USER
NOTE: the UI on :8000 is plain HTTP — reach it over an SSH tunnel or a tailnet,
or put a TLS proxy in front before exposing it to the internet.
Credentials shown once + saved in $VF_CREDS_DIR. Data lives in /data/coolify.
PLAN
}

mod_panel_coolify_check() { systemctl is-active --quiet coolify 2>/dev/null || docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^coolify$'; }

mod_panel_coolify_ask() {
	if [ "$VF_NONINTERACTIVE" != "1" ]; then
		cfg_set coolify.admin_user "$(vf_ask coolify.admin_user "Coolify admin username" "admin")"
		cfg_set coolify.admin_email "$(vf_ask coolify.admin_email "Coolify admin email (for the first-login account)" "")"
	fi
}

coolify_precheck() {
	local ok=0
	[ "$(nproc)" -ge 2 ] || {
		ui_error "Coolify needs 2+ CPU cores (have $(nproc))"
		ok=1
	}
	[ "$(vf_total_mb)" -ge 1900 ] || {
		ui_error "Coolify needs 2 GB+ RAM (have $(vf_total_mb) MB)"
		ok=1
	}
	[ "$(vf_disk_free_gb)" -ge 15 ] || {
		ui_error "Coolify needs serious disk (15+ GB free; docs recommend 30)"
		ok=1
	}
	snap list docker >/dev/null 2>&1 && {
		ui_error "snap docker present — remove it first (module 'docker' offers this)"
		ok=1
	}
	command -v docker >/dev/null 2>&1 || {
		ui_error "install the 'docker' module first (select the docker-host profile or docker in custom)"
		ok=1
	}
	iptables -nL DOCKER-USER >/dev/null 2>&1 || {
		ui_error "install the 'docker-fw' module first — panels MUST sit behind the DOCKER-USER default-deny"
		ok=1
	}
	if [ "$ok" -eq 0 ] && [ "$(vf_disk_free_gb)" -lt 30 ]; then
		ui_warn "Coolify docs recommend 30+ GB free disk; you have $(vf_disk_free_gb) GB."
		[ "$VF_NONINTERACTIVE" = "1" ] || ui_confirm "Continue anyway?" y || ok=1
	fi
	if [ "$ok" -ne 0 ]; then
		ui_error "Coolify requirements NOT met — install blocked (see messages above)"
		return 1
	fi
	return 0
}

mod_panel_coolify_run() {
	coolify_precheck || return 1

	local user email pass
	user="$(cfg_get coolify.admin_user admin)"
	email="$(cfg_get coolify.admin_email "")"
	if [ "$VF_NONINTERACTIVE" != "1" ] && [ -z "$email" ]; then
		email="$(vf_ask coolify.admin_email "Coolify admin email (required for the pre-created root account)" "")"
	fi
	[ -n "$email" ] || {
		ui_error "coolify.admin_email is required (whoever controls it owns the panel)"
		return 1
	}
	pass="$(vf_random_password 24)"
	# the password must never sit on a command line (ps) nor in the log
	vf_secret_register "$pass"

	ui_warn "The Coolify installer modifies /etc/docker/daemon.json (address pools). vps-forge will re-merge its hardening keys afterwards and restart Docker once."

	# hand the admin credentials to the installer via a 600-mode env file —
	# inline 'ROOT_USER_PASSWORD=...' strings used to land verbatim in the log
	local envf="$VF_TMP_DIR/coolify-install.env"
	umask 077
	{
		printf 'ROOT_USERNAME=%q\n' "$user"
		printf 'ROOT_USER_EMAIL=%q\n' "$email"
		printf 'ROOT_USER_PASSWORD=%q\n' "$pass"
		printf 'DOCKER_POOL_FORCE_OVERRIDE=false\n'
	} >"$envf"
	umask 022
	if ! ui_spin "Running Coolify installer (pulls images — takes minutes)" -- \
		bash -c 'set -a; . "$1"; set +a; exec curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash' _ "$envf"; then
		shred -u "$envf" 2>/dev/null || rm -f "$envf"
		ui_error "Coolify installer failed — see log"
		return 1
	fi
	shred -u "$envf" 2>/dev/null || rm -f "$envf"

	# re-merge our daemon.json hardening (installer rewrites it for address pools)
	if [ -r /etc/docker/daemon.json ] && command -v jq >/dev/null 2>&1; then
		jq -S --arg ip "$(cfg_get docker.bind_ip 0.0.0.0)" '. +
			{ iptables: true, ip: $ip, "log-driver": "json-file",
			  "log-opts": { "max-size": "10m", "max-file": "3" },
			  "live-restore": true, "userland-proxy": false, "no-new-privileges": true }' \
			/etc/docker/daemon.json >/etc/docker/daemon.json.vf && mv /etc/docker/daemon.json.vf /etc/docker/daemon.json
	fi
	systemctl restart docker
	sleep 5

	# expose exactly the needed ports
	local p
	for p in 80 443 8000 6001 6002; do
		vf_ufw_active && vf_ufw_allow_port "$p/tcp" allow
		grep -q "allow|tcp|$p|" "$VF_ETC_DIR/docker-user.rules" 2>/dev/null ||
			([ -r "$VF_ETC_DIR/docker-user.rules" ] && printf 'allow|tcp|%d|coolify\n' "$p" >>"$VF_ETC_DIR/docker-user.rules")
	done
	command -v vps-forge-docker-fw-load >/dev/null && vps-forge-docker-fw-load

	vf_save_credential "coolify-admin.txt" "Coolify admin: user=$user email=$email password=$pass
URL: http://$(hostname -I | awk '{print $1}'):8000  (register FIRST LOGIN immediately if the pre-created account did not apply)"

	ui_box "COOLIFY INSTALLED" \
		"URL:      http://$(hostname -I | awk '{print $1}'):8000   (plain HTTP — tunnel or TLS-proxy it)
admin:    $user / $email
password: $pass   (shown once; also in $VF_CREDS_DIR/coolify-admin.txt)
firewall: 80,443,8000,6001,6002 open (UFW + DOCKER-USER); all other published ports stay blocked
data:     /data/coolify   (keep .env — it holds APP_KEY for restores)"
	return 0
}

panel_remove_coolify() {
	# only when THIS vps-forge installed it (or Coolify actually runs here)
	if ! mod_panel_coolify_check &&
		[ ! -f "$VF_STATE_DIR/applied/panel_coolify.done" ]; then
		ui_info "Coolify not installed — nothing to remove"
		return 0
	fi
	ui_header "Removing Coolify"
	# shellcheck source=/dev/null
	[ -r "$VF_MODULE_DIR/41-docker-fw.sh" ] && source "$VF_MODULE_DIR/41-docker-fw.sh"
	docker rm -f coolify coolify-db coolify-redis coolify-realtime coolify-sentinel coolify-proxy >/dev/null 2>&1 || true
	docker volume rm coolify-db coolify-redis >/dev/null 2>&1 || true
	docker network rm coolify >/dev/null 2>&1 || true
	systemctl stop coolify >/dev/null 2>&1 || true
	rm -f /etc/systemd/system/coolify.service
	docker rmi ghcr.io/coollabsio/coolify ghcr.io/coollabsio/coolify-helper postgres:15-alpine redis:7-alpine traefik:v3.3 >/dev/null 2>&1 || true
	rm -rf /data/coolify
	for p in 80 443 8000 6001 6002; do
		ufw delete allow "$p/tcp" >/dev/null 2>&1 || true
		command -v docker_fw_deny >/dev/null && docker_fw_deny "$p/tcp" >/dev/null 2>&1 || true
	done
	systemctl daemon-reload || true
	ui_ok "Coolify removed (Docker itself and other containers were left alone)"
}

panel_remove() { # dispatcher (all three panel modules are sourced together)
	local which="$1"
	case "$which" in
	coolify | cloudpanel | cyberpanel) ;;
	*) vf_die "unknown panel: $which (coolify|cloudpanel|cyberpanel)" ;;
	esac
	# removal deletes containers/data for that panel — require a typed confirm
	# from a human; scripted runs must pass --yes deliberately
	if [ "$VF_NONINTERACTIVE" != "1" ] && [ "${VF_CLEAN_YES:-0}" != "1" ]; then
		local typed
		typed="$(ui_input "Type '${which}' to confirm removing $which (and its data)" "")" || typed=""
		[ "$typed" = "$which" ] || {
			ui_para "confirmation did not match — nothing was removed"
			return 1
		}
	fi
	case "$which" in
	coolify) panel_remove_coolify ;;
	cloudpanel) panel_remove_cloudpanel ;;
	cyberpanel) panel_remove_cyberpanel ;;
	esac
}
