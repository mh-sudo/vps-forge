#!/usr/bin/env bash
# docs/assets/render-demo.sh — stitch the VHS takes into the README GIF.
#
# Masters (gitignored, produced by the take flow in demo.tape's header):
#   demo-a.mp4  intro take: ssh -> tmux -> preflight -> custom checklist
#               -> asks -> review -> confirm (ends WITHOUT proceeding)
#   demo-b.mp4  apply take: tmux attach -> y -> snapshot + Lynis pre-audit
#               -> 11 modules -> Lynis post-audit -> summary (held on screen)
#
# Each SEGMENTS line: <master>|<start>|<end>|<speed>
# Natural speed (1.0) for human moments (checklist toggles, confirm, summary),
# fast (5-25x) for spinners and apt-heavy apply stretches. All dead air is
# trimmed by the segment boundaries — tune after re-recording.
set -euo pipefail
cd "$(dirname "$0")"

FPS="${FPS:-14}"
OUT="${OUT:-demo.gif}"

SEGMENTS=${SEGMENTS:-'
A|2.8|6.4|1.0
A|12.5|17.9|1.15
A|17.9|22.4|1.3
A|22.4|30.8|1.0
A|31.1|39.2|1.7
A|39.2|46.4|1.55
A|46.4|47.9|0.6
B|3.4|9.0|1.5
B|12.5|16.5|1.0
B|16.5|109.4|24.0
B|109.4|209.5|7.5
B|210.5|218.0|1.0
'}

[ -r demo-a.mp4 ] || { echo "demo-a.mp4 missing — see demo.tape header" >&2; exit 1; }
[ -r demo-b.mp4 ] || { echo "demo-b.mp4 missing — see demo.tape header" >&2; exit 1; }

n=0
filter=""
parts=""
while IFS='|' read -r m s e sp; do
	[ -n "$s" ] || continue
	case "$m" in
	A) idx=0 ;;
	B) idx=1 ;;
	*) echo "bad master '$m'" >&2; exit 1 ;;
	esac
	n=$((n + 1))
	filter+="[${idx}:v]trim=start=${s}:end=${e},setpts=(PTS-STARTPTS)/${sp}[v${n}];"
	parts+="[v${n}]"
done <<EOF
$SEGMENTS
EOF
[ "$n" -gt 1 ] || { echo "need at least 2 segments" >&2; exit 1; }

ffmpeg -hide_banner -loglevel error -y -i demo-a.mp4 -i demo-b.mp4 -filter_complex \
	"${filter}${parts}concat=n=${n}:v=1:a=0[v];[v]fps=${FPS},split[pa][pb];[pa]palettegen=max_colors=128[p];[pb][p]paletteuse=dither=bayer:bayer_scale=4" \
	"$OUT.raw.gif"
gifsicle -O3 --lossy=80 --colors 128 -o "$OUT" "$OUT.raw.gif"
rm -f "$OUT.raw.gif"

echo "== $OUT =="
du -h "$OUT" | awk '{print "size: " $1}'
ffprobe -v error -select_streams v:0 -show_entries stream=width,height,nb_frames -of default=nw=1 "$OUT"
