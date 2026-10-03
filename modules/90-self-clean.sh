# shellcheck shell=bash
# modules/90-self-clean.sh — 'vps-forge self-clean': remove everything vps-forge applied.
# Uses the FIRST-ever snapshot (original state) + state dir. NEVER touches the
# current ssh session's access path until the very end (guarded, verified).

self_clean() { # self_clean [scope]
	local scope="${1:-all}"
	ui_header "vps-forge self-clean (scope: $scope)"
	ui_warn "This removes vps-forge's users, packages, config files, firewall rules, Docker
containers/images, timers and snapshots, and restores original config files from
the FIRST snapshot. It is designed to return the server close to a fresh state."
	if [ "${VF_CLEAN_YES:-0}" != "1" ]; then
		ui_confirm "Type-confirm: this is destructive. Proceed?" n || {
			ui_para "aborted"
			return 0
		}
	fi

	vf_snapshot_create self-clean || true
	# load remembered answers BEFORE touching the state dir — the admin username
	# recorded there drives the user removal below
	cfg_load_state || true

	local first="$VF_BACKUP_ROOT/first"
	if [ -d "$first" ] && [ -r "$first/index.tsv" ]; then
		local kind path rel n=0
		# ORIG restores: for every path recorded in ANY snapshot, restore the copy
		# from the EARLIEST snapshot that backed it up (the pristine original).
		# NEW removals: files first created by any run are removed.
		local snaps=()
		mapfile -t snaps < <(ls -1d "$VF_BACKUP_ROOT"/*/ 2>/dev/null | sort)
		local seen_restore="/tmp/vps-forge-restore-seen.$$"
		: >"$seen_restore"
		# pass 1: origs, oldest snapshot first
		local snap
		for snap in "${snaps[@]}"; do
			[ -r "$snap/index.tsv" ] || continue
			while IFS='|' read -r kind path; do
				[ "$kind" = "orig" ] && [ -n "${path:-}" ] || continue
				grep -qxF "$path" "$seen_restore" && continue
				rel="${path#/}"
				if [ -e "$snap/files/$rel.orig" ]; then
					mkdir -p "$(dirname "$path")"
					cp -a "$snap/files/$rel.orig" "$path" 2>/dev/null && {
						printf '%s\n' "$path" >>"$seen_restore"
						n=$((n + 1))
					} || true
				fi
			done <"$snap/index.tsv"
		done
		# pass 2: news (removals), all snapshots
		for snap in "${snaps[@]}"; do
			[ -r "$snap/index.tsv" ] || continue
			while IFS='|' read -r kind path; do
				[ "$kind" = "new" ] && [ -n "${path:-}" ] || continue
				rm -f -- "$path" 2>/dev/null && n=$((n + 1)) || true
			done <"$snap/index.tsv"
		done
		rm -f "$seen_restore"
		ui_para "restored/removed $n recorded paths"
	else
		ui_warn "no first snapshot found — files will only be removed by pattern below"
	fi

	if [ "$scope" = "all" ] || [ "$scope" = "panels" ]; then
		# remove any installed panel first (containers/stack)
		# shellcheck source=/dev/null
		for pm in 70-panel-coolify.sh 71-panel-cloudpanel.sh 72-panel-cyberpanel.sh; do
			[ -r "$VF_MODULE_DIR/$pm" ] && source "$VF_MODULE_DIR/$pm"
		done
		command -v panel_remove_coolify >/dev/null && panel_remove_coolify || true
		command -v panel_remove_cloudpanel >/dev/null && panel_remove_cloudpanel || true
		command -v panel_remove_cyberpanel >/dev/null && panel_remove_cyberpanel || true
	fi

	# vps-forge-created systemd units/timers
	local u
	for u in vps-forge-health.timer vps-forge-health.service vps-forge-restic.timer \
		vps-forge-restic.service vps-forge-docker-fw.service node_exporter.service \
		caddy cloudflared wg-quick@wg0; do
		systemctl disable --now "$u" >/dev/null 2>&1 || true
		rm -f "/etc/systemd/system/$u" "/etc/systemd/system/$u.timer" 2>/dev/null || true
	done
	rm -f /etc/systemd/system/docker.service.d/10-vps-forge-fw.conf
	rmdir /etc/systemd/system/docker.service.d 2>/dev/null || true
	rm -f /usr/local/sbin/vps-forge-docker-fw-load /usr/local/sbin/vps-forge-health
	systemctl daemon-reload || true

	if [ "$scope" = "all" ] || [ "$scope" = "docker" ]; then
		systemctl stop docker >/dev/null 2>&1 || true
		rm -rf /var/lib/docker /var/lib/containerd /etc/docker/daemon.json /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.asc
		apt-get purge -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null 2>&1 || true
		iptables -F DOCKER-USER >/dev/null 2>&1 || true
		ip6tables -F DOCKER-USER >/dev/null 2>&1 || true
	fi

	if [ "$scope" = "all" ]; then
		# users vps-forge created
		local user
		for user in "$(cfg_get admin.username none)" deploy node_exporter; do
			[ "$user" = "none" ] && continue
			id "$user" >/dev/null 2>&1 && { userdel -r "$user" 2>/dev/null || userdel "$user" 2>/dev/null || true; }
		done
		# packages recorded in ALL snapshots
		local pkgs=() snap
		while read -r snap; do
			if [ -s "$snap/packages.txt" ]; then
				mapfile -t -O "${#pkgs[@]}" pkgs < <(sort -u "$snap/packages.txt")
			fi
		done < <(ls -1dt "$VF_BACKUP_ROOT"/*/ 2>/dev/null)
		if [ "${#pkgs[@]}" -gt 0 ]; then
			printf '%s\n' "purging recorded packages: ${pkgs[*]}"
			# shellcheck disable=SC2046
			apt-get purge -y -qq $(printf '%s\n' "${pkgs[@]}" | sort -u | tr '\n' ' ') >/dev/null 2>&1 || true
			apt-get autoremove -y -qq >/dev/null 2>&1 || true
		fi
		# vps-forge config/data footprint
		rm -rf "$VF_ETC_DIR" "$VF_STATE_DIR" "$VF_CREDS_DIR" /etc/vps-forge
		rm -f /root/vps-forge-report.txt
		# firewall: reset ufw to disabled/empty (original state on a fresh box)
		ufw --force reset >/dev/null 2>&1 || true
		ufw --force disable >/dev/null 2>&1 || true
		# su restriction off
		dpkg-statoverride --remove /bin/su >/dev/null 2>&1 || true
	fi

	# sshd: restored from first snapshot above if it was ever changed
	if [ -d /etc/ssh ]; then
		vf_sshd_validate || {
			ui_error "sshd config invalid after restore — investigating"
			return 1
		}
		vf_guard_start sshd 240 "exit 0" # placeholder guard: nothing to revert, just safety net
		vf_sshd_restart
		vf_guard_cancel sshd
	fi

	ui_para "self-clean complete. Open a NEW ssh session to confirm access before closing this one.
(kept: $(readlink -f "$VF_BACKUP_ROOT/first" 2>/dev/null || echo 'no')} snapshot + this project directory)"
	ui_warn "NOT removed: OS-level changes only visible in the first snapshot are restored, but
any package configuration prompts, kernels, or third-party services you configured
manually remain. For a 100% fresh server, reinstall the OS."
}
