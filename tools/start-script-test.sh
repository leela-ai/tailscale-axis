#!/usr/bin/env bash
#==============================================================================
#  File:         start-script-test.sh
#  Description:  Checks how app/Tailscale turns build-time options, an injected
#                options file and an injected auth key into a "tailscale up"
#                command line.
#                • Build-time options must come first so injected ones win
#                • An empty or comment-only options file must change nothing
#                • An auth key must be passed by reference, never inline, and
#                  must never appear in anything the script logs
#
#  Usage:        ./start-script-test.sh [path/to/Tailscale]
#                Defaults to app/Tailscale in this repository.
#
#  Requires:     python3, only to create the unix socket the real daemon would.
#                Runs entirely on the host; no camera or emulator involved.
#==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
START_SCRIPT="${1:-${REPO_DIR}/app/Tailscale}"

# What build.sh would substitute for a non-root package.
BUILD_DAEMON_ARGS="--tun=userspace-networking"
BUILD_UP_ARGS="--accept-routes"

log()   { printf -- ">>> %s\n" "$*"; }
fatal() { printf -- "!!! %s\n" "$*" >&2; exit 1; }

[[ -f "${START_SCRIPT}" ]] || fatal "No such start script: ${START_SCRIPT}"
command -v python3 >/dev/null 2>&1 || fatal "python3 is required to create the test socket"

# Deliberately not under TMPDIR: on macOS that is a long path, and a unix socket
# path is limited to 104 bytes, which the state directory below would exceed.
WORK_ROOT="$(mktemp -d /tmp/sstest.XXXXXX)"
trap 'rm -rf "${WORK_ROOT}"' EXIT INT TERM

PASSED=0
FAILED=0

#------------------------------------------------------------------------------
# Builds a throwaway package tree with a stub in place of the combined binary,
# then runs the start script against it and captures what it logged and what
# arguments reached "tailscale up".
#
# $1 case name, $2 tailscale_up_opts.txt contents, $3 tailscale_authkey contents
#------------------------------------------------------------------------------
run_case() {
    local name="$1" opts_content="$2" key_content="$3"
    local dir="${WORK_ROOT}/${name}"

    mkdir -p "${dir}/lib"
    printf '%s' "${opts_content}" >"${dir}/tailscale_up_opts.txt"
    printf '%s' "${key_content}"  >"${dir}/tailscale_authkey"

    # Stands in for the combined tailscaled: records CLI invocations, and as a
    # daemon creates the socket the start script waits for, then exits once the
    # CLI has handled "up" so the test does not depend on timing.
    cat >"${dir}/lib/tailscaled" <<STUB
#!/bin/sh
DIR="${dir}"
case "\$1" in
    --version) echo "1.102.2-test"; exit 0 ;;
esac

if [ "\${TS_BE_CLI:-}" = "1" ]; then
    printf '%s\n' "\$*" >>"\${DIR}/cli.log"
    # Record from the subcommand onwards, dropping the --socket flag the ts()
    # helper prepends, so the assertions read as the composed up command line.
    seen_up=0
    rest=""
    for arg in "\$@"; do
        if [ "\${seen_up}" = 1 ]; then
            rest="\${rest} \${arg}"
        elif [ "\${arg}" = "up" ]; then
            seen_up=1
            rest="up"
        fi
    done
    if [ "\${seen_up}" = 1 ]; then
        printf '%s\n' "\${rest}" >"\${DIR}/up.args"
        : >"\${DIR}/up.done"
        exit 0
    fi
    echo "stub status output"
    exit 0
fi

printf '%s\n' "\$*" >"\${DIR}/daemon.args"
SOCKET=""
prev=""
for arg in "\$@"; do
    if [ "\${prev}" = "--socket" ]; then SOCKET="\${arg}"; fi
    prev="\${arg}"
done
python3 -c "import socket,sys;s=socket.socket(socket.AF_UNIX);s.bind(sys.argv[1]);s.listen(1)" "\${SOCKET}"

i=0
while [ \${i} -lt 150 ]; do
    [ -f "\${DIR}/up.done" ] && break
    i=\$((i + 1))
    sleep 0.1
done
exit 0
STUB
    chmod +x "${dir}/lib/tailscaled"

    # Only APP_DIR and the two build-time placeholders are rewritten, so the
    # logic under test is exactly what ships.
    sed -e "s%__TAILSCALED_ARGS__%${BUILD_DAEMON_ARGS}%" \
        -e "s%__TAILSCALE_ARGS__%${BUILD_UP_ARGS}%" \
        -e "s%^APP_DIR=\"/usr/local/packages/Tailscale\"%APP_DIR=\"${dir}\"%" \
        "${START_SCRIPT}" >"${dir}/run.sh"
    chmod +x "${dir}/run.sh"

    grep -q "^APP_DIR=\"${dir}\"" "${dir}/run.sh" \
        || fatal "Could not redirect APP_DIR; has the start script changed?"

    ( cd "${dir}" && sh ./run.sh >"${dir}/stdout.log" 2>&1 ) || true

    if [[ ! -f "${dir}/up.args" ]]; then
        printf -- "--- %s output ---\n" "${name}" >&2
        cat "${dir}/stdout.log" >&2
        fatal "${name}: the start script never ran 'tailscale up'"
    fi
    CASE_DIR="${dir}"
    CASE_UP_ARGS="$(cat "${dir}/up.args")"
    CASE_STDOUT="$(cat "${dir}/stdout.log")"
}

check() {
    local what="$1"
    if [[ "$2" == "ok" ]]; then
        printf -- "    ok   %s\n" "${what}"
        PASSED=$((PASSED + 1))
    else
        printf -- "    FAIL %s\n" "${what}"
        printf -- "         %s\n" "$3"
        FAILED=$((FAILED + 1))
    fi
}

expect_args() {
    local what="$1" expected="$2"
    if [[ "${CASE_UP_ARGS}" == "${expected}" ]]; then
        check "${what}" ok
    else
        check "${what}" fail "expected 'up ${expected#up }' but got '${CASE_UP_ARGS}'"
    fi
}

expect_stdout_lacks() {
    local what="$1" needle="$2"
    if [[ "${CASE_STDOUT}" == *"${needle}"* ]]; then
        check "${what}" fail "'${needle}' appeared in the log output"
    else
        check "${what}" ok
    fi
}

expect_stdout_has() {
    local what="$1" needle="$2"
    if [[ "${CASE_STDOUT}" == *"${needle}"* ]]; then
        check "${what}" ok
    else
        check "${what}" fail "'${needle}' missing from the log output"
    fi
}

#------------------------------------------------------------------------------
# Cases
#------------------------------------------------------------------------------
log "Testing ${START_SCRIPT}"
log "Build-time up options: ${BUILD_UP_ARGS}"

log "Case: placeholders exactly as shipped by build.sh"
SHIPPED_OPTS="$(cat "${REPO_DIR}/app/tailscale_up_opts.txt")"
run_case shipped "${SHIPPED_OPTS}" ""
expect_args "only the build-time options are used" "up ${BUILD_UP_ARGS}"
expect_stdout_lacks "no auth key is referenced" "--auth-key"

log "Case: empty options file, empty key file"
run_case empty "" ""
expect_args "only the build-time options are used" "up ${BUILD_UP_ARGS}"

log "Case: injected options, no key"
run_case opts_only "--hostname=cam-01 --advertise-tags=tag:camera --ssh" ""
expect_args "build-time options come first, injected ones after" \
    "up ${BUILD_UP_ARGS} --hostname=cam-01 --advertise-tags=tag:camera --ssh"
expect_stdout_lacks "no auth key is referenced" "--auth-key"

log "Case: injected options spread over several lines with comments"
run_case multiline "$(printf '# Injected by eap-inject.sh for cam-02.\n--hostname=cam-02\n--advertise-tags=tag:camera\n')" ""
expect_args "comments are dropped and the lines are joined" \
    "up ${BUILD_UP_ARGS} --hostname=cam-02 --advertise-tags=tag:camera"

log "Case: injected options and an auth key"
SECRET="tskey-auth-kTESTKEY01-supersecretvalue"
run_case with_key "--hostname=cam-03 --advertise-tags=tag:camera" "${SECRET}"
expect_args "the key is passed by reference, last" \
    "up ${BUILD_UP_ARGS} --hostname=cam-03 --advertise-tags=tag:camera --auth-key=file:${CASE_DIR}/tailscale_authkey"
expect_stdout_lacks "the key itself never reaches the log" "${SECRET}"
expect_stdout_has "the log says a key was found" "Found an injected auth key"

log "Case: auth key with surrounding whitespace"
run_case key_whitespace "--hostname=cam-04" "$(printf '%s\n\n' "${SECRET}")"
expect_args "the key is still referenced" \
    "up ${BUILD_UP_ARGS} --hostname=cam-04 --auth-key=file:${CASE_DIR}/tailscale_authkey"
expect_stdout_lacks "the key itself never reaches the log" "${SECRET}"

log "Case: key file holding something that is not a key"
run_case key_garbage "--hostname=cam-05" "not-a-tailscale-key"
expect_args "the bogus key is ignored rather than passed on" \
    "up ${BUILD_UP_ARGS} --hostname=cam-05"

log "Case: options file holding only comments"
run_case comments_only "$(printf '# nothing to see here\n#--ssh\n')" ""
expect_args "a comment-only file counts as empty" "up ${BUILD_UP_ARGS}"

#------------------------------------------------------------------------------
log "${PASSED} passed, ${FAILED} failed"
[[ "${FAILED}" -eq 0 ]] || fatal "start script argument composition is wrong"
log "SUCCESS"
exit 0
