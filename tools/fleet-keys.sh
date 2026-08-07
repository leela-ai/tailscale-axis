#!/usr/bin/env bash
#==============================================================================
#  File:         fleet-keys.sh
#  Description:  Issues one Tailscale auth key per row of a fleet plan file and
#                writes the key and its ID back into the plan.
#                • Keys are tagged, pre-authorized, single-use and persistent
#                • Rows that already hold a key are left alone, so a re-run
#                  after a partial failure does not burn keys
#                • --revoke deletes every key recorded in the plan
#
#  Usage:        ./fleet-keys.sh [options] <plan.csv>
#
#  Credentials:  Either an API key:
#                    export TS_API_KEY=tskey-api-...
#                or an OAuth client, which does not expire after 90 days:
#                    export TS_OAUTH_CLIENT_ID=...
#                    export TS_OAUTH_CLIENT_SECRET=tskey-client-...
#                Optionally TAILNET (default "-", meaning the tailnet that owns
#                the credential).
#
#  Examples:
#       export TS_API_KEY=tskey-api-abc123
#       ./fleet-keys.sh fleet.plan.csv
#       ./fleet-keys.sh --expiry-days 30 fleet.plan.csv
#       ./fleet-keys.sh --revoke fleet.plan.csv
#==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools/fleet-plan.lib.sh
. "${SCRIPT_DIR}/fleet-plan.lib.sh"

# Overridable so the tooling can be pointed at a self-hosted control server, and
# so the API paths can be exercised against a mock.
API_BASE="${TS_API_BASE:-https://api.tailscale.com}"
DEFAULT_EXPIRY_DAYS=90
CREATE_ATTEMPTS=3

#------------------------------------------------------------------------------
# Options
#------------------------------------------------------------------------------
PLAN_FILE=""
EXPIRY_DAYS="${DEFAULT_EXPIRY_DAYS}"
REUSABLE="false"
EPHEMERAL="false"
PREAUTHORIZED="true"
DRY_RUN="false"
REVOKE="false"

usage() {
    cat <<EOF
Usage: ${0##*/} [options] <plan.csv>

Issues one Tailscale auth key per device row in the plan file and writes the key
and its ID back into the plan. Rows that already have a key are skipped.

Options:
  --expiry-days <n>   Key lifetime in days (default: ${DEFAULT_EXPIRY_DAYS}). Only
                      constrains how long the key may be redeemed for; it does
                      not expire the device once authenticated.
  --reusable          Issue reusable keys instead of single-use.
  --ephemeral         Issue ephemeral keys. Not recommended for cameras: the node
                      is removed from the tailnet whenever it goes offline, and a
                      camera restarting after a power cut cannot re-authenticate
                      with a single-use key it has already consumed.
  --no-preauth        Do not pre-authorize devices, so each one needs manual
                      approval in the admin console.
  --revoke            Delete every key recorded in the plan and clear the key
                      columns. Does not remove already-authenticated devices.
  --dry-run           Validate the plan and report what would be done, without
                      calling the API or modifying the plan.
  -h, --help          Show this help and exit.

Credentials, from the environment:
  TS_API_KEY                          Tailscale API key (tskey-api-...), or
  TS_OAUTH_CLIENT_ID                  OAuth client ID plus
  TS_OAUTH_CLIENT_SECRET              OAuth client secret (tskey-client-...)
  TAILNET                             Tailnet name; default "-", the tailnet
                                      that owns the credential.
  TS_API_BASE                         API root; default https://api.tailscale.com.

Note: keys created by an OAuth client must be tagged, and the tags must be ones
the OAuth client is allowed to own. Tags are required by the plan format anyway.
EOF
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --expiry-days)
            [[ $# -lt 2 ]] && fatal "Missing value for $1"
            EXPIRY_DAYS="$2"; shift 2 ;;
        --reusable)   REUSABLE="true";      shift ;;
        --ephemeral)  EPHEMERAL="true";     shift ;;
        --no-preauth) PREAUTHORIZED="false"; shift ;;
        --revoke)     REVOKE="true";        shift ;;
        --dry-run)    DRY_RUN="true";       shift ;;
        -h|--help)    usage 0 ;;
        --)           shift; break ;;
        -*)           fatal "Unknown flag: $1 (see --help)" ;;
        *)
            [[ -n "${PLAN_FILE}" ]] && fatal "Unexpected argument: $1"
            PLAN_FILE="$1"; shift ;;
    esac
done

# Anything left came after a literal "--".
if [[ $# -gt 0 ]]; then
    [[ -n "${PLAN_FILE}" || $# -gt 1 ]] && fatal "Expected exactly one plan file, got: $*"
    PLAN_FILE="$1"
fi

[[ -n "${PLAN_FILE}" ]] || usage 1
[[ "${EXPIRY_DAYS}" =~ ^[0-9]+$ ]] || fatal "--expiry-days must be a non-negative integer"
EXPIRY_SECONDS=$((EXPIRY_DAYS * 86400))

need curl
need jq

TAILNET="${TAILNET:--}"

#------------------------------------------------------------------------------
# Credentials
#
# The credential is written to a curl config file rather than passed on the
# command line, so it never appears in the process arguments.
#------------------------------------------------------------------------------
CURL_CONF=""
cleanup() {
    if [[ -n "${CURL_CONF}" ]]; then
        rm -f "${CURL_CONF}"
    fi
}
trap cleanup EXIT INT TERM

# Runs curl against the API with credentials attached, appending the HTTP status
# code to the body as a final line so callers can distinguish retryable failures
# from permanent ones.
api() {
    curl --silent --show-error --config "${CURL_CONF}" \
         --write-out '\n%{http_code}' \
         --max-time 30 \
         "$@"
}

setup_credentials() {
    local conf
    local old_umask
    old_umask="$(umask)"
    umask 077
    conf="$(mktemp "${TMPDIR:-/tmp}/fleet-keys-curl.XXXXXX")" \
        || fatal "Unable to create a temporary credential file"
    umask "${old_umask}"
    CURL_CONF="${conf}"

    if [[ -n "${TS_OAUTH_CLIENT_ID:-}" || -n "${TS_OAUTH_CLIENT_SECRET:-}" ]]; then
        [[ -n "${TS_OAUTH_CLIENT_ID:-}" ]] \
            || fatal "TS_OAUTH_CLIENT_SECRET is set but TS_OAUTH_CLIENT_ID is not"
        [[ -n "${TS_OAUTH_CLIENT_SECRET:-}" ]] \
            || fatal "TS_OAUTH_CLIENT_ID is set but TS_OAUTH_CLIENT_SECRET is not"

        log "Exchanging OAuth client credentials for an access token"
        local body response status token
        # Through a pipe rather than -d on the command line, again to keep the
        # secret out of the process arguments. printf is a builtin, so the
        # secret is not exposed by building this string either.
        body="$(printf 'grant_type=client_credentials&client_id=%s&client_secret=%s' \
            "${TS_OAUTH_CLIENT_ID}" "${TS_OAUTH_CLIENT_SECRET}")"
        response="$(printf '%s' "${body}" \
            | curl --silent --show-error --max-time 30 --write-out '\n%{http_code}' \
                   -X POST --data-binary @- "${API_BASE}/api/v2/oauth/token" || true)"
        status="$(printf '%s' "${response}" | tail -n1)"
        token="$(printf '%s' "${response}" | sed '$d' | jq -r '.access_token // empty' 2>/dev/null || true)"
        [[ -n "${token}" ]] \
            || fatal "OAuth token request failed (HTTP ${status:-none}); check TS_OAUTH_CLIENT_ID and TS_OAUTH_CLIENT_SECRET"
        printf 'header = "Authorization: Bearer %s"\n' "${token}" >"${conf}"
        info "Authenticating as OAuth client ${TS_OAUTH_CLIENT_ID}"
    elif [[ -n "${TS_API_KEY:-}" ]]; then
        [[ "${TS_API_KEY}" == tskey-api-* ]] \
            || warn "TS_API_KEY does not look like tskey-api-...; continuing anyway"
        printf 'user = "%s:"\n' "${TS_API_KEY}" >"${conf}"
        info "Authenticating with TS_API_KEY"
    else
        fatal "No credentials. Set TS_API_KEY, or TS_OAUTH_CLIENT_ID and TS_OAUTH_CLIENT_SECRET (see --help)."
    fi
}

#------------------------------------------------------------------------------
# Key creation
#------------------------------------------------------------------------------

# Builds the create-key request body for the tags given as arguments. The shape
# matches Tailscale's own API client: reusable, ephemeral, tags and
# preauthorized live under capabilities.devices.create, while description and
# expirySeconds are top level.
create_key_payload() {
    jq -nc \
        --argjson reusable "${REUSABLE}" \
        --argjson ephemeral "${EPHEMERAL}" \
        --argjson preauthorized "${PREAUTHORIZED}" \
        --argjson expiry "${EXPIRY_SECONDS}" \
        --arg desc "${1}" \
        '{
            capabilities: {
                devices: {
                    create: {
                        reusable:      $reusable,
                        ephemeral:     $ephemeral,
                        preauthorized: $preauthorized,
                        tags:          ($ARGS.positional)
                    }
                }
            },
            expirySeconds: $expiry,
            description:   $desc
        }' --args "${@:2}"
}

# Creates one key and prints "<key_id> <authkey>". Retries only on transport
# failures, 429 and 5xx: retrying a request that may have succeeded would leave
# an unused key behind in the tailnet.
create_key() {
    local description="$1"; shift
    local payload response status body key_id authkey attempt=1

    payload="$(create_key_payload "${description}" "$@")"

    while :; do
        response="$(printf '%s' "${payload}" \
            | api -X POST -H 'Content-Type: application/json' --data-binary @- \
                  "${API_BASE}/api/v2/tailnet/${TAILNET}/keys" || true)"
        status="$(printf '%s' "${response}" | tail -n1)"
        body="$(printf '%s' "${response}" | sed '$d')"

        if [[ "${status}" == 2?? ]]; then
            key_id="$(printf '%s' "${body}" | jq -r '.id // empty')"
            authkey="$(printf '%s' "${body}" | jq -r '.key // empty')"
            if [[ -n "${authkey}" ]]; then
                printf '%s %s\n' "${key_id:-unknown}" "${authkey}"
                return 0
            fi
            fatal "API returned HTTP ${status} but no key for '${description}'"
        fi

        case "${status}" in
            ''|000|429|5??)
                if [[ "${attempt}" -ge "${CREATE_ATTEMPTS}" ]]; then
                    fatal "Key creation for '${description}' failed after ${attempt} attempts (HTTP ${status:-none}): $(api_message "${body}")"
                fi
                warn "Attempt ${attempt}/${CREATE_ATTEMPTS} for '${description}' failed (HTTP ${status:-none}); retrying"
                warn "If the request did reach Tailscale, the retry will leave an unused key behind; check the admin console afterwards"
                attempt=$((attempt + 1))
                sleep $((attempt * 2))
                ;;
            *)
                fatal "Key creation for '${description}' rejected with HTTP ${status}: $(api_message "${body}")"
                ;;
        esac
    done
}

# Extracts the human-readable message from an API error body, falling back to
# the raw body when it is not the expected shape.
api_message() {
    printf '%s' "$1" | jq -r 'if type == "object" and has("message") then .message else tostring end' 2>/dev/null \
        || printf '%s' "$1"
}

#------------------------------------------------------------------------------
# Modes
#------------------------------------------------------------------------------
do_revoke() {
    local i revoked=0 skipped=0 failed=0 response status

    for ((i = 0; i < PLAN_COUNT; i++)); do
        if [[ -z "${PLAN_KEY_ID[i]}" ]]; then
            info "${PLAN_HOSTNAME[i]}: no key ID recorded, nothing to revoke"
            skipped=$((skipped + 1))
            continue
        fi

        if [[ "${DRY_RUN}" == "true" ]]; then
            info "${PLAN_HOSTNAME[i]}: would revoke key ${PLAN_KEY_ID[i]}"
            continue
        fi

        response="$(api -X DELETE "${API_BASE}/api/v2/tailnet/${TAILNET}/keys/${PLAN_KEY_ID[i]}" || true)"
        status="$(printf '%s' "${response}" | tail -n1)"
        case "${status}" in
            2??)
                info "${PLAN_HOSTNAME[i]}: revoked key ${PLAN_KEY_ID[i]}"
                PLAN_KEY_ID[i]=""
                PLAN_AUTHKEY[i]=""
                revoked=$((revoked + 1))
                ;;
            404)
                info "${PLAN_HOSTNAME[i]}: key ${PLAN_KEY_ID[i]} already gone"
                PLAN_KEY_ID[i]=""
                PLAN_AUTHKEY[i]=""
                revoked=$((revoked + 1))
                ;;
            *)
                warn "${PLAN_HOSTNAME[i]}: failed to revoke key ${PLAN_KEY_ID[i]} (HTTP ${status:-none}): $(api_message "$(printf '%s' "${response}" | sed '$d')")"
                failed=$((failed + 1))
                ;;
        esac
    done

    if [[ "${DRY_RUN}" != "true" ]]; then
        plan_rewrite "${PLAN_FILE}"
    fi

    log "Revoked ${revoked}, skipped ${skipped}, failed ${failed}"
    [[ "${failed}" -eq 0 ]] || exit 1
}

do_create() {
    local i pending=0 created=0 result
    local -a tags=()

    for ((i = 0; i < PLAN_COUNT; i++)); do
        [[ -z "${PLAN_AUTHKEY[i]}" ]] && pending=$((pending + 1))
    done

    log "${PLAN_COUNT} device row(s), ${pending} without a key"
    if [[ "${pending}" -eq 0 ]]; then
        log "Nothing to do. Use --revoke first if you want to reissue keys."
        return 0
    fi

    log "Policy: reusable=${REUSABLE} ephemeral=${EPHEMERAL} preauthorized=${PREAUTHORIZED} expiry=${EXPIRY_DAYS}d"
    log "Tailnet: ${TAILNET}"

    for ((i = 0; i < PLAN_COUNT; i++)); do
        if [[ -n "${PLAN_AUTHKEY[i]}" ]]; then
            info "${PLAN_HOSTNAME[i]}: key already present, skipping"
            continue
        fi

        tags=()
        while IFS= read -r tag; do
            [[ -n "${tag}" ]] && tags+=("${tag}")
        done <<<"$(plan_split_tags "${PLAN_TAGS[i]}")"

        if [[ "${DRY_RUN}" == "true" ]]; then
            info "${PLAN_HOSTNAME[i]}: would create a key for tags ${tags[*]}"
            continue
        fi

        result="$(create_key "${PLAN_HOSTNAME[i]}" "${tags[@]}")"
        PLAN_KEY_ID[i]="${result%% *}"
        PLAN_AUTHKEY[i]="${result#* }"
        created=$((created + 1))
        # Deliberately prints the ID and never the key.
        info "${PLAN_HOSTNAME[i]}: created key ${PLAN_KEY_ID[i]}"

        # Written after every key so an interruption cannot orphan one.
        plan_rewrite "${PLAN_FILE}"
    done

    if [[ "${DRY_RUN}" == "true" ]]; then
        log "Dry run: would have created ${pending} key(s); nothing was changed"
        return 0
    fi

    log "Created ${created} key(s). ${PLAN_FILE} now holds auth keys: treat it as a secret."
    log "Next: tools/fleet-build.sh -e <base.eap> -p ${PLAN_FILE}"
}

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------
plan_parse "${PLAN_FILE}"
plan_validate "${PLAN_FILE}"

if [[ "${DRY_RUN}" != "true" ]]; then
    setup_credentials
fi

if [[ "${REVOKE}" == "true" ]]; then
    do_revoke
else
    do_create
fi

exit 0
