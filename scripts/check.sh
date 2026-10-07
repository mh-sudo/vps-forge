#!/usr/bin/env bash
# scripts/check.sh — static consistency gates for the vps-forge repo.
# 1. every manifest id has plan/check/run functions in its module file
# 2. install.sh FILES list matches the real file tree
# 3. shellcheck + shfmt + bash -n
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"
fail=0

echo "== manifest <-> module functions =="
while IFS='|' read -r id file title profiles risk desc; do
	case "$id" in ''|\#*) continue ;; esac
	f="modules/$file"
	if [ ! -r "$f" ]; then echo "MISSING FILE: $f (id $id)"; fail=1; continue; fi
	for fn in plan check run; do
		if ! grep -q "^mod_${id}_${fn}()" "$f"; then
			echo "MISSING FUNCTION: mod_${id}_${fn} in $f"; fail=1
		fi
	done
	# profile tags valid
	for p in ${profiles//,/ }; do
		case "$p" in minimal|recommended|dockerhost|custom) ;; *) echo "BAD PROFILE TAG '$p' for $id"; fail=1 ;; esac
	done
	case "$risk" in low|medium|high|critical) ;; *) echo "BAD RISK TAG '$risk' for $id"; fail=1 ;; esac
done <modules/manifest.conf

echo "== install.sh FILES list <-> repo tree =="
# extract the FILES=( ... ) block, whitespace-split entries to one per line
sed -n '/^FILES=(/,/^)/p' install.sh | sed '/^FILES=(/d;/^)/d' | tr ' \t' '\n\n' | sed '/^$/d' >"$DIR/.files-list.tmp"
while read -r f; do
	if [ ! -r "$f" ]; then echo "install.sh lists MISSING file: $f"; fail=1; fi
done <"$DIR/.files-list.tmp"
# and the reverse: every repo file that install.sh should carry is listed
for f in vps-forge lib/*.sh modules/*.sh; do
	grep -qxF "$f" "$DIR/.files-list.tmp" || { echo "repo file NOT in install.sh FILES: $f"; fail=1; }
done
rm -f "$DIR/.files-list.tmp"

echo "== shellcheck =="
shellcheck -S warning vps-forge install.sh lib/*.sh modules/*.sh || fail=1
echo "== shfmt =="
shfmt -d -ln bash vps-forge install.sh lib/*.sh modules/*.sh >/dev/null || fail=1
echo "== bash -n =="
for f in vps-forge install.sh lib/*.sh modules/*.sh; do bash -n "$f" || fail=1; done

echo "== checksums.txt freshness =="
# checksums.txt must match the shipped tree exactly (a content change without
# regenerating it ships a verifier that fails server-side)
find vps-forge install.sh lib modules -type f | LC_ALL=C sort | while read -r f; do
	sha256sum "$f"
done >"$DIR/.cksum.tmp"
if ! diff -q "$DIR/.cksum.tmp" checksums.txt >/dev/null; then
	echo "checksums.txt STALE — run scripts/make-checksums.sh"
	diff "$DIR/.cksum.tmp" checksums.txt | head -6
	fail=1
fi
rm -f "$DIR/.cksum.tmp"

if [ "$fail" = "0" ]; then echo "ALL CONSISTENCY GATES PASS"; else echo "GATE FAILURES PRESENT"; exit 1; fi
