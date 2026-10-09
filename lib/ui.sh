# shellcheck shell=bash
# lib/ui.sh — TUI abstraction over gum (preferred) / whiptail / plain stdout.
# All prompts go to stderr; functions that RETURN a value print it to stdout.

VF_UI="${VF_UI:-auto}"
VF_ACCENT=45 # one accent color (ANSI 256: cyan)
VF_UI_WIDTH="${VF_UI_WIDTH:-0}"
# color + glyph policy (refined in ui_init): NO_COLOR / dumb terminals get
# plain text, non-UTF-8 locales get ASCII markers instead of ✓/✗/•
VF_COLOR="${VF_COLOR:-1}"
VF_GLYPH_OK="✓"
VF_GLYPH_FAIL="✗"
VF_GLYPH_SKIP="•"

ui_init() {
	local tty=1
	[ -t 0 ] && [ -t 2 ] || tty=0
	if [ -n "${NO_COLOR:-}" ] || [ "${TERM:-}" = "dumb" ]; then
		VF_COLOR=0
	fi
	case "${LC_ALL:-${LANG:-}}" in
	*UTF-8* | *utf8*) : ;;
	*)
		VF_GLYPH_OK="ok:"
		VF_GLYPH_FAIL="FAIL:"
		VF_GLYPH_SKIP="*"
		;;
	esac
	if [ "$VF_UI" = "auto" ]; then
		if [ "$tty" = "1" ] && command -v gum >/dev/null 2>&1 && [ "${TERM:-}" != "dumb" ] && [ -z "${NO_COLOR:-}" ]; then
			VF_UI=gum
		elif [ "$tty" = "1" ] && command -v whiptail >/dev/null 2>&1; then
			VF_UI=whiptail
		else
			VF_UI=plain
		fi
	fi
	local sz
	sz="$(stty size 2>/dev/null || true)"
	VF_UI_WIDTH="$(awk -v s="$sz" 'BEGIN {
		n = split(s, a, " "); w = a[2] + 0
		if (w >= 40 && w < 80) print w; else if (w >= 80) print 80; else print 76
	}')"
	vf_log_info "ui backend: $VF_UI (width=$VF_UI_WIDTH)"
}

ui_gum() { command gum "$@"; }

# ---------- static rendering ----------

ui_header() { # section header inside an accent box
	local t="$*"
	case "$VF_UI" in
	gum) ui_gum style --bold --foreground "$VF_ACCENT" \
		--border rounded --border-foreground "$VF_ACCENT" --padding "0 1" --margin "1 0" "$t" >&2 ;;
	*) printf '\n\033[1m== %s ==\033[0m\n' "$t" >&2 ;;
	esac
}

ui_para() { # paragraph, wrapped, dim leading label supported by caller
	local t="$*"
	case "$VF_UI" in
	gum) ui_gum style --width "$VF_UI_WIDTH" "$t" >&2 ;;
	*) printf '%s\n' "$t" | fold -s -w "$VF_UI_WIDTH" >&2 ;;
	esac
}

ui_warn() {
	ui_para "WARNING: $*"
	vf_log_warn "$*"
}
ui_error() {
	ui_para "ERROR: $*"
	vf_log_error "$*"
}
ui_ok() {
	if [ "$VF_COLOR" = 1 ]; then printf '\033[32m%s\033[0m %s\n' "$VF_GLYPH_OK" "$*" >&2; else printf '%s %s\n' "$VF_GLYPH_OK" "$*" >&2; fi
}
ui_fail() {
	if [ "$VF_COLOR" = 1 ]; then printf '\033[31m%s\033[0m %s\n' "$VF_GLYPH_FAIL" "$*" >&2; else printf '%s %s\n' "$VF_GLYPH_FAIL" "$*" >&2; fi
}
ui_skip() {
	if [ "$VF_COLOR" = 1 ]; then printf '\033[33m%s\033[0m %s (skipped)\n' "$VF_GLYPH_SKIP" "$*" >&2; else printf '%s %s (skipped)\n' "$VF_GLYPH_SKIP" "$*" >&2; fi
}
ui_info() { printf '  %s\n' "$*" >&2; }

ui_risk_ansi() { # risk level -> ANSI color (low green, medium yellow, high red, critical magenta)
	case "$1" in
	low) printf 32 ;;
	medium) printf 33 ;;
	high) printf 31 ;;
	critical) printf 35 ;;
	*) printf 36 ;;
	esac
}

ui_box() { # multi-line info box
	local title="$1"
	shift
	local body="$*"
	case "$VF_UI" in
	gum) {
		ui_gum style --bold --foreground "$VF_ACCENT" "$title" >&2
		ui_gum style --border rounded --border-foreground 245 --width "$VF_UI_WIDTH" "$body" >&2
	} ;;
	*) printf '\n%s\n%s\n' "== $title ==" "$body" >&2 ;;
	esac
}

# ---------- interactive primitives ----------

ui_confirm() { # ui_confirm "question" [default:y|n] -> exit code 0=yes 1=no
	local q="$1" def="${2:-y}"
	if [ "$VF_NONINTERACTIVE" = "1" ]; then
		[ "$def" = "y" ]
		return
	fi
	case "$VF_UI" in
	gum)
		# stderr stays visible: gum renders its UI there under command substitution
		ui_gum confirm "$q" --default="$([ "$def" = "n" ] && echo false || echo true)"
		;;
	whiptail)
		local extra=()
		[ "$def" = "n" ] && extra=(--defaultno)
		whiptail --yesno "$q" 0 "$VF_UI_WIDTH" "${extra[@]}" 2>/dev/null
		;;
	*)
		local reply
		# no tty (scripted runs): fall back to the default instead of erroring
		if [ "$def" = "n" ]; then
			read -r -p "$q [y/N] " reply </dev/tty 2>/dev/null || reply=""
		else
			read -r -p "$q [Y/n] " reply </dev/tty 2>/dev/null || reply=""
		fi
		case "${reply:-$def}" in y | Y | yes | YES) return 0 ;; *) return 1 ;; esac
		;;
	esac
}

ui_choose() { # ui_choose "prompt" opt1 opt2... -> stdout: chosen value
	local q="$1"
	shift
	local opts=("$@") i pick
	if [ "$VF_NONINTERACTIVE" = "1" ]; then
		printf '%s\n' "${opts[0]}"
		return
	fi
	case "$VF_UI" in
	gum)
		# choose takes options positionally — the question must go to --header,
		# and stderr stays visible: gum renders its UI there when stdout is
		# captured by a command substitution (suppressing it hides the whole UI)
		ui_gum choose --header "$q" --height "${VF_GUM_CHOOSE_HEIGHT:-15}" "${opts[@]}"
		;;
	whiptail)
		local menu=() idx=1
		for i in "${opts[@]}"; do
			menu+=("$idx" "$i" "")
			idx=$((idx + 1))
		done
		pick="$(whiptail --menu "$q" 0 "$VF_UI_WIDTH" 10 "${menu[@]}" --stdout 2>/dev/null)" && printf '%s\n' "${opts[pick - 1]}"
		;;
	*)
		idx=1
		for i in "${opts[@]}"; do
			printf '  %d) %s\n' "$idx" "$i" >&2
			idx=$((idx + 1))
		done
		read -r -p "$q [#] " pick </dev/tty >&2
		# empty or invalid input picks the FIRST option (the default) — bash
		# negative-array indexing used to silently select the LAST one
		if [[ ! "$pick" =~ ^[0-9]+$ ]] || [ "$pick" -lt 1 ] || [ "$pick" -gt "${#opts[@]}" ]; then
			pick=1
		fi
		printf '%s\n' "${opts[pick - 1]}"
		;;
	esac
}

ui_multi() { # ui_multi "prompt" "preselected,csv" opt1 opt2... -> stdout: csv of chosen
	local q="$1" pre="$2"
	shift 2
	local opts=("$@") i sel=() pick
	if [ "$VF_NONINTERACTIVE" = "1" ]; then
		printf '%s\n' "$pre"
		return
	fi
	case "$VF_UI" in
	gum)
		local out
		out="$(ui_gum choose --no-limit --header "$q" --selected "$pre" --height "${VF_GUM_CHOOSE_HEIGHT:-15}" "${opts[@]}")"
		[ -n "$out" ] && printf '%s\n' "$out" | paste -sd, -
		;;
	whiptail)
		# tags are indices (whiptail quotes space-containing tags in --stdout output)
		local list=() idx=1 on=off n
		for i in "${opts[@]}"; do
			on=off
			case ",$pre," in
			*",$i,"*) on=on ;;
			esac
			list+=("$idx" "${i:0:60}" "$on")
			idx=$((idx + 1))
		done
		pick="$(whiptail --checklist "$q" 0 "$VF_UI_WIDTH" 12 "${list[@]}" --stdout 2>/dev/null)" || return 1
		local res=""
		for n in $pick; do
			[[ "$n" =~ ^[0-9]+$ ]] && res+="${opts[n - 1]},"
		done
		printf '%s\n' "${res%,}"
		;;
	*)
		idx=1
		for i in "${opts[@]}"; do
			printf '  %d) %s\n' "$idx" "$i" >&2
			idx=$((idx + 1))
		done
		read -r -p "$q [comma numbers] " pick </dev/tty >&2
		IFS=',' read -ra sel <<<"$pick"
		local res="" n
		for n in "${sel[@]}"; do
			[[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#opts[@]}" ] && res+="${opts[n - 1]},"
		done
		printf '%s\n' "${res%,}"
		;;
	esac
}

ui_input() { # ui_input "prompt" [default] -> stdout: value
	local q="$1" d="${2:-}"
	local v
	if [ "$VF_NONINTERACTIVE" = "1" ]; then
		printf '%s\n' "$d"
		return
	fi
	case "$VF_UI" in
	gum)
		# placeholder, not --value: a prefilled value gets typed text APPENDED
		# (e.g. "auto" + "Asia/Dhaka" -> "autoAsia/Dhaka"); a gray placeholder
		# hint is replaced by typing, and empty input accepts the default
		if ! v="$(ui_gum input --header "$q" --placeholder "$d")"; then return 1; fi
		printf '%s\n' "${v:-$d}"
		;;
	whiptail) v="$(whiptail --inputbox "$q" 0 "$VF_UI_WIDTH" "$d" --stdout 2>/dev/null)" && printf '%s\n' "$v" ;;
	*)
		read -r -p "$q [$d]: " v </dev/tty >&2
		printf '%s\n' "${v:-$d}"
		;;
	esac
}

ui_password() { # secret input -> stdout
	local q="$1"
	if [ "$VF_NONINTERACTIVE" = "1" ]; then
		printf '\n'
		return
	fi
	case "$VF_UI" in
	gum) ui_gum input --password --header "$q" ;;
	whiptail) whiptail --passwordbox "$q" 0 "$VF_UI_WIDTH" --stdout 2>/dev/null ;;
	*)
		local v
		read -rs -p "$q: " v </dev/tty >&2
		printf '\n' >&2
		printf '%s\n' "$v"
		;;
	esac
}

ui_pause() {
	[ "$VF_NONINTERACTIVE" = "1" ] && return 0
	ui_para "Press Enter to continue..." >&2
	local _
	read -r _ </dev/tty >&2 || true
}

ui_pager() { # ui_pager <file>
	local f="$1"
	case "$VF_UI" in
	gum) ui_gum pager <"$f" >&2 ;;
	whiptail) whiptail --scrolltext --textbox "$f" 0 0 2>/dev/null || cat "$f" >&2 ;;
	*) cat "$f" >&2 ;;
	esac
}

ui_spin() { # ui_spin "title" -- cmd args... ; output captured to a per-call log; returns cmd status
	local title="$1"
	shift
	if [ "${1:-}" = "--" ]; then shift; fi
	# shell-quote EVERY arg, then log a REDACTED form: secrets must not reach
	# /var/log/vps-forge.log, and a value containing quotes must not break
	# the bash -c invocation
	local cmd=""
	printf -v cmd '%q ' "$@"
	# unique log per call — a shared spin.log gets polluted by later spins,
	# destroying the failure evidence of earlier ones
	local log
	log="$(mktemp "$VF_TMP_DIR/spin.XXXXXX.log")"
	vf_log_info "run: $(vf_redact "$cmd")"
	# VF_IN_SPIN tells nested helpers (vf_pkg_install) not to spin again
	if [ "$VF_UI" = "gum" ] && [ "$VF_NONINTERACTIVE" != "1" ]; then
		VF_IN_SPIN=1 ui_gum spin --spinner line --title " $title" -- bash -c "$cmd >'$log' 2>&1"
	else
		printf '  ... %s\n' "$title" >&2
		VF_IN_SPIN=1 bash -c "$cmd >'$log' 2>&1"
	fi
	local rc=$?
	[ $rc -ne 0 ] && { tail -15 "$log" >&2 || true; }
	cp -f "$log" "$VF_TMP_DIR/spin.last.log" 2>/dev/null || true
	return $rc
}

# ---------- ask-with-memory (used by modules) ----------

vf_ask() { # vf_ask <cfgkey> "question" "default" [choices...] -> stdout
	local key="$1" q="$2" def="$3"
	shift 3
	local opts=("$@") v
	v="$(cfg_get "$key" "$def")"
	if [ "$VF_NONINTERACTIVE" = "1" ]; then
		if ! cfg_has "$key" && [ -z "$def" ]; then vf_die "non-interactive: no value for '$key' and no default"; fi
		printf '%s\n' "$v"
		cfg_set "$key" "$v"
		return
	fi
	if [ ${#opts[@]} -gt 0 ]; then
		local has=0 o
		for o in "${opts[@]}"; do [ "$o" = "$v" ] && has=1; done
		[ "$has" = "0" ] && opts+=("$v")
		v="$(ui_choose "$q" "${opts[@]}")" || v="$(cfg_get "$key" "$def")"
	else
		v="$(ui_input "$q" "$v")" || v="$(cfg_get "$key" "$def")"
	fi
	cfg_set "$key" "$v"
	printf '%s\n' "$v"
}

vf_ask_bool() { # vf_ask_bool <cfgkey> "question" default(y|n) -> exit code
	local key="$1" q="$2" def="$3" v
	v="$(cfg_get "$key" "")"
	[ -n "$v" ] || v="$def"
	# normalize config/state spellings ("false", "true", "1", ...) BEFORE use:
	# ui_confirm treats only a literal "n" as No, so an unnormalized "false"
	# used to show "default: no" while Enter answered YES
	case "$v" in
	y | Y | yes | Yes | YES | true | True | TRUE | 1 | on | On | ON) v="y" ;;
	*) v="n" ;;
	esac
	if [ "$VF_NONINTERACTIVE" = "1" ]; then
		[ "$v" = "y" ]
		return
	fi
	ui_confirm "$q (default: $([ "$v" = "y" ] && echo yes || echo no))" "$v"
	local rc=$?
	cfg_set "$key" "$([ $rc -eq 0 ] && echo y || echo n)"
	return $rc
}

vf_ask_secret() { # vf_ask_secret <cfgkey> "question" -> stdout (from cfg when non-interactive)
	local key="$1" q="$2" v
	v="$(cfg_get "$key" "")"
	if [ "$VF_NONINTERACTIVE" = "1" ]; then
		printf '%s\n' "$v"
		return
	fi
	if [ -n "$v" ]; then
		ui_confirm "Reuse previously stored value for '$key'?" y && {
			printf '%s\n' "$v"
			return
		}
	fi
	v="$(ui_password "$q (leave blank to skip)")" || v=""
	cfg_set "$key" "$v"
	printf '%s\n' "$v"
}
