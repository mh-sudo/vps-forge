# shellcheck shell=bash
# modules/51-runtimes.sh — Node.js via NodeSource + Python 3 (apt) + pipx.

mod_runtimes_plan() {
	cat <<PLAN
Node.js: $([ "$(cfg_get runtimes.node none)" != none ] && echo "NodeSource apt repo, major $(cfg_get runtimes.node 22)" || echo "not selected")
Python: python3-full + pipx (apt)
PLAN
}

mod_runtimes_ask() {
	if [ "$VF_NONINTERACTIVE" != "1" ]; then
		local n
		n="$(vf_ask runtimes.node "Install Node.js from NodeSource?" "none" "none" "22 (LTS)" "20" "24")"
		cfg_set runtimes.node "${n%% *}"
	fi
}

mod_runtimes_check() {
	[ "$(cfg_get runtimes.node none)" = "none" ] && command -v pipx >/dev/null 2>&1 && return 0
	command -v node >/dev/null 2>&1 && node -v 2>/dev/null | grep -q "v$(cfg_get runtimes.node 22)" && return 0
	return 1
}

mod_runtimes_run() {
	local node
	node="$(cfg_get runtimes.node none)"
	case "$node" in none | "") : ;; 20 | 22 | 24 | 26)
		# NodeSource official setup (GPG-signed repo)
		if vf_curl "https://deb.nodesource.com/setup_${node}.x" -o "$VF_TMP_DIR/nodesource-setup.sh"; then
			bash "$VF_TMP_DIR/nodesource-setup.sh" >"$VF_TMP_DIR/nodesource.log" 2>&1 ||
				{
					tail -5 "$VF_TMP_DIR/nodesource.log" >&2 || true
					ui_warn "NodeSource setup failed — skipping Node"
				}
			vf_pkg_install nodejs
			node -v >&2 || true
		else
			ui_warn "could not reach NodeSource — skipping Node"
		fi
		;;
	*) ui_warn "unsupported Node major '$node' — skipping" ;;
	esac
	if cfg_is_true runtimes.python; then
		vf_pkg_install python3-full python3-pip pipx
	fi
	return 0
}
