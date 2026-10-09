# shellcheck shell=bash
# lib/common.sh — shared helpers: logging, config store, packages, misc.
# Sourced by the vps-forge entrypoint; not executable on its own.

# shellcheck disable=SC2034
VF_VERSION="0.2.0"
VF_LIB_DIR="${VF_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
VF_ROOT="$(cd "$VF_LIB_DIR/.." && pwd)"
VF_STATE_DIR="/var/lib/vps-forge"
VF_CREDS_DIR="/root/.vps-forge-credentials"
# shellcheck disable=SC2034
VF_BACKUP_ROOT="/var/backups/vps-forge"
VF_LOG_FILE="/var/log/vps-forge.log"
# shellcheck disable=SC2034
VF_REPORT_FILE="/root/vps-forge-report.txt"
# shellcheck disable=SC2034
VF_ETC_DIR="/etc/vps-forge"
# per-process scratch — /run, NOT /tmp: the tmpfs module mounts a fresh
# tmpfs over /tmp mid-run, which would shadow this directory and fail
# every later module's log redirection ("mod-X.log: No such file or")
# Created lazily by vf_init_tmpdir (after root is confirmed): source-time
# creation used to kill non-root `--version`/`--help` with a raw mktemp error
VF_TMP_DIR=""
vf_init_tmpdir() {
	[ -n "$VF_TMP_DIR" ] && return 0
	VF_TMP_DIR="$(mktemp -d /run/vps-forge.XXXXXX)" || vf_die "cannot create scratch dir under /run"
	# every run cleans up after itself (the dir used to leak one per run)
	trap '[ -n "$VF_TMP_DIR" ] && rm -rf "$VF_TMP_DIR"' EXIT
}
# shellcheck disable=SC2034
VF_MODULE_DIR="$VF_ROOT/modules"
VF_NONINTERACTIVE="${VF_NONINTERACTIVE:-0}"
VF_DRY_RUN="${VF_DRY_RUN:-0}"
VF_VERBOSE="${VF_VERBOSE:-0}"

# Associative config store: merged defaults <- config file <- interactive answers.
declare -A CFG

# ---------- secret redaction ----------

# registered values are replaced in every LOG line (never on the terminal —
# some secrets are deliberately shown once); ui_spin logs command strings,
# so anything passed on a command line must be registered here
declare -a VF_SECRETS=()
vf_secret_register() { # vf_secret_register <value>...
	local v
	for v in "$@"; do
		[ -n "$v" ] && VF_SECRETS+=("$v")
	done
}
vf_redact() { # vf_redact <string> -> stdout with registered secrets masked
	local s="$1" v
	for v in ${VF_SECRETS[@]+"${VF_SECRETS[@]}"}; do
		[ -n "$v" ] && s="${s//"$v"/***REDACTED***}"
	done
	printf '%s' "$s"
}

vf_log() { # vf_log LEVEL message...
	local lvl="$1"
	shift
	printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$lvl" "$(vf_redact "$*")" >>"$VF_LOG_FILE" 2>/dev/null || true
}
vf_log_info() { vf_log INFO "$@"; }
vf_log_warn() { vf_log WARN "$@"; }
vf_log_error() { vf_log ERROR "$@"; }

vf_die() { # vf_die message...
	vf_log_error "fatal: $*"
	printf 'vps-forge: error: %s\n' "$*" >&2
	exit 1
}

vf_running_as_root() { [ "$(id -u)" -eq 0 ]; }

vf_need_root() {
	if ! vf_running_as_root; then
		if command -v sudo >/dev/null 2>&1; then
			vf_log_info "not root; re-execing via sudo"
			# re-exec with the ORIGINAL argv — callers invoke vf_need_root bare,
			# so the function's own "$@" is empty and every flag was being dropped
			exec sudo -E bash "$0" ${VF_ORIG_ARGS+"${VF_ORIG_ARGS[@]}"}
		fi
		vf_die "must run as root (try: sudo $0)"
	fi
	vf_init_tmpdir
}

# ---------- config store ----------

cfg_set() { CFG["$1"]="$2"; }
cfg_get() {
	local k="$1" d="${2-}"
	if [ -n "${CFG[$k]+x}" ]; then printf '%s' "${CFG[$k]}"; else printf '%s' "$d"; fi
}
cfg_has() { [ -n "${CFG[$1]+x}" ]; }
cfg_is_true() { case "$(cfg_get "$1" "false")" in 1 | true | True | TRUE | yes | Yes | YES | on | On | ON) return 0 ;; *) return 1 ;; esac }

cfg_load_defaults() {
	# Default answers for every ask-able key (see README "Configuration keys").
	# NOTE: never preload sentinel-valued keys (sys.timezone/sys.hostname): vf_ask
	# prefills from the stored value, and sentinels like "auto"/"keep" then leak
	# into the input; module-passed defaults cover the unset case.
	local defaults=(
		"sys.locale=en_US.UTF-8"
		"swap.size=auto"
		"perf.zram=false"
		"perf.tmpfs_tmp=false"
		"admin.username=none"
		"admin.pubkey="
		"admin.disable_root_login=false"
		"ssh.port=keep"
		"ssh.harden=true"
		"ssh.password_auth=keep-until-verified"
		"ssh.allow_tcp_forwarding=false"
		"fw.open_ports="
		"fw.guard=true"
		"f2b.backend=systemd"
		"ua.auto_reboot=false"
		"docker.bind_ip=127.0.0.1"
		"docker.ipv6=false"
		"proxy.engine=none"
		"proxy.domain="
		"proxy.acme_email="
		"runtimes.node=none"
		"runtimes.python=true"
		"node_exporter.listen=127.0.0.1:9100"
		"health.webhook="
		"backup.target=none"
		"backup.paths=/etc /root /home /opt /var/lib/vps-forge"
		"backup.schedule=daily"
		"tailscale.auth_key="
		"wg.enabled=false"
		"wg.mode=access"
		"wg.port=51820"
		"cloudflared.token="
		"panel=none"
		"guard.timeout=180"
	)
	local kv k v
	for kv in "${defaults[@]}"; do
		k="${kv%%=*}"
		v="${kv#*=}"
		[ -n "${CFG[$k]+x}" ] || CFG["$k"]="$v"
	done
}

cfg_load_file() { # parse flat "key: value" / "key=value" config file (YAML subset)
	local f="$1" line k v
	[ -r "$f" ] || vf_die "config file not readable: $f"
	while IFS= read -r line || [ -n "$line" ]; do
		line="${line#"${line%%[![:space:]]*}"}" # ltrim
		[ -z "$line" ] && continue
		case "$line" in \#*) continue ;; esac
		case "$line" in
		*:*)
			k="${line%%:*}"
			v="${line#*:}"
			;;
		*=*)
			k="${line%%=*}"
			v="${line#*=}"
			;;
		*) continue ;;
		esac
		k="$(printf '%s' "$k" | tr -d '[:space:]')"
		v="${v#"${v%%[![:space:]]*}"}"
		v="${v%"${v##*[![:space:]]}"}"
		v="${v%\"}"
		v="${v#\"}"
		v="${v%\'}"
		v="${v#\'}"
		[ -n "$k" ] && CFG["$k"]="$v"
	done <"$f"
	vf_log_info "loaded config file: $f"
}

cfg_save() { # persist current answers for next run
	local f="$VF_STATE_DIR/config.env" k
	mkdir -p "$VF_STATE_DIR"
	{ for k in "${!CFG[@]}"; do printf '%s=%q\n' "$k" "${CFG[$k]}"; done; } >"$f.tmp"
	chmod 600 "$f.tmp" && mv -f "$f.tmp" "$f"
}

cfg_load_state() { # load persisted answers from a previous run (weaker than file/args)
	# parsed manually — the file uses dotted keys (ssh.port=…) which are not valid
	# bash identifiers, so the file must never be `source`d
	local f="$VF_STATE_DIR/config.env"
	[ -r "$f" ] || return 0
	local line k v
	while IFS= read -r line || [ -n "$line" ]; do
		[ -n "$line" ] || continue
		case "$line" in *=*) ;; *) continue ;; esac
		k="${line%%=*}"
		v="${line#*=}"
		[ -n "$k" ] || continue
		# values were written with printf %q; eval decodes exactly that quoting
		eval "v=$v" 2>/dev/null || true
		CFG["$k"]="$v"
	done <"$f"
}

# ---------- system facts ----------

vf_os_version_id() { . /etc/os-release 2>/dev/null && printf '%s' "${VERSION_ID:-}"; }
vf_os_supported() { case "$(vf_os_version_id)" in 22.04 | 24.04) return 0 ;; *) return 1 ;; esac }
vf_arch() { dpkg --print-architecture 2>/dev/null || uname -m; }
vf_online() { curl -fsS --max-time 8 -o /dev/null https://download.docker.com/linux/ubuntu/gpg 2>/dev/null ||
	curl -fsS --max-time 8 -o /dev/null http://archive.ubuntu.com 2>/dev/null; }

vf_ext_if() { # default-route interface (v4, fallback eth0)
	ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' | head -1 || true
}
vf_ext_if_resolved() {
	local i
	i="$(vf_ext_if)"
	printf '%s' "${i:-eth0}"
}

vf_current_ssh_ports() { # ports sshd is listening on right now (deduped, space-sep)
	ss -H -tlnp 2>/dev/null | awk '$NF ~ /"sshd"/ {print $4}' |
		sed -E 's/.*:([0-9]+)$/\1/' | sort -u | tr '\n' ' ' | sed 's/ $//'
}
vf_effective_ssh_port() { sshd -T 2>/dev/null | awk '$1=="port"{print $2; exit}'; }

vf_docker_present() { command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker 2>/dev/null; }

vf_free_mb() { awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo; }
vf_total_mb() { awk '/MemTotal/{print int($2/1024)}' /proc/meminfo; }
vf_disk_free_gb() { df -BG --output=avail / 2>/dev/null | tail -1 | tr -dc '0-9'; }

vf_random_password() {
	local n="${1:-24}"
	tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$n" || true
	printf '\n'
}
vf_sha256() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

vf_ensure_dir() {
	local d
	for d in "$@"; do mkdir -p "$d"; done
}
vf_ensure_credentials_dir() {
	vf_ensure_dir "$VF_CREDS_DIR"
	chmod 700 "$VF_CREDS_DIR"
	# provenance marker: self-clean removes this directory (restic.pw lives here)
	# only when vps-forge created/uses it — a foreign dir with the same name survives
	touch "$VF_CREDS_DIR/.created-by-vps-forge"
	chmod 600 "$VF_CREDS_DIR/.created-by-vps-forge"
}

# register a user account vps-forge created — self-clean deletes ONLY these
vf_note_created_user() {
	local u="$1"
	[ -n "$u" ] || return 0
	mkdir -p "$VF_STATE_DIR"
	touch "$VF_STATE_DIR/created-users.txt"
	grep -qxF "$u" "$VF_STATE_DIR/created-users.txt" 2>/dev/null ||
		printf '%s\n' "$u" >>"$VF_STATE_DIR/created-users.txt"
}

vf_save_credential() { # vf_save_credential <filename> <contents...>
	vf_ensure_credentials_dir
	local f="$VF_CREDS_DIR/$1"
	shift
	printf '%s\n' "$*" >"$f"
	chmod 600 "$f"
	vf_log_info "stored credential file: $f"
}

# ---------- packages ----------

# apt (>=2.0) waits up to N seconds for the dpkg/lists lock instead of failing —
# critical because unattended-upgrades / cloud-init hold it in the background.
VF_APT_LOCK_WAIT=600

vf_apt_wait_quiet() { # block until no OTHER apt-get/apt/dpkg process is running
	local waited=0 limit="${VF_APT_LOCK_WAIT:-600}"
	while [ "$waited" -lt "$limit" ]; do
		if ! pgrep -x apt-get >/dev/null 2>&1 && ! pgrep -x apt >/dev/null 2>&1 &&
			! pgrep -x dpkg >/dev/null 2>&1; then
			return 0
		fi
		sleep 5
		waited=$((waited + 5))
	done
	vf_log_warn "apt/dpkg still busy after ${limit}s — continuing (Lock::Timeout arbitrates)"
	return 0
}

vf_apt_updated="${VF_APT_UPDATED:-0}"
vf_apt_update() {
	[ "$vf_apt_updated" = "1" ] && return 0
	vf_apt_wait_quiet
	vf_log_info "apt-get update"
	apt-get -o DPkg::Lock::Timeout="$VF_APT_LOCK_WAIT" update -qq >>"$VF_TMP_DIR/apt.log" 2>&1 || {
		tail -5 "$VF_TMP_DIR/apt.log" >&2 || true
		return 1
	}
	vf_apt_updated=1
}

vf_pkg_install() { # vf_pkg_install pkg... — recorded in snapshot for rollback
	local pkgs=("$@") p
	vf_apt_wait_quiet
	vf_apt_update
	local missing=()
	for p in "${pkgs[@]}"; do
		if dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed'; then
			continue
		fi
		missing+=("$p")
		vf_log_info "apt installing: $p"
	done
	# progress is shown by the per-module animator (vf_module_progress_start);
	# a second spinner here would fight it for the same output line
	[ "${#missing[@]}" -gt 0 ] || return 0
	# pass ONLY the missing ones: the snapshot records exactly what this call
	# installs, so rollback/self-clean never purge packages that were already
	# on the server before vps-forge ran
	__vf_pkg_install_raw "${missing[@]}"
}

__vf_pkg_install_raw() {
	local pkgs=("$@")
	if ! DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout="$VF_APT_LOCK_WAIT" \
		install -y -qq "${pkgs[@]}" >>"$VF_TMP_DIR/apt.log" 2>&1; then
		tail -20 "$VF_TMP_DIR/apt.log" >&2 || true
		vf_log_error "apt install failed: ${pkgs[*]}"
		return 1
	fi
	for p in "${pkgs[@]}"; do vf_snapshot_note_pkg "$p"; done
}

vf_pkg_purge() { # vf_pkg_purge pkg... (best-effort)
	# NO autoremove here: rollback may run early in a server's life, and
	# autoremove sweeps auto-installed dependencies of PRE-EXISTING packages too
	DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout="$VF_APT_LOCK_WAIT" purge -y -qq "$@" >>"$VF_TMP_DIR/apt.log" 2>&1 || true
}

vf_svc_enable() { systemctl enable --now "$@" >/dev/null 2>&1 || systemctl restart "$1" >/dev/null 2>&1 || true; }

vf_curl() { curl -fsSL --retry 3 --connect-timeout 15 "$@"; }

vf_boot_spin() { # vf_boot_spin "label" -- cmd... — pre-UI animated step (no gum yet)
	local label="$1"
	shift
	[ "${1:-}" = "--" ] && shift
	local log="$VF_TMP_DIR/boot-spin.log"
	("$@" >"$log" 2>&1) &
	local pid=$!
	local frames=('|' / '-' '\') i=0
	if [ -t 2 ]; then
		while kill -0 "$pid" 2>/dev/null; do
			printf '\r  \033[36m%s\033[0m %s  ' "${frames[$((i % 4))]}" "$label" >&2
			i=$((i + 1))
			sleep 0.2
		done
		printf '\r\033[2K' >&2
	fi
	wait "$pid"
}
