<div align="center">

# vps-forge

**Turn a brand-new Ubuntu VPS into a secure, fast, production-ready server in minutes.**
An interactive terminal installer for people who don't want to learn 40 hardening guides first.

[![ShellCheck](https://github.com/mh-sudo/vps-forge/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/mh-sudo/vps-forge/actions/workflows/shellcheck.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Ubuntu](https://img.shields.io/badge/Ubuntu-22.04%20%7C%2024.04-E95420?logo=ubuntu&logoColor=white)](#requirements)
[![Pure Bash](https://img.shields.io/badge/pure-Bash-4EAA25?logo=gnubash&logoColor=white)](#how-it-works)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-ff69b4.svg)](CONTRIBUTING.md)

```bash
curl -fsSL https://raw.githubusercontent.com/mh-sudo/vps-forge/main/install.sh | sudo bash
```

<img src="docs/assets/demo.gif" alt="vps-forge in action: preflight on a fresh Ubuntu VM, picking modules from the risk-tagged checklist, reviewing every change, applying 11 modules with green checks, and a final summary with the Lynis hardening index rising 63 → 71" width="720">
<!-- Re-record: see the header of docs/assets/demo-a.tape (3-take flow + render-demo.sh) -->
<!-- (a real run on a disposable VM: 11 low-risk modules, honest Lynis numbers) -->

</div>

---

## What is vps-forge?

vps-forge is a free, open-source, pure-Bash terminal UI that provisions a fresh **Ubuntu 22.04 or 24.04 VPS** to a production-ready state. It creates a safe admin user, hardens SSH, sets up a firewall that actually works with Docker, installs Fail2ban and automatic security updates, tunes the kernel and memory, installs Docker, and can deploy a self-hosting panel like Coolify or CloudPanel.

You pick a profile, review exactly what will change, confirm, and it does the rest. Every change is backed up first, and anything that could lock you out has an automatic rollback timer.

It works on any provider that gives you Ubuntu and root: Hetzner, DigitalOcean, Vultr, Linode, OVH, Contabo, AWS Lightsail, and the rest.

## Who it's for

- You just bought a VPS to host an app, a bot, an API, an AI agent, or a side project, and you don't know what to do after the first login.
- You've been told to "secure your server" and don't know where to start.
- You use Docker and want published ports to be private by default.
- You're comfortable on the command line and are tired of pasting the same 200 lines into every new box.

## Why people lose servers (and what vps-forge does about it)

Most "how to secure a VPS" guides fail beginners in the same few places.

| Common failure | What vps-forge does |
|---|---|
| Changing the SSH port or disabling passwords and getting locked out | Validates with `sshd -t`, applies changes behind a timed auto-revert, and makes you confirm from a **new session** before the timer is cancelled |
| Turning on UFW before allowing SSH | Refuses. The active SSH port is allowed first, always |
| Disabling password login with no working key | Refuses until a key for the target user is verified |
| Docker ports ignoring UFW, so "denied" ports are open to the internet | Uses the `DOCKER-USER` chain so published container ports are **closed by default** until you allow them |
| Breaking something and not knowing what changed | Every touched file is backed up to `/var/backups/vps-forge/<timestamp>/`, and `vps-forge rollback` restores it |
| Not knowing if it worked | Runs a Lynis audit before and after and shows the score difference |

## Quick start

Run this on a fresh server as root, or with sudo:

```bash
curl -fsSL https://raw.githubusercontent.com/mh-sudo/vps-forge/main/install.sh | sudo bash
```

The entrypoint is tiny. It downloads the main script, verifies its checksum, and runs it.

**Prefer to read it first?** Good habit.

```bash
git clone https://github.com/mh-sudo/vps-forge.git
cd vps-forge
less install.sh          # the whole entrypoint
sudo ./vps-forge
```

**Keep a second SSH session open the entire time.** vps-forge will remind you, but it's the best safety net you have.

## What you'll see

1. **Preflight.** OS, RAM, disk, virtualization, current SSH user and port, detected provider, and the existing firewall state.
2. **Profile.** Minimal, Recommended, Docker-Host, or Custom with a checklist. Each item has a one-line description and a risk tag.
3. **Review.** A dry-run diff of exactly what will change, then an explicit confirm.
4. **Apply.** Live progress per module with ✓ / ✗ / skipped.
5. **Report.** A summary saved to `/root/vps-forge-report.txt`, the Lynis score delta, and a reboot recommendation only if one is needed.

It's built for an 80-column terminal, handles Ctrl+C safely, and uses one accent color. No ASCII-art banner.

## Profiles

| Profile | Good for | Includes |
|---|---|---|
| **Minimal** | Anyone, first run | Base tooling, SSH hardening, UFW, unattended security upgrades |
| **Recommended** | Most single-app servers | Minimal, plus sysctl hardening, swap, chrony time sync, BBR, journald limits, admin user, Fail2ban, PAM hardening, auditd, AppArmor, AIDE, rkhunter, health checks |
| **Docker-Host** | Containers and self-hosting | Recommended, plus Docker Engine and Compose from Docker's official apt repo, a hardened `daemon.json`, and the Docker-safe firewall |
| **Custom** | You | Pick any modules from the checklist |

## Features

<details open>
<summary><b>Security hardening</b></summary>

- New sudo admin user with an ed25519 SSH key, optional root login disable
- `sshd_config.d` drop-in (your main config is never edited) with modern ciphers, KEX and MACs, `MaxAuthTries`, `LoginGraceTime`, `AllowUsers`, and a custom port option
- UFW with default-deny incoming, rate-limited SSH, and consistent IPv6 handling
- Fail2ban with an sshd jail (CrowdSec may be added as an alternative module)
- Unattended security upgrades with a reboot policy
- Kernel and sysctl hardening that doesn't break Docker or networking
- PAM faillock, password policy, sane umask, unused services and filesystems disabled
- AppArmor enforcing, auditd baseline rules, AIDE file integrity monitoring, rkhunter and Lynis
- Optional TOTP 2FA for SSH with a lockout-safe flow and a backup-codes warning

</details>

<details>
<summary><b>Server optimization</b></summary>

- Timezone, locale, chrony NTP, hostname
- Swap file sized to your RAM, `vm.swappiness`, optional zram
- File descriptor limits, TCP BBR, journald size limits, logrotate
- Optional `/tmp` on tmpfs, disk TRIM
- Base tools: curl, git, htop, ncdu, jq and friends

</details>

<details>
<summary><b>Production readiness</b></summary>

- Docker Engine and Compose plugin (official apt repo, never the snap)
- Caddy or Nginx reverse proxy with automatic TLS
- node_exporter for Prometheus (loopback-only by default), a health script, and disk/RAM alerts by email or webhook
- Scheduled restic backups to S3, SFTP, REST or a local target, with a built-in restore test
- Tailscale, WireGuard, or Cloudflare Tunnel for private admin access
- Deploy user, Node.js and Python runtimes

</details>

<details>
<summary><b>One-click panels (pick one)</b></summary>

- **Coolify**, **CloudPanel**, **CyberPanel**
- Requirements are pre-checked (OS, RAM, ports, conflicts with Docker, UFW, Nginx) and the install is blocked with a clear message if they aren't met
- Only the ports the panel needs get opened, an admin password is generated and shown once, and the final access URL is printed

> [!WARNING]
> **CyberPanel has a history of serious security vulnerabilities**, and real servers have been compromised through them. If you pick it, vps-forge shows a visible warning and an extra hardening checklist. If you have a choice, consider Coolify or CloudPanel instead.

</details>

## The Docker + UFW problem, fixed

This is the one that quietly bites people.

When you publish a container port (`-p 8080:80`), Docker adds its own iptables rules that run **before** UFW's. So `ufw deny 8080` does nothing, and your "private" database or admin tool is open to the whole internet. Docker's own documentation describes this behavior.

vps-forge handles it with the supported approach: custom filtering in the `DOCKER-USER` chain, which Docker evaluates before its own rules.

- Published container ports are **not reachable from outside** by default
- Established traffic and traffic between containers on Docker networks keep working
- `daemon.json` sets the default published-port bind address to `127.0.0.1`, keeps Docker's iptables management on, and survives Docker restarts and reboots
- IPv6 is covered, and rules persist across reboots

Open a port on purpose:

```bash
vps-forge docker-allow 8080/tcp
vps-forge docker-allow 5432/tcp my-postgres-container
```

Don't take our word for it, prove it:

```bash
vps-forge verify-firewall
```

This starts a throwaway container with a published port, shows from the outside that it's blocked, opens it, shows it's reachable, and cleans up after itself.

The reasoning behind the chosen strategy, and the alternatives we compared, are in [`DECISIONS.md`](DECISIONS.md).

## Commands

```bash
sudo ./vps-forge                         # interactive TUI
sudo ./vps-forge --dry-run               # show what would change, touch nothing
sudo ./vps-forge --verbose               # detailed output
sudo ./vps-forge --help

vps-forge rollback                       # restore the most recent backup set
vps-forge rollback <snapshot> --force    # scripted rollback, skips prompts
vps-forge docker-allow <port>/<proto> [container]
vps-forge verify-firewall                # prove Docker ports are private by default
vps-forge backup-test                    # prove backups restore
vps-forge status                         # snapshots, guards, applied modules
```

### Non-interactive mode

For automation, cloud-init, or when there's no TTY:

```bash
sudo ./vps-forge --yes --profile=recommended --config=forge.yaml
# pick specific modules instead of a profile:
sudo ./vps-forge --yes --module=sshd,ufw,fail2ban,docker,docker_fw --config=forge.yaml
```

```yaml
# forge.yaml (flat "key: value" config; see examples/test-config.yaml)
sys.timezone: UTC
admin.username: deploy
admin.pubkey: ssh-ed25519 AAAA... you@example.com
admin.disable_root_login: false
ssh.port: 2222
fw.open_ports: 80,443
docker.bind_ip: 127.0.0.1
backup.target: none
panel: none
```

## How it works

- **Pure Bash.** `set -Eeuo pipefail`, an ERR trap, ShellCheck-clean, no runtime to install.
- **TUI.** Uses [`gum`](https://github.com/charmbracelet/gum) (auto-installed and checksum-verified), with `whiptail` as a fallback.
- **Modular.** `lib/` holds shared helpers, `modules/` holds one self-contained file per feature, and a single manifest registers them.
- **Idempotent.** Every module is safe to re-run.
- **Logged.** Structured logs go to `/var/log/vps-forge.log`.

```
vps-forge/
├── install.sh              # tiny verified entrypoint
├── vps-forge               # main script
├── checksums.txt           # sha256 for every shipped file
├── lib/                    # config, TUI, safety layer (snapshots + guards), preflight, runner
├── modules/                # one file per feature
│   └── manifest.conf       # the single place modules are registered
├── examples/               # non-interactive config example
├── DECISIONS.md            # design rationale + research citations
├── TESTING.md              # the full test log
└── README.md
```

### Add your own module

1. Create `modules/my-feature.sh` with the standard module functions (`mod_<id>_plan/_check/_run`, optional `_ask`).
2. Register it in `modules/manifest.conf`.
3. Open a PR. See [CONTRIBUTING.md](CONTRIBUTING.md).

## Requirements

- Ubuntu **22.04** or **24.04** LTS, fresh install recommended
- Root, or a user with sudo
- Internet access
- 1 GB RAM minimum for the basics (panels need more, and vps-forge checks before installing)

## Threat model

**vps-forge helps defend against:** automated SSH brute-forcing, exposed container ports, weak default SSH and kernel settings, unpatched packages, and misconfiguration lockouts.

**It does not replace:** application security, secrets management, a proper backup strategy you've tested, or monitoring someone actually looks at. A hardened server running a vulnerable app is still a vulnerable app.

**Trust:** you're running a script as root, so read it. The installer verifies checksums, and the source is short and modular on purpose.

## FAQ

**How do I secure a new Ubuntu VPS?**
At minimum: create a non-root sudo user, use SSH keys and disable password login, enable a default-deny firewall, install Fail2ban, and turn on automatic security updates. vps-forge's Minimal profile does all of that, with lockout protection.

**Does `ufw deny` protect Docker containers?**
No. Docker publishes ports through iptables rules that are processed before UFW's, so UFW rules don't block them. The supported fix is filtering in the `DOCKER-USER` chain, which vps-forge configures for you.

**Will vps-forge lock me out of my server?**
It's designed not to. SSH and firewall changes are validated, applied with an automatic rollback timer, and only kept after you confirm from a new connection. It also refuses to disable password login without a verified key. Your provider's web console is the last-resort recovery path, and vps-forge tells you how to reach it.

**Can I undo what it did?**
Yes. Every file it touches is backed up first, and `vps-forge rollback` restores them. `vps-forge self-clean` removes everything vps-forge applied.

**Is it safe to run on a server that already has stuff on it?**
A fresh VPS is the intended target. On an existing server, use `--dry-run` first and read the review screen carefully.

**Does it work on Debian, AlmaLinux, or Rocky?**
Not yet. Ubuntu 22.04 and 24.04 only for now.

**Which VPS providers work?**
Any that give you Ubuntu with root or sudo access.

**vps-forge or Ansible?**
Ansible is great if you manage many servers and want to write playbooks. vps-forge is for one or a few servers, guided, with no setup and no YAML to learn first. They solve different problems.

**vps-forge or a hosting panel?**
Panels manage apps. vps-forge secures and prepares the server underneath, and can install a panel for you afterward.

**Can I use it in cloud-init or CI?**
Yes, via `--yes --profile=... --config=...`.

## Status

vps-forge is **beta**. Live-tested end to end on Ubuntu 24.04 (2 vCPU / 2 GB KVM: module runs, full profiles, idempotency re-runs, lockout failsafes, Docker firewall proofs, all three panels, rollback and self-clean); 22.04 is supported in code but not yet live-tested. The full log is in [TESTING.md](TESTING.md). Please read the review screen before confirming, and open an issue if anything surprises you.

## Development

```bash
shellcheck -S warning vps-forge install.sh lib/*.sh modules/*.sh
shfmt -d -ln bash vps-forge install.sh lib/*.sh modules/*.sh
./scripts/check.sh      # manifest <-> module functions <-> install.sh cross-checks
```

CI runs the same gates on every push. See [CONTRIBUTING.md](CONTRIBUTING.md) for module conventions and the test protocol.

## Security

Found a vulnerability? Please don't open a public issue. See [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE)

---

<div align="center">

If vps-forge saved you an afternoon (or a server), a ⭐ helps other beginners find it.

</div>
