# shellcheck shell=bash
# modules/20-admin-user.sh — new sudo admin user with ed25519 key + random sudo password.

vf_key_verified_flag() { printf '%s' "$VF_STATE_DIR/key-verified"; }

mod_admin_user_plan() {
	local u
	u="$(cfg_get admin.username none)"
	cat <<PLAN
Create sudo admin user: ${u}
  - member of 'sudo' group, bash shell
  - random password generated (forced change on first login), stored in $VF_CREDS_DIR/
  - ed25519 SSH key installed (${admin_key_source:-from your input / generated here})
  - root login disable: $(cfg_get admin.disable_root_login false) (applied by sshd module after key verification)
PLAN
}

mod_admin_user_check() {
	local u
	u="$(cfg_get admin.username none)"
	[ "$u" != "none" ] && id "$u" >/dev/null 2>&1
}

mod_admin_user_ask() {
	if [ "$VF_NONINTERACTIVE" != "1" ]; then
		cfg_set admin.username "$(vf_ask admin.username "Admin username to create" "forge")"
		local pub
		pub="$(cfg_get admin.pubkey "")"
		if [ -z "$pub" ] && [ -s /root/.ssh/authorized_keys ]; then
			pub="$(head -1 /root/.ssh/authorized_keys)"
			ui_para "Found an existing key in /root/.ssh/authorized_keys — will reuse it."
		fi
		if [ -z "$pub" ]; then
			if ui_confirm "Paste an SSH public key for the admin user now? (No = generate an ed25519 pair on the server)" y; then
				pub="$(vf_ask admin.pubkey "Public key (ssh-ed25519 AAAA... comment)" "")"
			fi
		fi
		vf_validate_pubkey "$pub" || return 1
		cfg_set admin.pubkey "$pub"
		if vf_ask_bool admin.disable_root_login "Disable direct root SSH login after the admin key is verified?" y; then
			cfg_set admin.disable_root_login y
		else
			cfg_set admin.disable_root_login n
		fi
	fi
}

# vf_validate_pubkey <key> — reject placeholders (copy-pasted example configs
# must never give a stranger's key SSH access) and non-key strings; empty = ok
# (module then reuses root's key or generates one)
vf_validate_pubkey() {
	local pub="$1"
	[ -n "$pub" ] || return 0
	case "$pub" in
	*"<"* | *YOUR* | *your_* | *PLACEHOLDER* | *EXAMPLE* | *REPLACE*)
		ui_error "admin.pubkey looks like a placeholder — paste a REAL public key (ssh-ed25519 AAAA... )"
		return 1
		;;
	esac
	case "$pub" in
	ssh-ed25519\ * | ssh-rsa\ * | ecdsa-sha2-*\ * | ssh-dss\ *) return 0 ;;
	*)
		ui_error "admin.pubkey does not look like an SSH public key (expected: ssh-ed25519 AAAA...)"
		return 1
		;;
	esac
}

mod_admin_user_run() {
	local u pub pw
	u="$(cfg_get admin.username none)"
	[ "$u" = "none" ] && {
		ui_warn "no admin username configured — skipping"
		return 0
	}
	if id "$u" >/dev/null 2>&1; then
		ui_para "user '$u' already exists — ensuring sudo membership and key"
	else
		useradd -m -d "/home/$u" -s /bin/bash -G sudo "$u"
		vf_note_created_user "$u"
	fi

	# random password, forced change on first login
	if ! passwd -S "$u" 2>/dev/null | awk '{print $2}' | grep -q '^P$'; then
		pw="$(vf_random_password 20)"
		vf_secret_register "$pw"
		printf '%s:%s\n' "$u" "$pw" | chpasswd
		chage -d 0 "$u" 2>/dev/null || true
		vf_save_credential "admin-${u}-password.txt" \
			"sudo password for ${u} (CHANGE ON FIRST LOGIN): ${pw}"
		ui_para "sudo password for '$u' generated — saved to $VF_CREDS_DIR/admin-${u}-password.txt and shown once:"
		printf '    %s\n' "$pw" >&2
	fi

	# ssh key
	local keyfile="/home/$u/.ssh/authorized_keys"
	pub="$(cfg_get admin.pubkey "")"
	if [ -z "$pub" ] && [ -s /root/.ssh/authorized_keys ]; then
		pub="$(head -1 /root/.ssh/authorized_keys)"
	fi
	vf_validate_pubkey "$pub" || return 1
	if [ -n "$pub" ]; then
		install -d -m 700 -o "$u" -g "$u" "/home/$u/.ssh"
		printf '%s\n' "$pub" >"$keyfile.new"
		[ -s "$keyfile" ] || mv "$keyfile.new" "$keyfile"
		[ -e "$keyfile" ] || mv "$keyfile.new" "$keyfile"
		grep -qxF "$pub" "$keyfile" 2>/dev/null || printf '%s\n' "$pub" >>"$keyfile"
		rm -f "$keyfile.new"
		chown "$u:$u" "$keyfile"
		chmod 600 "$keyfile"
	else
		ui_para "generating an ed25519 keypair on the server for '$u'"
		local priv="$VF_CREDS_DIR/${u}_ed25519"
		rm -f "$priv" "$priv.pub"
		ssh-keygen -t ed25519 -N '' -C "vps-forge-${u}@$(hostname)" -f "$priv" -q
		chmod 600 "$priv"
		install -d -m 700 -o "$u" -g "$u" "/home/$u/.ssh"
		cp "$priv.pub" "/home/$u/.ssh/authorized_keys"
		chown "$u:$u" "/home/$u/.ssh/authorized_keys"
		chmod 600 "/home/$u/.ssh/authorized_keys"
		ui_warn "PRIVATE KEY shown ONCE — copy it now and delete the server copy afterwards:"
		sed 's/^/    /' "$priv" >&2
		ui_para "(kept at $priv until you delete it)"
	fi

	# interactive: verify login from a new session before sshd module may disable password auth
	if [ "$VF_NONINTERACTIVE" != "1" ] && [ ! -e "$(vf_key_verified_flag)" ]; then
		local ip
		ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
		ui_box "VERIFY KEY LOGIN" \
			"Open a NEW terminal and test:  ssh -p$([ -n "$(cfg_get ssh.port keep)" ] && [ "$(cfg_get ssh.port keep)" != keep ] && cfg_get ssh.port keep || echo 22) ${u}@${ip:-server}
Log in with the key, then run:  sudo -v   (password from above)
Come back here and confirm."
		if ui_confirm "Did key-based login + sudo for '$u' work?"; then
			touch "$(vf_key_verified_flag)"
			vf_log_info "admin key verified by user"
		else
			ui_warn "NOT verified — password authentication and root login will stay ENABLED."
		fi
	fi
	[ -e "$(vf_key_verified_flag)" ] || cfg_is_true admin.key_verified ||
		{
			cfg_set ssh.password_auth keep-until-verified
			cfg_set admin.disable_root_login false
		}
	return 0
}
