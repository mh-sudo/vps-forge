#!/bin/bash
# demo-predrive.sh — run ON the disposable VM (ssh vpsforge-demo, repo root).
# Drives a fresh interactive run to the "Proceed with these changes?" prompt
# and parks it there in a tmux session named "vpsforge", wrapped in a
# keep-alive so the final summary STAYS on screen after the run exits
# (a bare `tmux new ./vps-forge` closes the pane — and the summary — the
# instant the run finishes). demo-b.tape then attaches and types "y".
# The key sequence must match demo-a.tape's checklist toggles.
cap() { tmux capture-pane -t vpsforge -p | sed -e "s/\x1b\[[0-9;?]*[a-zA-Z]//g" > "/tmp/reh/$1.txt"; }
waitfor() {
	local tries=0
	while [ "$tries" -lt "${2:-20}" ]; do
		tries=$((tries + 1))
		tmux capture-pane -t vpsforge -p | sed -e "s/\x1b\[[0-9;?]*[a-zA-Z]//g" | grep -aq "$1" && { [ -n "${3:-}" ] && cap "$3"; return 0; }
		sleep 1
	done
	echo "TIMEOUT: $1" >&2
	return 1
}
mkdir -p /tmp/reh
tmux kill-server 2>/dev/null
sleep 1
# keep-alive wrapper: after ./vps-forge exits, the pane (and the summary) stays up
tmux new-session -d -s vpsforge -x 100 -y 30 "cd /root/vps-forge && ./vps-forge; echo; sleep 900"
waitfor "Press Enter to continue" 60 preflight || exit 1
tmux send-keys -t vpsforge Enter
waitfor "Choose a profile" 10 profile || exit 1
sleep 1
tmux send-keys -t vpsforge Down Down Down
sleep 1
tmux send-keys -t vpsforge Enter
waitfor "Select modules" 10 checklist || exit 1
sleep 1
tmux send-keys -t vpsforge Down Down Down Down Down Down Down Down
sleep 0.4; tmux send-keys -t vpsforge x
sleep 0.4; tmux send-keys -t vpsforge Down; sleep 0.3; tmux send-keys -t vpsforge x
sleep 0.4; tmux send-keys -t vpsforge Down; sleep 0.3; tmux send-keys -t vpsforge x
sleep 0.4; tmux send-keys -t vpsforge Down; sleep 0.3; tmux send-keys -t vpsforge x
sleep 0.4; tmux send-keys -t vpsforge Down Down Down Down Down Down
sleep 0.4; tmux send-keys -t vpsforge x
sleep 0.4; tmux send-keys -t vpsforge Down; sleep 0.3; tmux send-keys -t vpsforge x
sleep 0.4; tmux send-keys -t vpsforge Down Down Down Down Down Down Down Down
sleep 0.4; tmux send-keys -t vpsforge x
sleep 1
cap checklist-after
tmux send-keys -t vpsforge Enter
waitfor "Timezone" 10 ask-tz || exit 1
tmux send-keys -t vpsforge 'Asia/Dhaka'
sleep 0.6
tmux send-keys -t vpsforge Enter
waitfor "System locale" 10 || exit 1
tmux send-keys -t vpsforge Enter
waitfor "Hostname" 10 || exit 1
tmux send-keys -t vpsforge Enter
waitfor "esc quit" 20 pager || exit 1
sleep 1
tmux send-keys -t vpsforge PageDown
sleep 1
tmux send-keys -t vpsforge q
waitfor "Proceed with these changes" 10 confirm || exit 1
cap positioned
grep -a "selected modules" /var/log/vps-forge.log | tail -1
echo POSITIONED_AT_CONFIRM
