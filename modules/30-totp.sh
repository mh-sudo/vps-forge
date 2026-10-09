# shellcheck shell=bash
# modules/30-totp.sh — TOTP 2FA for SSH (pam_google_authenticator).
# Lockout-safe: pubkey auth stays primary; guard timer + NEW-session verification;
# scratch codes saved once. Non-interactive runs require explicit totp.enabled=true.
#
# Scope (see DECISIONS.md): TOTP applies ONLY to the enrolled users via an sshd
# Match block — key-only accounts (e.g. 'deploy') keep plain publickey login,
# and enabling TOTP never re-opens password authentication for anyone else.

mod_totp_plan() {
	cat <<PLAN
Install libpam-google-authenticator
For users: $(totp_users) — generate TOTP secrets + emergency scratch codes
PAM: 'auth required pam_google_authenticator.so' in /etc/pam.d/sshd
sshd drop-in 20-vps-forge-totp.conf (scoped to the enrolled users ONLY):
  Match User $(totp_users | tr ',' ' ' | tr -s ' ' ',')
    KbdInteractiveAuthentication yes
    AuthenticationMethods publickey,keyboard-interactive
GUARDED: 300s auto-revert; you MUST verify a TOTP login from a new session.
Scratch codes are shown ONCE and stored in $VF_CREDS_DIR.
PLAN
}

totp_users() {
	local t
	t="$(cfg_get totp.users "")"
	if [ -z "$t" ]; then
		t="$(cfg_get admin.username none)"
		if [ "$t" != "none" ]; then
			t="$t,root"
		else
			t="root"
		fi
	fi
	printf '%s' "$t"
}

mod_totp_check() {
	grep -q pam_google_authenticator /etc/pam.d/sshd 2>/dev/null &&
		[ -r /etc/ssh/sshd_config.d/20-vps-forge-totp.conf ]
}

mod_totp_ask() {
	if [ "$VF_NONINTERACTIVE" != "1" ]; then
		ui_box "TOTP 2FA for SSH" \
			"This adds a second factor (authenticator app) on top of your SSH key —
for the enrolled users only. If you lose your phone AND the scratch codes,
you are locked out — the provider console is the only way back."
		if ui_confirm "Enable SSH TOTP 2FA now?" n; then cfg_set totp.enabled y; else cfg_set totp.enabled n; fi
		local u
		u="$(cfg_get admin.username none)"
		[ "$u" != "none" ] && cfg_set totp.users "$(vf_ask totp.users "Users to enroll (comma-separated)" "$u,root")"
	fi
}

mod_totp_run() {
	if [ "$VF_NONINTERACTIVE" = "1" ] && ! cfg_is_true totp.enabled; then
		ui_warn "TOTP requires explicit opt-in (totp.enabled: true) — skipping"
		return 0
	fi
	if [ "$VF_NONINTERACTIVE" = "1" ] && ! cfg_is_true totp.confirmed; then
		ui_error "Non-interactive TOTP needs 'totp.confirmed: true' after you have verified a login once. Skipping."
		return 1
	fi
	vf_pkg_install libpam-google-authenticator

	# enroll users — the secret goes to ~/.google_authenticator, the path PAM
	# reads by default (an earlier version used ~/.ssh/google_authenticator,
	# which pam_google_authenticator.so never looked at)
	local list u secretfile
	list="$(totp_users | tr ',' ' ')"
	for u in $list; do
		id "$u" >/dev/null 2>&1 || continue
		secretfile="$(getent passwd "$u" | cut -d: -f6)/.google_authenticator"
		if [ -f "$secretfile" ]; then
			ui_info "$u already has a TOTP secret — keeping it"
			continue
		fi
		local out key url
		out="$(runuser -u "$u" -- google-authenticator -t -d -f -r 3 -R 30 -Q UTF8 2>/dev/null)" ||
			out="$(sudo -u "$u" google-authenticator -t -d -f -r 3 -R 30 -Q UTF8 2>/dev/null)" || true
		# the secret is printed as part of a sentence; match the base32 charset
		# anywhere (scratch codes are 8 digits, below the 16-char minimum)
		key="$(printf '%s\n' "$out" | grep -oE '[A-Z2-7]{16,}' | head -1 || true)"
		url="$(printf '%s\n' "$out" | grep -oE 'otpauth://[^ ]+' | head -1 || true)"
		if [ -z "$key" ]; then
			ui_error "could not enroll TOTP for '$u' — aborting module (nothing applied)"
			return 1
		fi
		vf_save_credential "totp-${u}.txt" "$out"
		ui_box "TOTP SECRET — $u (shown once)" \
			"Secret key: $key
Add it to your authenticator app, or open this URL on a phone:
$url
Scratch/emergency codes and full output: $VF_CREDS_DIR/totp-${u}.txt"
	done

	# PAM line: required for the keyboard-interactive TOTP prompt. Guarded.
	vf_backup_file /etc/pam.d/sshd
	if ! grep -q pam_google_authenticator /etc/pam.d/sshd; then
		printf 'auth required pam_google_authenticator.so\n' >/etc/pam.d/sshd.vfnew
		cat /etc/pam.d/sshd >>/etc/pam.d/sshd.vfnew
		mv /etc/pam.d/sshd.vfnew /etc/pam.d/sshd
	fi

	# sshd: scope TOTP to the enrolled users only — a global AuthenticationMethods
	# used to lock every key-only account (deploy) out of the server
	local users
	users="$(totp_users | tr ',' ' ' | tr -s ' ' | sed 's/^ //;s/ $//;s/ /,/')"
	vf_write_file /etc/ssh/sshd_config.d/20-vps-forge-totp.conf 644 <<EOF
# vps-forge TOTP scope: ONLY these users need key + TOTP. Everyone else keeps
# normal login (deploy-type accounts stay key-only).
Match User ${users}
	KbdInteractiveAuthentication yes
	AuthenticationMethods publickey,keyboard-interactive
EOF
	local conf2
	conf2=/etc/ssh/sshd_config.d/20-vps-forge-totp.conf
	vf_sshd_validate || {
		rm -f "$conf2"
		sed -i '/pam_google_authenticator/d' /etc/pam.d/sshd
		vf_sshd_validate || true
		ui_error "invalid sshd config — fully reverted (drop-in removed, PAM line removed)"
		return 1
	}

	vf_guard_start totp 300 \
		"rm -f '$conf2'; sed -i '/pam_google_authenticator/d' /etc/pam.d/sshd; systemctl restart ssh sshd 2>/dev/null; logger -t vps-forge 'TOTP auto-reverted by guard'"
	vf_sshd_restart || return 1
	if vf_confirm_new_session "SSH login WITH TOTP (key + 6-digit code) for at least one enrolled user"; then
		if ! vf_guard_cancel totp; then
			ui_error "the auto-revert guard already fired — TOTP was reverted; re-run this module"
			return 1
		fi
		cfg_set totp.confirmed true
		return 0
	fi
	ui_warn "guard will revert TOTP in 300s — that is the SAFE outcome if you could not log in"
	return 1
}
