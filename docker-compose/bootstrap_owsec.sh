#!/usr/bin/env bash
#
# bootstrap_owsec.sh - complete owsec's first-login setup.
#
# owsec ships with a default account that must change its password
# before it can be used. This does that, then creates a separate
# service account for Aura and writes the credentials into
# aura-cloud.env.
#
# Safe to re-run: if the default password has already been changed, it
# asks for the current one instead.
#
set -euo pipefail

cd "$(dirname "$0")"

# shellcheck disable=SC1091
. ./common.sh

ENV_FILE="aura-cloud.env"
DEFAULT_USER="tip@ucentral.com"
DEFAULT_PASS="openwifi"

# owsec validates the email domain and rejects anything without a dot,
# so "aura-service@localhost" fails with error 1011. Borrow the domain
# from the administrator account, which owsec has already accepted.
SERVICE_DOMAIN="${DEFAULT_USER#*@}"
SERVICE_USER="aura-service@${SERVICE_DOMAIN}"

info()  { printf '  %s\n' "$*"; }
ok()    { printf '  ok    %s\n' "$*"; }
warn()  { printf '  warn  %s\n' "$*" >&2; }
fail()  { printf '  ERROR %s\n' "$*" >&2; exit 1; }
step()  { printf '\n== %s\n' "$*"; }

[ -f "$ENV_FILE" ] || fail "$ENV_FILE not found. Run ./install.sh first."

# Address shown to the user for the OpenWiFi UI. PUBLIC_HOST comes from
# deploy.conf via common.sh, which install.sh writes.
UI_HOST="${PUBLIC_HOST:-$(hostname -f 2>/dev/null || hostname)}"

gen_password() { printf '%s' "$(openssl rand -base64 12 | tr -d '/+=' | cut -c1-14)Aa1@"; }

password_classes() {
	local pw="$1" n=0
	[[ "$pw" =~ [a-z] ]] && n=$((n+1))
	[[ "$pw" =~ [A-Z] ]] && n=$((n+1))
	[[ "$pw" =~ [0-9] ]] && n=$((n+1))
	[[ "$pw" =~ [^a-zA-Z0-9] ]] && n=$((n+1))
	printf '%s' "$n"
}

# POST to owsec's oauth2 endpoint. Echoes the response body.
owsec_login() {
	local user="$1" pass="$2" newpass="${3:-}"
	local body
	if [ -n "$newpass" ]; then
		body=$(printf '{"userId":"%s","password":"%s","newPassword":"%s"}' "$user" "$pass" "$newpass")
	else
		body=$(printf '{"userId":"%s","password":"%s"}' "$user" "$pass")
	fi
	owsec_curl -X POST "${OWSEC_URL}/api/v1/oauth2" \
		-H 'Content-Type: application/json' -d "$body"
}

json_field() { grep -o "\"$1\":\"[^\"]*" | cut -d'"' -f4; }

# --- wait for owsec ---------------------------------------------

step "Waiting for owsec"

for i in $(seq 1 60); do
	if owsec_curl "${OWSEC_URL}/api/v1/oauth2" -o /dev/null; then
		ok "owsec is responding"
		break
	fi
	[ "$i" -eq 60 ] && fail "owsec did not respond on ${OWSEC_URL}"
	sleep 2
done

# --- admin password ---------------------------------------------

step "owsec administrator"

RESP=$(owsec_login "$DEFAULT_USER" "$DEFAULT_PASS")

if echo "$RESP" | grep -q '"ErrorCode":1'; then
	# Error 1 is "password change required": this is a fresh install.
	info "This owsec install still has its default password."
	info "New password must be at least 8 characters and include 3 of:"
	info "lowercase, uppercase, digit, special character."
	info "Leave blank to generate one."

	GENERATED=0
	while true; do
		read -r -s -p "  New owsec administrator password: " ADMIN_PW; echo

		if [ -z "$ADMIN_PW" ]; then
			ADMIN_PW="$(gen_password)"
			GENERATED=1
			ok "generated"
			break
		fi

		if [ "${#ADMIN_PW}" -lt 8 ]; then
			warn "too short: needs at least 8 characters. Try again."
			continue
		fi

		if [ "$(password_classes "$ADMIN_PW")" -lt 3 ]; then
			warn "needs 3 of: lowercase, uppercase, digit, special. Try again."
			continue
		fi

		read -r -s -p "  Confirm password: " ADMIN_PW2; echo
		if [ "$ADMIN_PW" != "$ADMIN_PW2" ]; then
			warn "passwords do not match. Try again."
			continue
		fi

		break
	done

	RESP=$(owsec_login "$DEFAULT_USER" "$DEFAULT_PASS" "$ADMIN_PW")
	TOKEN=$(echo "$RESP" | json_field access_token)
	if [ -z "$TOKEN" ]; then
		warn "owsec rejected the new password:"
		info "$RESP"
		fail "try again with a different password"
	fi
	ok "administrator password set"

elif echo "$RESP" | grep -q '"access_token"'; then
	warn "owsec still has its default password and does not require a change"
	TOKEN=$(echo "$RESP" | json_field access_token)
	ADMIN_PW="$DEFAULT_PASS"
	GENERATED=0

else
	# Already configured, or the account is locked out.
	info "owsec no longer accepts the default password."
	GENERATED=0
	ATTEMPTS=0
	while true; do
		read -r -s -p "  Current owsec administrator password: " ADMIN_PW; echo
		RESP=$(owsec_login "$DEFAULT_USER" "$ADMIN_PW")
		TOKEN=$(echo "$RESP" | json_field access_token)
		[ -n "$TOKEN" ] && break

		ATTEMPTS=$((ATTEMPTS+1))
		warn "login failed"
		# owsec suspends an account after repeated failures, so stop
		# before making the situation worse.
		if [ "$ATTEMPTS" -ge 3 ]; then
			info "$RESP"
			fail "could not log in to owsec.
        If the account is locked out after repeated failures, clear it
        with:
          dc exec postgresql psql -U owsec -d owsec \\
            -c \"UPDATE users SET suspended=false WHERE email='${DEFAULT_USER}';\""
		fi
		info "Try again ($((3 - ATTEMPTS)) attempts left)."
	done
	ok "logged in"
fi

# --- service account --------------------------------------------

step "Aura service account"

# A dedicated account, so rotating a human administrator's password
# does not take Aura offline with it.

# On a re-run the account already exists with a password only
# aura-cloud.env knows. Try that first: if it still works there is
# nothing to do.
#
# Only reuse credentials that belong to the service account. A previous
# run may have fallen back to the administrator account, and reusing
# that would make the fallback permanent: the script would never try to
# create a proper service account again.
EXISTING_USER=$(grep -E '^OWSEC_USERNAME=' "$ENV_FILE" | cut -d= -f2-)
EXISTING_PW=$(grep -E '^OWSEC_PASSWORD=' "$ENV_FILE" | cut -d= -f2-)

REUSED=0
if [ "$EXISTING_USER" = "$SERVICE_USER" ] && [ -n "$EXISTING_PW" ]; then
	if owsec_login "$EXISTING_USER" "$EXISTING_PW" | grep -q '"access_token"'; then
		SERVICE_PW="$EXISTING_PW"
		REUSED=1
		ok "existing credentials for ${SERVICE_USER} still work"
	fi
elif [ -n "$EXISTING_USER" ]; then
	info "${ENV_FILE} currently uses ${EXISTING_USER}; switching to a service account"
fi

if [ "$REUSED" -eq 0 ]; then
	SERVICE_PW="$(gen_password)"

	CREATE=$(owsec_curl -X POST "${OWSEC_URL}/api/v1/user/0" \
		-H "Authorization: Bearer ${TOKEN}" \
		-H 'Content-Type: application/json' \
		-d "$(printf '{"email":"%s","currentPassword":"%s","userRole":"root","name":"Aura Service","description":"Used by Aura Cloud","changePassword":false}' \
			"$SERVICE_USER" "$SERVICE_PW")")

	# owsec returns the created user object on success. Match the
	# lowercase "id" field it actually emits, together with the email,
	# so a partial or error response is not mistaken for success.
	if echo "$CREATE" | grep -q '"id":"' && echo "$CREATE" | grep -q "\"email\":\"${SERVICE_USER}\""; then
		ok "created ${SERVICE_USER}"

	# A duplicate email also fails, and owsec does not distinguish it in
	# the response. Look the account up: if it exists, remove it and try
	# once more with the new password. grep exits non-zero when it finds
	# nothing, so the pipeline is guarded against set -e.
	elif echo "$CREATE" | grep -q '"ErrorCode"'; then
		USER_ID=$(owsec_curl "${OWSEC_URL}/api/v1/users" \
			-H "Authorization: Bearer ${TOKEN}" \
			| tr '{' '\n' | grep "\"email\":\"${SERVICE_USER}\"" \
			| grep -o '"id":"[^"]*' | head -1 | cut -d'"' -f4) || true

		if [ -n "${USER_ID:-}" ]; then
			info "${SERVICE_USER} exists with an unknown password; recreating"

			owsec_curl -X DELETE "${OWSEC_URL}/api/v1/user/${USER_ID}" \
				-H "Authorization: Bearer ${TOKEN}" >/dev/null || true

			CREATE=$(owsec_curl -X POST "${OWSEC_URL}/api/v1/user/0" \
				-H "Authorization: Bearer ${TOKEN}" \
				-H 'Content-Type: application/json' \
				-d "$(printf '{"email":"%s","currentPassword":"%s","userRole":"root","name":"Aura Service","description":"Used by Aura Cloud","changePassword":false}' \
					"$SERVICE_USER" "$SERVICE_PW")")

			if echo "$CREATE" | grep -q '"id":"'; then
				ok "recreated ${SERVICE_USER}"
			else
				warn "could not recreate the account; using the administrator account"
				info "response: $CREATE"
				SERVICE_USER="$DEFAULT_USER"
				SERVICE_PW="$ADMIN_PW"
			fi
		else
			warn "owsec rejected the new account; using the administrator account"
			info "response: $CREATE"
			SERVICE_USER="$DEFAULT_USER"
			SERVICE_PW="$ADMIN_PW"
		fi

	else
		warn "unexpected response creating the service account"
		info "response: $CREATE"
		SERVICE_USER="$DEFAULT_USER"
		SERVICE_PW="$ADMIN_PW"
	fi
fi

# Confirm the credentials Aura is about to be given actually work.
# Skipped when they were reused above, since that path already tested
# them.
if [ "$REUSED" -eq 0 ]; then
	VERIFY=$(owsec_login "$SERVICE_USER" "$SERVICE_PW")
	echo "$VERIFY" | grep -q '"access_token"' \
		|| fail "the service account cannot log in:
        $VERIFY"
	ok "credentials verified"
fi

# --- write to aura-cloud.env ------------------------------------

step "Updating $ENV_FILE"

sed -i "s|^OWSEC_USERNAME=.*|OWSEC_USERNAME=${SERVICE_USER}|" "$ENV_FILE"
sed -i "s|^OWSEC_PASSWORD=.*|OWSEC_PASSWORD=${SERVICE_PW}|" "$ENV_FILE"
ok "written"

# env_file is read when a container is created, not when it restarts,
# so the container has to be replaced for this to take effect.
step "Restarting aura-cloud"
dc up -d --force-recreate aura-cloud >/dev/null
ok "restarted"

step "Done"

cat <<EOF

  OpenWiFi UI

    Use these to sign in to the OpenWiFi interface.

    Address     https://${UI_HOST}
    Username    ${DEFAULT_USER}
EOF

if [ "${GENERATED:-0}" -eq 1 ]; then
	cat <<EOF
    Password    ${ADMIN_PW}

    This password is shown once. Store it somewhere safe.
EOF
else
	cat <<EOF
    Password    the one you entered above
EOF
fi

cat <<EOF

  Aura service account

    Used by Aura to call the OpenWiFi services. Not for signing in.
    Changing or deleting it stops Aura managing devices. It is stored
    in ${ENV_FILE}.

    Username    ${SERVICE_USER}

  Check Aura picked up the credentials:
    dc logs --tail=20 aura-cloud

EOF
