---
name: Bug report
about: Something broke or behaved unexpectedly
title: "[bug] "
labels: bug
assignees: ""
---

**Before you start**

- [ ] I ran this on a disposable/rebuildable server (or I know how to recover)
- [ ] I redacted IPs, hostnames and credentials below

**Environment**

- Ubuntu version: (22.04 / 24.04 / other)
- Provider: (Hetzner / DO / Vultr / ...)
- vps-forge version or commit: (`./vps-forge --version` or `git rev-parse --short HEAD`)
- Run mode: interactive TUI / `--yes --profile=... --config=...` / `--module=...`

**What happened?**

A clear description. What did you expect to happen instead?

**Steps to reproduce**

1. Run: `...`
2. Choose: `...`
3. See error

**Relevant output**

```
tail -50 /var/log/vps-forge.log   # redact as needed
```

And if it's a UI problem, the review screen text from the plan.

**Still standing?**

Did you confirm your server is still reachable from a NEW ssh session?
(vps-forge auto-revert guards may still be armed — check `vps-forge status`.)
