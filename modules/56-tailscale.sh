# shellcheck shell=bash
# modules/56-tailscale.sh — Tailscale private admin access (official pkgs.tailscale.com repo).

mod_tailscale_plan() {
	cat <<PLAN
Add Tailscale's official apt repo (pkgs.tailscale.com/stable, GPG-signed)
Install tailscale; enable tailscaled
Auth: $([ -n "$(cfg_get tailscale.auth_key "")" ] && echo "with the provided auth key (non-interactive)" || echo "interactive — a browser login URL is printed / 'tailscale up' left for you")
UFW: allow all inbound on tailscale0 (your tailnet is trusted; nothing else opens)
PLAN
}

mod_tailscale_check() {
	systemctl is-active --quiet tailscaled 2>/dev/null && command -v tailscale >/dev/null 2>&1
}

mod_tailscale_run() {
	local key
	key="$(cfg_get tailscale.auth_key "")"
	curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/tailscale-archive-keyring.gpg --yes \
		2>/dev/null || {
		mkdir -p /etc/apt/keyrings
		curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/tailscale-archive-keyring.gpg --yes
	}
	chmod a+r /etc/apt/keyrings/tailscale-archive-keyring.gpg
	local codename
	codename="$(. /etc/os-release && printf '%s' "$VERSION_CODENAME")"
	vf_write_file /etc/apt/sources.list.d/tailscale.list 644 <<EOF
deb [signed-by=/etc/apt/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/ubuntu ${codename} main
EOF
	vf_apt_update
	vf_pkg_install tailscale
	systemctl enable --now tailscaled >/dev/null 2>&1 || true
	if vf_ufw_active; then
		ufw allow in on tailscale0 >/dev/null 2>&1 || true
	fi
	if [ -n "$key" ]; then
		tailscale up --authkey="$key" --accept-dns=false >"$VF_TMP_DIR/ts-up.log" 2>&1 &&
			ui_ok "tailscale joined" || { ui_warn "tailscale up failed with key — run 'tailscale up' manually"; }
	elif [ "$VF_NONINTERACTIVE" != "1" ]; then
		ui_box "TAILSCALE LOGIN" \
			"Run in another terminal:  tailscale up
It prints a login URL — open it in a browser and approve the device."
	else
		ui_para "non-interactive without auth key: run 'tailscale up' once manually."
	fi
	return 0
}
