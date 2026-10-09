# shellcheck shell=bash
# modules/54-health.sh — periodic health checks with webhook alerts.

mod_health_plan() {
	cat <<PLAN
Install /usr/local/sbin/vps-forge-health — checks: sshd up, docker up (if present),
disk > 90%, RAM available < 5%, load > 4x vCPU; keeps a local history log
Alerts: POST JSON to $([ -n "$(cfg_get health.webhook "")" ] && echo "your webhook" || echo "(none set — local log only)")
systemd service + timer every 5 minutes
PLAN
}

mod_health_check() { systemctl is-enabled --quiet vps-forge-health.timer 2>/dev/null; }

mod_health_run() {
	local webhook
	webhook="$(cfg_get health.webhook "")"
	# the webhook is interpolated into a root-run script AND a JSON body —
	# reject anything that is not a plain http(s) URL (no quotes, backticks,
	# shell or JSON metacharacters)
	if [ -n "$webhook" ]; then
		case "$webhook" in
		https://* | http://*) ;;
		*)
			ui_error "health.webhook must start with http:// or https:// — got: $webhook"
			return 1
			;;
		esac
		case "$webhook" in
		*['"'\''`\\']* | *'$('*)
			ui_error "health.webhook contains quote/backtick/shell metacharacters — refusing (use a plain URL)"
			return 1
			;;
		esac
	fi
	vf_ensure_dir /usr/local/sbin
	vf_write_file /usr/local/sbin/vps-forge-health 755 <<EOF
#!/usr/bin/env bash
# vps-forge health probe — webhook: $webhook
set -u
WEBHOOK="$webhook"
HIST=/var/lib/vps-forge/health-history.log
PROBLEMS=""
[ "\$(systemctl is-active ssh)" = "active" ] || PROBLEMS+="ssh service DOWN; "
if command -v docker >/dev/null; then
	[ "\$(systemctl is-active docker)" = "active" ] || PROBLEMS+="docker DOWN; "
fi
DISK=\$(df --output=pcent / | tail -1 | tr -dc '0-9')
[ "\$DISK" -gt 90 ] && PROBLEMS+="disk at \${DISK}%; "
AVAIL=\$(awk '/MemAvailable/{print int(\$2/1024)}' /proc/meminfo)
[ "\$AVAIL" -lt 100 ] && PROBLEMS+="RAM available \${AVAIL}MB; "
LOAD=\$(awk '{print int(\$1)}' /proc/loadavg)
CPUS=\$(nproc)
[ "\$LOAD" -gt \$(( CPUS * 4 )) ] && PROBLEMS+="load \${LOAD}/\${CPUS} vCPU; "
STAMP=\$(date -u +%FT%TZ)
if [ -n "\$PROBLEMS" ]; then
	echo "\$STAMP ALERT \$PROBLEMS" >> "\$HIST"
	if [ -n "\$WEBHOOK" ]; then
		curl -fsS --max-time 10 -H 'Content-Type: application/json' \\
			-d "{\\"text\\": \\"vps-forge \$(hostname): \$PROBLEMS\\", \\"host\\": \\"\$(hostname)\\", \\"at\\": \\"\$STAMP\\"}" \\
			"\$WEBHOOK" >/dev/null 2>&1 || echo "\$STAMP webhook-failed" >> "\$HIST"
	fi
else
	echo "\$STAMP ok" >> "\$HIST"
fi
# trim history to 2000 lines
tail -2000 "\$HIST" > "\$HIST.t" 2>/dev/null && mv "\$HIST.t" "\$HIST"
exit 0
EOF
	vf_write_file /etc/systemd/system/vps-forge-health.service 644 <<'EOF'
[Unit]
Description=vps-forge health probe

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vps-forge-health
EOF
	vf_write_file /etc/systemd/system/vps-forge-health.timer 644 <<'EOF'
[Unit]
Description=run vps-forge health probe every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Unit=vps-forge-health.service

[Install]
WantedBy=timers.target
EOF
	systemctl daemon-reload
	systemctl enable --now vps-forge-health.timer >/dev/null 2>&1
	return 0
}
