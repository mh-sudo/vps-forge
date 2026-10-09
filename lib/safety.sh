# shellcheck shell=bash
# lib/safety.sh — snapshot/backup engine, timed auto-revert guards, safe sshd/ufw changes.
#
# Snapshot layout: /var/backups/vps-forge/<UTC-timestamp>/
#   files/<absolute-path-with-leading-slash-stripped>.orig   first-backup-in-snapshot of that file
#   files/...<ts>                                            latest copy (reference)
#   index.tsv                                                "orig|<path>" and "new|<path>" lines
#   packages.txt                                             packages installed by this run
#   meta.txt                                                 date, argv, version
# The first snapshot ever created is symlinked as "first" and never auto-pruned.

VF_SNAP_DIR=""

vf_snapshot_active() { [ -n "$VF_SNAP_DIR" ] && [ -d "$VF_SNAP_DIR" ]; }

vf_snapshot_note_pkg() { # record package for later removal on rollback/self-clean
	vf_snapshot_active || return 0
	printf '%s\n' "$1" >>"$VF_SNAP_DIR/packages.txt"
}

vf_snapshot_create() {             # vf_snapshot_create [tag]
	[ -n "$VF_SNAP_DIR" ] && return 0 # one snapshot per process
	vf_ensure_dir "$VF_BACKUP_ROOT"
	local ts tag="${1:-run}"
	ts="$(date -u +%Y%m%dT%H%M%SZ)"
	VF_SNAP_DIR="$VF_BACKUP_ROOT/${ts}.${tag}"
	local n=0
	while [ -e "$VF_SNAP_DIR" ]; do
		n=$((n + 1))
		VF_SNAP_DIR="$VF_BACKUP_ROOT/${ts}.${tag}.$n"
	done
	mkdir -p "$VF_SNAP_DIR/files"
	# snapshots hold copies of sshd_config, authorized_keys and similar —
	# keep them root-only
	chmod 700 "$VF_BACKUP_ROOT" "$VF_SNAP_DIR"
	{
		echo "created=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		echo "version=$VF_VERSION"
		echo "argv=$(printf '%q ' "$@")"
		echo "cwd=$PWD"
	} >"$VF_SNAP_DIR/meta.txt"
	if [ ! -e "$VF_BACKUP_ROOT/first" ]; then
		ln -s "$(basename "$VF_SNAP_DIR")" "$VF_BACKUP_ROOT/first"
	fi
	vf_log_info "snapshot created: $VF_SNAP_DIR"
}

vf_backup_file() { # vf_backup_file <path> — first backup in snapshot becomes .orig; new files marked
	local p="$1"
	[ -e "$p" ] || {
		vf_snapshot_active && { printf 'new|%s\n' "$p" >>"$VF_SNAP_DIR/index.tsv"; }
		return 0
	}
	vf_snapshot_active || return 0
	local rel="${p#/}"
	local dst="$VF_SNAP_DIR/files/$rel"
	mkdir -p "$(dirname "$dst")"
	if [ ! -e "$dst.orig" ]; then
		cp -a "$p" "$dst.orig"
		printf 'orig|%s\n' "$p" >>"$VF_SNAP_DIR/index.tsv"
	else
		cp -a "$p" "$dst.latest"
	fi
	vf_log_info "backed up: $p"
}

vf_write_file() { # vf_write_file <dest> [mode]  — content on stdin, atomic, backed up
	local dest="$1" mode="${2:-}"
	vf_backup_file "$dest"
	local tmp
	tmp="$(mktemp "${dest%/}.vfXXXXXX")"
	cat >"$tmp" || {
		rm -f "$tmp"
		return 1
	}
	chmod "${mode:-$([ -e "$dest" ] && stat -c %a "$dest" || echo 644)}" "$tmp"
	if [ -e "$dest" ]; then
		chown --reference="$dest" "$tmp" 2>/dev/null || true
	fi
	mv -f "$tmp" "$dest"
	vf_log_info "wrote: $dest"
}

vf_file_has_marker() { grep -q "vps-forge BEGIN" "$1" 2>/dev/null; }

vf_write_block() { # vf_write_block <file> <marker-id> — replace managed block (stdin) or append
	local file="$1" id="$2" tmp
	vf_backup_file "$file"
	touch "$file"
	tmp="$(mktemp)"
	awk -v id="$id" '
		$0 ~ "# vps-forge BEGIN "id { skip=1; next }
		$0 ~ "# vps-forge END "id   { skip=0; next }
		!skip { print }
	' "$file" >"$tmp"
	printf '# vps-forge BEGIN %s\n' "$id" >>"$tmp"
	cat >>"$tmp"
	printf '# vps-forge END %s\n' "$id" >>"$tmp"
	cat "$tmp" >"$file"
	rm -f "$tmp"
	vf_log_info "managed block '$id' updated in $file"
}

# ---------- timed auto-revert guards (systemd-run transient timers) ----------

vf_guard_start() { # vf_guard_start <name> <seconds> <shell-cmd>
	local name="$1" secs="$2"
	shift 2
	local unit="vpsforge-${name}"
	# clean any leftovers
	systemctl stop "${unit}.timer" >/dev/null 2>&1 || true
	systemctl reset-failed "$unit" >/dev/null 2>&1 || true
	if ! systemd-run --unit="$unit" --on-active="${secs}s" \
		--description="vps-forge auto-revert guard: $name" /bin/bash -c "$*" \
		>>"$VF_TMP_DIR/guard.log" 2>&1; then
		vf_log_error "failed to arm guard '$name' — refusing to proceed with risky change"
		return 1
	fi
	vf_log_warn "guard ARMED: $unit reverts in ${secs}s via: $*"
	printf 'guard|%s|%s\n' "$name" "$*" >>"$VF_TMP_DIR/guards-armed.txt"
}

vf_guard_cancel() { # -> 0 if cancelled while armed, 1 if the timer already fired
	local unit="vpsforge-$1"
	if systemctl is-active --quiet "${unit}.timer" 2>/dev/null; then
		systemctl stop "${unit}.timer" >/dev/null 2>&1 || true
		systemctl reset-failed "$unit" >/dev/null 2>&1 || true
		vf_log_info "guard CANCELLED: $unit"
		return 0
	fi
	# the guard is not armed anymore — either it already fired (change REVERTED)
	# or it was cancelled elsewhere; callers must not report success on rc=1
	vf_log_warn "guard $unit is NOT armed (already fired or gone) — the change may have been reverted"
	return 1
}

vf_guard_list() {
	systemctl list-units 'vpsforge-*' --all --no-legend 2>/dev/null || true
}

# ---------- sshd helpers ----------

vf_sshd_validate() {
	if ! sshd -t >>"$VF_TMP_DIR/sshd-t.log" 2>&1; then
		vf_log_error "sshd -t FAILED: $(tail -3 "$VF_TMP_DIR/sshd-t.log" 2>/dev/null | tr '\n' ' ')"
		return 1
	fi
}

vf_sshd_conf_file() { printf '%s' /etc/ssh/sshd_config.d/00-vps-forge.conf; }

vf_sshd_restart() {
	systemctl restart ssh 2>/dev/null || systemctl restart sshd
}

# Apply a full drop-in content with validation + guard + confirm-from-new-session.
# stdin: new /etc/ssh/sshd_config.d/00-vps-forge.conf content
vf_sshd_apply_dropin() {
	local conf
	conf="$(vf_sshd_conf_file)"
	vf_backup_file "$conf"
	local new
	new="$(mktemp)"
	cat >"$new"

	# Validate BEFORE touching the live config: write to a staging name, test, then move.
	local staging="/etc/ssh/sshd_config.d/.00-vps-forge.staging.conf"
	cp "$new" "$staging"
	mv "$staging" "$conf"
	if ! vf_sshd_validate; then
		vf_log_error "new sshd config invalid — restoring previous config"
		local orig="$VF_SNAP_DIR/files/${conf#/}.orig"
		if [ -f "$orig" ]; then
			cp -a "$orig" "$conf"
		else
			rm -f "$conf"
		fi
		vf_sshd_validate || true
		vf_sshd_restart || true
		rm -f "$new"
		return 1
	fi
	rm -f "$new"

	vf_log_info "sshd config valid; arming guard and restarting"
	vf_guard_start "sshd" "${VF_GUARD_TIMEOUT:-180}" \
		"cp -a '$VF_SNAP_DIR/files/${conf#/}.orig' '$conf' 2>/dev/null || rm -f '$conf'; systemctl restart ssh sshd 2>/dev/null; logger -t vps-forge 'sshd auto-reverted by guard'"
	vf_sshd_restart || {
		vf_log_error "sshd restart failed"
		return 1
	}
	return 0
}

# Confirm a risky change from a NEW session (interactive) — non-interactive runs
# NEVER auto-confirm a fail-closed change (sshd/port): the guard stays armed and
# will auto-revert unless the operator verifies externally and runs
# `vps-forge guard-cancel <name>`. Fail-open changes (ufw enable) pass
# `failopen` as the 3rd arg and auto-confirm after internal checks.
vf_confirm_new_session() { # vf_confirm_new_session "human description" [port-hint|failopen]
	local what="$1" hint="${2:-}" to="${VF_GUARD_TIMEOUT:-180}"
	if [ "$VF_NONINTERACTIVE" = "1" ]; then
		if [ "$hint" = "failopen" ]; then
			# fail-open auto-confirm is ONLY honest after proving the ssh port is
			# actually allowed — otherwise the firewall would stay up with no
			# auto-revert and no way in
			local ports p
			ports="$(vf_current_ssh_ports)"
			[ -n "$ports" ] || ports="$(vf_effective_ssh_port)"
			for p in $ports; do
				[ -n "$p" ] || continue
				if ufw status 2>/dev/null | grep -q -- "$p"; then
					ui_para "non-interactive fail-open change ('$what'): ufw allows ssh port $p — confirming"
					return 0
				fi
			done
			ui_error "fail-open check FAILED: no ssh port allowed in ufw — the auto-revert guard stays armed"
			return 1
		fi
		ui_warn "Non-interactive run: '$what' is protected by an auto-revert timer (${to}s)."
		ui_para "Verify from a NEW ssh session, then run:  vps-forge guard-cancel <name>"
		ui_para "Without it the change AUTO-REVERTS (the safe outcome for unverified access)."
		return 1
	fi
	local tries=0
	while [ $tries -lt 5 ]; do
		tries=$((tries + 1))
		if ui_confirm "OPEN A NEW TERMINAL and verify: $what ${hint:+($hint)} — did it work?"; then
			return 0
		fi
		ui_warn "Not confirmed yet. The auto-revert guard is still armed."
		if ! ui_confirm "Try again? (No = let the guard auto-revert the change)"; then
			return 1
		fi
	done
	return 1
}

# ---------- ufw helpers ----------

vf_ufw_active() { ufw status 2>/dev/null | grep -q "Status: active"; }

vf_ufw_allow_port() { # vf_ufw_allow_port <port/proto> [allow|limit] — checked: fails if the rule is absent
	local pp="$1" mode="${2:-allow}"
	local sub="$mode"
	case "$sub" in allow | limit) ;; *) sub=allow ;; esac
	if ! ufw "$sub" "$pp" >>"$VF_TMP_DIR/ufw.log" 2>&1; then
		vf_log_error "ufw $sub $pp failed (see $VF_TMP_DIR copy in log)"
		return 1
	fi
	# prove the rule took effect before continuing
	ufw status 2>/dev/null | grep -q -- "$pp"
}

vf_ufw_safe_enable() { # ensures ssh ports allowed, then enables with guard
	local ports p
	ports="$(vf_current_ssh_ports) $(cfg_get ssh.port keep | sed 's/keep//')"
	for p in $ports; do
		if [[ "$p" =~ ^[0-9]+$ ]]; then
			vf_ufw_allow_port "$p/tcp" limit || return 1
		fi
	done
	ufw default deny incoming >/dev/null 2>&1 || true
	ufw default allow outgoing >/dev/null 2>&1 || true
	if vf_ufw_active; then
		vf_log_info "ufw already active; rules refreshed"
		return 0
	fi
	if cfg_is_true fw.guard; then
		vf_guard_start "ufw" "$((${VF_GUARD_TIMEOUT:-180} + 120))" "ufw --force disable; logger -t vps-forge 'ufw auto-disabled by guard'"
	fi
	ufw --force enable >/dev/null 2>&1 || {
		vf_log_error "ufw enable failed"
		return 1
	}
	vf_log_info "ufw ENABLED (deny incoming; ssh rate-limited)"
	return 0
}

# ---------- provider out-of-band console hint ----------

vf_provider_hint() {
	local vendor product out
	vendor="$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo unknown)"
	product="$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)"
	# exact vendor matches — a glob like *DO* used to fire for ANY string
	# containing "DO", and every on-prem Hyper-V guest announced Azure
	case "$vendor $product" in
	*Hetzner*) out="Hetzner Cloud Console: https://console.hetzner.cloud → your server → Console (and Rescue mode)." ;;
	*DigitalOcean*) out="DigitalOcean: https://cloud.digitalocean.com → Droplet → Access → Recovery/Droplet console." ;;
	*Amazon* | *EC2*) out="AWS EC2: connect via Session Manager or the browser console (ec2instanceconnect/serial console)." ;;
	*Google* | *GCE*) out="GCP: Serial console via https://console.cloud.google.com → Compute Engine → VM → Serial console." ;;
	*Oracle*) out="Oracle Cloud: Cloud Shell / serial console from the instance page." ;;
	*Vultr*) out="Vultr: https://my.vultr.com → server → View Console (and Rescue ISO)." ;;
	*OVH* | *ovh*) out="OVH: KVM console from the OVH manager (Bare Metal/VM → ...)." ;;
	*Linode* | *Akamai*) out="Linode: Lish console from the Cloud Manager." ;;
	*)
		# KVM/QEMU also reports "QEMU"; VMware "VMware"; only Hyper-V says Microsoft
		if [ "$(systemd-detect-virt 2>/dev/null)" = "microsoft" ] && command -v systemd-detect-virt >/dev/null 2>&1; then
			out="Hyper-V guest: use VMConnect from the hypervisor host. If this is an AZURE VM, use Serial Console in the Azure portal (https://portal.azure.com)."
		else
			out="Unknown provider (DMI: $vendor / $product). Find the VNC/console or rescue option in your provider's control panel BEFORE continuing."
		fi
		;;
	esac
	printf '%s' "$out"
}

# ---------- rollback ----------

vf_do_rollback() { # vf_do_rollback [snapshot-dir-name]  (VF_ROLLBACK_FORCE=1 skips confirms for scripted use)
	vf_need_root
	local target="${1:-}" snap
	if [ -z "$target" ]; then
		snap="$(ls -1dt "$VF_BACKUP_ROOT"/*/ 2>/dev/null | head -1)"
		[ -n "$snap" ] || vf_die "no snapshots found under $VF_BACKUP_ROOT"
	else
		snap="$VF_BACKUP_ROOT/$target"
		[ -d "$snap" ] || snap="$VF_BACKUP_ROOT/${target%/}"
		[ -d "$snap" ] || vf_die "snapshot not found: $target"
	fi
	snap="${snap%/}"
	ui_header "Rolling back snapshot: $(basename "$snap")"
	ui_warn "This restores every file recorded in the snapshot and can purge packages it installed. SSH access may restart."
	if [ "${VF_ROLLBACK_FORCE:-0}" = "1" ]; then
		ui_warn "Scripted rollback (--force): interactive confirmations SKIPPED."
		vf_log_warn "rollback forced via --force (snapshot $(basename "$snap"))"
	elif ! ui_confirm "Continue with rollback?" n; then
		ui_para "Aborted."
		exit 0
	fi

	# restore files
	local kind path n=0 failed=0
	[ -r "$snap/index.tsv" ] || vf_die "snapshot has no index.tsv"
	while IFS='|' read -r kind path; do
		[ -n "${path:-}" ] || continue
		case "$kind" in
		orig)
			local rel="${path#/}"
			if [ -e "$snap/files/$rel.orig" ]; then
				mkdir -p "$(dirname "$path")"
				cp -a "$snap/files/$rel.orig" "$path" && n=$((n + 1)) || {
					failed=$((failed + 1))
					vf_log_error "restore failed: $path"
				}
			fi
			;;
		new)
			rm -f -- "$path" && n=$((n + 1)) || failed=$((failed + 1))
			;;
		esac
	done <"$snap/index.tsv"
	ui_para "Files restored: $n (failed: $failed)"

	# offer package purge
	if [ -s "$snap/packages.txt" ]; then
		sort -u "$snap/packages.txt" | tr '\n' ' ' >"$VF_TMP_DIR/rb-pkgs.txt"
		ui_para "Packages installed in that run: $(cat "$VF_TMP_DIR/rb-pkgs.txt")"
		if [ "${VF_ROLLBACK_FORCE:-0}" = "1" ] || ui_confirm "Purge these packages? (may remove things you now depend on)" n; then
			# shellcheck disable=SC2046
			vf_pkg_purge $(tr '\n' ' ' <"$VF_TMP_DIR/rb-pkgs.txt")
		fi
	fi

	# restart likely-affected services
	if [ -d /etc/ssh ]; then vf_sshd_validate && vf_sshd_restart && ui_ok "sshd restarted with restored config"; fi
	systemctl restart ufw >/dev/null 2>&1 || true
	if command -v systemctl >/dev/null; then systemctl daemon-reload || true; fi
	ui_para "Rollback complete. Open a NEW ssh session to confirm access before closing this one."
	vf_log_info "rollback of $(basename "$snap") done (files=$n failed=$failed)"
}
