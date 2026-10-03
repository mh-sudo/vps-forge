#!/usr/bin/env bash
# Local test helper: SSH to the designated vps-forge test server ONLY.
# Prefers the injected ed25519 key; falls back to the panel password.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$DIR/.env.test"
KEY="$HOME/.ssh/vf_test_admin"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=15
	-o ServerAliveInterval=30 -o ServerAliveCountMax=6)
if [ -f "$KEY" ]; then
	exec ssh -i "$KEY" -o IdentitiesOnly=yes "${SSH_OPTS[@]}" "${VF_TEST_USER}@${VF_TEST_HOST}" "$@"
fi
export SSHPASS="$VF_TEST_PASS"
exec sshpass -e ssh "${SSH_OPTS[@]}" "${VF_TEST_USER}@${VF_TEST_HOST}" "$@"
