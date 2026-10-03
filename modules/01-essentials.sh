# shellcheck shell=bash
# modules/01-essentials.sh — base tooling every server should have.

mod_essentials_plan() {
	cat <<'PLAN'
Install base packages: curl wget git htop ncdu jq unzip zip rsync tmux
dnsutils lsof strace bash-completion gnupg ca-certificates
apt-transport-https software-properties-common man-db socat
PLAN
}

mod_essentials_check() {
	local p missing=0
	for p in curl wget git htop ncdu jq unzip zip rsync tmux dnsutils lsof \
		strace bash-completion gnupg ca-certificates apt-transport-https \
		software-properties-common man-db socat; do
		dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed' || missing=1
	done
	return "$missing"
}

mod_essentials_run() {
	vf_pkg_install curl wget git htop ncdu jq unzip zip rsync tmux dnsutils lsof \
		strace bash-completion gnupg ca-certificates apt-transport-https \
		software-properties-common man-db socat
}
