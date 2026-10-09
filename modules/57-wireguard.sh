# shellcheck shell=bash
# modules/57-wireguard.sh — optional plain WireGuard server (wg-quick) with client template.

mod_wireguard_plan() {
	local mode allowed
	mode="$(cfg_get wg.mode access)"
	case "$mode" in full) allowed="0.0.0.0/0 (FULL TUNNEL — forwarding + NAT enabled)" ;; *) allowed="10.99.0.0/24 (server itself, over the tunnel)" ;; esac
	cat <<PLAN
Install wireguard tools; generate server keys (stored in $VF_CREDS_DIR)
Create wg0: port $(cfg_get wg.port 51820)/udp, 10.99.0.1/24
UFW: allow $(cfg_get wg.port 51820)/udp
Client access: $allowed
Enable wg-quick@wg0; print a client-config TEMPLATE (peers added manually with wg set)
PLAN
}

mod_wireguard_ask() {
	if [ "$VF_NONINTERACTIVE" != "1" ]; then
		local pick
		pick="$(vf_ask wg.mode "Client access mode" "access" \
			"access - clients reach the SERVER only (recommended)" \
			"full - full tunnel: all client traffic routes through this server")"
		cfg_set wg.mode "${pick%% -*}"
	fi
}

mod_wireguard_check() { [ -e /etc/wireguard/wg0.conf ] && ip link show wg0 >/dev/null 2>&1; }

mod_wireguard_run() {
	if ! cfg_is_true wg.enabled && [ "$VF_NONINTERACTIVE" = "1" ]; then return 0; fi
	vf_pkg_install wireguard-tools qrencode
	vf_ensure_credentials_dir
	local priv="$VF_CREDS_DIR/wg-server-private.key"
	if [ ! -s "$priv" ]; then
		# 077 scoped to the key generation only — a bare `umask 077` used to leak
		# into every module that ran after this one
		(umask 077 && wg genkey) >"$priv"
	fi
	local pub
	pub="$(wg pubkey <"$priv")"
	local port mode postup postdown allowedips
	port="$(cfg_get wg.port 51820)"
	mode="$(cfg_get wg.mode access)"
	local ext_if
	ext_if="$(vf_ext_if_resolved)"
	if [ "$mode" = "full" ]; then
		# full tunnel needs kernel forwarding + NAT for clients to reach the internet
		vf_write_file /etc/sysctl.d/62-vps-forge-wg.conf 644 <<'EOF'
# vps-forge WireGuard full-tunnel forwarding
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
		sysctl --system >/dev/null 2>&1 || true
		postup="ufw route allow in on wg0; ufw allow ${port}/udp; iptables -t nat -A POSTROUTING -s 10.99.0.0/24 -o ${ext_if} -j MASQUERADE"
		postdown="ufw route delete allow in on wg0; ufw delete allow ${port}/udp; iptables -t nat -D POSTROUTING -s 10.99.0.0/24 -o ${ext_if} -j MASQUERADE"
		allowedips="0.0.0.0/0"
	else
		postup="ufw route allow in on wg0; ufw allow ${port}/udp"
		postdown="ufw route delete allow in on wg0; ufw delete allow ${port}/udp"
		allowedips="10.99.0.0/24"
	fi
	vf_write_file /etc/wireguard/wg0.conf 600 <<EOF
[Interface]
Address = 10.99.0.1/24
ListenPort = ${port}
PrivateKey = $(cat "$priv")
PostUp = ${postup}
PostDown = ${postdown}
# add peers with:
#   wg set wg0 peer <CLIENT_PUBKEY> allowed-ips 10.99.0.2/32
EOF
	if vf_ufw_active; then vf_ufw_allow_port "$port/udp" allow || return 1; fi
	systemctl enable --now wg-quick@wg0 >/dev/null 2>&1 || systemctl restart wg-quick@wg0 >/dev/null 2>&1 || true
	ip link show wg0 >/dev/null 2>&1 && ui_ok "wg0 up on :$port (server pubkey below)"
	printf '  server pubkey: %s\n' "$pub" >&2
	vf_save_credential "wg-client-TEMPLATE.conf" "[Interface]
Address = 10.99.0.2/24
PrivateKey = <CLIENT_PRIVATE_KEY>
DNS = 1.1.1.1

[Peer]
PublicKey = ${pub}
Endpoint = $(hostname -I | awk '{print $1}'):${port}
AllowedIPs = ${allowedips}
PersistentKeepalive = 25"
	ui_para "client template saved to $VF_CREDS_DIR/wg-client-TEMPLATE.conf (mode: $mode)"
	return 0
}
