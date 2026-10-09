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
	systemctl is-active --quiet tailscaled 2>/dev/null && command -v tailscale >/dev/null 2>&1 &&
		# "installed" is not "joined": require the node to actually be logged in,
		# otherwise a re-run would skip an unauthenticated install
		tailscale status --json 2>/dev/null | grep -q '"BackendState": *"Running"'
}

mod_tailscale_run() {
	local key
	key="$(cfg_get tailscale.auth_key "")"
	vf_secret_register "$key"
	mkdir -p /etc/apt/keyrings
	if ! curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/tailscale-archive-keyring.gpg --yes 2>/dev/null; then
		ui_error "could not fetch Tailscale's signing key — are you online?"
		return 1
	fi
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
		# the auth key must not sit on a command line (visible in ps): hand it to
		# tailscale through the environment via a 600-mode file instead
		local envf="$VF_TMP_DIR/ts-auth.env"
		umask 077
		printf 'TS_AUTHKEY=%q\n' "$key" >"$envf"
		umask 022
		if bash -c 'set -a; . "$1"; set +a; exec tailscale up --accept-dns=false' _ "$envf" >"$VF_TMP_DIR/ts-up.log" 2>&1 &&
			ui_ok "tailscale joined"; then
			:
		else
			ui_warn "tailscale up failed with key — run 'tailscale up' manually (see $VF_TMP_DIR/ts-up.log in this run)"
		fi
		shred -u "$envf" 2>/dev/null || rm -f "$envf"
	elif [ "$VF_NONINTERACTIVE" != "1" ]; then
		ui_box "TAILSCALE LOGIN" \
			"Run in another terminal:  tailscale up
It prints a login URL — open it in a browser and approve the device."
	else
		ui_para "non-interactive without auth key: run 'tailscale up' once manually."
	fi
	return 0
}
