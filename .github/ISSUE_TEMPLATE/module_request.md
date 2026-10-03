---
name: Module request
about: Request a new feature module for the manifest
title: "[module] "
labels: enhancement, module-request
assignees: ""
---

**Module name**

`<kebab-case-id>` — will become `modules/<nn>-<name>.sh` and a manifest entry.

**What it does**

One paragraph. What state does it bring the server to?

**Why it belongs in vps-forge**

Who needs it, and why isn't the existing modules + a plain apt install enough?

**Sources for current best practice**

vps-forge does not rely on memory for version-sensitive things. Link the
official docs you'd expect the module to follow (install method, ports,
system requirements).

**Risk assessment**

What can this module break? Does it touch sshd, the firewall, users or PAM?
Does it conflict with another module or panel?

**Profile fit**

minimal / recommended / dockerhost / custom — where should it default on?
