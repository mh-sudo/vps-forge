# shellcheck shell=bash
# modules/17-trim.sh — weekly disk TRIM (fstrim.timer).

mod_trim_plan() { echo "Enable systemd fstrim.timer (weekly discard on supported block devices)"; }

mod_trim_check() { systemctl is-enabled --quiet fstrim.timer 2>/dev/null; }

mod_trim_run() {
	systemctl enable --now fstrim.timer >/dev/null 2>&1 || true
	mod_trim_check || {
		ui_warn "fstrim.timer unavailable (VM disk may not support TRIM)"
		return 0
	}
}
