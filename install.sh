#!/usr/bin/env bash
# Vps Forge install.sh — tiny curl|bash entrypoint.
# Downloads the project, verifies every file's sha256, runs ./vps-forge.
set -euo pipefail

REF="${VF_REF:-main}" # P10: pin this to the release tag (e.g. v0.2.0)
BASE_URL="${VF_BASE_URL:-https://raw.githubusercontent.com/mh-sudo/vps-forge/${REF}}"
DEST="${VF_DEST:-/root/.vps-forge}"

say() { printf '\033[36m==>\033[0m %s\n' "$*" >&2; }
die() {
	printf 'install.sh: error: %s\n' "$*" >&2
	exit 1
}

[ "$(id -u)" = "0" ] || die "run as root:  curl -fsSL <url>/install.sh | sudo bash"

# tiny arg parser — consumed flags are STRIPPED from what we pass to vps-forge
# (it rejects unknown flags, so forwarding them used to break the run)
PASS_ARGS=()
for arg in "$@"; do
	case "$arg" in
	--base-url=*) BASE_URL="${arg#*=}" ;;
	--dest=*) DEST="${arg#*=}" ;;
	--ref=*)
		REF="${arg#*=}"
		BASE_URL="https://raw.githubusercontent.com/mh-sudo/vps-forge/${REF}"
		;;
	--help | -h)
		echo "usage: curl -fsSL <url>/install.sh | sudo bash [--base-url=URL] [--dest=DIR] [--ref=TAG] [vps-forge flags]"
		echo "   or: sudo bash -s -- [--base-url=URL] [--dest=DIR] [--ref=TAG] [vps-forge flags]"
		exit 0
		;;
	*) PASS_ARGS+=("$arg") ;;
	esac
done
[ -n "$DEST" ] || die "--dest needs a non-empty directory"

command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required (apt-get install coreutils)"

# one downloader, curl or wget — minimal Ubuntu server images ship with NEITHER
FETCH=""
case "$(command -v curl || command -v wget || true)" in
*curl) FETCH=curl ;;
*wget) FETCH=wget ;;
*)
	die "this installer needs 'curl' or 'wget' to download the files.
On Ubuntu/Debian, run:
    sudo apt-get update && sudo apt-get install -y curl
then run the install command again."
	;;
esac

fetch_to() { # fetch_to <url> <outfile>
	case "$FETCH" in
	curl) curl -fsSL --retry 3 --connect-timeout 15 "$1" -o "$2" ;;
	wget) wget -q --tries=3 --timeout=15 "$1" -O "$2" ;;
	esac
}

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

# download into a staging dir and verify BEFORE touching the real destination:
# an interrupted update used to leave stale files from older versions behind
STAGE="${DEST}.new"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cd "$STAGE"
say "downloading vps-forge from $BASE_URL"
fetch_to "${BASE_URL%/}/checksums.txt" checksums.txt || die "could not fetch checksums.txt"

# animated progress: [####....] 12/44 — stderr, so it survives the curl|bash pipe
total=${#FILES[@]}
done_n=0
fail=0
bar() { # bar <done> <total>
	local w=22 filled
	filled=$((done_n * w / total))
	{
		printf '\r\033[36m==>\033[0m downloading \033[36m['
		printf '%*s' "$filled" '' | tr ' ' '#'
		printf '%*s' "$((w - filled))" '' | tr ' ' '.'
		printf ']\033[0m %2d/%d %s' "$done_n" "$total" ""
	} >&2
}
for f in "${FILES[@]}"; do
	done_n=$((done_n + 1))
	[ -t 2 ] && bar
	mkdir -p "$(dirname "$f")"
	fetch_to "${BASE_URL%/}/$f" "$f" || {
		[ -t 2 ] && printf '\r\033[2K' >&2
		say "FAILED to download $f"
		fail=1
	}
done
[ -t 2 ] && printf '\r\033[2K' >&2
[ "$fail" = "0" ] || die "download incomplete — check your connection and re-run"

say "verifying checksums"
# build the checksum list for EXACTLY the files we downloaded — every file must
# have an entry (no --ignore-missing: an unlisted file would otherwise run
# unverified as root)
: >checksums.partial
for f in "${FILES[@]}"; do
	line="$(grep -E "^[0-9a-f]{64}  ${f}\$" checksums.txt || true)"
	[ -n "$line" ] || die "checksums.txt has no entry for $f — refusing to run unverified"
	printf '%s\n' "$line" >>checksums.partial
done
if [ "$(wc -l <checksums.partial)" -ne "${#FILES[@]}" ]; then
	die "checksums.txt coverage mismatch — refusing to run"
fi
if ! sha256sum --quiet -c checksums.partial; then
	die "CHECKSUM MISMATCH — the downloaded files do not match checksums.txt. Aborting."
fi

chmod +x vps-forge
rm -rf "$DEST"
mv "$STAGE" "$DEST"
say "checksums OK — starting vps-forge in $DEST"

# When piped (curl | bash) stdin is the exhausted pipe — hand the TUI the
# real terminal instead, so its prompts work. (We must NOT re-exec ourselves:
# in a pipe, $0 is the bash BINARY, and "exec bash $0" dies with
# "cannot execute binary file". There are no prompts before this point.)
# The probe OPENS /dev/tty — a permission test like `-r /dev/tty` passes for
# root even with no controlling terminal (cloud-init/CI), and the later
# open would then fail under set -e without ever starting vps-forge.
if (: </dev/tty) 2>/dev/null; then
	exec bash "$DEST/vps-forge" ${PASS_ARGS+"${PASS_ARGS[@]}"} </dev/tty
fi
exec bash "$DEST/vps-forge" ${PASS_ARGS+"${PASS_ARGS[@]}"}
