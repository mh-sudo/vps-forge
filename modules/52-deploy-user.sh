# shellcheck shell=bash
# modules/52-deploy-user.sh — non-sudo deploy user with Docker access (risk: docker group ~ root).

mod_deploy_user_plan() {
	cat <<PLAN
Create user 'deploy' (no sudo), shell bash
Add to 'docker' group — NOTE: docker group membership is effectively ROOT access
Optional SSH key from admin.deploy_pubkey
PLAN
}

mod_deploy_user_check() { id deploy >/dev/null 2>&1; }

mod_deploy_user_run() {
	if ! id deploy >/dev/null 2>&1; then
		useradd -m -s /bin/bash deploy
		passwd -l deploy >/dev/null 2>&1 || true
	fi
	# pre-create the docker group so membership works even if docker runs later
	groupadd -f docker >/dev/null 2>&1 || true
	if usermod -aG docker deploy 2>/dev/null; then
		ui_para "deploy added to docker group (= root-equivalent; intentional for CI/CD)"
	else
		ui_warn "could not add deploy to docker group"
	fi
	local pub
	pub="$(cfg_get admin.deploy_pubkey "")"
	if [ -n "$pub" ]; then
		install -d -m 700 -o deploy -g deploy /home/deploy/.ssh
		printf '%s\n' "$pub" >/home/deploy/.ssh/authorized_keys
		chown deploy:deploy /home/deploy/.ssh/authorized_keys && chmod 600 /home/deploy/.ssh/authorized_keys
	fi
	return 0
}
