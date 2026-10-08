# Contributing to Vps Forge

Thanks for wanting to help. Vps Forge is deliberately small and strict: every
feature is a self-contained module, and every module must be safe to re-run on
a server someone loves.

## Ground rules

- **Pure Bash only.** No Python, no curl-piped magic beyond what a module
  explicitly documents.
- **`set -Eeuo pipefail` semantics.** Code must survive it. No `set +e` escapes
  without a comment explaining why.
- **Idempotent.** Running a module twice must not change anything the second
  time. Every module implements `mod_<id>_check` so the runner can skip it.
- **Lockout-safe.** Anything that touches sshd, the firewall, users or PAM
  must: back up files first (`vf_backup_file`), validate (`sshd -t` for sshd),
  arm an auto-revert guard (`vf_guard_start`), and require confirmation from a
  new session before cancelling it (`vf_confirm_new_session`).
- **ShellCheck + shfmt clean.** CI enforces both.

## Writing a module

1. Create `modules/<nn>-<name>.sh` (prefix sets the default run order) with:

   ```bash
   # shellcheck shell=bash
   # modules/<nn>-<name>.sh — one line about what it does.

   mod_<id>_plan()  { cat <<'PLAN'
   ...human-readable description shown on the review screen...
   PLAN
   }

   mod_<id>_check() { return 1; }   # 0 = already applied, runner skips it

   mod_<id>_run()   { ...do the work, idempotently...; }
   ```

   Optional: `mod_<id>_ask` prompts the user (interactive runs only) and
   stores answers with `cfg_set <key> <value>`.

2. Register it in `modules/manifest.conf`:

   ```
   <id>|<file>|<title>|<profiles>|<risk>|<one-line description>
   ```

   - `profiles`: comma list of `minimal,recommended,dockerhost,custom`
   - `risk`: `low | medium | high | critical` (drives the checklist display)

3. If your module adds a config key, document it in
   `lib/common.sh → cfg_load_defaults` and, if user-facing, in the README.

4. Add a `plan` output that tells the truth. The review screen is a promise.

## Before you open a PR

```bash
./scripts/check.sh        # manifest <-> functions <-> install.sh cross-check + linters
shellcheck -S warning vps-forge install.sh lib/*.sh modules/*.sh
shfmt -d -ln bash vps-forge install.sh lib/*.sh modules/*.sh
```

CI runs the same gates. Then test on a disposable VM (never your daily driver):

1. `--dry-run` first.
2. Run your module in isolation: `sudo ./vps-forge --yes --no-lynis --module=<id>`.
3. Re-run it to prove idempotency.
4. If it touches SSH/firewall: verify from a **new** connection after every step,
   and test the guard path (don't cancel the timer — let it revert once).

Log what you did in your PR description. The project's own test log lives in
[TESTING.md](TESTING.md) — follow the same format.

## Reporting bugs

Open an issue with: Ubuntu version, provider, the exact command you ran, the
review-screen plan, and the relevant tail of `/var/log/vps-forge.log`.
**Redact IPs and credentials** — issue templates remind you, but you are the
last line of defense.

## Style

- Tabs for indent (shfmt default), lowercase function names with the `mod_` /
  `vf_` / `docker_fw_` prefixes as you see in the tree.
- Comments explain constraints, not the obvious.
- One accent color, no emoji in output. The TUI is calm on purpose.
