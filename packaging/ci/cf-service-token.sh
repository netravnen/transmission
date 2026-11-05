#!/usr/bin/env bash
# Create or rotate the Cloudflare Access service token that GitHub Actions on
# this fork uses to clone the dht and libutp submodules from the forge, and
# store its two halves as the repository secrets CF_ACCESS_CLIENT_ID and
# CF_ACCESS_CLIENT_SECRET (see FORK.md, Setup).
#
# The values go from the Cloudflare API response straight into
# "gh secret set" on stdin. They are never printed, passed as arguments or
# written to disk.
#
# Needs: bash, curl, python3 (or python), and gh logged in with admin rights
# on the GitHub repository.
#
# Environment:
#   CLOUDFLARE_API_TOKEN  API token with "Access: Service Tokens: Edit" and,
#                         for "create", "Access: Apps and Policies: Edit".
#   CF_ACCOUNT_ID         Cloudflare account ID.
#   CF_ACCESS_APP_ID      "create" only: the Access application that protects
#                         the forge's dht and libutp repositories.
#   REPO                  GitHub repository (default netravnen/transmission).
#   TOKEN_NAME            Service token name (default gh-actions-transmission-fork).
#   TOKEN_DURATION        "create" only: token lifetime (default 8760h).
#
# Usage:
#   cf-service-token.sh create   new token, a Service Auth policy, both secrets
#   cf-service-token.sh rotate   new client secret for the token, one secret
#   cf-service-token.sh status   token ID and expiry, no secrets
set -euo pipefail

REPO=${REPO:-netravnen/transmission}
NAME=${TOKEN_NAME:-gh-actions-transmission-fork}
DURATION=${TOKEN_DURATION:-8760h}
: "${CLOUDFLARE_API_TOKEN:?set CLOUDFLARE_API_TOKEN}"
API="https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID:?set CF_ACCOUNT_ID}"
# The first Python that runs: on Windows, "python3" can be a Store alias.
PY=
for p in python3 python; do
	if "$p" -c '' >/dev/null 2>&1; then PY=$p; break; fi
done
[ -n "$PY" ] || { echo "python3 is required" >&2; exit 1; }

# curl reads the API token from the environment (--variable, curl 8.3 or
# later), so it is in no argument and no file.
curl --help all 2>/dev/null | grep -q -- '--expand-header\|--variable' \
	|| { echo "curl 8.3 or later is required (--variable)" >&2; exit 1; }

# cf METHOD PATH [JSON]: one API call.
cf() {
	local args=(-sS -X "$1" "$API$2"
		--variable '%CLOUDFLARE_API_TOKEN'
		--expand-header 'Authorization: Bearer {{CLOUDFLARE_API_TOKEN}}')
	if [ $# -ge 3 ]; then
		args+=(-H 'Content-Type: application/json' --data-binary @-)
		printf '%s' "$3" | curl "${args[@]}"
	else
		curl "${args[@]}"
	fi
}

# field NAME: print result[NAME] of the API response on stdin, with no
# newline. Fails with the API's error messages when the call failed.
field() {
	"$PY" -c '
import json, sys
d = json.load(sys.stdin)
if not d.get("success"):
    sys.exit("Cloudflare API error: %s" % "; ".join(e.get("message", "?") for e in d.get("errors", [])))
r = d["result"]
if isinstance(r, list):
    sys.exit("unexpected list result")
sys.stdout.write(str(r[sys.argv[1]]))
' "$1"
}

# token_id: the ID of the token named $NAME, or nothing.
token_id() {
	cf GET "/access/service_tokens?name=$NAME" | "$PY" -c '
import json, sys
d = json.load(sys.stdin)
if not d.get("success"):
    sys.exit("Cloudflare API error: %s" % "; ".join(e.get("message", "?") for e in d.get("errors", [])))
ids = [t["id"] for t in d["result"] if t.get("name") == sys.argv[1]]
if len(ids) > 1:
    sys.exit("more than one service token is named %s" % sys.argv[1])
sys.stdout.write(ids[0] if ids else "")
' "$NAME"
}

json() { # json KEY=VALUE...: a flat JSON object of strings
	"$PY" -c 'import json, sys; print(json.dumps(dict(a.split("=", 1) for a in sys.argv[1:])))' "$@"
}

case "${1:-}" in
create)
	: "${CF_ACCESS_APP_ID:?set CF_ACCESS_APP_ID}"
	if [ -n "$(token_id)" ]; then
		echo "A service token named $NAME exists already. Use \"rotate\"." >&2
		exit 1
	fi
	resp=$(cf POST /access/service_tokens "$(json name="$NAME" duration="$DURATION")")
	id=$(printf '%s' "$resp" | field id)
	printf '%s' "$resp" | field client_id | gh secret set CF_ACCESS_CLIENT_ID -R "$REPO"
	printf '%s' "$resp" | field client_secret | gh secret set CF_ACCESS_CLIENT_SECRET -R "$REPO"
	unset resp
	policy=$("$PY" -c '
import json, sys
print(json.dumps({
    "name": "Service Auth: GitHub Actions (%s)" % sys.argv[2],
    "decision": "non_identity",
    "include": [{"service_token": {"token_id": sys.argv[1]}}],
}))' "$id" "$REPO")
	cf POST "/access/apps/$CF_ACCESS_APP_ID/policies" "$policy" | field id >/dev/null
	echo "Created service token $NAME ($id), added a Service Auth policy to"
	echo "Access application $CF_ACCESS_APP_ID, and set CF_ACCESS_CLIENT_ID and"
	echo "CF_ACCESS_CLIENT_SECRET on $REPO."
	;;
rotate)
	id=$(token_id)
	if [ -z "$id" ]; then
		echo "No service token named $NAME. Use \"create\"." >&2
		exit 1
	fi
	cf POST "/access/service_tokens/$id/rotate" | field client_secret | gh secret set CF_ACCESS_CLIENT_SECRET -R "$REPO"
	echo "Rotated the client secret of $NAME ($id) and updated CF_ACCESS_CLIENT_SECRET"
	echo "on $REPO. The client ID is unchanged. The old secret stops working now."
	;;
status)
	id=$(token_id)
	if [ -z "$id" ]; then
		echo "No service token named $NAME."
		exit 1
	fi
	printf 'token %s (%s), expires ' "$NAME" "$id"
	cf GET "/access/service_tokens/$id" | field expires_at
	echo
	gh secret list -R "$REPO" | grep -E '^CF_ACCESS_CLIENT_(ID|SECRET)\b' || echo "no CF_ACCESS_* secrets on $REPO"
	;;
*)
	sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'
	exit 2
	;;
esac
