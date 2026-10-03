# shellcheck shell=bash
# lib/preflight.sh — gather and display system facts before anything is changed.

declare -A PF

vf_preflight_collect() {
	PF[os]="$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2)"
	PF[os_version]="$(vf_os_version_id)"
	PF[kernel]="$(uname -r)"
	PF[virt]="$(systemd-detect-virt 2>/dev/null || echo unknown)"
	PF[cpu]="$(nproc 2>/dev/null || echo '?')"
	PF[ram_mb]="$(vf_total_mb)"
	PF[disk_free_gb]="$(vf_disk_free_gb)"
	PF[arch]="$(vf_arch)"
	PF[ext_if]="$(vf_ext_if_resolved)"
	PF[ssh_user]="$(id -un)"
	PF[ssh_ports]="$(vf_current_ssh_ports)"
	PF[sshd_effective_port]="$(vf_effective_ssh_port || echo '?')"
	PF[ufw]="$(ufw status 2>/dev/null | head -1 || echo 'ufw: not installed')"
	PF[iptables_backend]="$(iptables --version 2>/dev/null | grep -o 'nf_tables\|legacy' || echo '?')"
	PF[docker]="$(vf_docker_present && echo 'running' || { command -v docker >/dev/null 2>&1 && echo 'installed, not running' || echo 'absent'; })"
	PF[swap]="$(swapon --show=NAME --noheadings 2>/dev/null | tr '\n' ' ')"
	PF[timezone]="$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone)"
	PF[hostname]="$(hostname)"
	PF[provider_dmi]="$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null | tr -d '\n') / $(cat /sys/class/dmi/id/product_name 2>/dev/null)"
	PF[reboot_required]="$([ -e /var/run/reboot-required ] && echo yes || echo no)"
	return 0
}

vf_preflight_render() { # -> exit 0 = sane to continue, 1 = blocked
	local rows="" problems=""
	rows+="Operating system|${PF[os]}"
	rows+="|Virtualization|${PF[virt]} on ${PF[provider_dmi]}"
	rows+="|CPU / RAM|${PF[cpu]} vCPU / ${PF[ram_mb]} MB"
	rows+="|Disk free|${PF[disk_free_gb]} GB"
	rows+="|Architecture|${PF[arch]}"
	rows+="|SSH session|user '${PF[ssh_user]}', sshd listening on port(s): ${PF[ssh_ports]}"
	rows+="|Firewall|UFW: ${PF[ufw]} (iptables backend: ${PF[iptables_backend]})"
	rows+="|Docker|${PF[docker]}"
	rows+="|Swap|${PF[swap]:-none}"
	rows+="|Timezone / hostname|${PF[timezone]} / ${PF[hostname]}"
	rows+="|Reboot pending|${PF[reboot_required]}"

	ui_header "Preflight"
	printf '%s\n' "$rows" | awk -F'|' -v w="$VF_UI_WIDTH" '
		{ printf "  \033[36m%-18s\033[0m %s\n", $1, $2 }' >&2

	if ! vf_os_supported; then
		problems="- This is not Ubuntu 22.04 or 24.04 LTS (detected: ${PF[os]}). vps-forge only supports 22.04/24.04."
	fi
	[ "${PF[ram_mb]:-0}" -lt 900 ] 2>/dev/null && problems+=$'\n'"- Less than 900 MB RAM — several modules (Docker, panels) will fail."
	[ "${PF[disk_free_gb]:-0}" -lt 4 ] 2>/dev/null && problems+=$'\n'"- Less than 4 GB free disk."
	[ -z "${PF[ssh_ports]}" ] && problems+=$'\n'"- Could not detect the SSH listening port — refusing to touch the firewall."

	if [ -n "$problems" ]; then
		ui_error "Preflight found problems:"
		printf '%s\n' "$problems" | sed 's/^/  /' >&2
		if ! ui_confirm "Continue anyway (not recommended)?" n; then return 1; fi
	fi
	ui_para "Out-of-band recovery: $(vf_provider_hint)"
	if [ "$VF_NONINTERACTIVE" != "1" ]; then
		ui_pause
	fi
	return 0
}
