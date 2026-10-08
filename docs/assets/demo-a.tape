# vps-forge demo GIF — take A (intro).
# Part of the 3-piece recording flow that produced docs/assets/demo.gif:
#   1. demo-predrive.sh   position a server-side tmux session at the confirm
#                         prompt (run ON the VM, from the repo root there)
#   2. demo-a.tape        record the intro:  ssh -> tmux new -A -> preflight
#                         -> custom checklist (toggles!) -> asks -> review
#                         -> confirm bubble. STOPS before "y".
#   3. demo-b.tape        record the apply:  tmux attach -> y -> snapshot +
#                         Lynis pre-audit -> 11 modules -> Lynis post-audit
#                         -> summary (kept on screen by the predrive wrapper)
#   4. render-demo.sh     stitch + pace + palette the two masters into demo.gif
#
# Run tapes with:  vhs docs/assets/demo-a.tape   (cwd = repo root, so the
# master lands in docs/assets/). Masters are gitignored.
#
# Before recording:
#   - ssh alias "vpsforge-demo" -> the disposable VM (no address on screen):
#       Host vpsforge-demo
#           HostName <ip>
#           User root
#           IdentityFile ~/.ssh/<key>
#   - /root/vps-forge deployed + checksum-verified on it, gum bootstrapped,
#     tmux present, ~/.tmux.conf with "set -g status off", /root/.hushlogin
#   - VM reset to a fresh state (self-clean --scope=all, then remove
#     /var/lib/vps-forge /etc/vps-forge /var/backups/vps-forge)
#   - checklist toggle key is "x" — NOT space: gum choose --no-limit uses x
#     to toggle; a space goes into the type-to-filter buffer.
Output demo-a.mp4
Set Shell bash
Set FontSize 20
Set Width 1150
Set Height 680
Set TypingSpeed 35ms
Set Theme {
	"name": "vps-forge",
	"background": "#0d1117",
	"foreground": "#c9d1d9",
	"accent": "#22d3ee"
}
Set Padding 32

Type "export PS1='demo@laptop:~$ '"
Enter
Ctrl+L
Sleep 700ms

Type "ssh vpsforge-demo"
Enter
Sleep 4000ms

Type "cd /root/vps-forge"
Enter
Sleep 800ms

Type "tmux new -A -s vpsforge ./vps-forge"
Enter
Sleep 6000ms

# preflight -> continue
Enter
Sleep 2500ms

# profile -> custom
Down
Sleep 400ms
Down
Sleep 400ms
Down
Sleep 600ms
Enter
Sleep 2500ms

# checklist: toggle off trim(9) admin_user(10) sshd(11) ufw(12) aide(18) rkhunter(19) health(27) — key is x
Down
Down
Down
Down
Down
Down
Down
Down
Sleep 500ms
Type "x"
Sleep 400ms
Down
Sleep 350ms
Type "x"
Sleep 400ms
Down
Sleep 350ms
Type "x"
Sleep 400ms
Down
Sleep 350ms
Type "x"
Sleep 500ms
Down
Down
Down
Down
Down
Down
Sleep 500ms
Type "x"
Sleep 400ms
Down
Sleep 350ms
Type "x"
Sleep 500ms
Down
Down
Down
Down
Down
Down
Down
Down
Sleep 500ms
Type "x"
Sleep 1500ms
Enter
Sleep 2000ms

# asks: timezone (typed), locale (default), hostname (default)
Type "Asia/Dhaka"
Sleep 500ms
Enter
Sleep 1500ms
Enter
Sleep 1500ms
Enter
Sleep 2000ms

# review pager
Sleep 4000ms
PageDown
Sleep 2500ms
Type "q"
Sleep 2000ms

# confirm bubble — hold, do NOT proceed (take B continues from here)
Sleep 5000ms
