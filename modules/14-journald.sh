# shellcheck shell=bash
# modules/14-journald.sh — persistent, size-capped journald + logrotate for our own log.

mod_journald_plan() {
	cat <<'PLAN'
Write /etc/systemd/journald.conf.d/99-vps-forge.conf:
  Storage=persistent, SystemMaxUse=200M, SystemKeepFree=500M,
  SystemMaxFileSize=50M, MaxRetentionSec=1month, Compress=yes
Restart systemd-journald; add /etc/logrotate.d/vps-forge
PLAN
}

mod_journald_check() {
	[ -r /etc/systemd/journald.conf.d/99-vps-forge.conf ] && systemctl is-active --quiet systemd-journald
}

mod_journald_run() {
	mkdir -p /var/log/journal /etc/systemd/journald.conf.d
	vf_write_file /etc/systemd/journald.conf.d/99-vps-forge.conf 644 <<'EOF'
[Journal]
Storage=persistent
Compress=yes
SystemMaxUse=200M
SystemKeepFree=500M
SystemMaxFileSize=50M
MaxRetentionSec=1month
RateLimitIntervalSec=30s
RateLimitBurst=10000
EOF
	systemctl restart systemd-journald || true
	mkdir -p /etc/logrotate.d
	vf_write_file /etc/logrotate.d/vps-forge 644 <<'EOF'
/var/log/vps-forge.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
}
EOF
	return 0
}
