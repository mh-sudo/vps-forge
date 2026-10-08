# shellcheck shell=bash
# modules/40-docker.sh — Docker Engine + Compose from the official apt repo, hardened daemon.json.
# iptables stays ENABLED (iptables:false is unsupported and breaks the firewall).

VF_DOCKER_GPG_FINGERPRINT="9DC858229FC7DD38854AE2D88D81803C0EBFCD88"

docker_daemon_json() { # -> desired daemon.json (respecting cfg)
	local bind ipv6
	bind="$(cfg_get docker.bind_ip 127.0.0.1)"
	ipv6="false"
	cfg_is_true docker.ipv6 && ipv6="true"
	local ip6block=""
	if [ "$ipv6" = "true" ]; then
		ip6block=',
    "ipv6": true,
    "ip6tables": true,
    "fixed-cidr-v6": "fd00:beef:cafe::/64"'
	fi
	cat <<EOF
{
    "iptables": true,
    "ip": "${bind}"${ip6block},
    "log-driver": "json-file",
    "log-opts": { "max-size": "10m", "max-file": "3" },
    "live-restore": true,
    "userland-proxy": false,
    "no-new-privileges": true
}
EOF
}

mod_docker_plan() {
	cat <<PLAN
Add Docker's official apt repo (download.docker.com, GPG fingerprint-pinned)
Install docker-ce, docker-ce-cli, containerd.io, docker-buildx-plugin, docker-compose-plugin
Write /etc/docker/daemon.json:
  iptables: true (explicit — never disabled)
  ip: "$(cfg_get docker.bind_ip 127.0.0.1)"  (default bind address for -p publishes: loopback = safe default)
  json-file logs capped at 10m x3, live-restore, userland-proxy off, no-new-privileges on
Enable docker service. NO ports are exposed from containers by default (see docker-fw module).
PLAN
}

mod_docker_check() {
	command -v docker >/dev/null 2>&1 && vf_docker_present &&
		docker compose version >/dev/null 2>&1 &&
		[ -r /etc/docker/daemon.json ]
}

mod_docker_ask() {
	if [ "$VF_NONINTERACTIVE" != "1" ]; then
		local v
		v="$(cfg_get docker.bind_ip 127.0.0.1)"
		v="$(vf_ask docker.bind_ip "Docker published ports bind to (ENTER = 127.0.0.1, recommended)" "$v" "127.0.0.1" "0.0.0.0")"
		cfg_set docker.bind_ip "$v"
	fi
}

mod_docker_run() {
	# refuse to fight a snap docker silently
	if snap list docker >/dev/null 2>&1; then
		ui_warn "Docker is installed via SNAP — panels and this module require the apt version."
		if ui_confirm "Remove snap docker and install apt docker-ce? (containers/images from snap docker are NOT migrated)" n; then
			snap remove docker >/dev/null 2>&1 || true
		else
			ui_error "refusing to install apt docker alongside snap docker — module aborted"
			return 1
		fi
	fi

	# official repo + GPG key (fingerprint-pinned)
	vf_ensure_dir /etc/apt/keyrings
	local key=/etc/apt/keyrings/docker.asc
	if ! vf_curl -o "$key" https://download.docker.com/linux/ubuntu/gpg; then
		ui_error "could not fetch Docker's signing key — are you online?"
		return 1
	fi
	chmod a+r "$key"
	local fp
	fp="$(gpg --show-keys --with-fingerprint "$key" 2>/dev/null | tr -d ' \n' | grep -oE '[A-F0-9]{40}')"
	if [ "$fp" != "$VF_DOCKER_GPG_FINGERPRINT" ]; then
		ui_error "Docker GPG key fingerprint mismatch (got: ${fp:-none}) — refusing the repo"
		return 1
	fi
	local codename
	codename="$(. /etc/os-release && printf '%s' "$VERSION_CODENAME")"
	vf_write_file /etc/apt/sources.list.d/docker.list 644 <<EOF
deb [arch=$(vf_arch) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${codename} stable
EOF
	vf_apt_update

	vf_pkg_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

	# daemon.json — merge with anything a panel/tool wrote there
	mkdir -p /etc/docker
	vf_backup_file /etc/docker/daemon.json
	local merged
	if [ -r /etc/docker/daemon.json ] && command -v jq >/dev/null 2>&1; then
		merged="$(jq -S --arg ip "$(cfg_get docker.bind_ip 127.0.0.1)" '. +
			{ iptables: true, ip: $ip,
			  "log-driver": "json-file",
			  "log-opts": { "max-size": "10m", "max-file": "3" },
			  "live-restore": true, "userland-proxy": false,
			  "no-new-privileges": true }' /etc/docker/daemon.json 2>/dev/null || true)"
	fi
	if [ -n "${merged:-}" ]; then
		printf '%s\n' "$merged" >/etc/docker/daemon.json
	else docker_daemon_json >/etc/docker/daemon.json; fi
	chmod 644 /etc/docker/daemon.json

	systemctl enable --now docker >/dev/null 2>&1 || systemctl restart docker >/dev/null 2>&1 || true
	sleep 2
	if ! vf_docker_present; then
		ui_error "docker did not start — check: journalctl -u docker -n 30"
		return 1
	fi
	docker info --format 'docker {{.ServerVersion}} running; containers: {{.Containers}}' >&2 || true
	ui_para "default publish bind: $(cfg_get docker.bind_ip 127.0.0.1) (use 'vps-forge docker-allow <port>/<proto>' to expose ports)"
	return 0
}
