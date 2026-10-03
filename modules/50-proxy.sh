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
		fi
	fi
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
		vf_curl -o /etc/apt/keyrings/caddy.asc https://dl.cloudsmith.io/public/caddy/stable/gpg.key
		vf_curl -o /etc/apt/keyrings/caddy-stable-archive-keyring.gpg \
			https://dl.cloudsmith.io/public/caddy/stable/gpg.key
		vf_write_file /etc/apt/sources.list.d/caddy-stable.list 644 <<'EOF'
deb [signed-by=/etc/apt/keyrings/caddy-stable-archive-keyring.gpg] https://dl.cloudsmith.io/public/caddy/stable/debian/ubuntu any-version main
EOF
		vf_apt_update
		vf_pkg_install caddy
		local domain email
		domain="$(cfg_get proxy.domain "")"
		email="$(cfg_get proxy.acme_email "")"
		if [ -n "$domain" ]; then
			[ -n "$email" ] && email="email $email" || email=""
			vf_write_file /etc/caddy/Caddyfile 644 <<EOF
{
	$email
}

$domain {
	reverse_proxy 127.0.0.1:8080
}
EOF
		else
			vf_write_file /etc/caddy/Caddyfile 644 <<'EOF'
:80 {
	respond "vps-forge: Caddy ready. Add your site in /etc/caddy/Caddyfile" 200
}
EOF
		fi
		systemctl enable --now caddy >/dev/null 2>&1 || systemctl reload caddy >/dev/null 2>&1 || systemctl restart caddy >/dev/null 2>&1
		systemctl is-active --quiet caddy && ui_ok "caddy active (see /etc/caddy/Caddyfile)"
	else
		vf_pkg_install nginx
		rm -f /etc/nginx/sites-enabled/default
		systemctl enable --now nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1
		nginx -t >/dev/null 2>&1 && ui_ok "nginx active (config: /etc/nginx/sites-available/)"
	fi
	return 0
}
