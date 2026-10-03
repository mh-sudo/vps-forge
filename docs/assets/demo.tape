# vps-forge demo tape — render with: vhs docs/assets/demo.tape
# Output: docs/assets/demo.gif (referenced by the README once uncommented)
# Keep under 30 seconds: preflight, pick profile, review, apply, report.
#
# NOTE: run against a THROWAWAY VM. The Type lines below simulate the keys you
# would press; adjust timings to taste before recording.

Output docs/assets/demo.gif
Set FontSize 20
Set Width 1200
Set Height 700
Set Theme { "name": "vps-forge", "background": "#0d1117", "foreground": "#c9d1d9", "accent": "#23d3d3" }

Type "ssh root@your-fresh-vps"
Enter
Sleep 800ms
Type "./vps-forge"
Enter
Sleep 2s

# preflight screen
Sleep 3s
Enter

# profile selection
Sleep 1s
Enter

# custom checklist (skip — accept recommended defaults)
Sleep 1s
Enter

# review screen
Sleep 4s

# confirm
Type "y"
Enter
Sleep 8s

# final summary + report path
Sleep 2s

Ctrl+C
Sleep 500ms
