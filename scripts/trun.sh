#!/usr/bin/env bash
# Local helper: run a command DETACHED on the test server via a systemd transient
# unit (immune to SSH session teardown). Output: /root/vf-run.log, exit code: /root/vf-run.done
# usage: scripts/trun.sh <command...>
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CMD="$*"
exec "$DIR/scripts/tssh.sh" \
	"systemctl stop vfrun.service 2>/dev/null; systemctl reset-failed vfrun 2>/dev/null; \
	 rm -f /root/vf-run.log /root/vf-run.done; \
	 systemd-run --unit=vfrun --collect bash -c '$CMD; echo \$? >/root/vf-run.done' \
	 >/root/vf-run.log 2>&1 && echo DETACHED-STARTED || echo DETACH-FAILED"
