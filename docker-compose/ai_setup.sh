#!/usr/bin/env bash
#
# ai_setup.sh - turn the Aura AI assistant on or off.
#
# Usage:
#   ./ai_setup.sh          ask for a Groq API key, check it, enable
#   ./ai_setup.sh --off    remove the key, disable
#
# For scripts, the key can be passed in the environment instead of being
# typed:  GROQ_API_KEY=gsk_... ./ai_setup.sh
# It is never taken as an argument, which would leave it in the shell
# history and in the process list.
#
# The assistant sends questions, and the network data needed to answer
# them, to Groq. Aura reads the key only at start-up, so the container is
# recreated at the end.
#
set -euo pipefail
cd "$(dirname "$0")"

# shellcheck disable=SC1091
. ./common.sh

ok()   { printf '  ok    %s\n' "$*"; }
warn() { printf '  warn  %s\n' "$*" >&2; }
fail() { printf '  ERROR %s\n' "$*" >&2; exit 1; }

ENV_FILE=aura-cloud.env
[ -f "$ENV_FILE" ] || fail "$ENV_FILE not found. Run ./install.sh first."

# set_key VALUE - replace GROQ_API_KEY=... if present, else append.
set_key() {
	if grep -q '^GROQ_API_KEY=' "$ENV_FILE"; then
		sed -i "s|^GROQ_API_KEY=.*|GROQ_API_KEY=$1|" "$ENV_FILE"
	else
		printf '\n# --- AI assistant (ai_setup.sh) ------------------------------\nGROQ_API_KEY=%s\n' "$1" >> "$ENV_FILE"
	fi
}

restart_aura() {
	dc up -d --force-recreate aura-cloud >/dev/null
	ok "aura-cloud restarted"
}

if [ "${1:-}" = "--off" ]; then
	set_key ""
	ok "AI assistant disabled in $ENV_FILE"
	restart_aura
	exit 0
fi
[ -z "${1:-}" ] || fail "usage: $0 [--off]"

KEY="${GROQ_API_KEY:-}"
if [ -z "$KEY" ]; then
	echo "  Get a key at https://console.groq.com/keys"
	read -r -s -p "  Groq API key: " KEY; echo
fi
[ -n "$KEY" ] || fail "no key given. Nothing changed."
[[ "$KEY" =~ ^[A-Za-z0-9_-]+$ ]] || fail "that does not look like an API key. Nothing changed."

# Check the key before restarting anything. The header is passed on stdin
# so the key does not appear in the process list. A network failure is
# not proof the key is bad, so it only warns.
CODE=$(printf 'Authorization: Bearer %s\n' "$KEY" |
	curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H @- \
		https://api.groq.com/openai/v1/models) || CODE=000
case "$CODE" in
	200) ok "Groq accepted the key" ;;
	401|403) fail "Groq rejected the key (HTTP $CODE). Nothing changed." ;;
	000) warn "could not reach api.groq.com from this host. Saving the key anyway; the assistant will fail until Aura can reach it." ;;
	*) warn "unexpected answer from Groq (HTTP $CODE). Saving the key anyway." ;;
esac

set_key "$KEY"
chmod 600 "$ENV_FILE"
ok "key saved in $ENV_FILE"
restart_aura

echo
echo "  Reload the Aura interface. The assistant panel appears for every signed-in user."
echo
