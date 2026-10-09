# Security Policy

Vps Forge runs as root on servers, so security reports matter.

## Reporting a vulnerability

**Please do not open a public issue for security problems.**

Use GitHub's private security advisories:
**Security → Advisories → New draft security advisory** on this repository
(<https://github.com/mh-sudo/vps-forge/security/advisories/new>).

Include:

- affected version (commit SHA or release tag),
- the module or file involved,
- a minimal reproduction (a disposable VM, please — never a production box),
- your assessment of impact.

You'll get an acknowledgement within 72 hours and a status update at least
weekly until it's resolved. Fixes land in a patch release, and you'll be
credited (or stay anonymous, your choice) in the release notes.

Note on integrity: release downloads are pinned to a git tag and verified
against the repo's `checksums.txt` from the same origin. Publishing signed
checksums is planned; until then treat the GitHub-hosted tag as the root of
trust and re-verify the tag's commit SHA out-of-band if your threat model
includes hoster compromise.

## Scope

In scope: anything that makes Vps Forge weaken a server it runs on — command
injection via config values, lockout regressions, checksum-verification bypasses,
firewall rules that silently fail open, secrets the tool writes to disk.

Out of scope: vulnerabilities in the panels and third-party software vps-forge
*installs* (report those upstream — CyberPanel/Coolify/CloudPanel each have
their own channels), and reports from automated scanners without a working
proof.

## Supported versions

Only the latest release receives security fixes. Vps Forge is beta software:
run it on disposable or rebuildable servers and keep provider console access
handy.
