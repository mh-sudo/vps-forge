# shellcheck shell=bash
# modules/53-node-exporter.sh — Prometheus node_exporter (pinned, checksum-verified),
# listening on loopback by default (expose via SSH tunnel / proxy / tailscale).

# NOTE: declare -g — module files are sourced inside a function; a plain declare
# would scope the array to that function and vanish before mod_*_run uses it.
VF_NE_VERSION="1.12.1"
declare -gA VF_NE_SHA=(
	[amd64]="b51d8a76aa2a9156a55d501aca6276fae09e262259a5e4e831d2c2222f084e63"
	[arm64]="ad35b605f9954b9f1ffddf5ba054bdc5a98d790b9eae5291e1eeb83f1ecbd0e7"
)

mod_node_exporter_plan() {
	cat <<PLAN
Download node_exporter v$VF_NE_VERSION (github releases, sha256-pinned) -> /usr/local/bin
Dedicated system user; systemd unit listening on $(cfg_get node_exporter.listen 127.0.0.1:9100)
(loopback only by default — NOT reachable from the internet)
PLAN
}

mod_node_exporter_check() {
	local arch
	arch="$(vf_arch)"
	[ -n "${VF_NE_SHA[$arch]:-}" ] || return 1
	systemctl is-active --quiet node_exporter 2>/dev/null || return 1
	# the installed BINARY's version must match the pinned release — comparing
	# the binary's sha256 to the TARBALL's pinned hash can never be true
	[ -x /usr/local/bin/node_exporter ] &&
		/usr/local/bin/node_exporter --version 2>&1 | grep -q "version ${VF_NE_VERSION}"
}

mod_node_exporter_run() {
	local arch tar dest
	arch="$(vf_arch)"
	[ -n "${VF_NE_SHA[$arch]:-}" ] || {
		ui_error "no pinned node_exporter checksum for $arch"
		return 1
	}
	tar="node_exporter-${VF_NE_VERSION}.linux-${arch}.tar.gz"
	dest="$VF_TMP_DIR/$tar"
	if ! vf_curl -o "$dest" "https://github.com/prometheus/node_exporter/releases/download/v${VF_NE_VERSION}/${tar}"; then
		ui_error "node_exporter download failed"
		return 1
	fi
	if [ "$(vf_sha256 "$dest")" != "${VF_NE_SHA[$arch]}" ]; then
		ui_error "node_exporter checksum mismatch — refusing"
		return 1
	fi
	tar -xzf "$dest" -C "$VF_TMP_DIR"
	install -m 755 "$VF_TMP_DIR/node_exporter-${VF_NE_VERSION}.linux-${arch}/node_exporter" /usr/local/bin/node_exporter
	id node_exporter >/dev/null 2>&1 || {
		useradd --system --no-create-home --shell /usr/sbin/nologin node_exporter
		vf_note_created_user node_exporter
	}
	vf_write_file /etc/systemd/system/node_exporter.service 644 <<EOF
[Unit]
Description=Prometheus Node Exporter
After=network-online.target

[Service]
User=node_exporter
ExecStart=/usr/local/bin/node_exporter --web.listen-address=$(cfg_get node_exporter.listen 127.0.0.1:9100)
Restart=on-failure
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes

[Install]
WantedBy=multi-user.target
EOF
	systemctl daemon-reload
	systemctl enable --now node_exporter >/dev/null 2>&1 || systemctl restart node_exporter >/dev/null 2>&1
	sleep 1
	curl -fsS --max-time 3 "http://$(cfg_get node_exporter.listen 127.0.0.1:9100 | sed 's/:.*//')$(cfg_get node_exporter.listen 127.0.0.1:9100 | sed 's/^[^:]*//')/metrics" >/dev/null 2>&1 &&
		ui_ok "node_exporter serving on $(cfg_get node_exporter.listen 127.0.0.1:9100)" ||
		ui_warn "node_exporter did not answer on loopback yet — check: systemctl status node_exporter"
	return 0
}
