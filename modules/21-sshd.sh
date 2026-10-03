# shellcheck shell=bash
# modules/21-sshd.sh — hardened sshd via /etc/ssh/sshd_config.d/00-vps-forge.conf drop-in.
# Port changes: transitional dual-port listening, external verification, guard timer.

VF_SSHD_PORT_STATE="$VF_STATE_DIR/sshd-port-applied"

mod_sshd_plan() {
	local newport
	newport="$(cfg_get ssh.port keep)"
	cat <<PLAN
Write /etc/ssh/sshd_config.d/00-vps-forge.conf (drop-in; main file untouched):
  modern KexAlgorithms (sntrup761x25519 + curve25519), Ciphers, MACs (etm-only)
  MaxAuthTries 4, LoginGraceTime 60, PermitEmptyPasswords no, UseDNS no
  X11Forwarding no, AllowAgentForwarding no, AllowTcpForwarding $(cfg_get ssh.allow_tcp_forwarding false)
  ClientAliveInterval 300 / CountMax 3
  PasswordAuthentication: $(sshd_password_plan_desc)
  PermitRootLogin: $(sshd_root_plan_desc)
  AllowUsers: $(sshd_allowusers_desc || echo "(omitted — see log)")
  SSH port: ${newport}$([ "$newport" = "keep" ] || echo "  (transition: old+new both open until you verify the new one)")
Guard: 180s auto-revert timer + mandatory confirm from a NEW session.
PLAN
}

sshd_password_plan_desc() {
	if [ "$(cfg_get ssh.password_auth keep-until-verified)" = "no" ]; then echo "no (disabled — key verified)"; else echo "yes (kept until an authorized key is verified)"; fi
}
sshd_root_value() { # bare sshd keyword value — NEVER restrict root login unless a key exists
	if cfg_is_true admin.disable_root_login && [ -e "$(vf_key_verified_flag)" ]; then
		echo "no"
		return 0
	fi
	# prohibit-password is only safe when root actually has an authorized key
	if [ -s /root/.ssh/authorized_keys ] 2>/dev/null && grep -qE '^(ssh-(ed25519|rsa)|ecdsa-sha2-) ' /root/.ssh/authorized_keys 2>/dev/null; then
		echo "prohibit-password"
	else
		# keep whatever the server already allows — restricting would lock out password users
		echo "yes"
	fi
	return 0
}
sshd_root_plan_desc() { # human description for the plan screen
	case "$(sshd_root_value)" in
	no) echo "no (disabled — verified admin key)" ;;
	prohibit-password) echo "prohibit-password (keys only for root — a root key exists)" ;;
	*) echo "yes (kept: no authorized root key found — restricting would lock you out)" ;;
	esac
}
sshd_allowusers_desc() {
	local u="" a
	a="$(cfg_get admin.username none)"
	[ "$a" != "none" ] && id "$a" >/dev/null 2>&1 && u="$a"
	[ "$(sshd_root_value)" = "no" ] || u="$u root"
	[ "$(id -un)" != "root" ] && [ -n "$(id -un)" ] && u="$u $(id -un)"
	u="$(printf '%s' "$u" | tr -s ' ' | sed 's/^ //;s/ $//')"
	[ -n "$u" ] && printf '%s' "$u"
	return 0
}

mod_sshd_check() {
	[ -r "$(vf_sshd_conf_file)" ] && vf_sshd_validate 2>/dev/null
}

mod_sshd_ask() {
	if [ "$VF_NONINTERACTIVE" != "1" ]; then
		cfg_set ssh.port "$(vf_ask ssh.port "SSH port (number, or 'keep' for $(vf_effective_ssh_port))" "keep")"
		if vf_ask_bool ssh.allow_tcp_forwarding "Allow SSH TCP forwarding (tunnels)? Disabling is the CIS default." n; then
			cfg_set ssh.allow_tcp_forwarding y
		else
			cfg_set ssh.allow_tcp_forwarding n
		fi
	fi
}

sshd_filter_algos() { # sshd_filter_algos <kind:kex|cipher|mac> <comma-list> -> supported subset
	local kind="$1" list="$2" supported item out=""
	supported="$(ssh -Q "$kind" 2>/dev/null || true)"
	for item in ${list//,/ }; do
		grep -qxF "$item" <<<"$supported" && out+="${item},"
	done
	printf '%s' "${out%,}"
}

sshd_dropin_content() { # -> stdout; args: extra Port lines already handled by caller
	local fwd users
	fwd="$(cfg_get ssh.allow_tcp_forwarding false)"
	case "$fwd" in y | yes | true | 1 | on) fwd="yes" ;; *) fwd="no" ;; esac
	# crypto lists are filtered against THIS server's OpenSSH at apply time
	local kex ciphers macs
	kex="$(sshd_filter_algos kex "sntrup761x25519-sha512@openssh.com,curve25519-sha256,curve25519-sha256@libssh.com,diffie-hellman-group16-sha512")"
	ciphers="$(sshd_filter_algos cipher "chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com")"
	macs="$(sshd_filter_algos mac "hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com")"
	[ -n "$kex" ] || kex="curve25519-sha256"
	[ -n "$ciphers" ] || ciphers="aes256-gcm@openssh.com"
	[ -n "$macs" ] || macs="hmac-sha2-512-etm@openssh.com"
	{
		if [ -n "${1:-}" ]; then printf '%s\n' "$1"; fi
		cat <<EOF
# vps-forge hardened sshd configuration
KexAlgorithms $kex
Ciphers $ciphers
MACs $macs
MaxAuthTries 4
LoginGraceTime 60
PermitEmptyPasswords no
PubkeyAuthentication yes
X11Forwarding no
AllowAgentForwarding no
EOF
		printf 'AllowTcpForwarding %s\n' "$fwd"
		cat <<'EOF'
ClientAliveInterval 300
ClientAliveCountMax 3
UseDNS no
EOF
		printf 'PasswordAuthentication %s\n' "$(sshd_password_plan_desc | grep -q 'no (disabled' && echo no || echo yes)"
		printf 'PermitRootLogin %s\n' "$(sshd_root_value)"
		users="$(sshd_allowusers_desc)"
		if [ -n "$users" ]; then
			printf 'AllowUsers %s\n' "$users"
		fi
	}
}

mod_sshd_run() {
	local newport oldport portlines
	newport="$(cfg_get ssh.port keep)"
	oldport="$(vf_effective_ssh_port)"
	case "$newport" in keep | "") newport="$oldport" ;; esac
	case "$newport" in *[!0-9]* | '') newport="$oldport" ;; esac

	# ufw interplay: if the firewall is already active, open the new port BEFORE restarting sshd
	if [ "$newport" != "$oldport" ] && vf_ufw_active; then
		vf_ufw_allow_port "$newport/tcp" limit
	fi

	if [ "$newport" != "$oldport" ] && [ ! -f "$VF_SSHD_PORT_STATE" ]; then
		ui_warn "SSH PORT CHANGE: sshd will listen on BOTH $oldport and $newport until you verify the new one."
		portlines="Port $oldport
Port $newport"
	elif [ "$newport" != "$oldport" ] && [ -f "$VF_SSHD_PORT_STATE" ]; then
		# previous transition already verified at least once; still go dual to be safe
		portlines="Port $oldport
Port $newport"
	else
		portlines=""
	fi

	if ! sshd_dropin_content "$portlines" | vf_sshd_apply_dropin; then
		ui_error "sshd hardening failed validation — previous config restored"
		return 1
	fi

	if [ -n "$portlines" ]; then
		# confirm reachable on the new port from a new session, then drop the old port
		if vf_confirm_new_session "SSH login on the NEW port $newport" "ssh -p $newport $(id -un)@$(hostname -I | awk '{print $1}')"; then
			vf_guard_cancel sshd
			printf '%s\n' "$newport" >"$VF_SSHD_PORT_STATE"
			ui_para "removing old port $oldport from sshd (final config keeps $newport only)"
			printf 'Port %s\n' "$newport" | {
				read -r pl
				sshd_dropin_content "$pl"
			} | vf_sshd_apply_dropin || return 1
			vf_confirm_new_session "SSH still reachable on port $newport after final restart" || true
			vf_guard_cancel sshd
			if vf_ufw_active && [ "$oldport" != "$newport" ]; then
				ufw delete limit "$oldport/tcp" >/dev/null 2>&1 || true
			fi
		else
			ui_warn "guard will restore the old sshd config (port $oldport). Re-run this module to retry."
			return 1
		fi
	else
		if vf_confirm_new_session "SSH login still works (new key/password rules)"; then
			vf_guard_cancel sshd
		elif [ "$VF_NONINTERACTIVE" = "1" ]; then
			# safe by design: applied + guard armed; reverts unless 'vps-forge guard-cancel sshd'
			ui_para "hardening APPLIED but the auto-revert guard stays armed (${VF_GUARD_TIMEOUT:-180}s)."
			ui_para "verify from a new session, then run: vps-forge guard-cancel sshd"
			printf '%s\n' "$newport" >"$VF_SSHD_PORT_STATE"
			return 0
		else
			ui_warn "guard will auto-revert the sshd hardening"
			return 1
		fi
	fi
	printf '%s\n' "$newport" >"$VF_SSHD_PORT_STATE"
	return 0
}
