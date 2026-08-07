#!/usr/bin/env bash
#==============================================================================
#  File:         fleet-build.sh
#  Description:  Produces one .eap per device from a single base package and a
#                fleet plan whose auth keys have already been issued.
#                • Stamps hostname, tags, shared and per-device options
#                • Delegates the repack to eap-inject.sh, which verifies each
#                  package against the base before it is published
#                • Writes a deployment summary with checksums and no keys
#
#  Usage:        ./fleet-build.sh -e <base.eap> -p <plan.csv> [-o <outdir>]
#                                 [-O "<shared opts>"] [--dry-run]
#                                 [--keep-going] [-v] [-h]
#
#  Examples:
#       ./build.sh -a aarch64 -u root
#       ./tools/fleet-keys.sh fleet.plan.csv
#       ./tools/fleet-build.sh -e tailscale-v1.102.2-aarch64-root-sdk1.15.eap \
#                              -p fleet.plan.csv -O "--accept-routes"
#==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools/fleet-plan.lib.sh
. "${SCRIPT_DIR}/fleet-plan.lib.sh"

INJECT_SCRIPT="${SCRIPT_DIR}/eap-inject.sh"
DEFAULT_OUTDIR="fleet-eaps"
SUMMARY_NAME="deployment.csv"

#------------------------------------------------------------------------------
# Options
#------------------------------------------------------------------------------
BASE_EAP=""
PLAN_FILE=""
OUTDIR="${DEFAULT_OUTDIR}"
SHARED_OPTS=""
DRY_RUN="false"
KEEP_GOING="false"
VERBOSE="false"

usage() {
    cat <<EOF
Usage: ${0##*/} -e <base.eap> -p <plan.csv> [options]

Builds one .eap per device row in the plan by stamping each device's identity and
auth key into a copy of the base package. Run tools/fleet-keys.sh first so the
plan has keys.

Required:
  -e <base.eap>   Base package from build.sh. Left unmodified.
  -p <plan.csv>   Fleet plan with the key columns filled in.

Optional:
  -o <outdir>     Output directory (default: ${DEFAULT_OUTDIR}).
  -O "<opts>"     Extra "tailscale up" options applied to every device, on top of
                  whatever was baked in at build time. Quote them.
  --dry-run       Report what would be built without writing anything.
  --keep-going    Carry on after a device fails instead of stopping.
  -v              Trace commands as they run.
  -h, --help      Show this help and exit.

Output:
  <outdir>/<base name>-<hostname>.eap for every device, plus
  <outdir>/${SUMMARY_NAME} mapping hostname to filename, tags, key ID and
  SHA-256. The summary contains no auth keys and is safe to share.
EOF
    exit "${1:-0}"
}

[[ $# -eq 0 ]] && usage 1

while [[ $# -gt 0 ]]; do
    case "$1" in
        -e) [[ $# -lt 2 ]] && fatal "Missing value for $1"; BASE_EAP="$2";     shift 2 ;;
        -p) [[ $# -lt 2 ]] && fatal "Missing value for $1"; PLAN_FILE="$2";    shift 2 ;;
        -o) [[ $# -lt 2 ]] && fatal "Missing value for $1"; OUTDIR="$2";       shift 2 ;;
        -O) [[ $# -lt 2 ]] && fatal "Missing value for $1"; SHARED_OPTS="$2";  shift 2 ;;
        --dry-run)    DRY_RUN="true";   shift ;;
        --keep-going) KEEP_GOING="true"; shift ;;
        -v)           VERBOSE="true";   shift ;;
        -h|--help)    usage 0 ;;
        --)           shift; break ;;
        *)            fatal "Unknown argument: $1 (see --help)" ;;
    esac
done
[[ $# -eq 0 ]] || fatal "Unexpected argument: $1"

[[ -n "${BASE_EAP}" ]]  || fatal "Base package (-e) is required."
[[ -n "${PLAN_FILE}" ]] || fatal "Plan file (-p) is required."
[[ -f "${BASE_EAP}" ]]  || fatal "No such file: ${BASE_EAP}"
[[ -x "${INJECT_SCRIPT}" ]] || fatal "Cannot execute ${INJECT_SCRIPT}"

if [[ "${SHARED_OPTS}" == *--auth-key* || "${SHARED_OPTS}" == *--authkey* ]]; then
    fatal "Do not pass an auth key in -O; keys come from the plan file."
fi
if [[ "${SHARED_OPTS}" == *--hostname* || "${SHARED_OPTS}" == *--advertise-tags* ]]; then
    fatal "Do not set --hostname or --advertise-tags in -O; they come from the plan file."
fi

need tar

#------------------------------------------------------------------------------
# Helpers
#------------------------------------------------------------------------------

# Prints the SHA-256 of $1, using whichever of the two usual tools is installed.
sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | cut -d' ' -f1
    else
        printf 'unavailable'
    fi
}

#------------------------------------------------------------------------------
# Pre-flight
#
# Everything that can be checked without producing a package is checked first, so
# a plan with one bad row does not leave a half-built output directory.
#------------------------------------------------------------------------------
plan_parse "${PLAN_FILE}"
plan_validate "${PLAN_FILE}"

MISSING=""
for ((i = 0; i < PLAN_COUNT; i++)); do
    if [[ -z "${PLAN_AUTHKEY[i]}" ]]; then
        MISSING="${MISSING} ${PLAN_HOSTNAME[i]}"
    fi
done
if [[ -n "${MISSING}" ]]; then
    warn "These devices have no auth key:${MISSING}"
    fatal "Run 'tools/fleet-keys.sh ${PLAN_FILE}' first, or clear those rows from the plan."
fi

if ! tar -tzf "${BASE_EAP}" 2>/dev/null | grep -qx 'tailscale_up_opts.txt'; then
    fatal "${BASE_EAP##*/} does not ship tailscale_up_opts.txt, so nothing can be injected into it. Rebuild it with build.sh."
fi

BASE_EAP="$(cd "$(dirname "${BASE_EAP}")" && pwd)/$(basename "${BASE_EAP}")"
BASE_NAME="$(basename "${BASE_EAP}" .eap)"

log "Base package:  ${BASE_EAP##*/}"
log "Plan:          ${PLAN_FILE} (${PLAN_COUNT} device(s))"
log "Output:        ${OUTDIR}"
[[ -n "${SHARED_OPTS}" ]] && log "Shared options: ${SHARED_OPTS}"

if [[ "${DRY_RUN}" == "true" ]]; then
    for ((i = 0; i < PLAN_COUNT; i++)); do
        info "${PLAN_HOSTNAME[i]} -> ${OUTDIR}/${BASE_NAME}-${PLAN_HOSTNAME[i]}.eap"
        info "    --hostname=${PLAN_HOSTNAME[i]} --advertise-tags=${PLAN_TAGS[i]}${SHARED_OPTS:+ ${SHARED_OPTS}}${PLAN_EXTRA[i]:+ ${PLAN_EXTRA[i]}}"
    done
    log "Dry run: nothing was written"
    exit 0
fi

mkdir -p "${OUTDIR}" || fatal "Cannot create ${OUTDIR}"
OUTDIR_ABS="$(cd "${OUTDIR}" && pwd)"

#------------------------------------------------------------------------------
# Build
#------------------------------------------------------------------------------
# The key is handed to eap-inject.sh in a 0600 file rather than as an argument,
# so it never appears in the process list.
KEY_TMP=""
cleanup() {
    if [[ -n "${KEY_TMP}" ]]; then
        rm -f "${KEY_TMP}"
    fi
}
trap cleanup EXIT INT TERM

OLD_UMASK="$(umask)"
umask 077
KEY_TMP="$(mktemp "${TMPDIR:-/tmp}/fleet-build-key.XXXXXX")" || fatal "Cannot create a temporary key file"
umask "${OLD_UMASK}"

SUMMARY="${OUTDIR_ABS}/${SUMMARY_NAME}"
printf 'hostname;eap_file;tags;key_id;sha256\n' >"${SUMMARY}"

BUILT=0
FAILED=0
FAILED_HOSTS=""

for ((i = 0; i < PLAN_COUNT; i++)); do
    host="${PLAN_HOSTNAME[i]}"
    device_opts="--hostname=${host} --advertise-tags=${PLAN_TAGS[i]}"
    [[ -n "${SHARED_OPTS}" ]]     && device_opts="${device_opts} ${SHARED_OPTS}"
    [[ -n "${PLAN_EXTRA[i]}" ]]   && device_opts="${device_opts} ${PLAN_EXTRA[i]}"

    log "[$((i + 1))/${PLAN_COUNT}] ${host}"
    printf '%s\n' "${PLAN_AUTHKEY[i]}" >"${KEY_TMP}"

    inject_args=(-e "${BASE_EAP}" -o "${device_opts}" -K "${KEY_TMP}" -n "${host}" -d "${OUTDIR_ABS}")
    [[ "${VERBOSE}" == "true" ]] && inject_args+=(-v)

    if "${INJECT_SCRIPT}" "${inject_args[@]}"; then
        eap="${BASE_NAME}-${host}.eap"
        printf '%s;%s;%s;%s;%s\n' \
            "${host}" "${eap}" "${PLAN_TAGS[i]}" "${PLAN_KEY_ID[i]}" \
            "$(sha256_of "${OUTDIR_ABS}/${eap}")" >>"${SUMMARY}"
        BUILT=$((BUILT + 1))
    else
        warn "${host}: injection failed"
        FAILED=$((FAILED + 1))
        FAILED_HOSTS="${FAILED_HOSTS} ${host}"
        if [[ "${KEEP_GOING}" != "true" ]]; then
            fatal "Stopping after the first failure. Pass --keep-going to build the rest anyway."
        fi
    fi
done

log "Built ${BUILT} package(s) in ${OUTDIR}"
log "Summary: ${SUMMARY}"
if [[ "${FAILED}" -gt 0 ]]; then
    warn "${FAILED} device(s) failed:${FAILED_HOSTS}"
    exit 1
fi

exit 0
