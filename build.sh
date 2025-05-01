#!/usr/bin/env bash
#==============================================================================
#  File:         build.sh
#  Description:  End-to-end builder for an Axis-ACAP Tailscale package (.eap)
#                • Cross-compiles Tailscale for ARM/aarch64 using Docker
#                • Injects user-supplied metadata into manifest & start script via Docker build args
#                • Produces a versioned .eap file named
#                  tailscale-<ts-ver>-<arch>-<user>-sdk<ver>.eap
#
#  Usage:        ./build.sh -a <arm|aarch64> [-s <sdk_ver>] -u <username>
#                          [-t "<tailscale up options>"] [-T <ts_version>] [-v] [-h]
#
#  Examples:
#       # Minimal (32-bit ARM, default SDK 1.15)
#       ./build.sh -a arm -u root
#
#       # 64-bit build, custom SDK, enable SSH + auth-key
#       ./build.sh -a aarch64 -s 1.15 -u admin \
#                  -t "--ssh --accept-routes --authkey=tskey-xxxxx"
#
#  Author:       Juho Hietala <juho@leela.ai>
#  Created:      2025-05-01
#  Version:      1.0.0
#==============================================================================

set -euo pipefail

#------------------------------------------------------------------------------
# Globals & Defaults
#------------------------------------------------------------------------------
DEFAULT_SDK_VERSION="1.15"
DEFAULT_TAILSCALE_UP_OPTS="--accept-routes" # Default passed to Docker if -t is omitted
DOCKERFILE="Dockerfile"                        # Change if you keep a separate build file
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="axis-tailscale-builder"
CONTAINER_NAME=""
TMP_DIR=""

#------------------------------------------------------------------------------
# Logging helpers
#------------------------------------------------------------------------------
log()   { printf -- ">>> [%s] %s\n" "$(date +'%H:%M:%S')" "$*"; }
fatal() { printf -- "!!! [%s] %s\n" "$(date +'%H:%M:%S')" "$*" >&2; exit 1; }

#------------------------------------------------------------------------------
# Cleanup handler
#------------------------------------------------------------------------------
cleanup() {
    [[ -n "${CONTAINER_NAME}" ]] && docker rm -f "${CONTAINER_NAME}" &>/dev/null || true
    [[ -n "${TMP_DIR}"        ]] && rm -rf "${TMP_DIR}"
}
trap cleanup EXIT INT TERM

#------------------------------------------------------------------------------
# Usage
#------------------------------------------------------------------------------
usage() {
  cat << EOF
Usage: ${0##*/} -a <arch> -u <user> [-s <sdk_ver>] [-t "<ts_opts>"] [-T <ts_version>] [-v] [-h]

Builds an Axis ACAP Tailscale package (.eap) with specified parameters.

Required arguments:
  -a <arch>     Target architecture: 'arm' (ARMv7 32-bit) or 'aarch64' (ARM 64-bit).
  -u <user>     (Optional) Username that will own the Tailscale process inside the package.
                If omitted, no explicit user/group will be added to the manifest.

Optional arguments:
  -s <sdk_ver>  Axis ACAP Native SDK version to use.
                (Default: "${DEFAULT_SDK_VERSION}")
  -t "<ts_opts>" Tailscale startup options passed to 'tailscale up'.
                Quote the options if they contain spaces.
                (Default: if omitted, only '--accept-routes' is used)
                Example: "--ssh --accept-routes --authkey=tskey-xxxxx"
  -T <ts_version> Specify the Tailscale version tag to build (e.g., 'v1.80.0').
                  If omitted, the Dockerfile will attempt to use the latest stable tag.
  -v            Enable verbose mode (set -x). Prints commands as they execute.
  -h            Show this help message and exit.

Examples:
  # Minimal build (ARMv7, SDK ${DEFAULT_SDK_VERSION}, user 'root', default 'up' options, latest Tailscale)
  ${0##*/} -a arm -u root

  # 64-bit build, custom SDK, custom 'up' options, user 'admin', specific Tailscale version
  ${0##*/} -a aarch64 -s 1.4 -u admin -t "--ssh --accept-routes" -T v1.80.0

EOF
  exit "${1:-0}"
}

#------------------------------------------------------------------------------
# Initial Check - Show help if no arguments provided
#------------------------------------------------------------------------------
if [[ $# -eq 0 ]]; then
    fatal "No arguments provided."
    usage 1 # Technically unreachable due to fatal, but good practice
fi

#------------------------------------------------------------------------------
# Parse CLI options
#------------------------------------------------------------------------------
ARCH=""             # arm | aarch64
SDK_VERSION="${DEFAULT_SDK_VERSION}"
USERNAME=""
TAILSCALE_UP_OPTS="" # Renamed from TS_OPTS
TS_VERSION_ARG=""   # Optional Tailscale version from CLI

while getopts ":a:s:u:t:T:vh" opt; do
  case "${opt}" in
    a) ARCH="${OPTARG}"        ;;
    s) SDK_VERSION="${OPTARG}" ;;
    u) USERNAME="${OPTARG}"    ;;
    t)
      # Detect missing quotes around -t value (starts with another option flag)
      if [[ "${OPTARG}" == -* ]]; then
        fatal "Option -t requires its value to be quoted. Example: -t \"--ssh --accept-routes\""
      fi
      TAILSCALE_UP_OPTS="${OPTARG}"     ;; # Renamed from TS_OPTS
    T) TS_VERSION_ARG="${OPTARG}" ;; # Store specified Tailscale version
    v) set -x ;;               # Verbose mode
    h) usage 0 ;;
    \?) fatal "Unknown flag: -${OPTARG}. See -h for help." ;;
    :)  fatal "Option -${OPTARG} requires an argument." ;;
  esac
done

#------------------------------------------------------------------------------
# Validate inputs
#------------------------------------------------------------------------------
[[ -z "${ARCH}"     ]] && fatal "Architecture (-a) is required."
# Username is now optional; if omitted, downstream Dockerfile will drop the user object from manifest.

# Derive ACAP architecture tag (e.g., armv7hf, aarch64)
case "${ARCH}" in
  arm)
    GOARCH="arm"; GOARM="7";   ACAP_ARCH_TAG="armv7hf" ;;
  aarch64)
    GOARCH="arm64"; GOARM="";  ACAP_ARCH_TAG="aarch64" ;;
  *) fatal "Invalid arch '${ARCH}'. Allowed: arm | aarch64." ;;
esac

# Fallback for tailscale options
[[ -z "${TAILSCALE_UP_OPTS}" ]] && TAILSCALE_UP_OPTS="${DEFAULT_TAILSCALE_UP_OPTS}"

#------------------------------------------------------------------------------
# Build Docker image
#------------------------------------------------------------------------------
log "Building Docker image ${IMAGE_NAME} (SDK ${SDK_VERSION}, ARCH ${ACAP_ARCH_TAG}) ..."
docker build --no-cache --progress=plain \
  --build-arg GOARCH="${GOARCH}" \
  $( [[ -n "${GOARM}" ]] && printf -- '--build-arg GOARM=%s ' "${GOARM}" ) \
  --build-arg SDK_VERSION="${SDK_VERSION}" \
  $( [[ -n "${USERNAME}" ]] && printf -- '--build-arg APP_USERNAME=%s ' "${USERNAME}" ) \
  --build-arg ACAP_ARCH_TAG="${ACAP_ARCH_TAG}" \
  --build-arg TAILSCALE_UP_OPTS="${TAILSCALE_UP_OPTS}" \
  $( [[ -n "${TS_VERSION_ARG}" ]] && printf -- '--build-arg TAILSCALE_VERSION=%s ' "${TS_VERSION_ARG}" ) \
  -t "${IMAGE_NAME}" \
  -f "${DOCKERFILE}" .

#------------------------------------------------------------------------------
# Create container & extract artifacts
#------------------------------------------------------------------------------
CONTAINER_NAME="temp-extract-$(date +%s)"
log "Creating temporary container ${CONTAINER_NAME} ..."
docker create --name "${CONTAINER_NAME}" "${IMAGE_NAME}" >/dev/null

TMP_DIR="$(mktemp -d)"
log "Copying artifacts (.eap and version file) from container to ${TMP_DIR} ... "
docker cp "${CONTAINER_NAME}:/opt/app/." "${TMP_DIR}"

EAP_FILE="$(find "${TMP_DIR}" -maxdepth 1 -name '*.eap' -print -quit)"
[[ -z "${EAP_FILE}" ]] && fatal "No .eap file found in container artifacts at ${TMP_DIR}."

VERSION_FILE="${TMP_DIR}/tailscale_version.txt"
[[ ! -f "${VERSION_FILE}" ]] && fatal "Version file not found in container artifacts at ${TMP_DIR}."
TS_VERSION=$(cat "${VERSION_FILE}")
[[ -z "${TS_VERSION}" ]] && fatal "Unable to read Tailscale version from ${VERSION_FILE}."
log "Determined Tailscale version: ${TS_VERSION}"

#------------------------------------------------------------------------------
# Rename + move artifact
#------------------------------------------------------------------------------
DEST_USER_PART=${USERNAME:+-${USERNAME}} # Add username part only if USERNAME is set
DEST_FILE="tailscale-${TS_VERSION}-${ACAP_ARCH_TAG}${DEST_USER_PART}-sdk${SDK_VERSION}.eap" # Use ACAP_ARCH_TAG
cp "${EAP_FILE}" "./${DEST_FILE}"

log "Final artifact size:"
du -sh "./${DEST_FILE}" # Use -s for summary line

log "SUCCESS – output: ${DEST_FILE}"
exit 0