# vps-forge demo GIF — take B (apply). See demo-a.tape header for the flow.
# Requires the predriven session (demo-predrive.sh) parked at the confirm.
Output demo-b.mp4

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

Type "tmux attach -t vpsforge"
Enter
Sleep 5000ms

# proceed: snapshot + lynis pre + 11 modules + lynis post + summary
Type "y"
Sleep 330000ms

# summary — hold
Sleep 6000ms
