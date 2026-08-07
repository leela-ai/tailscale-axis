#!/usr/bin/env bash
#==============================================================================
#  File:         smoke-test.sh
#  Description:  Verifies a built .eap before it is published.
#                • Checks the package layout (combined binary, symlink, CGI)
#                • Runs the cross-compiled binary under qemu to confirm it
#                  executes, reports the stamped version, dispatches to the CLI
#                  both by argv[0] and by TS_BE_CLI, still has the flags that
#                  depend on non-stripped features, and can serve the exact
#                  status query that status.cgi makes.
#                • With --injected-from, checks a package produced by
#                  tools/eap-inject.sh against the base it came from
#
#  Usage:        ./smoke-test.sh [--injected-from <base.eap>] <package.eap>
#
#  Requires:     docker with binfmt/qemu emulation for the target architecture
#                (docker/setup-qemu-action in CI, Docker Desktop locally).
#==============================================================================

set -euo pipefail

log()   { printf -- ">>> %s\n" "$*"; }
fatal() { printf -- "!!! %s\n" "$*" >&2; exit 1; }

EAP_FILE=""
BASE_EAP=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --injected-from)
            [[ $# -lt 2 ]] && fatal "Missing value for $1"
            BASE_EAP="$2"; shift 2 ;;
        -*) fatal "Unknown flag: $1" ;;
        *)
            [[ -n "${EAP_FILE}" ]] && fatal "Unexpected argument: $1"
            EAP_FILE="$1"; shift ;;
    esac
done

[[ -z "${EAP_FILE}" ]] && fatal "Usage: ${0##*/} [--injected-from <base.eap>] <package.eap>"
[[ -f "${EAP_FILE}" ]] || fatal "No such file: ${EAP_FILE}"
EAP_FILE="$(cd "$(dirname "${EAP_FILE}")" && pwd)/$(basename "${EAP_FILE}")"

if [[ -n "${BASE_EAP}" ]]; then
    [[ -f "${BASE_EAP}" ]] || fatal "No such base package: ${BASE_EAP}"
    BASE_EAP="$(cd "$(dirname "${BASE_EAP}")" && pwd)/$(basename "${BASE_EAP}")"
fi

WORK_DIR="$(mktemp -d)"
# Kept apart from the extracted tree so nothing this script writes can be
# mistaken for a package member.
SCRATCH_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}" "${SCRATCH_DIR}"' EXIT INT TERM

log "Extracting ${EAP_FILE##*/} ..."
tar -xzf "${EAP_FILE}" -C "${WORK_DIR}"

#------------------------------------------------------------------------------
# Package layout
#------------------------------------------------------------------------------
log "Checking package layout ..."
[[ -f "${WORK_DIR}/lib/tailscaled" ]] || fatal "lib/tailscaled missing from package"
[[ -L "${WORK_DIR}/lib/tailscale"  ]] || fatal "lib/tailscale is not a symlink in the package"
[[ -f "${WORK_DIR}/status.cgi"     ]] || fatal "status.cgi missing from package (is it passed to acap-build with -a?)"
[[ -f "${WORK_DIR}/cgi.conf"       ]] || fatal "cgi.conf missing from package (is httpConfig set in the manifest?)"
[[ -x "${WORK_DIR}/status.cgi"     ]] || fatal "status.cgi is not executable"

grep -q 'status.cgi' "${WORK_DIR}/package.conf" \
    || fatal "package.conf does not reference status.cgi in OTHERFILES"
grep -q 'administrator /status.cgi' "${WORK_DIR}/cgi.conf" \
    || fatal "cgi.conf does not grant admin access to /status.cgi"

# Per-device injection rewrites these two members rather than adding files, so
# they have to be real package members in every build.
[[ -f "${WORK_DIR}/tailscale_up_opts.txt" ]] \
    || fatal "tailscale_up_opts.txt missing from package (is it passed to acap-build with -a?)"
[[ -f "${WORK_DIR}/tailscale_authkey" ]] \
    || fatal "tailscale_authkey missing from package (is it passed to acap-build with -a?)"
grep -q 'tailscale_up_opts.txt' "${WORK_DIR}/package.conf" \
    || fatal "package.conf does not reference tailscale_up_opts.txt in OTHERFILES"
grep -q 'tailscale_authkey' "${WORK_DIR}/package.conf" \
    || fatal "package.conf does not reference tailscale_authkey in OTHERFILES"

if [[ -z "${BASE_EAP}" ]]; then
    # A package straight out of build.sh must not carry credentials, which also
    # catches an auth key accidentally committed to app/tailscale_authkey.
    [[ ! -s "${WORK_DIR}/tailscale_authkey" ]] \
        || fatal "tailscale_authkey is not empty in a freshly built package; it must ship blank"
    if grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' \
            "${WORK_DIR}/tailscale_up_opts.txt" >/dev/null 2>&1; then
        fatal "tailscale_up_opts.txt carries options in a freshly built package; it must ship with comments only"
    fi
fi

#------------------------------------------------------------------------------
# Injected packages: the only difference from the base must be the two members
# that tools/eap-inject.sh rewrites. Anything else means the repack altered the
# package, which on a camera shows up as a failed install or a dead daemon.
#------------------------------------------------------------------------------
if [[ -n "${BASE_EAP}" ]]; then
    log "Comparing against base package ${BASE_EAP##*/} ..."

    # The two injected members are dropped from both listings and everything else
    # then has to match exactly. Comparing the remainders rather than sifting
    # through diff output avoids having to tell a removed member apart from a
    # diff marker, since a listing line for a regular file also begins with '-'.
    tar -tvzf "${BASE_EAP}" \
        | grep -v -e ' tailscale_up_opts.txt$' -e ' tailscale_authkey$' \
        >"${SCRATCH_DIR}/listing-base.txt"
    tar -tvzf "${EAP_FILE}" \
        | grep -v -e ' tailscale_up_opts.txt$' -e ' tailscale_authkey$' \
        >"${SCRATCH_DIR}/listing-injected.txt"

    if ! diff -u "${SCRATCH_DIR}/listing-base.txt" "${SCRATCH_DIR}/listing-injected.txt" >&2; then
        fatal "the injected package differs from its base in members other than the injected two"
    fi

    [[ -s "${WORK_DIR}/tailscale_authkey" ]] \
        || fatal "the injected package has no auth key"
    grep -q '^tskey-' "${WORK_DIR}/tailscale_authkey" \
        || fatal "tailscale_authkey does not hold a tskey-... value, so the start script will ignore it"
    grep -q -- '--hostname=' "${WORK_DIR}/tailscale_up_opts.txt" \
        || fatal "tailscale_up_opts.txt has no --hostname, so every device would use the camera's own name"

    grep -q -- '--auth-key=file:' "${WORK_DIR}/Tailscale" \
        || fatal "the start script does not pass the auth key by reference"

    # tailscale_authkey is the only place a key belongs. Anywhere else, notably
    # the start script or the options file, would put it on a command line and
    # from there into the application log, which the settings page exposes.
    # lib/ is skipped: the daemon legitimately contains key-shaped strings.
    # 20 or more key characters after the prefix. That is long enough to tell a
    # real key from the "^tskey-" pattern the start script greps with.
    LEAKED="$(grep -rIlE 'tskey-[A-Za-z0-9-]{20,}' "${WORK_DIR}" 2>/dev/null \
        | grep -v -e '/tailscale_authkey$' -e "^${WORK_DIR}/lib/" || true)"
    if [[ -n "${LEAKED}" ]]; then
        fatal "auth key material found outside tailscale_authkey: ${LEAKED//${WORK_DIR}\//}"
    fi

    log "Injected package matches its base apart from the injected members"
fi

MANIFEST_VERSION="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${WORK_DIR}/manifest.json" | head -n1)"
ARCHITECTURE="$(sed -n 's/.*"architecture"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${WORK_DIR}/manifest.json" | head -n1)"
[[ -n "${MANIFEST_VERSION}" ]] || fatal "Could not read version from manifest.json"

case "${ARCHITECTURE}" in
  armv7hf) PLATFORM="linux/arm/v7" ;;
  aarch64) PLATFORM="linux/arm64"  ;;
  *) fatal "Unexpected architecture in manifest: '${ARCHITECTURE}'" ;;
esac

log "Architecture ${ARCHITECTURE} -> docker platform ${PLATFORM}, expecting version ${MANIFEST_VERSION}"

#------------------------------------------------------------------------------
# Run the binary under emulation
#------------------------------------------------------------------------------
log "Running binary under qemu ..."
docker run --rm --platform "${PLATFORM}" \
    -v "${WORK_DIR}:/pkg" \
    -e "EXPECTED_VERSION=${MANIFEST_VERSION}" \
    alpine:3 sh -eu -c '
cd /pkg
BIN=./lib/tailscaled
STATE=/tmp/state
SOCK="${STATE}/tailscaled.sock"

echo "== tailscaled --version =="
"${BIN}" --version
REPORTED=$("${BIN}" --version | head -n1)
if [ "${REPORTED}" != "${EXPECTED_VERSION}" ]; then
    echo "!!! version stamp mismatch: binary reports \"${REPORTED}\", package says \"${EXPECTED_VERSION}\""
    exit 1
fi

# "version" is not a tailscaled subcommand, so these only succeed if the binary
# actually dispatched into the embedded CLI.
echo "== CLI dispatch via argv[0] (lib/tailscale symlink) =="
./lib/tailscale version | head -n1

echo "== CLI dispatch via TS_BE_CLI =="
TS_BE_CLI=1 "${BIN}" version | head -n1

echo "== feature-dependent flags on tailscale up =="
TS_BE_CLI=1 "${BIN}" up --help >/tmp/uphelp 2>&1 || true
for flag in --ssh --accept-routes --advertise-routes --exit-node --accept-dns \
            --auth-key --hostname --advertise-tags; do
    if ! grep -q -- "${flag}" /tmp/uphelp; then
        echo "!!! tailscale up is missing ${flag}; a required feature was stripped"
        cat /tmp/uphelp
        exit 1
    fi
done
echo "all present"

echo "== daemon startup with userspace networking =="
mkdir -p "${STATE}"
"${BIN}" --statedir "${STATE}" --socket "${SOCK}" --tun=userspace-networking >/tmp/daemon.log 2>&1 &
DAEMON_PID=$!

i=0
while [ $i -lt 60 ]; do
    if [ -S "${SOCK}" ]; then break; fi
    if ! kill -0 "${DAEMON_PID}" 2>/dev/null; then
        echo "!!! tailscaled exited before creating its socket"
        cat /tmp/daemon.log
        exit 1
    fi
    i=$((i + 1))
    sleep 1
done
if [ ! -S "${SOCK}" ]; then
    echo "!!! tailscaled did not create ${SOCK} within 60s"
    cat /tmp/daemon.log
    kill "${DAEMON_PID}" 2>/dev/null || true
    exit 1
fi
echo "socket ready after ${i}s"

# The exact query status.cgi makes.
echo "== status --json --peers=false =="
STATUS=$(TS_BE_CLI=1 "${BIN}" --socket "${SOCK}" status --json --peers=false)
echo "${STATUS}"
echo "${STATUS}" | grep -q "\"BackendState\"" \
    || { echo "!!! status output has no BackendState"; kill "${DAEMON_PID}" 2>/dev/null || true; exit 1; }

kill "${DAEMON_PID}" 2>/dev/null || true
wait "${DAEMON_PID}" 2>/dev/null || true
'

log "SUCCESS - ${EAP_FILE##*/} passed all smoke tests"
