#!/usr/bin/env bash
#
# reset.sh - remove data and configuration.
#
# Usage:
#   ./reset.sh                 remove everything
#   ./reset.sh --keep-config   remove data, keep aura-cloud.env
#   ./reset.sh --owsec-only    reissue the Aura service account only,
#                              leaving devices and history untouched
#
# A full reset stops the stack, deletes the database volumes, and clears
# the per-service state files under */persist/.
#
# Those state files live on the host, not in a volume, so
# "dc down -v" alone does not remove them. owsec records
# defaultusercreated=true in its registry.json, and will not recreate
# its administrator account on a fresh database while that flag is set.
# The result is a stack that starts cleanly but rejects every login.
#
set -euo pipefail
cd "$(dirname "$0")"

# shellcheck disable=SC1091
. ./common.sh

KEEP_CONFIG=0
OWSEC_ONLY=0
for arg in "$@"; do
	case "$arg" in
		--keep-config) KEEP_CONFIG=1 ;;
		--owsec-only)  OWSEC_ONLY=1 ;;
		-h|--help) sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	esac
done

# --- service account only ---------------------------------------

# Clears just the Aura service account and the credentials that refer
# to it, so bootstrap_owsec.sh can issue a fresh pair. Nothing else is
# touched: devices, venues and history are left alone.
#
# Needed when a previous bootstrap fell back to the administrator
# account, or when the generated password was lost.
if [ "$OWSEC_ONLY" -eq 1 ]; then
	# Must match the address bootstrap_owsec.sh derives. owsec rejects
	# email domains without a dot, so the domain is taken from the
	# default administrator account.
	SERVICE_USER="aura-service@ucentral.com"

	echo
	echo "  Removing the Aura service account and its stored credentials."
	echo "  Devices and history are not affected."
	echo

	if ! dc ps --status running --services 2>/dev/null | grep -q postgresql; then
		echo "  ERROR the stack is not running. Start it first:" >&2
		echo "        ./start_aura.sh" >&2
		exit 1
	fi

	dc exec -T postgresql psql -U owsec -d owsec \
		-c "DELETE FROM users WHERE email='${SERVICE_USER}';" >/dev/null 2>&1 \
		&& echo "  removed ${SERVICE_USER} from owsec" \
		|| echo "  warn  could not remove ${SERVICE_USER} (it may not exist)"

	if [ -f aura-cloud.env ]; then
		sed -i 's|^OWSEC_USERNAME=.*|OWSEC_USERNAME=|; s|^OWSEC_PASSWORD=.*|OWSEC_PASSWORD=|' aura-cloud.env
		echo "  cleared the owsec credentials in aura-cloud.env"
	fi

	echo
	echo "  Done. Reissue them with:"
	echo "    ./bootstrap_owsec.sh"
	echo
	exit 0
fi

# --- full reset -------------------------------------------------

echo
echo "  This deletes all devices, users, history and configuration."
echo
read -r -p "  Type 'reset' to confirm: " CONFIRM
[ "$CONFIRM" = "reset" ] || { echo "  Cancelled."; exit 1; }

echo
echo "  Stopping and removing volumes"
dc down -v

echo "  Clearing service state"

# The OpenWiFi services write these as root, so a non-root user cannot
# remove them directly. They matter: owsec records
# defaultusercreated=true in registry.json and will not recreate its
# administrator account on a fresh database while that flag is present.
STATE_FILES=$(ls ./*_data/persist/registry.json ./*_data/persist/secrets.json 2>/dev/null) || true

if [ -n "$STATE_FILES" ]; then
	if ! rm -f $STATE_FILES 2>/dev/null; then
		echo "  Some state files are owned by root; removing with sudo"
		sudo rm -f $STATE_FILES
	fi
fi

# Confirm, because a leftover registry.json produces a stack that starts
# cleanly and then rejects every login.
LEFT=$(ls ./*_data/persist/registry.json 2>/dev/null) || true
if [ -n "$LEFT" ]; then
	echo
	echo "  WARNING: could not remove:"
	echo "$LEFT" | sed 's/^/    /'
	echo "  Remove them manually or owsec will not recreate its"
	echo "  administrator account:"
	echo "    sudo rm -f ./*_data/persist/registry.json"
	echo
fi

if [ "$KEEP_CONFIG" -eq 0 ]; then
	echo "  Removing aura-cloud.env and deploy.conf"
	rm -f aura-cloud.env deploy.conf
	# The Aura database credentials were appended by install.sh and are
	# regenerated on the next run.
	sed -i '/^AURA_DB/d' postgresql.env 2>/dev/null || true
	sed -i '/^$/{ /./!d }' postgresql.env 2>/dev/null || true
fi

echo
echo "  Done. Run ./install.sh to set up again."
echo
