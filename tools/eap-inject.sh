#!/usr/bin/env bash
#==============================================================================
#  File:         eap-inject.sh
#  Description:  Stamps per-device "tailscale up" options and an auth key into a
#                finished .eap, producing a new package without rebuilding.
#                • Rewrites the tailscale_up_opts.txt and tailscale_authkey
#                  members that every build ships empty, so nothing is added
#                  that the package manifest does not already declare
#                • Repacks with the same tar settings the ACAP SDK uses
#                • Verifies the result against the source archive before
#                  declaring success
#
#  Usage:        ./eap-inject.sh -e <eap> [-o "<opts>"] [-k <key>|-K <file>]
#                                [-n <suffix>] [-d <outdir>] [-v] [-h]
#
#  Examples:
#       # Turn on Tailscale SSH in a package that was built without it
#       ./eap-inject.sh -e tailscale-v1.102.2-aarch64-sdk1.15.eap -o "--ssh"
#
#       # Stamp one camera's identity and auth key
#       ./eap-inject.sh -e base.eap -n warehouse-cam-01 \
#                       -o "--hostname=warehouse-cam-01 --advertise-tags=tag:camera" \
#                       -K /run/secrets/cam01.key
#==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools/fleet-plan.lib.sh
. "${SCRIPT_DIR}/fleet-plan.lib.sh"

# Package members that every build ships empty for exactly this purpose. Both
# must already be present: adding new files to a finished .eap would leave them
# absent from package.conf, and whether the camera installer keeps files it was
# never told about is not something this script can guarantee.
OPTS_MEMBER="tailscale_up_opts.txt"
KEY_MEMBER="tailscale_authkey"

# Timestamp reference for the two rewritten members. Copying the mtime from an
# untouched member keeps the archive as uniform as the SDK produced it, without
# having to parse dates out of a tar listing.
MTIME_REFERENCE="manifest.json"

#------------------------------------------------------------------------------
# Options
#------------------------------------------------------------------------------
EAP_FILE=""
UP_OPTS=""
AUTHKEY=""
KEY_FILE=""
OUTPUT_SUFFIX="injected"
OUTPUT_DIR="."

usage() {
    cat <<EOF
Usage: ${0##*/} -e <eap> [-o "<opts>"] [-k <key> | -K <file>] [-n <suffix>] [-d <dir>] [-v] [-h]

Stamps per-device options and an auth key into an existing .eap, without
rebuilding. At least one of -o, -k or -K is required.

Required:
  -e <eap>       Package to use as the base. Left unmodified.

Optional:
  -o "<opts>"    "tailscale up" options for this device, appended after the
                 options baked in at build time so they take precedence. Quote
                 them. Must not contain an auth key: use -k or -K so the key is
                 passed to tailscale by reference instead of on its command line.
  -k <key>       Auth key literal. Visible in the process list while this runs;
                 prefer -K for anything automated.
  -K <file>      Read the auth key from a file.
  -n <suffix>    Suffix for the output filename (default: ${OUTPUT_SUFFIX}).
  -d <dir>       Output directory (default: current directory).
  -v             Trace commands as they run.
  -h             Show this help and exit.

Output:
  <dir>/<base name of eap>-<suffix>.eap
EOF
    exit "${1:-0}"
}

[[ $# -eq 0 ]] && usage 1

while getopts ':e:o:k:K:n:d:vh' opt; do
    case "${opt}" in
        e) EAP_FILE="${OPTARG}" ;;
        o) UP_OPTS="${OPTARG}" ;;
        k) AUTHKEY="${OPTARG}" ;;
        K) KEY_FILE="${OPTARG}" ;;
        n) OUTPUT_SUFFIX="${OPTARG}" ;;
        d) OUTPUT_DIR="${OPTARG}" ;;
        v) set -x ;;
        h) usage 0 ;;
        :) fatal "Option -${OPTARG} requires an argument." ;;
        \?) fatal "Unknown option: -${OPTARG}. See -h for help." ;;
    esac
done
shift $((OPTIND - 1))
[[ $# -eq 0 ]] || fatal "Unexpected argument: $1"

[[ -n "${EAP_FILE}" ]] || fatal "Base package (-e) is required."
[[ -f "${EAP_FILE}" ]] || fatal "No such file: ${EAP_FILE}"
[[ -n "${OUTPUT_SUFFIX}" ]] || fatal "Output suffix (-n) must not be empty."

if [[ -n "${AUTHKEY}" && -n "${KEY_FILE}" ]]; then
    fatal "Use either -k or -K, not both."
fi
if [[ -n "${KEY_FILE}" ]]; then
    [[ -f "${KEY_FILE}" ]] || fatal "Auth key file not found: ${KEY_FILE}"
    AUTHKEY="$(plan_trim "$(cat "${KEY_FILE}")")"
    [[ -n "${AUTHKEY}" ]] || fatal "Auth key file is empty: ${KEY_FILE}"
fi
if [[ -z "${UP_OPTS}" && -z "${AUTHKEY}" ]]; then
    fatal "Nothing to inject. Pass options with -o, an auth key with -k or -K, or both."
fi

# The start script only honours a key that looks like one, so reject anything
# else here rather than shipping a package that silently never authenticates.
if [[ -n "${AUTHKEY}" && "${AUTHKEY}" != tskey-* ]]; then
    fatal "Auth key does not start with 'tskey-'; the package would ignore it."
fi
if [[ "${UP_OPTS}" == *--auth-key* || "${UP_OPTS}" == *--authkey* ]]; then
    fatal "Do not put an auth key in -o: it would appear in the process list and in the application log. Use -k or -K."
fi
# The suffix becomes part of a filename.
if [[ ! "${OUTPUT_SUFFIX}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    fatal "Output suffix '${OUTPUT_SUFFIX}' must start alphanumeric and contain only letters, digits, '.', '_' or '-'."
fi

#------------------------------------------------------------------------------
# tar selection
#
# The SDK builds the .eap with GNU tar (see eap-create.sh), so GNU tar is used
# when available. bsdtar, which is what macOS ships as "tar", can produce an
# equivalent archive given the right flags; either way the result is checked
# against the source archive at the end.
#------------------------------------------------------------------------------
TAR=""
TAR_FLAVOUR=""

detect_tar() {
    local candidate
    for candidate in gtar gnutar tar; do
        command -v "${candidate}" >/dev/null 2>&1 || continue
        if "${candidate}" --version 2>&1 | head -n1 | grep -q 'GNU tar'; then
            TAR="${candidate}"
            TAR_FLAVOUR="gnu"
            return 0
        fi
    done
    if command -v tar >/dev/null 2>&1 && tar --version 2>&1 | head -n1 | grep -q 'bsdtar'; then
        TAR="tar"
        TAR_FLAVOUR="bsd"
        return 0
    fi
    fatal "Need GNU tar or bsdtar. On macOS 'tar' is bsdtar and works; elsewhere install tar."
}

# Repacks $2 (a directory) into the archive $1, taking member names and their
# order from the file $3. Ownership is forced to 0:0 and extended attributes are
# dropped, both of which the SDK's own tar invocation does.
pack_eap() {
    local out="$1" dir="$2" list="$3"

    case "${TAR_FLAVOUR}" in
        gnu)
            "${TAR}" --create --file "${out}" \
                --use-compress-program="gzip --no-name -9" \
                --format=gnu \
                --numeric-owner --owner=0 --group=0 \
                --no-recursion \
                --directory "${dir}" \
                --files-from "${list}"
            ;;
        bsd)
            # --no-mac-metadata and --no-xattrs matter here: macOS tags files it
            # creates with extended attributes, which would otherwise be packed
            # as AppleDouble members the ACAP installer knows nothing about.
            "${TAR}" --create --file "${out}" \
                --gzip --options 'gzip:compression-level=9,gzip:!timestamp' \
                --format gnutar \
                --numeric-owner --uid 0 --gid 0 --uname '' --gname '' \
                --no-mac-metadata --no-xattrs \
                -n \
                -C "${dir}" \
                -T "${list}"
            ;;
        *)
            fatal "Internal error: tar flavour not detected"
            ;;
    esac
}

# Prints a listing of an archive with mode, ownership, size, timestamp and name
# for every member, leaving out the two this script rewrites. Everything that is
# left has to survive a repack untouched.
#
# Comparing the remainders is deliberate: sifting through diff output would mean
# telling a removed member apart from a diff marker, and a listing line for a
# regular file also begins with '-'.
archive_listing_except_injected() {
    "${TAR}" -tvzf "$1" \
        | grep -v -e " ${OPTS_MEMBER}\$" -e " ${KEY_MEMBER}\$"
}

#------------------------------------------------------------------------------
# Work
#------------------------------------------------------------------------------
detect_tar

EAP_FILE="$(cd "$(dirname "${EAP_FILE}")" && pwd)/$(basename "${EAP_FILE}")"
mkdir -p "${OUTPUT_DIR}" || fatal "Cannot create output directory: ${OUTPUT_DIR}"
OUTPUT_DIR="$(cd "${OUTPUT_DIR}" && pwd)"
OUTPUT_FILE="${OUTPUT_DIR}/$(basename "${EAP_FILE}" .eap)-${OUTPUT_SUFFIX}.eap"

if [[ "${OUTPUT_FILE}" == "${EAP_FILE}" ]]; then
    fatal "Output would overwrite the base package: ${EAP_FILE}"
fi

WORK_DIR=""
cleanup() {
    if [[ -n "${WORK_DIR}" ]]; then
        rm -rf "${WORK_DIR}"
    fi
}
trap cleanup EXIT INT TERM

# The work tree is created 0700 so the auth key is never readable by other users
# on the build host, which also means the extracted files themselves do not need
# restrictive modes.
OLD_UMASK="$(umask)"
umask 077
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/eap-inject.XXXXXX")" || fatal "Cannot create a work directory"
CONTENT_DIR="${WORK_DIR}/contents"
mkdir -p "${CONTENT_DIR}"
umask "${OLD_UMASK}"

log "Unpacking ${EAP_FILE##*/} with ${TAR} (${TAR_FLAVOUR})"
"${TAR}" -tzf "${EAP_FILE}" >"${WORK_DIR}/members.txt" \
    || fatal "Cannot list ${EAP_FILE}; is it a gzipped tar?"
# -p keeps the archive's own modes. Without it tar subtracts the umask for a
# non-root user, and the repack would no longer match the base package.
"${TAR}" -xzpf "${EAP_FILE}" -C "${CONTENT_DIR}" \
    || fatal "Cannot extract ${EAP_FILE}"

for member in "${OPTS_MEMBER}" "${KEY_MEMBER}" "${MTIME_REFERENCE}" Tailscale; do
    [[ -f "${CONTENT_DIR}/${member}" ]] || fatal \
        "${EAP_FILE##*/} has no '${member}'. Rebuild with build.sh: packages from before per-device injection was added do not ship the placeholder members this rewrites."
done

# Writing the members is pointless if the start script in this package does not
# read them, which would leave a package that looks stamped but authenticates
# interactively like any other.
grep -q "${OPTS_MEMBER}" "${CONTENT_DIR}/Tailscale" \
    || fatal "The start script in ${EAP_FILE##*/} does not read ${OPTS_MEMBER}; rebuild the package."
grep -q -- '--auth-key=file:' "${CONTENT_DIR}/Tailscale" \
    || fatal "The start script in ${EAP_FILE##*/} does not pass an auth key by reference; rebuild the package."

log "Writing ${OPTS_MEMBER}"
{
    printf '# Injected by %s for %s.\n' "${0##*/}" "${OUTPUT_SUFFIX}"
    [[ -n "${UP_OPTS}" ]] && printf '%s\n' "${UP_OPTS}"
} >"${CONTENT_DIR}/${OPTS_MEMBER}"
info "options: ${UP_OPTS:-<none>}"

if [[ -n "${AUTHKEY}" ]]; then
    log "Writing ${KEY_MEMBER}"
    printf '%s\n' "${AUTHKEY}" >"${CONTENT_DIR}/${KEY_MEMBER}"
    # Deliberately never logs the key itself.
    info "auth key: ${AUTHKEY:0:12}... (${#AUTHKEY} characters)"
else
    : >"${CONTENT_DIR}/${KEY_MEMBER}"
    info "auth key: <none>, this package will still need interactive login"
fi

# Match the rest of the archive so the only difference from the base package is
# the contents of these two members.
chmod 644 "${CONTENT_DIR}/${OPTS_MEMBER}" "${CONTENT_DIR}/${KEY_MEMBER}"
touch -r "${CONTENT_DIR}/${MTIME_REFERENCE}" \
    "${CONTENT_DIR}/${OPTS_MEMBER}" "${CONTENT_DIR}/${KEY_MEMBER}"

log "Repacking as ${OUTPUT_FILE##*/}"
pack_eap "${WORK_DIR}/out.eap" "${CONTENT_DIR}" "${WORK_DIR}/members.txt" \
    || fatal "Repacking failed"

#------------------------------------------------------------------------------
# Verify before publishing
#
# Compares the new archive against the base one member by member. Anything other
# than a size change on the two injected members means the repack lost or altered
# something, which on a camera would show up as a package that fails to install
# or a daemon that will not start.
#------------------------------------------------------------------------------
log "Verifying the repacked archive against the base package"
archive_listing_except_injected "${EAP_FILE}"         >"${WORK_DIR}/listing-base.txt"
archive_listing_except_injected "${WORK_DIR}/out.eap" >"${WORK_DIR}/listing-new.txt"

if ! diff -u "${WORK_DIR}/listing-base.txt" "${WORK_DIR}/listing-new.txt" >&2; then
    warn "Repacking changed members other than ${OPTS_MEMBER} and ${KEY_MEMBER}"
    fatal "Refusing to publish ${OUTPUT_FILE##*/}"
fi

# Read the key back out of the finished archive, so a package is never published
# on the assumption that writing the member worked.
REPACKED_KEY="$(plan_trim "$("${TAR}" -xzOf "${WORK_DIR}/out.eap" "${KEY_MEMBER}")")"
if [[ "${REPACKED_KEY}" != "${AUTHKEY}" ]]; then
    fatal "The auth key did not survive the repack"
fi

mv -f "${WORK_DIR}/out.eap" "${OUTPUT_FILE}" || fatal "Cannot write ${OUTPUT_FILE}"
chmod 644 "${OUTPUT_FILE}"

log "Wrote ${OUTPUT_FILE} ($(du -h "${OUTPUT_FILE}" | cut -f1))"
exit 0
