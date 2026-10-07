#!/usr/bin/env bash
# Local test helper: rsync the project to the test server (key preferred).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$DIR/.env.test"
KEY="$HOME/.ssh/vf_test_admin"
REMOTE_DIR="${1:-/root/vps-forge}"
if [ -f "$KEY" ]; then
	RSH="ssh -i $KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15"
else
	RSH="ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15"
	export SSHPASS="$VF_TEST_PASS"
	RSH="sshpass -e $RSH"
fi
# -rlptD = archive MINUS owner/group: macOS ships openrsync (no --chown), and
# -a would carry the local uid/gid (501) onto the server — the deployed tree
# must be root-owned. Existing receiver files keep their owner, so a fresh
# mirror over an old one needs: ssh … chown -R root:root /root/vps-forge
exec rsync -rlptD --delete --stats -e "$RSH" \
	--exclude '.git' --exclude '.env.test' --exclude 'test-out' --exclude 'scripts/' --exclude '*.log' \
	"$DIR/" "${VF_TEST_USER}@${VF_TEST_HOST}:$REMOTE_DIR/"
