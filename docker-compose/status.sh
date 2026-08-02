#!/usr/bin/env bash
#
# status.sh - show what is running and check the things that commonly
# go wrong.
#
set -uo pipefail
cd "$(dirname "$0")"

# shellcheck disable=SC1091
. ./common.sh

ok()   { printf '  ok    %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*"; }
warn() { printf '  warn  %s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }

printf '\n  deployment: %s (%s)\n' "$TLS_MODE" "$COMPOSE_FILE"

step "Containers"
dc ps --format 'table {{.Service}}\t{{.Status}}' 2>/dev/null | sed 's/^/  /'

step "Checks"

# Postgres
if dc exec -T postgresql pg_isready -U postgres >/dev/null 2>&1; then
	ok "postgres accepting connections"
else
	bad "postgres not ready"
fi

# Aura's database and the extension its first migration needs
DB_NAME=$(grep -E '^DB_NAME=' aura-cloud.env 2>/dev/null | cut -d= -f2)
DB_NAME="${DB_NAME:-nearhop}"
if dc exec -T postgresql psql -U postgres -lqt 2>/dev/null | cut -d'|' -f1 | grep -qw "$DB_NAME"; then
	ok "database ${DB_NAME} exists"
	if dc exec -T postgresql psql -U postgres -d "$DB_NAME" -tAc \
		"SELECT 1 FROM pg_extension WHERE extname='vector'" 2>/dev/null | grep -q 1; then
		ok "vector extension installed"
	else
		bad "vector extension missing in ${DB_NAME}"
	fi
else
	bad "database ${DB_NAME} does not exist"
fi

# owsec has a user to authenticate against. An empty users table is the
# symptom of a reset that left */persist/registry.json in place.
COUNT=$(dc exec -T postgresql psql -U owsec -d owsec -tAc \
	'SELECT count(*) FROM users' 2>/dev/null | tr -d '[:space:]')
if [ "${COUNT:-0}" -gt 0 ]; then
	ok "owsec has ${COUNT} user(s)"
else
	bad "owsec has no users"
	echo "        A wipe that leaves */persist/registry.json behind stops"
	echo "        owsec reseeding its default account. Use ./reset.sh."
fi

# Aura HTTP
PORT=$(grep -E '^SERVER_PORT=' aura-cloud.env 2>/dev/null | cut -d= -f2)
PORT="${PORT:-9090}"
# With traefik in front, aura-cloud publishes no port on the host, so it
# is checked from inside the network instead.
if [ "$TLS_MODE" = "letsencrypt" ]; then
	if dc exec -T owgw curl -sf "http://aura-cloud:${PORT}" -o /dev/null 2>/dev/null; then
		ok "aura-cloud responding"
	else
		bad "aura-cloud not responding"
		echo "        ./status.sh cannot reach it; check dc logs aura-cloud"
	fi
elif curl -sf "http://127.0.0.1:${PORT}" -o /dev/null 2>&1; then
	ok "aura-cloud responding on ${PORT}"
else
	bad "aura-cloud not responding on ${PORT}"
	echo "        dc logs --tail=30 aura-cloud"
fi

# owgw southbound: the port APs connect to
if ss -tln 2>/dev/null | grep -qE '[^0-9]15002\b'; then
	ok "owgw southbound listening on 15002"
else
	bad "nothing listening on 15002; APs cannot connect"
fi

echo
