#!/usr/bin/env bash
#
# tmate_setup.sh - prepare the self-hosted tmate server for the AP
# debug shell.
#
# Usage: ./tmate_setup.sh <host>
#
#   <host>  the name or IP the APs (and operators) use to reach this
#           machine. It ends up in the "ssh ...@<host>" string the UI
#           shows, so it must work from both sides.
#
# The public ssh.tmate.io server no longer resolves, so APs need a
# server of our own. This script:
#   1. creates host keys in tmate_data/keys (once; reruns keep them,
#      since changing them breaks every AP until aura-cloud restarts),
#   2. writes TMATE_HOST to the compose env file, where the tmate
#      service reads it,
#   3. writes TMATE_* to aura-cloud.env, where aura-cloud reads them to
#      point the APs at this server and pin its host keys.
#
# Then: dc up -d tmate && dc up -d --force-recreate aura-cloud
#
set -euo pipefail
cd "$(dirname "$0")"

# shellcheck disable=SC1091
. ./common.sh

ok()   { printf '  ok    %s\n' "$*"; }
fail() { printf '  ERROR %s\n' "$*" >&2; exit 1; }

HOST="${1:-}"
[ -n "$HOST" ] || fail "usage: $0 <host the APs use to reach this machine>"
[[ "$HOST" =~ ^[A-Za-z0-9.:-]+$ ]] || fail "invalid host: $HOST"
PORT=2200

command -v ssh-keygen >/dev/null || fail "ssh-keygen not found (apt install openssh-client)"
[ -f aura-cloud.env ] || fail "aura-cloud.env not found. Run ./install.sh first."

KEYS=tmate_data/keys
mkdir -p "$KEYS"
for t in rsa ed25519; do
	k="$KEYS/ssh_host_${t}_key"
	if [ -f "$k" ]; then
		ok "keeping existing $k"
	else
		ssh-keygen -q -t "$t" -N '' -f "$k"
		ok "generated $k"
	fi
done

fp() { ssh-keygen -l -E SHA256 -f "$1.pub" | cut -d' ' -f2; }
RSA_FP=$(fp "$KEYS/ssh_host_rsa_key")
ED_FP=$(fp "$KEYS/ssh_host_ed25519_key")

# set_var FILE NAME VALUE - replace NAME=... if present, else append.
set_var() {
	if grep -q "^$2=" "$1"; then
		sed -i "s|^$2=.*|$2=$3|" "$1"
	else
		printf '%s=%s\n' "$2" "$3" >> "$1"
	fi
}

set_var "$COMPOSE_ENV" TMATE_HOST "$HOST"
ok "$COMPOSE_ENV: TMATE_HOST=$HOST"

grep -q '^# --- AP debug shell' aura-cloud.env ||
	printf '\n# --- AP debug shell (tmate_setup.sh) ----------------------\n' >> aura-cloud.env
set_var aura-cloud.env TMATE_HOST "$HOST"
set_var aura-cloud.env TMATE_PORT "$PORT"
set_var aura-cloud.env TMATE_RSA_FINGERPRINT "$RSA_FP"
set_var aura-cloud.env TMATE_ED25519_FINGERPRINT "$ED_FP"
ok "aura-cloud.env: TMATE_HOST, TMATE_PORT, TMATE_*_FINGERPRINT"

echo
echo "  Next:"
echo "    allow inbound TCP ${PORT} on this machine's firewall"
echo "    . ./common.sh && dc up -d tmate && dc up -d --force-recreate aura-cloud"
echo
