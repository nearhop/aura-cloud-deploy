#!/usr/bin/env bash
#
# stop_aura.sh - stop the Aura Cloud stack.
#
# Containers are stopped but not removed, and no data is deleted.
# Use reset.sh to wipe everything.
#
set -euo pipefail
cd "$(dirname "$0")"

# shellcheck disable=SC1091
. ./common.sh

dc down

echo
echo "  Stopped. Data is preserved; start again with ./start_aura.sh"
echo
