# shellcheck shell=bash
# modules/11-swap.sh — swap file sized for the RAM, plus sane swappiness (in sysctl module).

mod_swap_plan() {
	cat <<PLAN
Create swap file /swapfile sized for RAM $(vf_total_mb) MB:
  rule: RAM <= 2 GB -> 2 GB swap; 2-8 GB -> equal to RAM (max 4 GB); > 8 GB -> 4 GB
Add /swapfile to /etc/fstab (noauto removal is documented in README)
PLAN
}

swap_size_for_ram() {
	local ram
	ram="$(vf_total_mb)"
	if [ "$ram" -le 2048 ]; then
		echo 2048
	elif [ "$ram" -le 8192 ]; then
		echo $((ram > 4096 ? 4096 : ram))
	else echo 4096; fi
}

mod_swap_check() {
	swapon --show=NAME --noheadings 2>/dev/null | grep -q '^/swapfile$' &&
		grep -q '^/swapfile' /etc/fstab
}

mod_swap_run() {
	local size
	size="$(cfg_get swap.size auto)"
	if [ "$size" = "auto" ]; then size="$(swap_size_for_ram)"; fi
	case "$size" in '' | *[!0-9]*) size="$(swap_size_for_ram)" ;; esac
	[ "$size" -lt 512 ] && {
		ui_warn "swap size ${size}MB too small — skipping swap"
		return 0
	}

	if [ -e /swapfile ] && ! swapon --show=NAME --noheadings | grep -q '/swapfile'; then
		ui_warn "/swapfile exists but is not active — recreating"
		swapoff /swapfile 2>/dev/null || true
	fi
	if ! [ -e /swapfile ]; then
		fallocate -l "${size}M" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count="$size" status=none
		chmod 600 /swapfile
		mkswap /swapfile >/dev/null
	fi
	swapon /swapfile 2>/dev/null || true
	if ! grep -q '^/swapfile' /etc/fstab; then
		vf_backup_file /etc/fstab
		printf '/swapfile none swap sw 0 0\n' >>/etc/fstab
	fi
	swapon --show | sed 's/^/  /' >&2 || true
}
