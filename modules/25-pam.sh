# shellcheck shell=bash
# modules/25-pam.sh — pwquality, pam_faillock, umask, core dumps, su restriction.

mod_pam_plan() {
	cat <<'PLAN'
Password quality: /etc/security/pwquality.conf.d/vps-forge.conf (minlen 14, classes)
PAM faillock: deny=5, unlock_time=900 in /etc/security/faillock.conf + common-auth
umask 027 in /etc/login.defs; core dumps disabled (limits)
su restricted to the 'sudo' group (pam_wheel + mode 4750 root:sudo on /bin/su)
PLAN
}

mod_pam_check() {
	[ -r /etc/security/pwquality.conf.d/vps-forge.conf ] &&
		[ -r /etc/security/faillock.conf ] && grep -q '^deny *= *5' /etc/security/faillock.conf &&
		grep -q 'pam_faillock.so preauth' /etc/pam.d/common-auth &&
		grep -q 'pam_faillock' /etc/pam.d/common-account
}

mod_pam_run() {
	# password quality
	mkdir -p /etc/security/pwquality.conf.d
	vf_write_file /etc/security/pwquality.conf.d/vps-forge.conf 644 <<'EOF'
# vps-forge password policy (CIS-informed)
minlen = 14
dcredit = -1
ucredit = -1
ocredit = -1
lcredit = -1
maxrepeat = 3
usercheck = 1
dictcheck = 1
enforcing = 1
EOF

	# faillock config
	vf_write_file /etc/security/faillock.conf 644 <<'EOF'
# vps-forge login throttling
deny = 5
fail_interval = 900
unlock_time = 900
even_deny_root = 0
audit = 1
EOF

	# faillock PAM integration (idempotent, marker-guarded; canonical stack from pam_faillock(8))
	vf_backup_file /etc/pam.d/common-auth
	if ! grep -q 'vps-forge faillock' /etc/pam.d/common-auth; then
		sed -i '/^auth\s.*pam_unix.so/i auth required pam_faillock.so preauth audit silent deny=5 unlock_time=900 # vps-forge faillock preauth' /etc/pam.d/common-auth
		sed -i '/^auth\s.*pam_unix.so/a auth [default=die] pam_faillock.so authfail audit deny=5 unlock_time=900 # vps-forge faillock authfail\nauth sufficient pam_faillock.so authsucc audit # vps-forge faillock authsucc' /etc/pam.d/common-auth
	fi
	vf_backup_file /etc/pam.d/common-account
	if ! grep -q 'pam_faillock' /etc/pam.d/common-account; then
		printf 'account required pam_faillock.so # vps-forge faillock\n' >>/etc/pam.d/common-account
	fi

	# umask + core dumps
	vf_backup_file /etc/login.defs
	sed -i 's/^UMASK\s\+.*/UMASK 027/' /etc/login.defs
	grep -q '^UMASK' /etc/login.defs || echo 'UMASK 027' >>/etc/login.defs
	vf_write_file /etc/security/limits.d/99-vps-forge-core.conf 644 <<'EOF'
* hard core 0
EOF
	if [ -d /etc/systemd/coredump.conf.d ]; then :; else mkdir -p /etc/systemd/coredump.conf.d; fi
	vf_write_file /etc/systemd/coredump.conf.d/99-vps-forge.conf 644 <<'EOF'
[Coredump]
Storage=none
ProcessSizeMax=0
EOF

	# restrict su to the sudo group
	if ! grep -qE '^\s*auth\s+required\s+pam_wheel.so' /etc/pam.d/su; then
		vf_backup_file /etc/pam.d/su
		sed -i 's|^#\s*auth\s*required\s*pam_wheel.so use_uid$|auth required pam_wheel.so use_uid group=sudo|' /etc/pam.d/su
		grep -q 'pam_wheel.so use_uid group=sudo' /etc/pam.d/su ||
			printf 'auth required pam_wheel.so use_uid group=sudo\n' >>/etc/pam.d/su
	fi
	local cur
	cur="$(dpkg-statoverride --list /bin/su 2>/dev/null || true)"
	if [ -z "$cur" ]; then
		groupadd -f sudo
		dpkg-statoverride --update --add root sudo 4750 /bin/su || true
	fi
	return 0
}
