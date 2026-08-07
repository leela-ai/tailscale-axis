#!/usr/bin/env bash
#==============================================================================
#  File:         build.sh
#  Description:  End-to-end builder for an Axis-ACAP Tailscale package (.eap)
#                • Cross-compiles a single combined Tailscale binary (daemon +
#                  CLI) for ARM/aarch64 using Docker
#                • Strips unused Tailscale features via ts_omit_* build tags
#                • Injects user-supplied metadata into manifest & start script
#                • Produces a versioned .eap file named
#                  tailscale-<ts-ver>-<arch>[-<user>][-upx]-sdk<ver>.eap
#
#  Usage:        ./build.sh -a <arm|aarch64> [-s <sdk_ver>] [-u <username>]
#                          [-t "<tailscale up options>"] [-T <ts_version>]
#                          [-F "<features>"] [-U] [-v] [-h]
#
#  Examples:
#       # Minimal (32-bit ARM, default SDK)
#       ./build.sh -a arm -u root
#
#       # 64-bit build, custom SDK, enable SSH + auth-key
#       ./build.sh -a aarch64 -s 1.15 -u admin \
#                  -t "--ssh --accept-routes --authkey=tskey-xxxxx"
#
#  Author:       Juho Hietala <juho@leela.ai>
#  Created:      2025-05-01
#  Version:      2.0.0
#==============================================================================

set -euo pipefail

#------------------------------------------------------------------------------
# Globals & Defaults
#------------------------------------------------------------------------------
DEFAULT_SDK_VERSION="1.15"
DEFAULT_TAILSCALE_UP_OPTS="--accept-routes" # Default passed to Docker if -t is omitted
DOCKERFILE="Dockerfile"
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
Usage: ${0##*/} -a <arch> [-u <user>] [-s <sdk_ver>] [-t "<ts_opts>"] [-T <ts_version>]
                [-F "<features>"] [-U] [-v] [-h]

Builds an Axis ACAP Tailscale package (.eap) with specified parameters.

Required arguments:
  -a <arch>     Target architecture: 'arm' (ARMv7 32-bit) or 'aarch64' (ARM 64-bit).

Optional arguments:
  -u <user>     Username that will own the Tailscale process inside the package.
                If omitted, no explicit user/group is added to the manifest and
                the daemon runs with --tun=userspace-networking.
  -s <sdk_ver>  Axis ACAP Native SDK version to use.
                (Default: "${DEFAULT_SDK_VERSION}")
  -t "<ts_opts>" Tailscale startup options passed to 'tailscale up'.
                Quote the options if they contain spaces.
                (Default: if omitted, only '--accept-routes' is used)
                Example: "--ssh --accept-routes --authkey=tskey-xxxxx"
  -T <ts_version> Specify the Tailscale version tag to build (e.g., 'v1.80.0').
                  If omitted, the Dockerfile uses the latest stable tag.
  -F "<features>" Comma-separated list of Tailscale features to keep. Everything
                  else is stripped via ts_omit_* build tags. Unknown names abort
                  the build. If omitted, the default set in the Dockerfile is
                  used. Run 'go run ./cmd/featuretags --list' in the Tailscale
                  repo for the full list.
  -U            Pack the binary with UPX. Roughly quarters the on-flash size,
                at the cost of the whole binary being resident in RAM after
                self-extraction plus decompression on every invocation.
  -v            Enable verbose mode (set -x). Prints commands as they execute.
  -h            Show this help message and exit.

Examples:
  # Minimal build (ARMv7, SDK ${DEFAULT_SDK_VERSION}, user 'root', default 'up' options, latest Tailscale)
  ${0##*/} -a arm -u root

  # 64-bit build, custom SDK, custom 'up' options, user 'admin', specific Tailscale version
  ${0##*/} -a aarch64 -s 1.15 -u admin -t "--ssh --accept-routes" -T v1.80.0

  # UPX-compressed non-root build
  ${0##*/} -a aarch64 -U

EOF
  exit "${1:-0}"
}

#------------------------------------------------------------------------------
# Initial Check - Show help if no arguments provided
#------------------------------------------------------------------------------
if [[ $# -eq 0 ]]; then
    fatal "No arguments provided. See -h for help."
fi

#------------------------------------------------------------------------------
# Parse CLI options
#------------------------------------------------------------------------------
ARCH=""             # arm | aarch64
SDK_VERSION="${DEFAULT_SDK_VERSION}"
USERNAME=""
TAILSCALE_UP_OPTS=""
TS_VERSION_ARG=""   # Optional Tailscale version from CLI
TS_FEATURES=""      # Optional feature override; empty means Dockerfile default
UPX_COMPRESS="0"

while getopts ":a:s:u:t:T:F:Uvh" opt; do
  case "${opt}" in
    a) ARCH="${OPTARG}"              ;;
    s) SDK_VERSION="${OPTARG}"       ;;
    u) USERNAME="${OPTARG}"          ;;
    t) TAILSCALE_UP_OPTS="${OPTARG}" ;;
    T) TS_VERSION_ARG="${OPTARG}"    ;;
    F) TS_FEATURES="${OPTARG}"       ;;
    U) UPX_COMPRESS="1"              ;;
    v) set -x ;;
    h) usage 0 ;;
    \?) fatal "Unknown flag: -${OPTARG}. See -h for help." ;;
    :)  fatal "Option -${OPTARG} requires an argument." ;;
  esac
done

#------------------------------------------------------------------------------
# Validate inputs
#------------------------------------------------------------------------------
[[ -z "${ARCH}" ]] && fatal "Architecture (-a) is required."

# Derive ACAP architecture tag (e.g., armv7hf, aarch64)
case "${ARCH}" in
  arm)
    GOARCH="arm"; GOARM="7";   ACAP_ARCH_TAG="armv7hf" ;;
  aarch64)
    GOARCH="arm64"; GOARM="";  ACAP_ARCH_TAG="aarch64" ;;
  *) fatal "Invalid arch '${ARCH}'. Allowed: arm | aarch64." ;;
esac

# Fallback for tailscale options
if [[ -z "${TAILSCALE_UP_OPTS}" ]]; then TAILSCALE_UP_OPTS="${DEFAULT_TAILSCALE_UP_OPTS}"; fi

# Tolerate "a, b, c" in -F; the Dockerfile splits strictly on commas.
TS_FEATURES="${TS_FEATURES//[[:space:]]/}"

#------------------------------------------------------------------------------
# Build Docker image
#------------------------------------------------------------------------------
log "Building Docker image ${IMAGE_NAME} (SDK ${SDK_VERSION}, ARCH ${ACAP_ARCH_TAG}, UPX ${UPX_COMPRESS}) ..."

BUILD_ARGS=(
  --build-arg "GOARCH=${GOARCH}"
  --build-arg "SDK_VERSION=${SDK_VERSION}"
  --build-arg "ACAP_ARCH_TAG=${ACAP_ARCH_TAG}"
  --build-arg "TAILSCALE_UP_OPTS=${TAILSCALE_UP_OPTS}"
  --build-arg "UPX_COMPRESS=${UPX_COMPRESS}"
)
# Omitted rather than passed empty, so the Dockerfile defaults apply and the
# manifest keeps no user object when none was requested.
if [[ -n "${GOARM}" ]];          then BUILD_ARGS+=(--build-arg "GOARM=${GOARM}"); fi
if [[ -n "${USERNAME}" ]];       then BUILD_ARGS+=(--build-arg "APP_USERNAME=${USERNAME}"); fi
if [[ -n "${TS_VERSION_ARG}" ]]; then BUILD_ARGS+=(--build-arg "TAILSCALE_VERSION=${TS_VERSION_ARG}"); fi
if [[ -n "${TS_FEATURES}" ]];    then BUILD_ARGS+=(--build-arg "TS_FEATURES=${TS_FEATURES}"); fi

docker build --no-cache --progress=plain \
  "${BUILD_ARGS[@]}" \
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
DEST_USER_PART=${USERNAME:+-${USERNAME}}
DEST_UPX_PART=""
[[ "${UPX_COMPRESS}" == "1" ]] && DEST_UPX_PART="-upx"
DEST_FILE="tailscale-${TS_VERSION}-${ACAP_ARCH_TAG}${DEST_USER_PART}${DEST_UPX_PART}-sdk${SDK_VERSION}.eap"
cp "${EAP_FILE}" "${SCRIPT_DIR}/${DEST_FILE}"

# The .eap is gzipped for transfer; the unpacked binary is what consumes camera
# flash, so report both.
log "Package size (.eap, compressed):"
du -h "${SCRIPT_DIR}/${DEST_FILE}"
log "Combined binary size (unpacked on camera):"
du -h "${TMP_DIR}/lib/tailscaled"

log "SUCCESS – output: ${DEST_FILE}"
exit 0
