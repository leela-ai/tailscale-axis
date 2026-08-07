#!/usr/bin/env bash
#==============================================================================
#  File:         fleet-plan.lib.sh
#  Description:  Shared helpers for the fleet tooling: logging, dependency
#                checks, and parsing/validating the semicolon-delimited fleet
#                plan file.
#
#  Usage:        Sourced, not executed:
#                    . "$(dirname "$0")/fleet-plan.lib.sh"
#
#  Plan format:  See tools/fleet-plan.example.csv. One row per device:
#                    hostname;tags;extra_opts;key_id;authkey
#                Semicolons separate columns so commas stay usable inside tags
#                and extra_opts. Blank lines and # comments are ignored.
#==============================================================================

# Guard against being run directly, which would silently do nothing.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    printf -- "!!! %s is a library and must be sourced, not executed.\n" "${BASH_SOURCE[0]##*/}" >&2
    exit 1
fi

PLAN_HEADER="hostname;tags;extra_opts;key_id;authkey"

#------------------------------------------------------------------------------
# Logging helpers
#------------------------------------------------------------------------------
log()   { printf -- ">>> [%s] %s\n" "$(date +'%H:%M:%S')" "$*"; }
info()  { printf -- "  - %s\n" "$*"; }
warn()  { printf -- "!!! [%s] %s\n" "$(date +'%H:%M:%S')" "$*" >&2; }
fatal() { warn "$*"; exit 1; }

need() {
    command -v "$1" >/dev/null 2>&1 || fatal "Missing required dependency: $1"
}

#------------------------------------------------------------------------------
# Parsed plan, as parallel arrays indexed 0..PLAN_COUNT-1. PLAN_LINE_NO holds
# the source line of each row so validation errors can point at it.
#------------------------------------------------------------------------------
PLAN_COUNT=0
declare -a PLAN_HOSTNAME=()
declare -a PLAN_TAGS=()
declare -a PLAN_EXTRA=()
declare -a PLAN_KEY_ID=()
declare -a PLAN_AUTHKEY=()
declare -a PLAN_LINE_NO=()

# Trims leading and trailing whitespace from $1 and prints the result.
plan_trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "${s}"
}

# Prints the comma-separated tag list $1 as one trimmed, non-empty tag per line.
# The IFS override is scoped to the read builtin so it cannot leak into the
# caller, and printing avoids needing namerefs (bash 4.3+, absent on macOS).
plan_split_tags() {
    local raw="$1"
    local -a parts=()
    local part
    IFS=',' read -r -a parts <<<"${raw}"
    for part in "${parts[@]}"; do
        part="$(plan_trim "${part}")"
        [[ -n "${part}" ]] && printf '%s\n' "${part}"
    done
    return 0
}

# True when the line carries no data: empty, whitespace only, or a comment.
plan_line_is_skippable() {
    local line
    line="$(plan_trim "$1")"
    [[ -z "${line}" || "${line}" == \#* ]]
}

# Reads a plan file into the PLAN_* arrays. Rejects a missing or reordered
# header, since silently misreading columns would put auth keys in the wrong
# packages.
plan_parse() {
    local file="$1"
    [[ -f "${file}" ]] || fatal "Plan file not found: ${file}"

    PLAN_COUNT=0
    PLAN_HOSTNAME=(); PLAN_TAGS=(); PLAN_EXTRA=()
    PLAN_KEY_ID=(); PLAN_AUTHKEY=(); PLAN_LINE_NO=()

    local line lineno=0 seen_header=0
    local hostname tags extra key_id authkey overflow
    while IFS= read -r line || [[ -n "${line}" ]]; do
        lineno=$((lineno + 1))
        # Tolerate CRLF, which is what spreadsheet exports produce.
        line="${line%$'\r'}"

        plan_line_is_skippable "${line}" && continue

        if [[ "${seen_header}" -eq 0 ]]; then
            seen_header=1
            if [[ "$(plan_trim "${line}")" != "${PLAN_HEADER}" ]]; then
                fatal "${file}:${lineno}: first data line must be the header '${PLAN_HEADER}', got '${line}'"
            fi
            continue
        fi

        IFS=';' read -r hostname tags extra key_id authkey overflow <<<"${line}"
        if [[ -n "${overflow}" ]]; then
            fatal "${file}:${lineno}: too many ';' separated columns; expected 5 (${PLAN_HEADER})"
        fi

        PLAN_HOSTNAME[PLAN_COUNT]="$(plan_trim "${hostname}")"
        PLAN_TAGS[PLAN_COUNT]="$(plan_trim "${tags}")"
        PLAN_EXTRA[PLAN_COUNT]="$(plan_trim "${extra}")"
        PLAN_KEY_ID[PLAN_COUNT]="$(plan_trim "${key_id}")"
        PLAN_AUTHKEY[PLAN_COUNT]="$(plan_trim "${authkey}")"
        PLAN_LINE_NO[PLAN_COUNT]="${lineno}"
        PLAN_COUNT=$((PLAN_COUNT + 1))
    done < "${file}"

    [[ "${seen_header}" -eq 1 ]] || fatal "${file}: no header line found"
    [[ "${PLAN_COUNT}" -gt 0 ]] || fatal "${file}: header found but no device rows"
}

# Validates the parsed plan. Everything is checked before any side effect so a
# typo cannot leave half a fleet provisioned.
plan_validate() {
    local file="$1"
    local i host tags extra tag errors=0
    local seen=""

    for ((i = 0; i < PLAN_COUNT; i++)); do
        host="${PLAN_HOSTNAME[i]}"
        tags="${PLAN_TAGS[i]}"
        extra="${PLAN_EXTRA[i]}"
        local where="${file}:${PLAN_LINE_NO[i]}"

        if [[ -z "${host}" ]]; then
            warn "${where}: hostname is empty"
            errors=$((errors + 1))
            continue
        fi

        # The hostname also becomes part of the output .eap filename, so keep it
        # to characters that are safe in both a filename and a DNS label.
        if [[ ! "${host}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
            warn "${where}: hostname '${host}' must start alphanumeric and contain only letters, digits, '.', '_' or '-'"
            errors=$((errors + 1))
        fi
        if [[ "${#host}" -gt 63 ]]; then
            warn "${where}: hostname '${host}' is longer than the 63 character DNS label limit"
            errors=$((errors + 1))
        fi
        if [[ "${host}" =~ [A-Z] ]]; then
            warn "${where}: hostname '${host}' contains uppercase; Tailscale will lowercase it"
        fi

        case ";${seen};" in
            *";${host};"*)
                warn "${where}: duplicate hostname '${host}'"
                errors=$((errors + 1))
                ;;
        esac
        seen="${seen};${host}"

        if [[ -z "${tags}" ]]; then
            warn "${where}: tags are required; tagged nodes have key expiry disabled, so an untagged camera drops off the tailnet when its node key expires"
            errors=$((errors + 1))
        else
            while IFS= read -r tag; do
                [[ -z "${tag}" ]] && continue
                if [[ ! "${tag}" =~ ^tag:[a-zA-Z0-9][a-zA-Z0-9-]*$ ]]; then
                    warn "${where}: invalid tag '${tag}'; expected the form tag:name"
                    errors=$((errors + 1))
                fi
            done <<<"$(plan_split_tags "${tags}")"
        fi

        # An inline key here would end up in the process arguments and in the
        # application log, which the settings page exposes to any admin.
        if [[ "${extra}" == *--auth-key* || "${extra}" == *--authkey* ]]; then
            warn "${where}: extra_opts must not contain an auth key; put it in the authkey column so it is passed by reference"
            errors=$((errors + 1))
        fi
        if [[ "${extra}" == *--hostname* || "${extra}" == *--advertise-tags* ]]; then
            warn "${where}: extra_opts must not set --hostname or --advertise-tags; use the hostname and tags columns"
            errors=$((errors + 1))
        fi
    done

    [[ "${errors}" -eq 0 ]] || fatal "${file}: ${errors} problem(s) found; nothing was changed"
}

# Prints the plan row at index $1 as a plan file line.
plan_format_row() {
    local i="$1"
    printf '%s;%s;%s;%s;%s\n' \
        "${PLAN_HOSTNAME[i]}" "${PLAN_TAGS[i]}" "${PLAN_EXTRA[i]}" \
        "${PLAN_KEY_ID[i]}" "${PLAN_AUTHKEY[i]}"
}

# Rewrites a plan file from the PLAN_* arrays, streaming the original so
# comments, blank lines and row order survive untouched. Only the data rows are
# replaced, in order. Written via a 0600 temp file and moved into place so an
# interrupted run cannot leave a half-written plan.
plan_rewrite() {
    local file="$1"
    local tmp line lineno=0 row=0 seen_header=0
    local old_umask
    old_umask="$(umask)"
    umask 077
    tmp="$(mktemp "${file}.XXXXXX")" || fatal "Unable to create a temporary file next to ${file}"
    umask "${old_umask}"

    while IFS= read -r line || [[ -n "${line}" ]]; do
        lineno=$((lineno + 1))
        line="${line%$'\r'}"

        if plan_line_is_skippable "${line}"; then
            printf '%s\n' "${line}" >>"${tmp}"
            continue
        fi
        if [[ "${seen_header}" -eq 0 ]]; then
            seen_header=1
            printf '%s\n' "${line}" >>"${tmp}"
            continue
        fi

        plan_format_row "${row}" >>"${tmp}"
        row=$((row + 1))
    done < "${file}"

    if [[ "${row}" -ne "${PLAN_COUNT}" ]]; then
        rm -f "${tmp}"
        fatal "${file} changed while it was being processed (${row} rows now, ${PLAN_COUNT} when parsed); nothing was written"
    fi

    mv -f "${tmp}" "${file}" || { rm -f "${tmp}"; fatal "Failed to update ${file}"; }
    chmod 600 "${file}"
}
