# TESTING.md — test log and results

Test server: HOSTTIER VPS, Ubuntu 24.04.5 LTS, 2 vCPU, 2 GB RAM, 25 GB disk, KVM.
22.04 is supported by the code but **not live-tested** (server runs 24.04) — known gap.
Lint gates: `shellcheck -S warning` + `shfmt -d` = clean across all files (re-run after
every fix; see §C).

## A. Safety layer / failsafes (protocol: second SSH session kept open throughout)

| # | Test | Result |
|---|------|--------|
| A1 | Bad sshd config: piped garbage into `vf_sshd_apply_dropin` | **PASS** — `sshd -t` rejected it, previous config auto-restored, drop-in removed, new connection OK |
| A2 | UFW enable + 40s guard, guard NOT cancelled | **PASS** — SSH allowed first, connection OK with UFW on; guard fired at 40s → `ufw disable` + `logger` tag; new connection OK after auto-revert |
| A3 | sshd hardening + 45s guard, guard NOT cancelled | **PASS (after 3 fixes, see below)** — drop-in applied + validated, NEW connection OK while hardened; guard reverted the drop-in; connection OK after |
| A4 | Failed-confirmation semantics | Covered by A2/A3 (no-confirm → auto-revert) |
| A5 | `rollback` command full cycle | **PENDING** (blocked by server access, see §E) |

### Bugs found & fixed during A1–A3 (each re-tested)
1. `AllowTcpForwarding false` invalid sshd syntax → map booleans to `no`/`yes`.
2. Hardcoded KEX list included `curve25519-sha256@libssh.com`, removed in OpenSSH 9.6
   (Ubuntu 24.04) → crypto lists now filtered at apply time via `ssh -Q`.
3. `PermitRootLogin` printed a human description ("prohibit-password (keys only for
   root)") into the config → split value vs description helpers.
4. Snapshot restore path lost a slash (`files` + `etc/...` → `filesetc/...`) → fixed in
   `vf_sshd_apply_dropin` (guard command + restore).
5. Arg-parse loop shifted `$@` while reading an unchanging array (only the first flag
   was applied) → rewritten over positional params.
6. `stty size` under a pipe made `fold -w ''` explode → width computation hardened.

## B. Incident — 2026-10-02 lockout (root cause of D9)

During test A3 with the pre-fix code, a **non-interactive** module run applied
`PermitRootLogin prohibit-password` and auto-cancelled the safety guard after internal
validation only. The operator (this test harness) had no authorized root key — only
root/password — so every NEW ssh session was refused from that moment
(verified: `Permission denied (publickey,password)` with correct credentials).
Established sessions were unaffected (sshd restart does not kill them) but none was
interactive. Recovery requires the provider's out-of-band console (HOSTTIER panel) —
out of this agent's reach — or an OS reinstall.

Consequences in code (all verified by re-running A2/A3 logic locally + A1/A2 on server):
- `vf_confirm_new_session` non-interactive path now returns FAILURE for fail-closed
  changes → the guard stays armed → auto-revert unless `vps-forge guard-cancel` is run
  after external verification. `failopen` arg added for UFW.
- `sshd_root_value` refuses to restrict root login unless an authorized key exists.
- This incident is precisely the class of failure the guards exist for; the fixed code
  reverts such changes instead of persisting them.

## C. Lint / static gates

| gate | result |
|---|---|
| `shellcheck -S warning` (all 41 files) | CLEAN |
| `shfmt -d` | CLEAN (0 diff) |
| `bash -n` all files | CLEAN |
| gum v2.0.2 .deb sha256 verify + install + flag probe (choose/input/spin/confirm/style) | PASS on server |

## D. Functional tests on the server

| # | Area | Result |
|---|------|--------|
| D1 | `--help`, `--version`, `status` | PASS |
| D2 | non-interactive `--dry-run` minimal profile (preflight → plan → review) | PASS (after fix 5/6) |
| D3 | essentials/sysbase/swap/journald/sysctl/perf/pam/… module runs | **PENDING** (server access) |
| D4 | Full recommended profile + idempotency re-run | **PENDING** |
| D5 | Docker + DOCKER-USER + `verify-firewall` + docker-allow flow | **PENDING** |
| D6 | Panels (one at a time, clean reset between) | **PENDING** |
| D7 | `rollback`, `backup-test`, non-interactive real run | **PENDING** |
| D8 | Lynis before/after delta | **PENDING** |

## E. Blocker log

- **2026-10-02 16:39Z — lockout (see §B).** Server unreachable for new sessions;
  awaiting provider-console fix or OS reinstall by the server owner, after which §D
  resumes. All remaining work that does not require the server (docs, lint, entrypoint
  checksums, code fixes) has been completed meanwhile.
- **2026-10-02 ~21:55Z — wrong-console incident (disclosed to user).** The VNC details
  provided (<VNC-CONSOLE>, pw <redacted-vnc-password>) turned out to control **<OTHER-SERVER-IP>**
  ("<hostname-redacted>" — a different VPS), NOT the test server <TEST-SERVER-IP>.
  Verified via `hostname -I` on that console. Actions taken there (believing it was the
  test box): root login (that box's root password = the VNC password), the recovery
  one-liner (`rm -f /etc/ssh/sshd_config.d/00-vps-forge.conf` — no-op, file absent;
  `systemctl restart ssh` — ~1s restart, no config change; `echo`), and read-only
  identity checks (`hostname -I`, `cat /etc/hostname`, `ss -tlnp`). Root shell then
  closed with `exit`. No configuration or data was modified on that machine. Test server
  remains locked. Awaiting correct VNC details for <TEST-SERVER-IP>.

## F. Post-reinstall test battery (2026-10-02 17:00–19:15Z) — server REINSTALLED fresh 24.04.2

Setup: fresh Ubuntu 24.04.2 (hostname <hostname>), zcode ed25519 key injected
via panel, project at /root/vps-forge. Long runs executed via `systemd-run` transient
units (SSH-session teardown killed nohup'd runs twice — see bugs below).

| # | Test | Result |
|---|------|--------|
| B0 | Deploy + baseline recon | PASS |
| B1 | 18 modules in isolation (essentials sysbase swap journald trim sysctl perf unattended pam services apparmor_auditd fail2ban health deploy_user node_exporter runtimes aide rkhunter) | **ALL PASS** (trim = skipped by design, no discard on VM disk) |
| B1i | Idempotency re-run of batch 1 | PASS — 7 modules "skipped (already applied)" |
| B2 | admin_user (forge + sudo + key + forced password change) | PASS — key login reaches PAM forced-change; sudo group set |
| B3 | sshd hardening with D9 guard semantics | **PASS** — guard stayed ARMED in non-interactive, NEW conn verified, guard-cancel, still hardened (maxauthtries 4, prohibit-password — safe: root HAS a key) |
| B4 | ufw enable | PASS — deny incoming + 22/tcp LIMIT; NEW conn OK |
| B5 | Full recommended profile + Lynis | PASS (rc=0) — Lynis index 74; idempotency re-run all-skipped; delta report written |
| B7 | `rollback <snapshot> --force` (new flag) | PASS — 9 files restored, sshd restarted, access verified; interactive path intact |
| B7Δ | Lynis delta cycle: rollback→audit→re-harden→audit | **73 → 74 (+1)** in /root/vps-forge-report.txt (file-level rollback only moves config scoring — see limitations) |
| B6 | docker + docker_fw | PASS — Docker 29.8.2 official repo; daemon.json hardened; DOCKER-USER: established ACCEPT → bridge ACCEPT → DROP from ens3 → RETURN |
| B6e | External default-deny proof (curl from operator machine) | **PASS** — published port 18099 blocked (timeout) by default |
| B6e2 | docker-allow → external reachability | **PASS after fix** — conntrack ctorigdstport rule (see bug 9); external curl got busybox 404 |
| B6e3 | docker-deny + reboot persistence | PASS — deny re-blocks; after reboot DOCKER-USER rebuilt by boot unit, docker active, ssh fine |
| B8 | restic + `backup-test` | PASS — snapshot → restore → compare → "PASS: backup+restore verified end-to-end" |
| B9a | Coolify | PASS — precheck enforced admin_email; containers healthy; creds shown once + stored; DOCKER-USER opens exactly 8000/6001/6002 (+80/443); external :8000 → 302; daemon.json hardening survived installer rewrite; `panel-remove coolify` clean (0 containers, /data gone, rules removed) |
| B9b | CloudPanel | PASS after fix — install completed (2.5.4-3), external :8443 → 302; removal best-effort as documented |
| B9c | CyberPanel | in progress (installer's own 113MB dep download over slow link) |

### Bugs found & fixed during F (each re-tested)
7. **apt lock contention** — boot-time `apt-get update` (cloud-init/unattended) held the
   lists lock; installs failed. Fix: `vf_apt_wait_quiet` gate + `DPkg::Lock::Timeout=600`.
8. **config.env sourcing** — dotted keys (`wg.port=…`) are invalid bash; cfg_load_state
   `source`d the file → exit 127. Fix: manual parse + eval of %q values.
9. **docker-allow matched post-DNAT port** — allow rule used `--dport 18099` but
   DOCKER-USER sees packets after DNAT (container port) → allowed ports were still
   blocked. Fix: `-m conntrack --ctorigdstport` per Docker's packet-filtering docs.
   (Caught precisely because the external probe is REAL — the local check passed.)
10. **`declare -A` inside sourced module = function-local** — VF_NE_SHA vanished
    before mod_node_exporter_check ran → set -u silent death (stderr was redirected).
    Fix: `declare -gA` + comment.
11. **ERR-trap inside $( ) with set -E** — `grep '^warnings'` exit 1 (no warnings in
    lynis report) killed the whole run mid-lynis. Fix: `|| true` on report greps;
    sparse-array guards in summary/report (`${RUN_STATUS[$i]:-pending}`); trap now
    logs the real failing function (FUNCNAME[1]).
12. **our UMASK 027 hardening broke the CloudPanel installer** — its GPG keyring
    became unreadable by apt's _apt user → NO_PUBKEY. Fix: `umask 022` in vf_main_run
    (all vps-forge file writes set explicit modes).
13. **CyberPanel flags** — `-a default` made the installer print usage and exit 0
    (false success). Fix: official flags `-v ols -p r` + post-condition
    `[ -d /usr/local/CyberCP ]` before claiming success.
14. **SSH-kill of long runs** — nohup'd runs died with the SSH session. Fix: test
    helper switched to `systemd-run` transient units (no product-code change).
15. **rollback --force flag** — added for scripted use (skips both confirms with loud
    warning); flag parser now passes post-subcommand flags through.

| B9c final | CyberPanel | **PASS** — installed (lsws active, CyberCP present, creds shown once), installer's ufw removal detected → posture restored (8090 rate-limited open, 7080/ftp CLOSED — verified externally 8090=200, 7080=timeout); removal path exercised |
| B10 | `self-clean --scope=all` | PASS — panels removed, docker torn down, users/packages/timers/firewall removed, configs restored; final external state: ONLY ssh :22 listening; password + key login both verified from NEW connections |

### Bugs found & fixed during B9/B10 (each re-tested)
16. **self-clean missed later-run paths** — it only restored/removed entries from the
    FIRST snapshot's index; the sshd drop-in (created in a later run) survived.
    Fix: union across ALL snapshots — origs restored from the EARLIEST snapshot that
    has them, news removed from every snapshot. Also `cfg_load_state` before user
    removal (admin.username lives in the state dir it deletes later).
17. **CyberPanel installer removes ufw** — after install the host had NO firewall and
    lsws WebAdmin (:7080) + FTP were externally reachable. Fix: module reinstalls ufw
    and re-applies the posture (8090 rate-limited, 80/443, everything else closed).
18. **CloudPanel package prerm is broken upstream** (calls su on a nologin user —
    cloudpanel-io/cloudpanel-ce#87) — it blocks EVERY later apt transaction, including
    CyberPanel's pure-ftpd install. Fix: `panel-remove cloudpanel` neuter the
    maintainer scripts and force-purge; documented.
19. **CyberPanel precheck vs its own leftovers** — a failed install leaves lsws holding
    80/443/7080, and the fresh-server precheck then blocks any resume. Fix: precheck
    stops ITS OWN litespeed processes and resumes; foreign services still block.
20. **rollback --force + ui_confirm no-tty fallback** — scripted rollback support and
    ui_confirm no longer errors when /dev/tty is absent (falls back to the default).

### Final server state (after B10)
Ubuntu 24.04 (point release auto-upgraded to .5 by unattended-upgrades during tests);
only sshd :22 listening; zero vps-forge packages/users/units/firewall/Docker data;
operator access = root password (as configured by owner) + the zcode ed25519 key;
project deployed at /root/vps-forge with checksums.txt verified server-side.

## G. Interactive-path validation (2026-10-06/07) — after the owner's manual test failed

Context: owner reinstalled the server (fresh 24.04, zcode key) and ran the TUI by
hand; it failed with "all sorts of errors". The non-interactive suite never
exercises the gum prompt path, so the whole class was invisible to it. Reproduced
by driving the REAL interactive flow in a tmux session on the server
(`tmux send-keys` + `capture-pane`, ANSI-stripped) — a driver that types into the
same UI a human sees.

| # | Test | Result |
|---|------|--------|
| G1 | Reproduce owner's failure in tmux driver | **REPRODUCED** — `error: unknown profile: Chooseaprofile` + prompts rendering invisibly (runs hung) |
| G2 | Full Recommended profile, interactive, tmux-driven end to end | **PASS** — 17/18 ✓ (one transient aideinit failure: retried, then continue-prompt), summary + report written, Lynis 62 → 73 |
| G3 | Custom profile checklist (ui_multi: risk tags + preselections) | PASS — rendered correctly, selection edited, clean abort path intact |
| G4 | AIDE idempotency re-entry | PASS — "database already present — keeping existing baseline" |
| G5 | Reset for owner re-test | PASS — self-clean + deep clean; only sshd :22 remains, key + password both work |

### Bugs found & fixed during G (each re-tested)
21. **question-as-option in `gum choose`** — options are positional; the question
    text was passed as the FIRST option, so "Choose a profile" was selectable and
    picking it crashed with `unknown profile: Chooseaprofile`. Fix: question goes
    to `--header` (ui_choose + ui_multi).
22. **stderr suppression hid the entire UI** — gum renders its interface to STDERR
    when stdout is captured by command substitution; every prompt call had
    `2>/dev/null`, so choose/multi/confirm/input/password were invisible and runs
    hung. Fix: suppression removed on all gum prompt paths (kept for whiptail,
    which uses --stdout correctly).
23. **shared spin.log destroyed failure evidence + aideinit postinst race** — one
    global spin log meant a later spin overwrote an earlier failure's output
    (masked why aideinit died); aideinit also fails transiently right after
    install. Fix: per-call `mktemp` spin logs; aideinit retries once after 10s.

Fixed tree: shellcheck/shfmt/manifest gates pass, committed
(`fix(tui): gum interactive prompts`), pushed, CI green; re-mirrored to
/root/vps-forge and `sha256sum -c checksums.txt` verified server-side (an
earlier partial sync had left 2 deployed files diverging from checksums).

## H. README marketing GIF (2026-10-07/08) — re-record + the bugs the retake flushed out

Owner asked for a marketing-grade GIF of the workflow for the README hero
(custom-checklist cut chosen, replacing the old single-module demo).

| # | Test | Result |
|---|------|--------|
| H1 | Rehearse checklist key sequence in tmux driver | **PASS** — exact 11-module selection; pager + confirm verified |
| H2 | Take 1: single VHS tape, whole flow | **FAIL** — recording went black ~454s in (ttyd/page died → ssh HUP → run killed at module 8/11); no server-side OOM/disconnect trace. Restructured: run the TUI in a server-side tmux session, record two SHORT takes (A: intro→confirm; B: attach→y→apply→summary) stitched at the identical confirm screen |
| H3 | Take A + take B (tmux-attach architecture) | **PASS** — A parked at confirm; B: all 11 modules [ok], Lynis 63 → 71, summary HELD on screen (keep-alive wrapper — a bare `tmux new ./vps-forge` closes the pane, and the summary, the instant the run exits) |
| H4 | render-demo.sh: segment trims/speeds + palette + gifsicle | PASS — 42s, 1.4 MB, 1150×680 |
| H5 | Frame review (contact sheet + full-res) | PASS — story readable, risk tags + ✓s + delta legible at README width; NO IP/hostname-leak/password anywhere |

### Bugs found & fixed during H (each re-tested or proven live in the retake)
24. **minimal images ship without curl** — gum bootstrap failed → whole run
    silently degraded to plain UI. Fix: vf_ensure_gum apt-installs curl first.
25. **UI backend picked before the gum bootstrap** — ui_init only resolves
    VF_UI="auto"; the post-bootstrap re-detect was a no-op, so the FIRST run on
    a gum-less box stayed on whiptail/plain forever. Fix: reset to auto before
    re-detect.
26. **gum input prefill corrupts typed answers** — `--value` prefills and typed
    text APPENDS; with cfg defaults preloading `sys.timezone=auto`, typing
    "Asia/Dhaka" produced "autoAsia/Dhaka" (any user typing over a default hit
    this). Fix: `--placeholder` + empty-accepts-default; sentinel keys no
    longer preloaded; sysbase treats "" tz like auto.
27. **check.sh didn't gate checksums.txt freshness** — the curl fix initially
    shipped without regenerating it (caught server-side: 1 non-OK). Fix: gate
    added (tree hash vs checksums.txt).
28. **gum choose --no-limit toggle key is "x", not space** — space goes into
    the type-to-filter buffer and toggles nothing (cost the first rehearsal).
    Documented in the tape headers. (Upstream UX, not our bug.)
29. **self-clean needs its snapshots** — running it after deleting
    /var/backups/vps-forge silently degrades to pattern-only cleanup
    ("no first snapshot found"). Operator error, documented here; the final
    reset below was run WITH snapshots intact.

Final server state after H: self-clean --scope=all (snapshots intact) + manual
residue purge; only sshd :22 listening; /root/vps-forge re-synced + checksums
verified; recording alias removed. GIF pipeline committed: demo-predrive.sh +
demo-a.tape + demo-b.tape + render-demo.sh (masters gitignored).

## I. Public-launch fix (2026-10-08) — real user hit both failure modes

Owner ran the public quickstart on a fresh box:
`curl -fsSL <raw>/install.sh | sudo bash` →
`sudo: unable to resolve host Vpsforge.example.com` +
`/usr/bin/bash: /usr/bin/bash: cannot execute binary file`.

| # | Test | Result |
|---|------|--------|
| I1 | Reproduce on test server (fresh reinstall, password auth, key re-injected) | **REPRODUCED** — both messages exact; line 12 of old install.sh identified |
| I2 | Pipe path with fixed install.sh (`cat install.sh \| bash -s -- --version` under `script` pty) | **PASS** — downloads all files, checksums OK, tty-handed `exec vps-forge --version` → "Vps Forge 1.0.0", rc=0 |
| I3 | sysbase hosts repair on the live unresolvable box | **PASS** — 127.0.1.1 line added, `getent hosts` resolves, `sudo -n true` silent (exit 0) |
| I4 | Idempotency re-run | PASS — "• skipped"; repair logged exactly once |

### Bugs found & fixed during I
30. **pipe install was fatal** — when piped, `$0` IS the bash binary; the
    stdin re-exec `exec bash "$0" </dev/tty` tried to run the ELF as a script
    ("cannot execute binary file"). Re-reading stdin is impossible anyway
    (bash has consumed the pipe buffer). Fix: no stdin re-exec (the installer
    never prompts); attach /dev/tty to the FINAL vps-forge exec instead.
31. **unresolvable hostname left sudo warning forever** — provider images set
    the hostname without an /etc/hosts entry; every sudo prints "unable to
    resolve host". Fix: sysbase maps the hostname to 127.0.1.1 (Debian
    convention) when unresolvable; module check now also requires resolution
    so later runs repair it.

Note: raw.githubusercontent CDN edges lag on commit by minutes (the BD edge
served the previous commit while my local edge had the new one) — verified
the fix via the deployed copy, and the public raw URLs once the edge caught
up (both confirmed VF_REEXEC-free).

## J. Real 29-module custom run on the public quickstart (2026-10-08, owner's terminal)

The owner ran the public `curl | bash` quickstart on the fresh box and drove a
full Custom profile (29 modules incl. zram, tmpfs, TOTP, Docker, CyberPanel).
Result: modules 1–8 ✓, then **21 consecutive ✗** — every one with
`mod-X.log: No such file or directory`. The pipe install itself now worked
(round I).

| # | Test | Result |
|---|------|--------|
| J1 | Reproduce (single run: `--module=tmpfs,services` after unmounting /tmp) | **REPRODUCED** — rc=1, ENOENT cascade; even the shell's own `> /tmp/x.log` redirect was shadowed by the mid-run mount |
| J2 | Same scenario with the fix (scratch dir in /run) | **PASS** — rc=0, tmpfs ✓, follow-module clean |
| J3 | Reset after the broken half-run | PASS — self-clean + zram stop + /tmp unmount + swapfile removal + reboot; only sshd :22, /tmp on disk, checksums 0 non-OK |

### Bugs found & fixed during J
32. **tmpfs module shadowed the run's scratch dir** — `mktemp -d
    /tmp/vps-forge.XXX` lives under the very mount the tmpfs module creates
    mid-run; every later module's `2>> $VF_TMP_DIR/mod-X.log` redirection then
    hits a missing path → exit-1 cascade. Isolation testing can't catch this
    (each module = its own invocation = fresh scratch); only tmpfs + later
    modules in ONE run triggers it. Fix: scratch dir in **/run** (tmpfs
    anyway, never shadowed by our own modules) + runner self-heals the dir
    before each module + the tmpfs module now warns that existing /tmp files
    become hidden until reboot.

Note: the module-failure continue-prompts DID render during the owner's run —
gum widgets draw and erase in place, so they leave no trace in terminal
scrollback (they look absent in pastes; the user answered them).
