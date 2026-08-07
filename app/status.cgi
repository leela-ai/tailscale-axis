#!/bin/sh
#
# ACAP CGI endpoint returning live tailscaled status as JSON.
#
# Declared in manifest.json under acapPackageConf.configuration.httpConfig and
# served at /local/Tailscale/status.cgi with "admin" access. The settings page
# polls it instead of scraping the system log, which gives it the real
# BackendState and an AuthURL that is not tied to any particular control server.
#
# "--peers=false" makes tailscaled answer from StatusWithoutPeers: the response
# keeps AuthURL, BackendState, Health and Self, but drops the peer list that
# the page has no use for.

APP_DIR="/usr/local/packages/Tailscale"
TAILSCALED_BIN="${APP_DIR}/lib/tailscaled"
SOCKET="${APP_DIR}/state/tailscaled.sock"

printf 'Content-Type: application/json\r\n'
printf 'Cache-Control: no-store\r\n'
printf '\r\n'

# TS_BE_CLI makes the combined binary run as the CLI regardless of the name it
# was invoked under, so this works without relying on the lib/tailscale symlink
# surviving installation.
STATUS=$(TS_BE_CLI=1 "${TAILSCALED_BIN}" --socket "${SOCKET}" status --json --peers=false 2>&1)
RC=$?

if [ "${RC}" -ne 0 ] || [ -z "${STATUS}" ]; then
    # Answer 200 with a renderable state rather than an HTTP error, so the page
    # can tell "daemon not up yet" apart from "endpoint is broken".
    DETAIL=$(printf '%s' "${STATUS}" | tr '\r\n\t' '   ' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
    printf '{"BackendState":"NoState","CGIError":"%s"}\n' "${DETAIL}"
    exit 0
fi

printf '%s\n' "${STATUS}"
