#!/usr/bin/env bash
#
# install.sh - first-run setup for the Aura Cloud stack.
#
# Generates aura-cloud.env with per-install secrets, checks the host is
# ready, and starts the stack. Run once. Use start_aura.sh / stop_aura.sh
# afterwards, and reset.sh to start over.
#
set -euo pipefail

cd "$(dirname "$0")"

# shellcheck disable=SC1091
. ./common.sh

ENV_FILE="aura-cloud.env"
PG_ENV_FILE="postgresql.env"
FORCE=0

for arg in "$@"; do
	case "$arg" in
		--force) FORCE=1 ;;
		-h|--help)
			sed -n '3,9p' "$0" | sed 's/^# \{0,1\}//'
			exit 0 ;;
		*) echo "unknown option: $arg" >&2; exit 1 ;;
	esac
done

# --- output helpers ---------------------------------------------

info()  { printf '  %s\n' "$*"; }
ok()    { printf '  ok    %s\n' "$*"; }
warn()  { printf '  warn  %s\n' "$*" >&2; }
fail()  { printf '  ERROR %s\n' "$*" >&2; exit 1; }
step()  { printf '\n== %s\n' "$*"; }

# --- preflight --------------------------------------------------

step "Checking prerequisites"

command -v docker >/dev/null 2>&1 || fail "docker is not installed"

# Compose v2 only. v1 cannot parse this file: it has no top-level
# version key, so v1 falls back to the legacy schema and reports
# "Unsupported config option for services".
if ! docker compose version >/dev/null 2>&1; then
	fail "dc v2 is required.
        Install it with:  sudo apt-get install docker-compose-v2
        The older docker-compose (with a hyphen) cannot read this file."
fi
ok "docker compose $(docker compose version --short 2>/dev/null || echo v2)"

if ! docker info >/dev/null 2>&1; then
	fail "cannot reach the docker daemon.
        Either run this with sudo, or add yourself to the docker group:
          sudo usermod -aG docker \$USER
        then log out and back in."
fi
ok "docker daemon reachable"

# Ports the stack publishes. Anything already listening will make the
# corresponding container fail to start with a bind error.
#
# Read from docker-compose.yml rather than "dc config",
# because that resolves env_file references and fails before
# aura-cloud.env has been written.
# Match only the port portion of the Local Address field. A looser
# pattern matches digits elsewhere in the output and reports ports as
# busy when nothing is listening on them.
check_port() {
	local port="$1"
	ss -tln 2>/dev/null | awk 'NR>1 {print $4}' | grep -qE ":${port}\$"
}

# grep exits non-zero when nothing matches, which would trip set -e.
PUBLISHED=$(grep -oE '^[[:space:]]+- "[0-9]+:' docker-compose.yml 2>/dev/null \
	| grep -oE '[0-9]+' | sort -un) || true

PORT_CLASH=0
if [ -z "$PUBLISHED" ]; then
	warn "could not determine published ports; skipping the port check"
else
	for port in $PUBLISHED; do
		if check_port "$port"; then
			warn "port ${port} is already in use"
			PORT_CLASH=1
		fi
	done
	[ "$PORT_CLASH" -eq 0 ] && ok "required ports are free"
fi

if [ "$PORT_CLASH" -eq 1 ]; then
	info ""
	info "Change the port mapping in docker-compose.yml, or stop whatever"
	info "is holding it. To see what is using a port:"
	info "  sudo ss -tlnp '( sport = :80 )'"
	exit 1
fi

# Aura's first migration needs the vector extension.
if ! grep -q 'pgvector/pgvector' docker-compose.yml; then
	fail "docker-compose.yml does not use the pgvector postgres image.
        Aura's first migration creates the vector extension, which the
        stock postgres image does not provide."
fi
ok "postgres image provides pgvector"

# The image downloads the Aura binary at build time, so the release tag
# must be set and the host must be able to reach the release URL.
AURA_TAG=$(grep -E '^AURA_TAG=' .env 2>/dev/null | cut -d= -f2) || true
if [ -z "${AURA_TAG:-}" ]; then
	fail "AURA_TAG is not set in .env.
        Set it to the Aura release to deploy, for example:
          AURA_TAG=v1.35"
fi
ok "aura release ${AURA_TAG}"

# postgres runs this as its own user on first initialisation. If it is
# not both readable and executable the databases are never created, and
# the symptom appears later as "database owsub does not exist".
if [ ! -r postgresql/init-db.sh ] || [ ! -x postgresql/init-db.sh ]; then
	fail "postgresql/init-db.sh must be readable and executable.
        Fix with:  chmod 755 postgresql/init-db.sh"
fi
ok "database init script is executable"

AVAIL_KB=$(df -Pk . | awk 'NR==2 {print $4}')
if [ "$AVAIL_KB" -lt 5242880 ]; then
	warn "less than 5 GB free on this filesystem"
fi

# --- existing install -------------------------------------------

if [ -f "$ENV_FILE" ] && [ "$FORCE" -eq 0 ]; then
	fail "$ENV_FILE already exists.
        This looks like an existing install. To start the stack:
          ./start_aura.sh
        To wipe everything and set up again:
          ./reset.sh && ./install.sh"
fi

# --- gather settings --------------------------------------------

step "Configuration"

gen_secret() { openssl rand -hex 32; }
gen_password() { openssl rand -base64 18 | tr -d '/+=' | cut -c1-20; }

# Aura requires 3 of: lowercase, uppercase, digit, special.
gen_admin_password() { printf '%s' "$(openssl rand -base64 12 | tr -d '/+=' | cut -c1-14)Aa1@"; }

read -r -p "  Administrator email [admin@example.com]: " ADMIN_EMAIL
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example.com}"
# Aura requires 3 of: lowercase, uppercase, digit, special. Checking it
# here rather than letting Aura reject it at startup, where the reason
# ends up buried in a restart loop.
password_classes() {
	local pw="$1" n=0
	[[ "$pw" =~ [a-z] ]] && n=$((n+1))
	[[ "$pw" =~ [A-Z] ]] && n=$((n+1))
	[[ "$pw" =~ [0-9] ]] && n=$((n+1))
	[[ "$pw" =~ [^a-zA-Z0-9] ]] && n=$((n+1))
	printf '%s' "$n"
}

info "Password must be at least 8 characters and include 3 of:"
info "lowercase, uppercase, digit, special character."
info "Leave blank to generate one."

GENERATED_ADMIN_PW=0
while true; do
	read -r -s -p "  Administrator password: " ADMIN_PASSWORD; echo

	if [ -z "$ADMIN_PASSWORD" ]; then
		ADMIN_PASSWORD="$(gen_admin_password)"
		GENERATED_ADMIN_PW=1
		ok "generated"
		break
	fi

	if [ "${#ADMIN_PASSWORD}" -lt 8 ]; then
		warn "too short: needs at least 8 characters. Try again."
		continue
	fi

	if [ "$(password_classes "$ADMIN_PASSWORD")" -lt 3 ]; then
		warn "needs 3 of: lowercase, uppercase, digit, special. Try again."
		continue
	fi

	read -r -s -p "  Confirm password: " ADMIN_PASSWORD2; echo
	if [ "$ADMIN_PASSWORD" != "$ADMIN_PASSWORD2" ]; then
		warn "passwords do not match. Try again."
		continue
	fi

	break
done

# The access points connect to the gateway and, for remote terminal,
# to this name directly, so it must resolve from the AP network and not
# only from a browser.
DEFAULT_HOST="$(hostname -f 2>/dev/null || hostname)"
read -r -p "  Hostname or IP that APs will use to reach this server [${DEFAULT_HOST}]: " PUBLIC_HOST
PUBLIC_HOST="${PUBLIC_HOST:-$DEFAULT_HOST}"

# --- TLS ---------------------------------------------------------

# Two deployments are supported. Self-signed works anywhere and needs
# nothing from the network. Let's Encrypt puts traefik in front and
# obtains real certificates, which removes the browser warnings but
# requires public DNS and inbound port 80 for the ACME challenge.
info ""
info "Certificates:"
info "  1) Self-signed. Works anywhere. Browsers show a warning."
info "  2) Let's Encrypt. No warnings, but needs public DNS pointing"
info "     at this host and inbound port 80."

TLS_CHOICE=""
while [ -z "$TLS_CHOICE" ]; do
	read -r -p "  Choose [1]: " TLS_CHOICE
	TLS_CHOICE="${TLS_CHOICE:-1}"
	case "$TLS_CHOICE" in
		1) TLS_MODE="selfsigned" ;;
		2) TLS_MODE="letsencrypt" ;;
		*) warn "enter 1 or 2"; TLS_CHOICE="" ;;
	esac
done

if [ "$TLS_MODE" = "letsencrypt" ]; then
	COMPOSE_FILE="docker-compose.lb.letsencrypt.yml"
	COMPOSE_ENV=".env.letsencrypt"

	read -r -p "  Hostname for the Aura interface [aura.${PUBLIC_HOST#*.}]: " AURA_HOST
	AURA_HOST="${AURA_HOST:-aura.${PUBLIC_HOST#*.}}"

	read -r -p "  Email for certificate expiry notices [${ADMIN_EMAIL}]: " ACME_EMAIL
	ACME_EMAIL="${ACME_EMAIL:-$ADMIN_EMAIL}"

	# The ACME challenge has Let's Encrypt connect back on port 80 for
	# each name. If DNS points elsewhere the challenge is answered by
	# another host and this one gets nothing, while still counting
	# against the rate limit of 5 duplicate certificates per week.
	#
	# Both the addresses configured on this host and the one it appears
	# to come from are accepted. A floating or reserved address, as used
	# by most cloud providers, is bound locally but is not the address
	# outbound traffic appears to originate from, and traffic sent to it
	# still arrives here.
	LOCAL_IPS=$(ip -4 addr show 2>/dev/null | grep -oE 'inet [0-9.]+' | awk '{print $2}') || true
	OUT_IP=$(curl -s --max-time 10 https://api.ipify.org 2>/dev/null) || true
	ALL_IPS="${LOCAL_IPS:-} ${OUT_IP:-}"

	if [ -n "$(echo "$ALL_IPS" | tr -d '[:space:]')" ]; then
		DNS_MISMATCH=0
		for h in "$PUBLIC_HOST" "$AURA_HOST"; do
			RESOLVED=$(getent ahostsv4 "$h" 2>/dev/null | awk 'NR==1{print $1}') || true
			if [ -z "${RESOLVED:-}" ]; then
				warn "${h} does not resolve"
				DNS_MISMATCH=1
			elif echo "$ALL_IPS" | tr ' ' '\n' | grep -qx "$RESOLVED"; then
				ok "${h} resolves here (${RESOLVED})"
			else
				warn "${h} resolves to ${RESOLVED}, which is not an address on this host"
				DNS_MISMATCH=1
			fi
		done

		if [ "$DNS_MISMATCH" -eq 1 ]; then
			info ""
			info "Certificates cannot be issued unless both names reach this"
			info "host on port 80. Addresses on this host:"
			echo "$ALL_IPS" | tr ' ' '\n' | grep -v '^$' | sed 's/^/      /'
			read -r -p "  Continue anyway? [y/N]: " GO
			case "$GO" in
				[yY]*) ;;
				*) fail "stopped. Point both names at this host and run this again." ;;
			esac
		fi
	else
		warn "could not determine this host's addresses; skipping the DNS check"
	fi
else
	COMPOSE_FILE="docker-compose.yml"
	COMPOSE_ENV=".env"
	AURA_HOST="$PUBLIC_HOST"
fi

# --- AI assistant -------------------------------------------------

# Optional. Without a key the assistant panel is simply not shown, so
# an empty answer is a normal choice, not a failure. The key is read
# without echo because it is a credential.
info ""
info "AI assistant (optional). Answers questions about the network in"
info "the Aura interface, using Groq. Questions and the network data"
info "needed to answer them are sent to Groq. Get a key at"
info "https://console.groq.com/keys, or leave empty and add one later"
info "with ./ai_setup.sh."

GROQ_API_KEY=""
while :; do
	read -r -s -p "  Groq API key [none]: " GROQ_API_KEY; echo
	# The key is written into an env file, so only characters a key can
	# contain are accepted.
	if [ -z "$GROQ_API_KEY" ] || [[ "$GROQ_API_KEY" =~ ^[A-Za-z0-9_-]+$ ]]; then
		break
	fi
	warn "that does not look like an API key; try again or leave empty"
done

DB_PASSWORD="$(gen_password)"
JWT_SECRET="$(gen_secret)"

# --- write configuration ----------------------------------------

step "Writing configuration"

# Recorded so the other scripts target the same deployment. A stack
# started with one compose file cannot be managed with another.
cat > deploy.conf <<EOF
# Written by install.sh on $(date -u '+%Y-%m-%d %H:%M UTC'). Do not edit.
COMPOSE_FILE="${COMPOSE_FILE}"
COMPOSE_ENV="${COMPOSE_ENV}"
TLS_MODE="${TLS_MODE}"
PUBLIC_HOST="${PUBLIC_HOST}"
AURA_HOST="${AURA_HOST}"
EOF
ok "deploy.conf"

# The owsec endpoint depends on the deployment, which was not known when
# common.sh was sourced.
set_owsec_endpoint

if [ "$TLS_MODE" = "letsencrypt" ]; then
	# SDKHOSTNAME is the name traefik routes the OpenWiFi interfaces on,
	# and the one it requests a certificate for.
	sed -i "s|^SDKHOSTNAME=.*|SDKHOSTNAME=${PUBLIC_HOST}|" "$COMPOSE_ENV"

	# pgvector is needed by Aura's first migration. The variant env
	# files are separate from .env and do not inherit from it.
	if grep -q '^PGVECTOR_TAG=' "$COMPOSE_ENV"; then
		sed -i "s|^PGVECTOR_TAG=.*|PGVECTOR_TAG=pg15|" "$COMPOSE_ENV"
	else
		echo "PGVECTOR_TAG=pg15" >> "$COMPOSE_ENV"
	fi
	ok "$COMPOSE_ENV"

	sed -i "s|^TRAEFIK_CERTIFICATESRESOLVERS_OPENWIFI_ACME_EMAIL=.*|TRAEFIK_CERTIFICATESRESOLVERS_OPENWIFI_ACME_EMAIL=${ACME_EMAIL}|" traefik.env
	ok "traefik.env"

	# Route the Aura hostname to the aura-cloud container. The upstream
	# file has no entry for it, so it is added if absent and the
	# hostname updated if it is already there.
	TRAEFIK_YAML="traefik/openwifi_letsencrypt.yaml"
	if [ -f "$TRAEFIK_YAML" ]; then
		if grep -q 'aura-cloud-service' "$TRAEFIK_YAML"; then
			sed -i "s|rule: \"Host(\`[^\`]*\`)\" *# aura|rule: \"Host(\`${AURA_HOST}\`)\" # aura|" "$TRAEFIK_YAML"
		else
			python3 - "$TRAEFIK_YAML" "$AURA_HOST" <<-'PY'
			import sys
			path, host = sys.argv[1], sys.argv[2]
			s = open(path).read()

			service = (
			    '    aura-cloud-service:\n'
			    '      loadBalancer:\n'
			    '        servers:\n'
			    '          - url: "http://aura-cloud:9090/"\n'
			)
			router = (
			    '    aura-cloud-http:\n'
			    '      entryPoints: "owgwuihttp"\n'
			    '      service: "aura-cloud-service"\n'
			    f'      rule: "Host(`{host}`)" # aura\n'
			    '    aura-cloud-https:\n'
			    '      entryPoints: "owgwuihttps"\n'
			    '      service: "aura-cloud-service"\n'
			    f'      rule: "Host(`{host}`)" # aura\n'
			    '      tls:\n'
			    '        certResolver: "openwifi"\n'
			)

			s = s.replace('\n  routers:\n', service + '\n  routers:\n' + router, 1)
			open(path, 'w').write(s)
			PY
		fi
		ok "$TRAEFIK_YAML"
	fi
fi

# The database is created by postgresql/init-db.sh on first start, so
# the credentials must be in place before postgres initialises.
if grep -q '^AURA_DB=' "$PG_ENV_FILE" 2>/dev/null; then
	sed -i "s|^AURA_DB_PASSWORD=.*|AURA_DB_PASSWORD=${DB_PASSWORD}|" "$PG_ENV_FILE"
else
	cat >> "$PG_ENV_FILE" <<-EOF

	AURA_DB=nearhop
	AURA_DB_USER=nearhop
	AURA_DB_PASSWORD=${DB_PASSWORD}
	EOF
fi
ok "$PG_ENV_FILE"

umask 077
cat > "$ENV_FILE" <<EOF
# Generated by install.sh on $(date -u '+%Y-%m-%d %H:%M UTC').
# Contains credentials. Do not commit.

# --- Server -----------------------------------------------------
SERVER_PORT=9090
ENV=production

# --- Database ---------------------------------------------------
DB_HOST=postgresql
DB_PORT=5432
DB_NAME=nearhop
DB_USER=nearhop
DB_PASSWORD=${DB_PASSWORD}
DB_SSLMODE=disable

# --- Auth -------------------------------------------------------
# Signs Aura's session tokens. Anyone holding this can mint a token for
# any user. Changing it logs everyone out.
JWT_SECRET=${JWT_SECRET}
JWT_EXPIRY_HOURS=24

# Private inter-service endpoints, resolvable only inside the compose
# network. Credentials are set by bootstrap_owsec.sh.
OWSEC_URL=https://owsec.wlan.local:17001
OWSEC_USERNAME=
OWSEC_PASSWORD=
OWGW_URL=https://owgw.wlan.local:17002

# --- Kafka ------------------------------------------------------
KAFKA_BROKERS=kafka:9092

# --- Deployment -------------------------------------------------
DEPLOYMENT_MODE=self-hosted

# --- Initial administrator --------------------------------------
SUPERADMIN_EMAIL=${ADMIN_EMAIL}
SUPERADMIN_NAME=Administrator
SUPERADMIN_PASSWORD=${ADMIN_PASSWORD}

# --- AI assistant (optional) ------------------------------------
# Groq API key. Empty turns the assistant off. Questions and the network
# data needed to answer them are sent to Groq. Change with ./ai_setup.sh.
GROQ_API_KEY=${GROQ_API_KEY}

# --- Email (optional) -------------------------------------------
#SMTP_HOST=
#SMTP_PORT=587
#SMTP_USERNAME=
#SMTP_PASSWORD=
#SMTP_FROM='Aura Cloud Alerts <noreply@example.com>'
EOF
umask 022
ok "$ENV_FILE"

# The stock env files refer to openwifi.wlan.local for everything the
# outside world touches. That name only resolves inside the compose
# network, so browsers and APs cannot reach it.
#
# Three kinds of address are involved and only two are rewritten:
#
#   SYSTEM_URI_PUBLIC   returned by owsec from /systemEndpoints and
#                       followed by the UI after login. Left wrong, the
#                       login succeeds and the dashboard is empty.
#   SYSTEM_URI_UI       links the services build back to the UI.
#   RTTY_SERVER         the AP connects to this directly for remote
#                       terminal, so it must resolve from the AP.
#
#   SYSTEM_URI_PRIVATE  container to container, resolved by the Docker
#                       network aliases. Rewriting it breaks every
#                       inter-service call, so it is left alone.
step "Setting the public hostname"

for f in ow*.env; do
	[ -f "$f" ] || continue
	changed=0

	if grep -q '^SYSTEM_URI_PUBLIC=' "$f"; then
		sed -i "s|^\(SYSTEM_URI_PUBLIC=https\?://\)[^:/]*|\1${PUBLIC_HOST}|" "$f"
		changed=1
	fi

	if grep -q '^SYSTEM_URI_UI=' "$f"; then
		sed -i "s|^\(SYSTEM_URI_UI=https\?://\)[^:/]*|\1${PUBLIC_HOST}|" "$f"
		changed=1
	fi

	if grep -q '^RTTY_SERVER=' "$f"; then
		sed -i "s|^RTTY_SERVER=.*|RTTY_SERVER=${PUBLIC_HOST}|" "$f"
		changed=1
	fi

	[ "$changed" -eq 1 ] && ok "$f"
done

# The OpenWiFi UI runs in the browser, so it cannot use the internal
# compose alias the backend services use. Left at its default it fails
# every login with "Invalid Credentials", which is the same message it
# shows for a genuinely wrong password.
if [ -f owgw-ui.env ]; then
	sed -i "s|^REACT_APP_UCENTRALSEC_URL=.*|REACT_APP_UCENTRALSEC_URL=https://${PUBLIC_HOST}:16001|" owgw-ui.env
	ok "owgw-ui.env"
fi

if [ -f owprov-ui.env ]; then
	sed -i "s|^REACT_APP_UCENTRALSEC_URL=.*|REACT_APP_UCENTRALSEC_URL=https://${PUBLIC_HOST}:16001|" owprov-ui.env
	ok "owprov-ui.env"
fi

# --- start ------------------------------------------------------

step "Starting the stack"
info "First run pulls several images and may take a few minutes."

dc up -d

# --- wait for readiness -----------------------------------------

step "Waiting for services"

wait_for() {
	local name="$1" cmd="$2" tries="${3:-60}"
	local i=0
	while [ "$i" -lt "$tries" ]; do
		if eval "$cmd" >/dev/null 2>&1; then
			ok "$name"
			return 0
		fi
		i=$((i+1))
		sleep 2
	done
	warn "$name did not come up in time"
	return 1
}

wait_for "postgresql" "dc exec -T postgresql pg_isready -U postgres"

# 403 from an unauthenticated request means owsec is up and answering.
# Do not use curl -f here: it exits non-zero on any 4xx, so the status
# code never reaches the comparison.
# owsec_curl and OWSEC_URL come from common.sh and account for
# traefik, which owns port 16001 in the letsencrypt deployment and
# routes it by hostname rather than serving 127.0.0.1 directly.
#
# Do not use curl -f here: it exits non-zero on any 4xx, so the status
# code never reaches the comparison. A 403 from an unauthenticated
# request is the expected healthy answer.
wait_for "owsec" "owsec_curl -o /dev/null -w '%{http_code}' ${OWSEC_URL}/api/v1/systemEndpoints | grep -qE '200|40[13]'"

# --- owsec credentials ------------------------------------------

# Aura treats OWSEC_USERNAME and OWSEC_PASSWORD as required and will not
# start without them, so this has to happen before the aura-cloud check
# below. Kept in its own script so it can be re-run on its own if the
# owsec credentials ever need to change.
step "Configuring owsec"

if ! ./bootstrap_owsec.sh; then
	warn "owsec configuration did not complete"
	info ""
	info "The stack is running but Aura cannot manage devices yet."
	info "Fix the problem above, then run:"
	info "  ./bootstrap_owsec.sh"
	exit 1
fi

# --- final check ------------------------------------------------

step "Waiting for Aura"

# Aura restarts on failure rather than exiting, so a misconfiguration
# looks like "still starting". Check the log for the listening line.
if ! wait_for "aura-cloud" "dc logs --tail=40 aura-cloud 2>/dev/null | grep -qiE 'listening|serving on|http server'" 45; then
	warn "aura-cloud has not reported ready. Recent output:"
	dc logs --tail=20 aura-cloud | sed 's/^/      /'
fi

# --- summary ----------------------------------------------------

# Addresses depend on the deployment. With traefik the interfaces are
# on the standard ports under their own hostnames; without it they are
# on the ports the containers publish directly.
if [ "$TLS_MODE" = "letsencrypt" ]; then
	AURA_URL="https://${AURA_HOST}"
	OPENWIFI_URL="https://${PUBLIC_HOST}"
else
	AURA_URL="http://${PUBLIC_HOST}:9090"
	OPENWIFI_URL="https://${PUBLIC_HOST}"
fi

step "Done"

cat <<EOF

  Aura Cloud     ${AURA_URL}
  OpenWiFi UI    ${OPENWIFI_URL}

  Administrator  ${ADMIN_EMAIL}
  AI assistant   $([ -n "$GROQ_API_KEY" ] && echo "on (Groq)" || echo "off, enable with ./ai_setup.sh")
EOF

if [ "$GENERATED_ADMIN_PW" -eq 1 ]; then
	cat <<EOF
  Password       ${ADMIN_PASSWORD}

  This password is shown once. It is also in ${ENV_FILE}.
EOF
fi

cat <<EOF

EOF

if [ "$TLS_MODE" = "selfsigned" ]; then
	cat <<EOF

  The certificates are self-signed, so browsers warn on first visit.
  The OpenWiFi UI also calls owsec on a separate port, which the
  browser treats as a separate site. Visit this once and accept the
  warning, or every login will fail:

    https://${PUBLIC_HOST}:16001/api/v1/systemEndpoints
EOF
fi

cat <<EOF

  Logs:   dc logs -f aura-cloud
  Status: ./status.sh
  Stop:   ./stop_aura.sh
  Start:  ./start_aura.sh

EOF
