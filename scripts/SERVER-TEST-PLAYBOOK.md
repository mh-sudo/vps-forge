# SERVER-TEST-PLAYBOOK — exact resume steps once access is restored

Precondition: user fixed sshd via console (or reinstalled OS 24.04).
Every risky phase keeps a second session open: `./scripts/tssh.sh 'sleep 1800' &` (background task).

## B0 — redeploy + baseline
```
./scripts/tscp.sh /root/vps-forge
./scripts/tssh.sh 'cd /root/vps-forge && ./scripts/check.sh 2>/dev/null || bash vps-forge status; ufw status | head -1; ls /etc/ssh/sshd_config.d/'
```
If server was REINSTALLED: expect clean state (ufw inactive, only cloud-init drop-ins).
If only console-fixed: leftover state from A-tests may exist (snapshots, gum, /var/lib/vps-forge);
that is fine — tests continue on top; the final self-clean uses the FIRST snapshot.

Generate the test admin keypair (once, local):
```
ssh-keygen -t ed25519 -N '' -f ~/.ssh/vf_test_admin -C vf-test-admin
```
Write /root/vps-forge/test-config.yaml on the server (via tssh heredoc):
```
admin.username: forge
admin.pubkey: <contents of ~/.ssh/vf_test_admin.pub>
ssh.port: keep
sys.timezone: UTC
backup.target: none
```

## B1 — module isolation (non-interactive, keep-going)
For each: `./scripts/tssh.sh 'cd /root/vps-forge && bash vps-forge --yes --no-lynis --keep-going --module=<id> --config=/root/vps-forge/test-config.yaml'`
Order: essentials sysbase swap journald trim sysctl perf unattended pam services
apparmor_auditd fail2ban aide rkhunter health node_exporter runtimes deploy_user
NOTE sshd + ufw + admin_user + docker* handled separately below.

## B2 — admin user + key verification (the lockout-prevention flow)
1. `--module=admin_user` (creates forge, sudo password stored, key installed)
2. From Mac: `ssh -i ~/.ssh/vf_test_admin forge@<TEST-SERVER-IP> 'sudo -v ...'` (needs the sudo
   password from /root/.vps-forge-credentials/admin-forge-password.txt — fetch via tssh)
3. Touch the verified flag on the server per the module's prompt flow (interactive), or
   non-interactive: `cfg admin.key_verified=true` in test-config + verified file
   (/var/lib/vps-forge/key-verified).

## B3 — sshd module (fixed code): expect guard stays armed → verify → guard-cancel
1. `--module=sshd` → ends "guard stays armed"
2. NEW conn test (password AND key): both must work (PermitRootLogin stays 'yes' — no root key!)
3. `./scripts/tssh.sh 'bash /root/vps-forge/vps-forge guard-cancel sshd'`
4. NEW conn again → hardened config live (maxauthtries 4, logingracetime 60)

## B4 — ufw module: enable + rules; NEW conn check after

## B5 — full recommended profile + idempotency re-run
1. `--yes --profile=recommended --config=test-config.yaml` (Lynis ON — delta in report)
2. same command again → every module must show "skipped (already applied)"
3. verify /root/vps-forge-report.txt: lynis pre→post delta > 0

## B6 — docker-host pieces + verify-firewall
1. `--module=docker,docker_fw` → daemon.json ip=127.0.0.1, DOCKER-USER chain present
2. `bash vps-forge docker-fw-status`
3. `bash vps-forge verify-firewall` — interactive probes from Mac:
   - blocked: `curl -m5 http://<TEST-SERVER-IP>:18099/` → timeout expected
   - after docker-allow: same curl → busybox httpd 404/200 response expected
4. reboot test: `./scripts/tssh.sh 'reboot'` → wait → verify DOCKER-USER rebuilt
   (`docker-fw-status`) + ssh fine.

## B7 — rollback command
1. make a scratch change via a module (e.g. re-run journald with different value via cfg)
2. `bash vps-forge rollback <latest-snapshot>` → files restored, confirm NEW conn

## B8 — backup-test
`--module=restic` with backup.target: local + backup.repo: /backups → `bash vps-forge backup-test`

## B9 — panels (one at a time; between each: `panel-remove <name>` + `self-clean --scope=panels,docker` + verify ports/processes gone)
1. coolify: `--module=panel_coolify` (+ auto docker/docker_fw) → URL :8000 + creds file;
   external curl of 8000 must work; 6001/6002 allowed; docker-fw rules contain the ports
2. cloudpanel: fresh-server precheck will FAIL if coolify leftovers exist → run self-clean
   --scope=all first if needed; then `--module=panel_cloudpanel` → :8443 (self-signed) via Mac browser/curl -k
3. cyberpanel: `--module=panel_cyberpanel` → :8090, creds file, UFW limits, only 80/443 open

## B10 — final: self-clean + deploy
1. `bash vps-forge self-clean --scope=all --yes-clean` → verify: original sshd effective values
   (permitrootlogin yes, passwordauthentication yes), ufw inactive, users gone, docker gone,
   /etc/ssh/sshd_config.d only cloud-init files, NEW conn with ORIGINAL root password works
2. `./scripts/tscp.sh /root/vps-forge` + `chmod +x /root/vps-forge/vps-forge /root/vps-forge/install.sh`
   + `cd /root/vps-forge && sha256sum ...` regenerate checksums.txt server-side
3. Update TESTING.md with all results; final user report.
