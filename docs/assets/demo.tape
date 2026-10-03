# vps-forge demo tape — render with: vhs docs/assets/demo.tape
# Output: docs/assets/demo.gif (referenced by README.md)
#
# Records a REAL run of vps-forge (single harmless module: journald caps) on a
# disposable test VM over SSH. The VM is reached through an ssh config alias
# ("vpsforge-demo") so no address ever appears on screen. Reset the VM after
# re-recording (see TESTING.md) and remove the alias from ~/.ssh/config.
#
# Before recording:
#   1. point ~/.ssh/config at your VM:
#        Host vpsforge-demo
#            HostName <ip>
#            User root
#            IdentityFile ~/.ssh/<key>
#   2. have /root/vps-forge deployed on it

Output docs/assets/demo.gif
Set FontSize 18
Set Width 1150
Set Height 680
Set Shell bash
Set Theme {
	"name": "vps-forge",
	"background": "#0d1117",
	"foreground": "#c9d1d9",
	"accent": "#22d3ee"
}
Set Padding 32

# neutral local prompt (no personal info in the GIF)
Type "export PS1='demo@laptop:~$ '"
Enter
Ctrl+L
Sleep 600ms

# ssh to the disposable VM via alias (no address on screen)
Type "ssh vpsforge-demo"
Enter
Sleep 3000ms

# launch vps-forge: one small module, lynis skipped to keep the demo short
Type "cd /root/vps-forge && DEBIAN_FRONTEND=noninteractive ./vps-forge --module=journald --no-lynis"
Enter
Sleep 14000ms

# preflight screen -> press Enter to continue
Sleep 1500ms
Enter
Sleep 2500ms

# review screen (gum pager) -> read, then quit with q
Sleep 2500ms
Type "q"
Sleep 1500ms

# confirm -> yes
Type "y"
Enter
Sleep 8000ms

# summary shown; show the saved report
Sleep 1500ms
Type "clear"
Enter
Sleep 400ms
Type "cat /root/vps-forge-report.txt"
Enter
Sleep 3500ms

Type "exit"
Enter
Sleep 800ms
