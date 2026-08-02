#!/usr/bin/env bash
#
# update_aura.sh - move aura-cloud to the release named by AURA_TAG.
#
# The binary is downloaded when the image is built, so changing the tag
# has no effect until the image is rebuilt and the container recreated.
# A plain restart keeps running the old one.
#
set -euo pipefail
cd "$(dirname "$0")"

# shellcheck disable=SC1091
. ./common.sh

ok()   { printf '  ok    %s\n' "$*"; }
warn() { printf '  warn  %s\n' "$*" >&2; }
fail() { printf '  ERROR %s\n' "$*" >&2; exit 1; }
step() { printf '\n== %s\n' "$*"; }

[ -f aura-cloud.env ] || fail "aura-cloud.env not found. Run ./install.sh first."

# The image downloads the binary at build time, so moving to another
# release is a matter of changing AURA_TAG and rebuilding. --no-cache on
# the download layer would be needed only if the same tag were
# republished with different contents.
AURA_TAG=$(grep -E '^AURA_TAG=' "$COMPOSE_ENV" 2>/dev/null | cut -d= -f2) || true
[ -n "${AURA_TAG:-}" ] || fail "AURA_TAG is not set in ${COMPOSE_ENV}"

step "Updating to ${AURA_TAG}"

RUNNING=$(dc exec -T aura-cloud /usr/local/bin/aura-cloud --version 2>/dev/null) || true
[ -n "${RUNNING:-}" ] && ok "currently running: ${RUNNING}"

step "Rebuilding the image"
dc build aura-cloud

step "Restarting"
dc up -d --force-recreate aura-cloud

step "Done"
echo
echo "  dc logs --tail=30 -f aura-cloud"
echo
