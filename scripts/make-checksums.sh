#!/usr/bin/env bash
# Generate checksums.txt for install.sh's verified download flow.
# Run from the repo root (or via scripts/): writes checksums.txt for every shipped file.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"
{
	find vps-forge install.sh lib modules -type f | LC_ALL=C sort | while read -r f; do
		# paths relative to the repo root as install.sh downloads them
		sha256sum "$f"
	done
} >checksums.txt
echo "checksums.txt written: $(wc -l <checksums.txt | tr -d ' ') files"
