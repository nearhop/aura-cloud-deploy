#!/usr/bin/env bash
#
# common.sh - shared settings for the Aura Cloud scripts.
#
# Sourced, not run. Defines dc(), a wrapper around docker compose that
# targets whichever deployment was chosen at install time.
#
# install.sh writes deploy.conf; without it the plain self-signed
# deployment is assumed, which is also what a manual "docker compose"
# would use.

DEPLOY_CONF="deploy.conf"

COMPOSE_FILE="docker-compose.yml"
COMPOSE_ENV=".env"
TLS_MODE="selfsigned"
PUBLIC_HOST=""
AURA_HOST=""

# shellcheck disable=SC1090
[ -f "$DEPLOY_CONF" ] && . "./$DEPLOY_CONF"

# All scripts call docker compose through this, so the letsencrypt
# deployment does not need a different command from the plain one. A
# stack started with one set of files cannot be managed with another:
# compose would treat the services as unrelated and leave the running
# containers behind.
dc() {
	docker compose --env-file "$COMPOSE_ENV" -f "$COMPOSE_FILE" "$@"
}

# How to reach owsec from the host.
#
# Without traefik, owsec publishes 16001 directly and 127.0.0.1 works.
# With traefik, 16001 belongs to traefik, which routes by hostname, so a
# request to 127.0.0.1 has no name to match and is refused. --resolve
# sets both the Host header and the TLS server name while still
# connecting locally, so this works before DNS points here.
#
# install.sh calls this again once the deployment has been chosen, since
# the values are not known when this file is first sourced.
set_owsec_endpoint() {
	OWSEC_URL="https://127.0.0.1:16001"
	OWSEC_RESOLVE=()

	if [ "$TLS_MODE" = "letsencrypt" ] && [ -n "$PUBLIC_HOST" ]; then
		OWSEC_URL="https://${PUBLIC_HOST}:16001"
		OWSEC_RESOLVE=(--resolve "${PUBLIC_HOST}:16001:127.0.0.1")
	fi
}

set_owsec_endpoint

# curl against owsec, with whatever the deployment needs.
owsec_curl() {
	curl -ks "${OWSEC_RESOLVE[@]}" "$@"
}
