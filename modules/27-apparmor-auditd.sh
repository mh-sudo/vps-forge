# shellcheck shell=bash
# modules/27-apparmor-auditd.sh — AppArmor enforcing + auditd baseline rules.

mod_apparmor_auditd_plan() {
	cat <<'PLAN'
Ensure AppArmor is enabled and profiles are in enforce mode (no per-profile forcing)
Install auditd + write /etc/audit/rules.d/99-vps-forge.rules baseline:
  watches: identity files (/etc/passwd, group, shadow, gshadow, sudoers*),
  login records (lastlog, faillog, utmp), sudoers, /etc/sysctl.conf
  syscalls: time-change, system-locale, mounts (b64+b32)
Load with augenrules; enable auditd service
PLAN
}

mod_apparmor_auditd_check() {
	aa-status 2>/dev/null | grep -q 'profiles are loaded' &&
		systemctl is-active --quiet auditd 2>/dev/null &&
		[ -r /etc/audit/rules.d/99-vps-forge.rules ]
}

mod_apparmor_auditd_run() {
	vf_pkg_install apparmor auditd audispd-plugins apparmor-utils

	# AppArmor: ensure enabled + enforcing where profiles exist
	systemctl enable --now apparmor >/dev/null 2>&1 || true
	local loaded enforcing
	# '|| true' guards the substitution: a missing/failing aa-status must not
	# kill the module under the runner's errexit
	loaded="$({ aa-status 2>/dev/null | grep -q 'profiles are loaded'; } &&
		aa-status 2>/dev/null | awk '/profiles are in enforce mode/{gsub(/[.,]/,"");print $1}' ||
		true)"
	enforcing="${loaded:-0}"
	if [ "$enforcing" = "0" ]; then
		ui_warn "AppArmor has no enforcing profiles — leaving as-is (Ubuntu default profiles apply)"
	else
		ui_para "AppArmor: $enforcing profile(s) in enforce mode"
	fi

	vf_write_file /etc/audit/rules.d/99-vps-forge.rules 640 <<'EOF'
## vps-forge auditd baseline (CIS-informed)
## identity
-w /etc/group -p wa -k identity
-w /etc/passwd -p wa -k identity
-w /etc/gshadow -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/security/opasswd -p wa -k identity
## sudoers
-w /etc/sudoers -p wa -k scope
-w /etc/sudoers.d/ -p wa -k scope
## logins
-w /var/log/faillog -p wa -k logins
-w /var/log/lastlog -p wa -k logins
-w /var/run/utmp -p wa -k session
## system clock
-a always,exit -F arch=b64 -S adjtimex -S settimeofday -k time-change
-a always,exit -F arch=b32 -S adjtimex -S settimeofday -S stime -k time-change
-w /etc/localtime -p wa -k time-change
## locale
-a always,exit -F arch=b64 -S sethostname -S setdomainname -k system-locale
-a always,exit -F arch=b32 -S sethostname -S setdomainname -k system-locale
-w /etc/issue -p wa -k system-locale
-w /etc/issue.net -p wa -k system-locale
-w /etc/hosts -p wa -k system-locale
## mounts
-a always,exit -F arch=b64 -S mount -F auid>=1000 -F auid!=4294967295 -k mounts
-a always,exit -F arch=b32 -S mount -F auid>=1000 -F auid!=4294967295 -k mounts
## sysctl
-w /etc/sysctl.conf -p wa -k sysctl
-w /etc/sysctl.d/ -p wa -k sysctl
## MAC policy
-w /etc/apparmor/ -p wa -k MAC-policy
-w /etc/apparmor.d/ -p wa -k MAC-policy
## kernel modules
-a always,exit -F arch=b64 -S init_module -S finit_module -S delete_module -F auid!=4294967295 -k modules
-a always,exit -F arch=b32 -S init_module -S finit_module -S delete_module -F auid!=4294967295 -k modules
EOF
	augenrules --load >/dev/null 2>&1 || { ui_warn "augenrules load reported errors — check auditctl -l"; }
	systemctl enable --now auditd >/dev/null 2>&1 || systemctl restart auditd >/dev/null 2>&1 || true
	return 0
}
