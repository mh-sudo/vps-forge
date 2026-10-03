# shellcheck shell=bash
# modules/30-totp.sh — TOTP 2FA for SSH (pam_google_authenticator).
# Lockout-safe: pubkey auth stays primary; guard timer + NEW-session verification;
# scratch codes saved once. Non-interactive runs require explicit totp.enabled=true.

mod_totp_plan() {
	cat <<PLAN
Install libpam-google-authenticator
For users: $(totp_users) — generate TOTP secrets + emergency scratch codes
PAM: 'auth required pam_google_authenticator.so' in /etc/pam.d/sshd
sshd drop-in: KbdInteractiveAuthentication yes +
  AuthenticationMethods publickey,keyboard-interactive
GUARDED: 300s auto-revert; you MUST verify a TOTP login from a new session.
Scratch codes are shown ONCE and stored in $VF_CREDS_DIR.
PLAN
}

totp_users() {
	local u t
	t="$(cfg_get totp.users "")"
	if [ -z "$t" ]; then
		u="$(cfg_get admin.username none)"
		[ "$u" != "none" ] && id "$u" >/dev/null 2>&1 && t="$u"
	fi
	printf '%s root' "$t"
}

mod_totp_check() { grep -q pam_google_authenticator /etc/pam.d/sshd 2>/dev/null; }

mod_totp_ask() {
	if [ "$VF_NONINTERACTIVE" != "1" ]; then
		ui_box "TOTP 2FA for SSH" \
			"This adds a second factor (authenticator app) on top of your SSH key.
If you lose your phone AND the scratch codes, you are locked out — the provider console is the only way back."
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

	# enroll users
	local list u secretfile
	list="$(totp_users | tr ',' ' ')"
	for u in $list; do
		id "$u" >/dev/null 2>&1 || continue
		secretfile="/home/$u/.ssh/google_authenticator"
		[ "$u" = "root" ] && secretfile="/root/.ssh/google_authenticator"
		if [ -f "$secretfile" ]; then continue; fi
		local out key url
		out="$(runuser -u "$u" -- google-authenticator -t -d -f -r 3 -R 30 -Q UTF8 2>/dev/null)" ||
			out="$(sudo -u "$u" google-authenticator -t -d -f -r 3 -R 30 -Q UTF8 2>/dev/null)" || true
		key="$(printf '%s\n' "$out" | grep -E '^[A-Z2-7]{16,}$' | head -1)"
		url="$(printf '%s\n' "$out" | grep -oE 'otpauth://[a-z0-9]+/[^ ]+' | head -1)"
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

	# PAM + sshd changes, guarded
	vf_backup_file /etc/pam.d/sshd
	if ! grep -q pam_google_authenticator /etc/pam.d/sshd; then
		printf 'auth required pam_google_authenticator.so\n' >/etc/pam.d/sshd.vfnew
		cat /etc/pam.d/sshd >>/etc/pam.d/sshd.vfnew
		mv /etc/pam.d/sshd.vfnew /etc/pam.d/sshd
	fi
	local conf
	conf="$(vf_sshd_conf_file)"
	vf_backup_file "$conf"
	cat "$conf" >"$VF_TMP_DIR/sshd.pre-totp"
	{
		cat "$conf"
		printf 'KbdInteractiveAuthentication yes\nAuthenticationMethods publickey,keyboard-interactive\n'
	} >"$conf"
	vf_sshd_validate || {
		cp "$VF_TMP_DIR/sshd.pre-totp" "$conf"
		ui_error "invalid sshd config — reverted, PAM line kept but harmless without AuthenticationMethods"
		return 1
	}

	vf_guard_start totp 300 \
		"cp '$VF_TMP_DIR/sshd.pre-totp' '$conf'; sed -i '/pam_google_authenticator/d' /etc/pam.d/sshd; systemctl restart ssh sshd 2>/dev/null; logger -t vps-forge 'TOTP auto-reverted by guard'"
	vf_sshd_restart || return 1
	if vf_confirm_new_session "SSH login WITH TOTP (key + 6-digit code) for at least one enrolled user"; then
		vf_guard_cancel totp
		cfg_set totp.confirmed true
		return 0
	fi
	ui_warn "guard will revert TOTP in 300s — that is the SAFE outcome if you could not log in"
	return 1
}
