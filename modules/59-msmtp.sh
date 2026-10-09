# shellcheck shell=bash
# modules/59-msmtp.sh — msmtp mail relay for server alerts.

mod_msmtp_plan() {
	cat <<PLAN
Install msmtp-mta (system mail transport)
Write /etc/msmtprc for SMTP relay: $(cfg_get msmtp.host "(not set)")
Alert mail goes to: $(cfg_get msmtp.to root@localhost)
SMTP credentials stored in /etc/msmtprc (mode 640) — treat as sensitive.
PLAN
}

mod_msmtp_check() { [ -r /etc/msmtprc ]; }

mod_msmtp_ask() {
	if [ "$VF_NONINTERACTIVE" != "1" ]; then
		if ui_confirm "Configure an SMTP relay for outbound alert mail?" n; then
			cfg_set msmtp.host "$(vf_ask msmtp.host "SMTP host (e.g. smtp.gmail.com)" "")"
			cfg_set msmtp.port "$(vf_ask msmtp.port "SMTP port" "587")"
			cfg_set msmtp.user "$(vf_ask msmtp.user "SMTP username" "")"
			cfg_set msmtp.pass "$(vf_ask_secret msmtp.pass "SMTP password / app password")"
			cfg_set msmtp.from "$(vf_ask msmtp.from "From address" "vps-forge@$(hostname -d 2>/dev/null || hostname)")"
			cfg_set msmtp.to "$(vf_ask msmtp.to "Deliver local mail to (alert recipient)" "root@localhost")"
		else
			cfg_set msmtp.host ""
		fi
	fi
}

mod_msmtp_run() {
	if [ -z "$(cfg_get msmtp.host "")" ]; then
		ui_para "no SMTP host configured — skipping msmtp"
		return 0
	fi
	vf_pkg_install msmtp-mta bsd-mailx
	vf_secret_register "$(cfg_get msmtp.pass "")"
	# msmtp config values must be quoted — a password with spaces or '#' would
	# otherwise end the value / comment out the rest of the line
	__mq() { # shell-quote a value for /etc/msmtprc
		local s="$1"
		s="${s//\\/\\\\}"
		s="${s//\"/\\\"}"
		printf '"%s"' "$s"
	}
	local tls="tls"
	[ "$(cfg_get msmtp.port 587)" = "465" ] && tls="ssl"
	vf_write_file /etc/msmtprc 640 <<EOF
# vps-forge msmtp relay
defaults
auth           on
tls            on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile        /var/log/msmtp.log

account        default
host           $(__mq "$(cfg_get msmtp.host "")")
port           $(__mq "$(cfg_get msmtp.port 587)")
from           $(__mq "$(cfg_get msmtp.from "")")
user           $(__mq "$(cfg_get msmtp.user "")")
password       $(__mq "$(cfg_get msmtp.pass "")")
$([ "$tls" = ssl ] && echo "tls_starttls off")

aliases        /etc/aliases
EOF
	vf_backup_file /etc/aliases
	grep -q '^root:' /etc/aliases || echo "root: $(cfg_get msmtp.to root@localhost)" >>/etc/aliases
	newaliases >/dev/null 2>&1 || true
	if [ "$VF_NONINTERACTIVE" != "1" ] && ui_confirm "Send a test mail to $(cfg_get msmtp.to root@localhost)?" n; then
		echo "vps-forge test mail $(date -u)" | mail -s "vps-forge test" root >/dev/null 2>&1 &&
			ui_ok "test mail queued (check the inbox / /var/log/msmtp.log)" ||
			ui_warn "mail send failed — check /var/log/msmtp.log"
	fi
	return 0
}
