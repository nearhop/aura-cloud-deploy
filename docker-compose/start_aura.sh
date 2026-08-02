#!/usr/bin/env bash
#
# start_aura.sh - start the Aura Cloud stack.
#
set -euo pipefail
cd "$(dirname "$0")"

# shellcheck disable=SC1091
. ./common.sh

if [ ! -f aura-cloud.env ]; then
	echo "  ERROR aura-cloud.env not found. Run ./install.sh first." >&2
	exit 1
fi

dc up -d

echo
echo "  Started. Check status with ./status.sh"
echo "  Logs:  dc logs -f aura-cloud"
echo
