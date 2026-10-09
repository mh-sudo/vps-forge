# shellcheck shell=bash
# modules/50-proxy.sh — reverse proxy with automatic TLS: Caddy (default) or Nginx.

mod_reverse_proxy_plan() {
	local e
	e="$(cfg_get proxy.engine none)"
	case "$e" in
	caddy)
		cat <<PLAN
Install Caddy from the official apt repo (dl.cloudsmith.io/public/caddy/stable)
Caddyfile: $([ -n "$(cfg_get proxy.domain "")" ] && echo "https://$(cfg_get proxy.domain "") (auto-TLS via ACME, email $(cfg_get proxy.acme_email "(none set)"))" || echo "plain :80 listener (add your site later in /etc/caddy/Caddyfile)")
Open 80+443 in UFW
PLAN
		;;
	nginx)
		echo "Install nginx (Ubuntu repo); default site removed; 80+443 opened in UFW; TLS certs manual (certbot suggested)"
		;;
	*) echo "no proxy selected (proxy.engine=none)" ;;
	esac
}

mod_reverse_proxy_ask() {
	if [ "$VF_NONINTERACTIVE" != "1" ]; then
		local pick
		pick="$(vf_ask proxy.engine "Reverse proxy?" "none" "none" "caddy - automatic HTTPS" "nginx - manual TLS")"
		cfg_set proxy.engine "${pick%% -*}"
		if [[ "$(cfg_get proxy.engine none)" == caddy* ]]; then
			cfg_set proxy.domain "$(vf_ask proxy.domain "Domain to serve (empty = no domain yet)" "")"
			cfg_set proxy.acme_email "$(vf_ask proxy.acme_email "ACME account email (for Let's Encrypt)" "")"
			cfg_set proxy.upstream_port "$(vf_ask proxy.upstream_port "Upstream app port to proxy to" "8080")"
		fi
	fi
}

__vf_valid_domain() { # empty ok; else hostname chars only
	local d="$1"
	[ -z "$d" ] && return 0
	case "$d" in
	*[!A-Za-z0-9.-]*) return 1 ;;
	esac
	case "$d" in
	.* | *.*.*) return 0 ;;
	*) return 0 ;;
	esac
}

mod_reverse_proxy_check() {
	case "$(cfg_get proxy.engine none)" in
	caddy) systemctl is-active --quiet caddy 2>/dev/null ;;
	nginx) systemctl is-active --quiet nginx 2>/dev/null ;;
	*) return 1 ;; # nothing selected: run() will no-op with a clear message
	esac
}

mod_reverse_proxy_run() {
	local e
	e="$(cfg_get proxy.engine none)"
	case "$e" in
	caddy | caddy*) e=caddy ;;
	nginx | nginx*) e=nginx ;;
	*)
		ui_para "no proxy selected — skipping"
		return 0
		;;
	esac

	if vf_ufw_active; then
		vf_ufw_allow_port 80/tcp allow
		vf_ufw_allow_port 443/tcp allow
	fi

	if [ "$e" = "caddy" ]; then
		vf_ensure_dir /etc/apt/keyrings
		# the repo key is ASCII-armored: download ONCE and dearmor. The old
		# code wrote the armored key to a *.gpg name (twice) and apt rejected
		# the whole repo
		if ! vf_curl -o /etc/apt/keyrings/caddy.asc https://dl.cloudsmith.io/public/caddy/stable/gpg.key; then
			ui_error "could not fetch Caddy's signing key — are you online?"
			return 1
		fi
		if ! gpg --batch --yes --dearmor -o /etc/apt/keyrings/caddy-stable-archive-keyring.gpg /etc/apt/keyrings/caddy.asc; then
			ui_error "could not dearmor Caddy's signing key"
			return 1
		fi
		chmod a+r /etc/apt/keyrings/caddy-stable-archive-keyring.gpg
		vf_write_file /etc/apt/sources.list.d/caddy-stable.list 644 <<'EOF'
deb [signed-by=/etc/apt/keyrings/caddy-stable-archive-keyring.gpg] https://dl.cloudsmith.io/public/caddy/stable/debian/ubuntu any-version main
EOF
		vf_apt_update
		vf_pkg_install caddy
		local domain email upstream
		domain="$(cfg_get proxy.domain "")"
		email="$(cfg_get proxy.acme_email "")"
		upstream="$(cfg_get proxy.upstream_port 8080)"
		case "$upstream" in '' | *[!0-9]*) upstream=8080 ;; esac
		if ! __vf_valid_domain "$domain"; then
			ui_error "proxy.domain '$domain' is not a valid hostname (letters/digits/dots/hyphens only)"
			return 1
		fi
		if [ -n "$domain" ]; then
			[ -n "$email" ] && email="email $email" || email=""
			vf_write_file /etc/caddy/Caddyfile 644 <<EOF
{
	$email
}

$domain {
	reverse_proxy 127.0.0.1:${upstream}
}
EOF
		else
			vf_write_file /etc/caddy/Caddyfile 644 <<'EOF'
:80 {
	respond "vps-forge: Caddy ready. Add your site in /etc/caddy/Caddyfile" 200
}
EOF
		fi
		if ! { systemctl enable --now caddy >/dev/null 2>&1 || systemctl restart caddy >/dev/null 2>&1; }; then
			ui_error "could not start caddy — check: journalctl -u caddy -n 30"
			return 1
		fi
		if systemctl is-active --quiet caddy; then
			ui_ok "caddy active (config: /etc/caddy/Caddyfile)"
		else
			ui_error "caddy is not active after start — check: journalctl -u caddy -n 30"
			return 1
		fi
	else
		vf_pkg_install nginx
		rm -f /etc/nginx/sites-enabled/default
		systemctl enable --now nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1
		nginx -t >/dev/null 2>&1 && ui_ok "nginx active (config: /etc/nginx/sites-available/)"
	fi
	return 0
}
