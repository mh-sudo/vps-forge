# shellcheck shell=bash
# modules/57-wireguard.sh — optional plain WireGuard server (wg-quick) with client template.

mod_wireguard_plan() {
	cat <<PLAN
Install wireguard tools; generate server keys (stored in $VF_CREDS_DIR)
Create wg0: port $(cfg_get wg.port 51820)/udp, 10.99.0.1/24
UFW: allow $(cfg_get wg.port 51820)/udp
Enable wg-quick@wg0; print a client-config TEMPLATE (peers added manually with wg set)
PLAN
}

mod_wireguard_check() { [ -e /etc/wireguard/wg0.conf ] && ip link show wg0 >/dev/null 2>&1; }

mod_wireguard_run() {
	if ! cfg_is_true wg.enabled && [ "$VF_NONINTERACTIVE" = "1" ]; then return 0; fi
	vf_pkg_install wireguard-tools qrencode
	vf_ensure_credentials_dir
	local priv="$VF_CREDS_DIR/wg-server-private.key"
	if [ ! -s "$priv" ]; then
		umask 077
		wg genkey >"$priv"
	fi
	local pub
	pub="$(wg pubkey <"$priv")"
	local port
	port="$(cfg_get wg.port 51820)"
	vf_write_file /etc/wireguard/wg0.conf 600 <<EOF
[Interface]
Address = 10.99.0.1/24
ListenPort = ${port}
PrivateKey = $(cat "$priv")
PostUp = ufw route allow in on wg0; ufw allow ${port}/udp
PostDown = ufw route delete allow in on wg0; ufw delete allow ${port}/udp
# add peers with:
#   wg set wg0 peer <CLIENT_PUBKEY> allowed-ips 10.99.0.2/32
EOF
	if vf_ufw_active; then vf_ufw_allow_port "$port/udp" allow; fi
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
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25"
	ui_para "client template saved to $VF_CREDS_DIR/wg-client-TEMPLATE.conf"
	return 0
}
