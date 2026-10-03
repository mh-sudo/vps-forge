# shellcheck shell=bash
# modules/41-docker-fw.sh — DOCKER-USER chain management: container ports are
# unreachable from outside by default; explicit allow via 'vps-forge docker-allow'.
#
# Strategy (see DECISIONS.md): Docker's supported DOCKER-USER hook + a loader that
# (re)builds the chain on EVERY docker start (ExecStartPost) and at boot. UFW stays
# the host firewall; the loader is idempotent and backend-agnostic (iptables-nft
# or legacy — Ubuntu default is nft). Raw nftables rulesets are NOT used (Docker
# docs: unsupported alongside Docker).

VF_DF_RULES_FILE="$VF_ETC_DIR/docker-user.rules"
VF_DF_LOADER=/usr/local/sbin/vps-forge-docker-fw-load

docker_fw_write_loader() {
	vf_ensure_dir /usr/local/sbin
	vf_write_file "$VF_DF_LOADER" 755 <<'LOADER'
#!/usr/bin/env bash
# Rebuilt on every docker start by docker.service.d/10-vps-forge-fw.conf.
# Rules source: /etc/vps-forge/docker-user.rules  (allow|tcp|PORT|comment)
set -u
RULES=/etc/vps-forge/docker-user.rules
EXT_IF="$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
[ -n "$EXT_IF" ] || EXT_IF=eth0

ensure_chain() { # $1 = iptables binary, $2 = family
	local ipt="$1"
	$ipt -nL DOCKER-USER >/dev/null 2>&1 || $ipt -N DOCKER-USER
	# Docker must jump to DOCKER-USER from FORWARD; ensure it exists (may be
	# absent after backend switches or restored rulesets — handled explicitly).
	$ipt -C FORWARD -j DOCKER-USER >/dev/null 2>&1 || $ipt -I FORWARD 1 -j DOCKER-USER
	$ipt -F DOCKER-USER
	# 1. replies to outbound container traffic + established inbound
	$ipt -A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
	# 2. container-originated + inter-container traffic (all docker bridges)
	local br
	for br in $(ls /sys/class/net 2>/dev/null | grep -E '^(docker0|br-)'); do
		$ipt -A DOCKER-USER -i "$br" -j ACCEPT
	done
	# 3. explicit per-port allows — matched on the ORIGINAL destination port
	#    via conntrack: DOCKER-USER sees packets AFTER DNAT, so --dport would
	#    compare against the CONTAINER port, not the published one
	#    (per Docker's packet-filtering docs: use conntrack ctorigdst/ctorigdstport)
	if [ -r "$RULES" ]; then
		while IFS='|' read -r act proto port comment; do
			[ "${act:-}" = "allow" ] || continue
			case "$port" in ''|*[!0-9]*) continue ;; esac
			case "$proto" in tcp|udp) ;; *) proto=tcp ;; esac
			$ipt -A DOCKER-USER -i "$EXT_IF" -p "$proto" -m conntrack --ctorigdstport "$port" -j ACCEPT
		done <"$RULES"
	fi
	# 4. default-deny inbound from the outside to published ports
	$ipt -A DOCKER-USER -i "$EXT_IF" -j DROP
	# do not interfere with traffic not arriving from the outside interface
	$ipt -A DOCKER-USER -j RETURN
}

ensure_chain iptables 4
command -v ip6tables >/dev/null 2>&1 && ensure_chain ip6tables 6
exit 0
LOADER
}

docker_fw_write_rules_file() {
	vf_ensure_dir "$VF_ETC_DIR"
	[ -r "$VF_DF_RULES_FILE" ] || {
		: >"$VF_DF_RULES_FILE"
		chmod 644 "$VF_DF_RULES_FILE"
	}
}

docker_fw_install_hook() {
	mkdir -p /etc/systemd/system/docker.service.d
	vf_write_file /etc/systemd/system/docker.service.d/10-vps-forge-fw.conf 644 <<'EOF'
# vps-forge: rebuild DOCKER-USER filtering after every docker start/restart.
# Leading '-' = never block the docker daemon from starting.
[Service]
ExecStartPost=-/usr/local/sbin/vps-forge-docker-fw-load
EOF
	systemctl daemon-reload || true
	# standalone unit for manual/boot-time reconciliation
	vf_write_file /etc/systemd/system/vps-forge-docker-fw.service 644 <<'EOF'
[Unit]
Description=vps-forge DOCKER-USER firewall reconcile
After=docker.service
Wants=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vps-forge-docker-fw-load
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
	systemctl enable vps-forge-docker-fw.service >/dev/null 2>&1 || true
}

docker_fw_reload_live() {
	"$VF_DF_LOADER" || {
		ui_error "DOCKER-USER loader failed"
		return 1
	}
}

docker_fw_allow() { # docker_fw_allow <port/proto> [comment]
	local pp="$1" comment="${2:-manual-allow}"
	local port="${pp%%/*}" proto="${pp#*/}"
	case "$proto" in tcp | udp) ;; *) proto=tcp ;; esac
	case "$port" in '' | *[!0-9]*) vf_die "invalid port: $pp" ;; esac
	docker_fw_write_rules_file
	grep -v "^allow|$proto|$port|" "$VF_DF_RULES_FILE" >"$VF_DF_RULES_FILE.tmp" || true
	printf 'allow|%s|%s|%s\n' "$proto" "$port" "$comment" >>"$VF_DF_RULES_FILE.tmp"
	mv "$VF_DF_RULES_FILE.tmp" "$VF_DF_RULES_FILE"
	docker_fw_reload_live
	echo "allowed $port/$proto from outside to Docker-published ports (persists reboots/restarts)"
	iptables -S DOCKER-USER 2>/dev/null | grep -- "--dport $port " || true
}

docker_fw_deny() { # docker_fw_deny <port/proto>
	local pp="$1"
	local port="${pp%%/*}" proto="${pp#*/}"
	case "$proto" in tcp | udp) ;; *) proto=tcp ;; esac
	docker_fw_write_rules_file
	grep -v "^allow|$proto|$port|" "$VF_DF_RULES_FILE" >"$VF_DF_RULES_FILE.tmp" || true
	mv "$VF_DF_RULES_FILE.tmp" "$VF_DF_RULES_FILE"
	docker_fw_reload_live
	echo "removed allow for $port/$proto (default deny applies again)"
}

docker_fw_status() {
	echo "== /etc/vps-forge/docker-user.rules =="
	cat "$VF_DF_RULES_FILE" 2>/dev/null
	echo "== iptables DOCKER-USER (v4) =="
	iptables -vnL DOCKER-USER 2>/dev/null || echo "(missing)"
	echo "== ip6tables DOCKER-USER (v6) =="
	ip6tables -vnL DOCKER-USER 2>/dev/null || echo "(missing)"
	echo "== FORWARD jump present: $(iptables -C FORWARD -j DOCKER-USER >/dev/null 2>&1 && echo yes || echo NO) =="
}

mod_docker_fw_plan() {
	cat <<'PLAN'
Install DOCKER-USER filtering (default-DENY for externally published container ports):
  - /usr/local/sbin/vps-forge-docker-fw-load (rebuilds chain, idempotent)
  - docker.service drop-in: ExecStartPost reloads rules after EVERY docker start
  - vps-forge-docker-fw.service for boot-time reconcile
  - /etc/vps-forge/docker-user.rules = persistent allow list
Order: established/related ACCEPT -> bridge (inter-container + container-originated)
ACCEPT -> explicit allows -> DROP from $(_df_extif) -> RETURN
Commands: vps-forge docker-allow|docker-deny|docker-fw-status|verify-firewall
PLAN
}
_df_extif() { vf_ext_if_resolved; }

mod_docker_fw_check() {
	[ -x "$VF_DF_LOADER" ] && iptables -nL DOCKER-USER 2>/dev/null | grep -q DROP &&
		[ -r /etc/systemd/system/docker.service.d/10-vps-forge-fw.conf ]
}

mod_docker_fw_run() {
	if ! vf_docker_present && ! command -v docker >/dev/null 2>&1; then
		ui_error "docker is not installed — the docker module must run first"
		return 1
	fi
	docker_fw_write_rules_file
	docker_fw_write_loader
	docker_fw_install_hook
	if vf_docker_present; then
		docker_fw_reload_live || return 1
	else
		"$VF_DF_LOADER" || true # pre-seed chains; docker start will re-run via hook
	fi
	iptables -vnL DOCKER-USER | sed 's/^/  /' >&2 || true
	ui_para "container ports are now BLOCKED from outside by default — open with: vps-forge docker-allow <port>/<proto>"
	return 0
}

# ---------- verify-firewall subcommand ----------

docker_fw_verify() {
	echo "vps-forge verify-firewall — proving the DOCKER-USER default-deny"
	if ! vf_docker_present; then
		echo "FAIL: docker is not running"
		exit 1
	fi
	local TP=18099 IMG="busybox:latest"
	echo "[1/6] asserting DOCKER-USER rules..."
	docker_fw_reload_live || {
		echo "FAIL: loader"
		exit 1
	}
	iptables -C DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT >/dev/null 2>&1 && echo "  ok: established/related ACCEPT" || {
		echo "FAIL: established rule"
		exit 1
	}
	iptables -S DOCKER-USER | grep -q -- "-i $(vf_ext_if_resolved) -p tcp -m conntrack --ctorigdstport $TP -j ACCEPT" && {
		echo "FAIL: port $TP already allowed — deny it first (vps-forge docker-deny $TP/tcp)"
		exit 1
	}
	iptables -S DOCKER-USER | grep -q -- "-i $(vf_ext_if_resolved) -j DROP" && echo "  ok: default DROP from $(vf_ext_if_resolved)" || {
		echo "FAIL: default DROP missing"
		exit 1
	}

	echo "[2/6] starting test container publishing 0.0.0.0:$TP (busybox httpd)..."
	docker rm -f vf-fwtest >/dev/null 2>&1 || true
	if ! docker run -d --name vf-fwtest -p "0.0.0.0:$TP:8080" "$IMG" httpd -f -p 8080 >/dev/null 2>&1; then
		echo "FAIL: could not start test container (image pull failed? retry)"
		exit 1
	fi
	sleep 2

	echo "[3/6] local sanity: service answers on loopback..."
	if curl -fsS --max-time 5 "http://127.0.0.1:$TP/" >/dev/null 2>&1; then
		echo "  ok: container serves on 127.0.0.1:$TP"
	else
		echo "WARN: local curl failed — container may still be starting; continuing"
	fi

	echo "[4/6] EXTERNAL probe: from YOUR computer run:  curl -m 5 http://$(hostname -I | awk '{print $1}'):$TP/"
	echo "      expected result: TIMEOUT (blocked). (A local curl from the server itself proves nothing:"
	echo "      loopback traffic does not traverse DOCKER-USER.)"
	if [ "$VF_NONINTERACTIVE" != "1" ] && ui_confirm "Was the external curl BLOCKED (timeout)?" y; then
		echo "  ok: externally blocked by default"
	else
		echo "  unverified externally (non-interactive or not confirmed) — rules asserted above remain authoritative"
	fi

	echo "[5/6] opening $TP via docker-allow and re-probing..."
	docker_fw_allow "$TP/tcp" "verify-firewall-test"
	echo "      run again from your computer:  curl -m 5 http://$(hostname -I | awk '{print $1}'):$TP/"
	if [ "$VF_NONINTERACTIVE" != "1" ] && ui_confirm "Was the external curl now SUCCESSFUL?" y; then
		echo "  ok: allow works end-to-end"
	else
		echo "  unverified externally — check 'vps-forge docker-fw-status'"
	fi

	echo "[6/6] cleanup..."
	docker rm -f vf-fwtest >/dev/null 2>&1 || true
	docker_fw_deny "$TP/tcp"
	echo "PASS: DOCKER-USER default-deny verified (container removed, test allow removed)"
}
