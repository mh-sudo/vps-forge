# shellcheck shell=bash
# lib/runner.sh — manifest parsing, module selection, ask/plan/run phases, report.

declare -a M_IDS=() M_FILES=() M_TITLES=() M_RISK=() M_DESC=() M_PROFILES=()
declare -a RUN_ORDER=() RUN_STATUS=() RUN_DETAIL=()
declare -A LYNIS

manifest_load() {
	local f="$VF_MODULE_DIR/manifest.conf" id file title profiles risk desc
	[ -r "$f" ] || vf_die "manifest not found: $f"
	while IFS='|' read -r id file title profiles risk desc; do
		case "$id" in '' | \#*) continue ;; esac
		[ -r "$VF_MODULE_DIR/$file" ] || {
			vf_log_warn "manifest references missing file: $file (skipped)"
			continue
		}
		M_IDS+=("$id")
		M_FILES+=("$file")
		M_TITLES+=("$title")
		M_PROFILES+=("$profiles")
		M_RISK+=("$risk")
		M_DESC+=("$desc")
	done <"$f"
	vf_log_info "manifest loaded: ${#M_IDS[@]} modules"
}

manifest_index_of() { # -> index or empty
	local i id="$1"
	for i in "${!M_IDS[@]}"; do [ "${M_IDS[$i]}" = "$id" ] && {
		echo "$i"
		return
	}; done
}

profile_module_ids() { # -> space-separated ids for a profile name
	local profile="$1" i out="" p
	for i in "${!M_IDS[@]}"; do
		IFS=',' read -ra p <<<"${M_PROFILES[$i]}"
		for id in "${p[@]}"; do [ "$id" = "$profile" ] && out+="${M_IDS[$i]} "; done
	done
	printf '%s' "$out"
}

selection_pick() { # interactive/custom selection; sets RUN_ORDER from ids list or profile
	local requested="$1" i idx id all=()
	if [ "$requested" != "custom" ]; then
		local sel
		sel="$(profile_module_ids "$requested")"
		[ -n "$sel" ] || vf_die "unknown profile: $requested (use minimal|recommended|dockerhost|custom)"
		for id in $sel; do RUN_ORDER+=("$id"); done
	else
		for i in "${!M_IDS[@]}"; do
			all+=("${M_IDS[$i]} [${M_RISK[$i]}]")
		done
		local def="" pre="" id2
		def="$(profile_module_ids recommended)"
		for id2 in $def; do
			idx="$(manifest_index_of "$id2")"
			pre+="${M_IDS[$idx]} [${M_RISK[$idx]}],"
		done
		pre="${pre%,}"
		local chosen
		chosen="$(ui_multi "Select modules (arrows/space, enter to confirm)" "$pre" "${all[@]}")" || vf_die "selection cancelled"
		local c
		for c in $(printf '%s' "$chosen" | tr ',' ' '); do
			id="${c%% \[*}"
			RUN_ORDER+=("$id")
		done
	fi
	# panels are mutually exclusive
	local panels=() r
	for r in "${RUN_ORDER[@]}"; do case "$r" in panel_*) panels+=("$r") ;; esac done
	if [ "${#panels[@]}" -gt 1 ]; then
		ui_warn "Panels are mutually exclusive: chose ${panels[*]}"
		local pick
		pick="$(ui_choose "Which panel do you want?" "${panels[@]}")" || vf_die "cancelled"
		local filtered=()
		for r in "${RUN_ORDER[@]}"; do
			case "$r" in panel_*) [ "$r" = "$pick" ] && filtered+=("$r") ;; *) filtered+=("$r") ;; esac
		done
		RUN_ORDER=("${filtered[@]}")
		cfg_set panel "${pick#panel_}"
	fi
	# panel prerequisites/conflicts
	if printf '%s\n' "${RUN_ORDER[@]}" | grep -q '^panel_'; then
		local has_panel="" again=()
		for r in "${RUN_ORDER[@]}"; do case "$r" in panel_*) has_panel="$r" ;; esac done
		for r in "${RUN_ORDER[@]}"; do
			if [ "$r" = "reverse_proxy" ]; then
				ui_warn "dropping the reverse-proxy module — the panel (${has_panel#panel-}) owns ports 80/443"
				continue
			fi
			again+=("$r")
		done
		RUN_ORDER=("${again[@]}")
		# coolify sits on Docker: make sure docker + docker-fw are included
		if [ "$has_panel" = "panel_coolify" ]; then
			local hasdocker=0
			for r in "${RUN_ORDER[@]}"; do [ "$r" = "docker" ] && hasdocker=1; done
			if [ "$hasdocker" = "0" ]; then
				ui_warn "adding the docker module — Coolify runs on Docker"
				RUN_ORDER+=("docker")
			fi
			local hasfw=0
			for r in "${RUN_ORDER[@]}"; do [ "$r" = "docker_fw" ] && hasfw=1; done
			if [ "$hasfw" = "0" ]; then RUN_ORDER+=("docker_fw"); fi
		fi
	fi
	# sort by manifest order
	local sorted=()
	for i in "${!M_IDS[@]}"; do
		for r in "${RUN_ORDER[@]}"; do [ "${M_IDS[$i]}" = "$r" ] && sorted+=("$r"); done
	done
	RUN_ORDER=("${sorted[@]}")
	[ "${#RUN_ORDER[@]}" -gt 0 ] || vf_die "no modules selected"
	vf_log_info "selected modules: ${RUN_ORDER[*]}"
}

module_source_all() {
	local id idx f
	for id in "${RUN_ORDER[@]}"; do
		idx="$(manifest_index_of "$id")"
		f="$VF_MODULE_DIR/${M_FILES[$idx]}"
		vf_log_info "sourcing module file: $f"
		# shellcheck source=/dev/null
		source "$f" || vf_die "failed to source $f"
		declare -F "mod_${id}_run" >/dev/null || vf_die "$f does not define mod_${id}_run"
	done
}

module_ask_all() {
	local id
	for id in "${RUN_ORDER[@]}"; do
		declare -F "mod_${id}_ask" >/dev/null || continue
		vf_log_info "ask phase: $id"
		"mod_${id}_ask" || vf_log_warn "ask phase failed for $id (continuing with defaults)"
	done
}

module_plan_all() { # -> writes human-readable plan to $VF_PLAN_FILE
	VF_PLAN_FILE="$VF_TMP_DIR/plan.txt"
	local id idx
	{
		echo "Vps Forge $VF_VERSION — planned changes"
		echo "server: $(hostname) — $(date -u)"
		echo "modules: ${RUN_ORDER[*]}"
		echo
		for id in "${RUN_ORDER[@]}"; do
			idx="$(manifest_index_of "$id")"
			echo "── ${M_TITLES[$idx]} (${id})  [risk: ${M_RISK[$idx]}]"
			if declare -F "mod_${id}_check" >/dev/null && "mod_${id}_check" 2>/dev/null; then
				echo "    (already applied — will be re-validated only)"
			else
				"mod_${id}_plan" 2>/dev/null | sed 's/^/    /'
			fi
			echo
		done
	} >"$VF_PLAN_FILE"
}

module_run_all() {
	local id idx n=0 total="${#RUN_ORDER[@]}" rc
	for id in "${RUN_ORDER[@]}"; do
		n=$((n + 1))
		idx="$(manifest_index_of "$id")"
		mkdir -p "$VF_TMP_DIR" 2>/dev/null || true # self-heal if something removed our scratch
		ui_header "[$n/$total] ${M_TITLES[$idx]}"
		RUN_STATUS[$((n - 1))]="pending"
		RUN_DETAIL[$((n - 1))]=""
		if declare -F "mod_${id}_check" >/dev/null && "mod_${id}_check" 2>>"$VF_TMP_DIR/mod-$id.log"; then
			ui_skip "${M_TITLES[$idx]}"
			RUN_STATUS[$((n - 1))]="skipped"
			RUN_DETAIL[$((n - 1))]="already applied"
			vf_log_info "module $id: skipped (already applied)"
			continue
		fi
		vf_log_info "module $id: running"
		if "mod_${id}_run" 2>>"$VF_TMP_DIR/mod-$id.log"; then
			ui_ok "${M_TITLES[$idx]}"
			RUN_STATUS[$((n - 1))]="ok"
			printf '%s\n' "$(date -u +%FT%TZ)" >"$VF_STATE_DIR/applied/$id.done" 2>/dev/null || {
				mkdir -p "$VF_STATE_DIR/applied"
				printf '%s\n' "$(date -u +%FT%TZ)" >"$VF_STATE_DIR/applied/$id.done"
			}
		else
			rc=$?
			ui_fail "${M_TITLES[$idx]} (exit $rc) — see $(basename "$VF_LOG_FILE")"
			tail -5 "$VF_TMP_DIR/mod-$id.log" >&2 || true
			RUN_STATUS[$((n - 1))]="failed"
			RUN_DETAIL[$((n - 1))]="exit $rc"
			if [ "$VF_NONINTERACTIVE" = "1" ]; then
				if [ "${VF_KEEP_GOING:-0}" != "1" ]; then
					vf_log_error "aborting (module $id failed; use --keep-going to continue)"
					break
				fi
			elif ! ui_confirm "A module failed. Continue with the remaining modules?" y; then
				break
			fi
		fi
	done
	return 0
}

# ---------- Lynis before/after ----------

lynis_available() { command -v lynis >/dev/null 2>&1; }

lynis_ensure() {
	if ! lynis_available; then
		vf_apt_update && apt-get install -y -qq lynis >>"$VF_TMP_DIR/apt.log" 2>&1 || return 1
	fi
}

lynis_run() { # lynis_run pre|post
	local when="$1"
	lynis_available || return 1
	ui_spin "Running Lynis audit ($when) — this takes ~1 minute" -- \
		"lynis audit system --quick" >/dev/null 2>&1 || true
	local dat=/var/log/lynis-report.dat
	[ -r "$dat" ] || return 1
	# '|| true' — grep exits 1 when the field is absent (e.g. zero warnings);
	# under pipefail+ERR-trap that would otherwise kill the whole run
	LYNIS["${when}_index"]="$(grep '^hardening_index' "$dat" | tail -1 | cut -d= -f2 || true)"
	LYNIS["${when}_warnings"]="$(grep '^warnings' "$dat" | tail -1 | cut -d= -f2 || true)"
	LYNIS["${when}_suggestions"]="$(grep '^suggestions' "$dat" | tail -1 | cut -d= -f2 || true)"
	cp -f "$dat" "$VF_STATE_DIR/lynis-$when.dat" 2>/dev/null || true
	vf_log_info "lynis $when: index=${LYNIS[${when}_index]:-?} warnings=${LYNIS[${when}_warnings]:-?}"
}

# ---------- report ----------

report_write() {
	local f="$VF_REPORT_FILE" i idx id
	{
		echo "════════════════════════════════════════════════"
		echo " Vps Forge $VF_VERSION — run report"
		echo " $(date -u '+%Y-%m-%d %H:%M:%S UTC') on $(hostname)"
		echo "════════════════════════════════════════════════"
		echo
		echo "MODULES"
		for i in "${!RUN_ORDER[@]}"; do
			id="${RUN_ORDER[$i]}"
			idx="$(manifest_index_of "$id")"
			printf '  [%s] %s (%s)%s\n' "${RUN_STATUS[$i]:-?}" "${M_TITLES[$idx]}" "$id" "${RUN_DETAIL[$i]:+ — ${RUN_DETAIL[$i]}}"
		done
		echo
		echo "LYNIS HARDENING"
		if [ -n "${LYNIS[pre_index]:-}" ] || [ -n "${LYNIS[post_index]:-}" ]; then
			echo "  before: index ${LYNIS[pre_index]:-n/a}, warnings ${LYNIS[pre_warnings]:-n/a}"
			echo "  after:  index ${LYNIS[post_index]:-n/a}, warnings ${LYNIS[post_warnings]:-n/a}"
			if [ -n "${LYNIS[pre_index]:-}" ] && [ -n "${LYNIS[post_index]:-}" ]; then
				echo "  delta:  $((LYNIS[post_index] - LYNIS[pre_index])) points"
			fi
		else
			echo "  (lynis audit not run)"
		fi
		echo
		echo "SNAPSHOT"
		echo "  ${VF_SNAP_DIR:-none}"
		if [ -n "${VF_SNAP_DIR:-}" ]; then
			echo "  rollback with: vps-forge rollback $(basename "$VF_SNAP_DIR")"
		else
			echo "  rollback with: vps-forge rollback   (latest snapshot)"
		fi
		echo
		echo "CREDENTIALS"
		[ -d "$VF_CREDS_DIR" ] && ls -1 "$VF_CREDS_DIR" | sed 's/^/  saved: /' || echo "  (none generated)"
		echo
		if [ -e /var/run/reboot-required ]; then
			echo "REBOOT: REQUIRED — a reboot is needed to apply kernel/libc updates."
		else
			echo "REBOOT: not required for the changes applied."
		fi
	} >"$f"
	chmod 600 "$f"
	vf_log_info "report written: $f"
}

summary_render() {
	ui_header "Summary"
	local i idx id fails=0
	for i in "${!RUN_ORDER[@]}"; do
		id="${RUN_ORDER[$i]}"
		idx="$(manifest_index_of "$id")"
		case "${RUN_STATUS[$i]:-pending}" in
		ok) ui_ok "${M_TITLES[$idx]}" ;;
		skipped) ui_skip "${M_TITLES[$idx]}" ;;
		failed)
			ui_fail "${M_TITLES[$idx]} ${RUN_DETAIL[$i]:-}"
			fails=$((fails + 1))
			;;
		pending) ui_fail "${M_TITLES[$idx]} (not run — aborted)" ;;
		esac
	done
	[ -n "${LYNIS[post_index]:-}" ] && ui_para "Lynis hardening index: ${LYNIS[pre_index]:-?} → ${LYNIS[post_index]}"
	ui_para "Full report: $VF_REPORT_FILE"
	ui_para "Backups/snapshot: ${VF_SNAP_DIR:-none} — rollback: vps-forge rollback"
	[ -e /var/run/reboot-required ] && ui_warn "A REBOOT is recommended."
	return "$fails"
}
