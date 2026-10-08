# shellcheck shell=bash
# modules/10-sysbase.sh — timezone, locale, chrony NTP, hostname/hosts.

mod_sysbase_plan() {
	cat <<PLAN
Timezone: $(cfg_get sys.timezone auto)   Locale: $(cfg_get sys.locale en_US.UTF-8)
Install and enable chrony (NTP); stop systemd-timesyncd
Hostname: $(cfg_get sys.hostname keep)
/etc/hosts: map the hostname to 127.0.1.1 if unresolvable (silences sudo
"unable to resolve host" — common on provider images)
PLAN
}

mod_sysbase_check() {
	command -v chronyd >/dev/null 2>&1 && systemctl is-active --quiet chrony &&
		{ [ "$(cfg_get sys.hostname keep)" = "keep" ] || [ "$(hostname)" = "$(cfg_get sys.hostname keep)" ]; } &&
		getent hosts "$(hostname)" >/dev/null 2>&1
	return $?
}

mod_sysbase_ask() {
	if [ "$VF_NONINTERACTIVE" != "1" ]; then
		cfg_set sys.timezone "$(vf_ask sys.timezone "Timezone (tz database name, e.g. Asia/Dhaka)" "$(cat /etc/timezone 2>/dev/null || echo UTC)")"
		cfg_set sys.locale "$(vf_ask sys.locale "System locale" "en_US.UTF-8" "en_US.UTF-8" "C.UTF-8")"
		cfg_set sys.hostname "$(vf_ask sys.hostname "Hostname (empty = keep current)" "keep")"
	fi
}

mod_sysbase_run() {
	local tz loc hn
	tz="$(cfg_get sys.timezone auto)"
	loc="$(cfg_get sys.locale en_US.UTF-8)"
	hn="$(cfg_get sys.hostname keep)"

	# timezone ("" and "auto" both mean: keep the current timezone)
	if [ -n "$tz" ] && [ "$tz" != "auto" ] && [ "$tz" != "$(cat /etc/timezone 2>/dev/null)" ]; then
		if timedatectl list-timezones 2>/dev/null | grep -qx "$tz"; then
			timedatectl set-timezone "$tz" && vf_log_info "timezone set: $tz"
		else
			ui_warn "invalid timezone '$tz' — keeping current"
		fi
	fi

	# locale
	if locale -a 2>/dev/null | grep -qx "${loc//.utf8/.UTF-8}" || locale -a 2>/dev/null | grep -qxi "${loc//.UTF-8/}"; then
		:
	else
		locale-gen "$loc" >/dev/null 2>&1 || true
	fi
	vf_backup_file /etc/default/locale
	update-locale LANG="$loc" >/dev/null 2>&1 || true

	# chrony
	vf_pkg_install chrony
	systemctl disable --now systemd-timesyncd >/dev/null 2>&1 || true
	systemctl enable --now chrony >/dev/null 2>&1 || systemctl restart chrony >/dev/null 2>&1
	for _ in 1 2 3 4 5; do
		chronyc tracking >/dev/null 2>&1 && break
		sleep 2
	done
	chronyc tracking >/dev/null 2>&1 || ui_warn "chrony is not synced yet (check later: chronyc tracking)"

	# hostname
	if [ "$hn" != "keep" ] && [ -n "$hn" ] && [ "$hn" != "$(hostname)" ]; then
		local old
		old="$(hostname)"
		hostnamectl set-hostname "$hn"
		vf_backup_file /etc/hosts
		sed -i "s/\b${old}\b/${hn}/g" /etc/hosts 2>/dev/null || true
	fi

	# /etc/hosts sanity: providers often set the hostname without an /etc/hosts
	# entry — every sudo then prints "unable to resolve host". Map it to
	# 127.0.1.1 (the Debian convention) only while it resolves to nothing.
	if ! getent hosts "$(hostname)" >/dev/null 2>&1; then
		vf_backup_file /etc/hosts
		printf '127.0.1.1\t%s\n' "$(hostname)" >>/etc/hosts
		vf_log_info "hostname '$(hostname)' was unresolvable — mapped to 127.0.1.1 in /etc/hosts"
	fi
	return 0
}
