#!/usr/bin/env bash
# Vps Forge install.sh — tiny curl|bash entrypoint.
# Downloads the project, verifies every file's sha256, runs ./vps-forge.
set -euo pipefail

BASE_URL="${VF_BASE_URL:-https://raw.githubusercontent.com/mh-sudo/vps-forge/main}"
DEST="${VF_DEST:-/root/.vps-forge}"

say() { printf '\033[36m==>\033[0m %s\n' "$*" >&2; }
die() {
	printf 'install.sh: error: %s\n' "$*" >&2
	exit 1
}

[ "$(id -u)" = "0" ] || die "run as root:  curl -fsSL <url>/install.sh | sudo bash"

# tiny arg parser: --base-url=... --dest=...
for arg in "$@"; do
	case "$arg" in
	--base-url=*) BASE_URL="${arg#*=}" ;;
	--dest=*) DEST="${arg#*=}" ;;
	--help | -h)
		echo "usage: curl -fsSL <url>/install.sh | sudo bash [--base-url=URL] [--dest=DIR] [vps-forge flags]"
		echo "   or: sudo bash -s -- [--base-url=URL] [--dest=DIR] [vps-forge flags]"
		exit 0
		;;
	*) ;;
	esac
done

command -v curl >/dev/null 2>&1 || die "curl is required"
command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required"

FILES=(
	vps-forge
	lib/common.sh lib/ui.sh lib/safety.sh lib/preflight.sh lib/runner.sh
	modules/manifest.conf
	modules/01-essentials.sh modules/10-sysbase.sh modules/11-swap.sh
	modules/12-sysctl.sh modules/13-perf.sh modules/14-journald.sh
	modules/15-zram.sh modules/16-tmpfs.sh modules/17-trim.sh
	modules/20-admin-user.sh modules/21-sshd.sh modules/22-ufw.sh
	modules/23-fail2ban.sh modules/24-unattended.sh modules/25-pam.sh
	modules/26-services.sh modules/27-apparmor-auditd.sh modules/28-aide.sh
	modules/29-rkhunter.sh modules/30-totp.sh
	modules/40-docker.sh modules/41-docker-fw.sh
	modules/50-proxy.sh modules/51-runtimes.sh modules/52-deploy-user.sh
	modules/53-node-exporter.sh modules/54-health.sh modules/55-restic.sh
	modules/56-tailscale.sh modules/57-wireguard.sh modules/58-cloudflared.sh
	modules/59-msmtp.sh
	modules/70-panel-coolify.sh modules/71-panel-cloudpanel.sh modules/72-panel-cyberpanel.sh
	modules/90-self-clean.sh
)

mkdir -p "$DEST"
cd "$DEST"
say "downloading vps-forge from $BASE_URL"
curl -fsSL --retry 3 "${BASE_URL%/}/checksums.txt" -o checksums.txt || die "could not fetch checksums.txt"

fail=0
for f in "${FILES[@]}"; do
	mkdir -p "$(dirname "$f")"
	curl -fsSL --retry 3 "${BASE_URL%/}/$f" -o "$f" || {
		say "FAILED to download $f"
		fail=1
	}
done
[ "$fail" = "0" ] || die "download incomplete"

say "verifying checksums"
if ! sha256sum --quiet --ignore-missing -c checksums.txt; then
	die "CHECKSUM MISMATCH — the downloaded files do not match checksums.txt. Aborting."
fi

chmod +x vps-forge
say "checksums OK — starting vps-forge in $DEST"

# When piped (curl | bash) stdin is the exhausted pipe — hand the TUI the
# real terminal instead, so its prompts work. (We must NOT re-exec ourselves:
# in a pipe, $0 is the bash BINARY, and "exec bash $0" dies with
# "cannot execute binary file". There are no prompts before this point.)
if [ -r /dev/tty ] && [ -w /dev/tty ]; then
	exec bash "$DEST/vps-forge" "$@" </dev/tty
fi
exec bash "$DEST/vps-forge" "$@"
