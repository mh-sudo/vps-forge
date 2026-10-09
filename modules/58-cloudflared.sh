# shellcheck shell=bash
# modules/58-cloudflared.sh — optional Cloudflare Tunnel (no inbound ports needed).

mod_cloudflared_plan() {
	cat <<PLAN
Add Cloudflare's official apt repo (pkg.cloudflare.com) and install cloudflared
$([ -n "$(cfg_get cloudflared.token "")" ] && echo "Install tunnel as a service with your token (connector online immediately)" || echo "Install binary only — run 'cloudflared tunnel login' + create tunnel manually")
No firewall ports opened (tunnel is outbound-only).
PLAN
}

mod_cloudflared_check() { command -v cloudflared >/dev/null 2>&1 && systemctl is-active --quiet cloudflared 2>/dev/null; }

mod_cloudflared_run() {
	local key
	key="$(cfg_get cloudflared.token "")"
	vf_secret_register "$key"
	local codename
	codename="$(. /etc/os-release && printf '%s' "$VERSION_CODENAME")"
	case "$codename" in noble | jammy) : ;; *) codename="noble" ;; esac
	vf_ensure_dir /etc/apt/keyrings
	if ! curl -fsSL --retry 2 https://pkg.cloudflare.com/cloudflare-main.gpg | tee /etc/apt/keyrings/cloudflare-main.gpg >/dev/null; then
		if ! vf_curl -o /etc/apt/keyrings/cloudflare-main.gpg https://pkg.cloudflare.com/cloudflare-main.gpg; then
			ui_error "could not fetch Cloudflare's signing key — are you online?"
			return 1
		fi
	fi
	chmod a+r /etc/apt/keyrings/cloudflare-main.gpg
	vf_write_file /etc/apt/sources.list.d/cloudflared.list 644 <<EOF
deb [signed-by=/etc/apt/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared ${codename} main
EOF
	vf_apt_update
	vf_pkg_install cloudflared
	if [ -n "$key" ]; then
		# keep the tunnel token off the command line (visible in ps): pass it
		# through the environment from a 600-mode file
		local envf="$VF_TMP_DIR/cfd-token.env"
		umask 077
		printf 'TUNNEL_TOKEN=%q\n' "$key" >"$envf"
		umask 022
		if bash -c 'set -a; . "$1"; set +a; exec cloudflared service install "$TUNNEL_TOKEN"' _ "$envf" >"$VF_TMP_DIR/cfd.log" 2>&1; then
			ui_ok "cloudflared tunnel service installed"
		else
			tail -10 "$VF_TMP_DIR/cfd.log" >&2 || true
			ui_warn "cloudflared service install failed — configure the tunnel manually"
			shred -u "$envf" 2>/dev/null || rm -f "$envf"
			return 1
		fi
		shred -u "$envf" 2>/dev/null || rm -f "$envf"
	else
		ui_para "binary installed; configure a tunnel with: cloudflared tunnel login"
	fi
	return 0
}
