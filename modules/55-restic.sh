# shellcheck shell=bash
# modules/55-restic.sh — restic backups with a systemd timer + self-test command.

restic_env_file() { printf '%s' "$VF_CREDS_DIR/restic.env"; }

mod_restic_plan() {
	cat <<PLAN
Install restic (apt); repository: $(cfg_get backup.target none)
  password generated and stored in $VF_CREDS_DIR/restic.pw (mode 600)
  paths: $(cfg_get backup.paths "/etc /root /home /opt /var/lib/vps-forge")
  schedule: $(cfg_get backup.schedule daily) (systemd timer vps-forge-restic)
  retention: --keep-daily 7 --keep-weekly 4 --keep-monthly 6
Self-test: 'vps-forge backup-test' snapshots and restores a test directory
PLAN
}

mod_restic_check() {
	command -v restic >/dev/null 2>&1 && systemctl is-enabled --quiet vps-forge-restic.timer 2>/dev/null
}

mod_restic_ask() {
	if [ "$VF_NONINTERACTIVE" != "1" ]; then
		local pick
		pick="$(vf_ask backup.target "Backup repository type" "none" \
			"none" "s3 - AWS/S3-compatible (needs keys)" "sftp - remote host (needs ssh)" "rest - REST server" "local - a local path")"
		cfg_set backup.target "${pick%% -*}"
		local t
		t="$(cfg_get backup.target none)"
		case "$t" in
		s3*)
			cfg_set backup.s3_url "$(vf_ask backup.s3_url "S3 endpoint+bucket (s3:https://s3.amazonaws.com/bucket)" "")"
			cfg_set backup.s3_key "$(vf_ask_secret backup.s3_key "AWS_ACCESS_KEY_ID")"
			cfg_set backup.s3_secret "$(vf_ask_secret backup.s3_secret "AWS_SECRET_ACCESS_KEY")"
			;;
		sftp* | rest*) cfg_set backup.repo "$(vf_ask backup.repo "Repository URL (sftp:user@host:/path or rest:https://...)" "")" ;;
		local*) cfg_set backup.repo "$(vf_ask backup.repo "Local path (e.g. /backups)" "/backups")" ;;
		esac
	fi
}

restic_repo_url() {
	case "$(cfg_get backup.target none)" in
	s3) printf 's3:%s' "$(cfg_get backup.s3_url "")" ;;
	*) printf '%s' "$(cfg_get backup.repo "")" ;;
	esac
}

restic_env() { # exports for one command: restic_env && restic ...
	local pwfile="$VF_CREDS_DIR/restic.pw"
	[ -r "$pwfile" ] || return 1
	export RESTIC_PASSWORD_FILE="$pwfile"
	export RESTIC_REPOSITORY
	RESTIC_REPOSITORY="$(restic_repo_url)"
	if [ "$(cfg_get backup.target none)" = "s3" ]; then
		export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
		AWS_ACCESS_KEY_ID="$(cfg_get backup.s3_key "")"
		AWS_SECRET_ACCESS_KEY="$(cfg_get backup.s3_secret "")"
	fi
	[ -n "$RESTIC_REPOSITORY" ] && [ "$RESTIC_REPOSITORY" != "s3:" ]
}

mod_restic_run() {
	vf_pkg_install restic
	if [ "$(cfg_get backup.target none)" = "none" ]; then
		ui_warn "no backup target configured — installing restic only. Re-run with backup.target set."
		return 0
	fi
	local url
	url="$(restic_repo_url)"
	[ -n "$url" ] || {
		ui_error "backup repository URL is empty"
		return 1
	}
	if [ ! -r "$VF_CREDS_DIR/restic.pw" ]; then
		vf_ensure_credentials_dir
		vf_random_password 32 >"$VF_CREDS_DIR/restic.pw"
		chmod 600 "$VF_CREDS_DIR/restic.pw"
	fi
	if ! restic_env; then
		ui_error "backup credentials incomplete"
		return 1
	fi
	if ! restic snapshots >/dev/null 2>&1; then
		ui_para "initializing repository $url ..."
		restic init >/dev/null 2>&1 || {
			ui_error "restic init failed (credentials/endpoint reachable?)"
			return 1
		}
	fi
	vf_write_file /etc/systemd/system/vps-forge-restic.service 644 <<EOF
[Unit]
Description=vps-forge restic backup
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=/root/.vps-forge-credentials/restic.env
ExecStart=/bin/bash -c 'set -a; source /root/.vps-forge-credentials/restic.env; set +a; restic backup --one-file-system $(cfg_get backup.paths "/etc /root /home /opt /var/lib/vps-forge") && restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune'
EOF
	# service file renders cfg at install time; regenerate env file for systemd
	restic_env_dump >"$VF_CREDS_DIR/restic.env"
	chmod 600 "$VF_CREDS_DIR/restic.env"
	vf_write_file /etc/systemd/system/vps-forge-restic.timer 644 <<'EOF'
[Unit]
Description=vps-forge restic backup timer

[Timer]
OnCalendar=*-*-* 02:30:00
RandomizedDelaySec=15m
Persistent=true

[Install]
WantedBy=timers.target
EOF
	systemctl daemon-reload
	systemctl enable --now vps-forge-restic.timer >/dev/null 2>&1
	ui_para "backup timer active (02:30 daily). Run 'vps-forge backup-test' to prove restore works."
	return 0
}

restic_env_dump() {
	echo "RESTIC_REPOSITORY=$(restic_repo_url)"
	echo "RESTIC_PASSWORD_FILE=$VF_CREDS_DIR/restic.pw"
	if [ "$(cfg_get backup.target none)" = "s3" ]; then
		echo "AWS_ACCESS_KEY_ID=$(cfg_get backup.s3_key "")"
		echo "AWS_SECRET_ACCESS_KEY=$(cfg_get backup.s3_secret "")"
	fi
}

restic_selftest() {
	command -v restic >/dev/null 2>&1 || {
		echo "FAIL: restic not installed"
		exit 1
	}
	restic_env || {
		echo "FAIL: backup not configured (run the backups module first)"
		exit 1
	}
	local tdir=/tmp/vf-restore-test
	local rdir="$tdir/restore"
	rm -rf "$tdir"
	mkdir -p "$tdir/data" "$rdir"
	echo "vps-forge selftest $(date -u)" >"$tdir/data/prove.txt"
	echo "[1/4] snapshot test dir..."
	restic backup "$tdir/data" --tag vf-selftest --host selftest >/dev/null || {
		echo "FAIL: backup"
		exit 1
	}
	echo "[2/4] restore latest selftest snapshot..."
	local sid
	sid="$(restic snapshots --tag vf-selftest --json 2>/dev/null | jq -r '.[-1].short_id')"
	restic restore "$sid" --target "$rdir" >/dev/null || {
		echo "FAIL: restore"
		exit 1
	}
	echo "[3/4] comparing..."
	if cmp -s "$tdir/data/prove.txt" "$rdir/$tdir/data/prove.txt"; then
		echo "  content identical"
	else
		echo "FAIL: restored content differs"
		exit 1
	fi
	echo "[4/4] cleanup (keeping snapshots)..."
	rm -rf "$tdir"
	echo "PASS: backup+restore verified end-to-end"
}
