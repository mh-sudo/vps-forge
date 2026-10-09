# DECISIONS.md — design rationale, research citations, and incident log

Format: decision → why → sources. Research verified 2026-10 against official docs.

## D1. Firewall strategy for Docker: DOCKER-USER chain + loader (chosen)

**Options compared:**

1. **ufw-docker (chaifeng/ufw-docker)** — appends an `# BEGIN UFW AND DOCKER` block to
   `/etc/ufw/after.rules` that jumps DOCKER-USER into `ufw-user-forward`, so you manage
   container access with `ufw route allow … container_ip:port`. Pros: `ufw route` UX;
   recommended by Docker's *older* docs and by Coolify's docs. Cons: rules target
   container IPs (break when containers are recreated — Coolify's own docs warn about
   this); requires `ufw-docker reload` after IP changes; IPv6 is "experimental" in the
   project README; Docker's current docs no longer recommend it.
   https://github.com/chaifeng/ufw-docker · https://coolify.io/docs/core/infrastructure/servers/firewall
2. **nftables-native + Docker's nftables backend** — Docker 29+ ships an experimental,
   opt-in nftables backend (`firewall-backend: nftables`); raw nftables rulesets are
   only supported with that backend (no DOCKER-USER; separate tables instead). Not
   production-robust on 22.04/24.04 where the iptables backend is the mature path.
   https://docs.docker.com/engine/network/firewall-nftables
3. **DOCKER-USER chain managed by our own idempotent loader (CHOSEN)** — host ports are
   what an operator thinks in ("allow 8080/tcp"), not container IPs that churn; rules
   survive `systemctl restart docker` (moby explicitly never deletes/modifies
   pre-existing DOCKER-USER rules — verified in `libnetwork/firewall_linux.go`,
   moby v28.4.0) and are rebuilt at every docker start via a `docker.service.d`
   `ExecStartPost=` hook + a boot reconcile unit; works identically under iptables-nft
   (Ubuntu default since 20.10) and iptables-legacy; IPv4 + IPv6 chains managed.

**Layered default-deny for published ports:** (a) `daemon.json "ip": "127.0.0.1"` makes
naive `-p 8080:80` binds loopback-only — note this covers the *default bridge* per
Docker's port-publishing docs, user-defined networks can override per-network; (b)
DOCKER-USER drops all unsolicited external traffic to published ports regardless of
bind address; (c) `iptables` stays `true` — Docker's docs: setting it false "is not
appropriate for most users" and breaks masquerading/isolation.
https://docs.docker.com/engine/network/packet-filtering-firewalls/ ·
https://docs.docker.com/engine/network/firewall-iptables/ ·
https://docs.docker.com/engine/network/port-publishing/

Note: Docker restructured its firewall docs in late 2025 — the DOCKER-USER material now
lives at /engine/network/firewall-iptables (old /engine/network/iptables/ 404s).

## D2. sshd hardening values

- Crypto lists are **filtered at apply time against `ssh -Q kex/cipher/mac`** on the
  target server (sntrup761x25519 + curve25519 + dh-group16 preferred, falling back to
  what's available). Rationale: hardcoding broke on Ubuntu 24.04's OpenSSH 9.6 which
  removed the `curve25519-sha256@libssh.com` alias (found in testing, see TESTING.md).
- Mozilla Infosec guidelines (curve25519-first, chacha20/aes-gcm ciphers, etm MACs,
  `AuthenticationMethods publickey,keyboard-interactive:pam` for MFA) informed the sets:
  https://infosec.mozilla.org/guidelines/openssh.html (page is 2017-era; we go stricter
  where OpenSSH ≥8.9 allows).
- CIS values for MaxAuthTries 4 / LoginGraceTime 60 verified via the rule-for-rule
  community implementation: https://github.com/ansible-lockdown/UBUNTU24-CIS.
- Drop-in at `/etc/ssh/sshd_config.d/00-vps-forge.conf` — `00-` sorts before cloud-init's
  `50-cloud-init.conf`, and sshd applies the FIRST obtained value, so we win without
  editing the main file.
- `AllowTcpForwarding no` default (CIS) — configurable.

## D3. fail2ban (not CrowdSec)

fail2ban chosen: in Ubuntu main/universe repos, trivially configured, no account/registration.
CrowdSec requires an account for blocklists and brings an agent + LAPI surface — deferred
as a future module. On 24.04 Ubuntu's package already defaults `banaction=nftables`,
`backend=systemd` (verified from `fail2ban_1.0.2-3.debian.tar.xz`); we set both explicitly
anyway. On 22.04 (0.11.2) the default banaction is `iptables-multiport`; we set
`nftables-multiport` for consistency. `jail.d/vps-forge.local`, sshd jail only.

## D4. Kernel/sysctl values (CIS-informed, Docker-safe)

- `ip_forward` is deliberately NOT written: CIS wants 0, Docker requires 1 and enables it
  itself (https://docs.docker.com/network/packet-filtering-firewalls/).
- `rp_filter=1` (CIS strict; Ubuntu default is 2/loose). No Docker conflict documented;
  Docker makes no rp_filter statement (verified — term absent from their docs).
- `kptr_restrict=2`, `dmesg_restrict=1`: NOT Ubuntu-CIS items (they are RHEL-CIS items —
  verified by 0 hits in ansible-lockdown UBUNTU22/24-CIS) but sound hardening; kept,
  documented as beyond-CIS.
- `kernel.apparmor_restrict_unprivileged_userns=1` is a 24.04 default and only affects
  rootless Docker (we install standard docker-ce) — left untouched.
- `squashfs`/`vfat` deliberately NOT blacklisted (snap + UEFI need them); CIS-blacklisted
  cramfs/freevxfs/jffs2/hfs/hfsplus/udf are.
- auditd baseline is the CIS event subset (identity/logins/time/locale/mounts/sysctl/
  MAC-policy/modules) — full CIS adds per-binary privileged-command enumeration; we skip
  `-e 2` (immutable rules) to keep rollback/iteration possible. Documented trade-off.

## D5. Panels

- **Requirements pre-checked and enforced** (ports free, RAM/CPU/disk, snap-docker,
  fresh-server checks for CloudPanel). Ports opened: ONLY what each panel needs.
- **Coolify**: official env-driven installer (ROOT_USERNAME/EMAIL/PASSWORD pre-creates
  the admin — closes the first-registration bot race); 22/80/443/8000/6001/6002
  (6001+6002 verified from docker-compose.prod.yml; close 8000/6001/6002 once a domain
  fronts the panel per Coolify's firewall docs); data in /data/coolify; documented
  uninstall implemented. Coolify's installer rewrites daemon.json (address pools) — we
  re-merge our hardening keys afterwards and restart Docker once.
- **CloudPanel**: official installer (installer.cloudpanel.io/ce/v2/install.sh),
  DB_ENGINE per OS release (MYSQL_8.4 on 24.04, MYSQL_8.0 on 22.04); installer's sha256
  recorded per install and pinnable via cfg (`cloudpanel.sha256`) — the upstream rotates
  the script, so a hard-coded default would rot; admin is created in the browser (the
  installer prints nothing) — we tell the user to do it IMMEDIATELY (bot race). No
  official uninstaller exists — `panel-remove cloudpanel` is best-effort (documented).
- **CyberPanel**: LOUD warning citing the real CVE history: CVE-2024-51567/51568/51378
  (CVSS 10.0, CISA KEV, PSAUX ransomware ≈22k servers, Oct–Dec 2024) and 2026 CVEs
  (CVE-2026-67614 hard-coded JWT secret, CVE-2026-88895 API-2FA bypass, …).
  Non-interactive install via the official installer's flags (`-v ols -p r -a default`,
  root-only), admin password captured/generated + shown once, UFW opens ONLY
  8090 (rate-limited) + 80/443 — FTP/mail/DNS/7080 stay closed; hardening checklist
  printed. Note: the CVE-2024-46113 ID circulating in some writeups does not exist in
  NVD — the real set is above.
- Panel modules auto-drop the reverse-proxy module (port conflict) and Coolify
  auto-includes docker+docker-fw.

## D6. Monitoring: node_exporter (not Netdata)

Pinned release (v1.12.1, sha256-pinned per arch), loopback-only listener
(127.0.0.1:9100) — zero new attack surface; expose via SSH tunnel/reverse proxy/
Tailscale. Netdata's kickstart isn't checksum-verifiable; left as a future module.

## D7. Backups: restic (apt) + systemd timer

Local/s3/sftp/rest targets, generated repository password (0600 creds dir), daily timer
02:30 + prune policy, `vps-forge backup-test` proves snapshot→restore→compare.
apt restic (3.0.x-era on 24.04) is old but stable; documented.

## D8. gum bootstrap

gum v2.0.2 .deb from GitHub releases, sha256 pinned for amd64/arm64 (values in
`vps-forge`), installed via apt; any mismatch/download failure falls back to whiptail,
then plain stdout. gum v2's flag surface was live-verified (choose --no-limit/--selected,
input --value/--header/--password, confirm, spin, style — all present in v2.0.2).

## D9. Guard semantics after the 2026-10-02 lockout incident (see TESTING.md §A)

Root causes fixed:
1. Non-interactive runs used to auto-cancel the sshd guard after internal validation
   only → an unverified `PermitRootLogin prohibit-password` stayed applied and locked
   out password-based operators. **Now:** non-interactive NEVER auto-confirms fail-closed
   changes (sshd/port/TOTP) — the guard stays armed and auto-reverts unless the operator
   verifies externally and runs `vps-forge guard-cancel sshd`. Fail-open changes (ufw
   enable, whose lockout risk is pre-mitigated by allowing SSH ports first) pass
   `failopen` and still auto-confirm.
2. `PermitRootLogin` used to downgrade to `prohibit-password` unconditionally. **Now:**
   it only restricts when an authorized root key already exists (or a verified admin
   key), otherwise it keeps the current server value and says so in the plan.

## D10. Small calls

- Locale default `en_US.UTF-8`; timezone default = keep current (auto).
- Swap sizing: ≤2 GB RAM → 2 GB; 2–8 GB → min(RAM, 4 GB); >8 GB → 4 GB.
- journald cap 200M, keep-free 500M, 1-month retention.
- `unattended-upgrades`: security origin only; `Automatic-Reboot` off by default
  (cfg `ua.auto_reboot`), `Remove-Unused-Dependencies true`, weekly autoclean.
- AIDE baselines the post-hardening state (re-run `aideinit` after panel installs);
  rkhunter `--propupd` baseline to avoid first-scan false positives.
- APT repos (docker/caddy/tailscale/cloudflared/nodesource) are GPG-verified;
  binary downloads (gum, node_exporter) are sha256-pinned. No third-party scripts are
  piped to bash except the panel installers themselves (their whole point), with
  CloudPanel's installer additionally checksum-recorded/pinnable.
- `--config` files are a flat `key: value` subset of YAML (documented as such).
- TOTP is opt-in with explicit warnings + `totp.confirmed` required in non-interactive
  mode; scratch codes saved once.

## D11. External-audit remediation calls (2026-10-09)

1. **Destruction requires provenance.** self-clean / panel-remove / rollback
   only remove what vps-forge actually created: packages recorded as
   *installed-by-us* (missing-only snapshot records), users recorded at
   creation (`created-users.txt`), Docker data only with `applied/docker.done`,
   the credentials dir only with its creation marker. Panel removals purge the
   panel's OWN packages (cloudpanel*, openlitespeed/lsphp) and NEVER shared
   stacks (nginx*/php*/mysql*), never `/var/www`, never site dirs
   (`/home/clp`). Cost: self-clean on an old install (no records) leaves more
   behind, with instructions — that is the safe direction.
2. **Typed confirms.** `self-clean` requires typing `self-clean`; CLI
   `panel-remove` requires typing the panel name; `--yes`/`--yes-clean`
   bypass deliberately for scripted use.
3. **Module failure semantics.** Modules run inside `( set -Eeuo pipefail )`
   subshells: an unexpected failing command now FAILS the module (it used to
   be swallowed by the runner's `if` context). Exit-code contract: 0 = applied,
   **2 = user declined** (recorded as a skip, never "applied"), other = failure.
   Legitimately-failing probes are guarded explicitly (`|| true` / `|| warn`).
4. **fail-open confirmations must prove themselves.** The non-interactive ufw
   auto-confirm now requires the SSH port to be visible in `ufw status` first;
   guard-cancel reports an already-fired timer as a failure and sshd/ufw/totp
   re-validate the live state before recording success.
5. **TOTP scoping.** TOTP applies ONLY to enrolled users via `Match User` in
   its own `20-vps-forge-totp.conf` sshd drop-in (global AuthenticationMethods
   locked key-only accounts like deploy out). Secrets go to the PAM default
   `~/.google_authenticator` (the old `~/.ssh/` path was never read by PAM).
6. **DOCKER-USER atomicity.** The chain is rebuilt in one `iptables-restore`
   transaction (no unfiltered window between flush and rebuild). DROP targets
   every non-internal interface (docker bridges + tunnel ifaces exempt) —
   covering multi-NIC boxes while keeping tailnet→container access working.
7. **Installer pins by ref.** install.sh accepts `--ref=<tag>`/VF_REF and
   defaults to `main` until the v0.2.0 release, at which point the default
   flips to the tag (release process, P10).
8. **Version scheme.** VF_VERSION tracks the next RELEASE tag (0.2.0); the
   v0.1.0 tag predates the version string and is superseded by v0.2.0.
9. **Personal test helpers left the public repo** (vnc_*.py, trun/tssh/tscp):
   they take passwords as argv and auto-accept host keys — maintainer-local
   only now. `scripts/check.sh` + `make-checksums.sh` stay (CI uses them).
