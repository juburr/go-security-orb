#!/bin/bash
#
# Sets up where go fetches modules from, for the configure_modules command:
# GOPROXY, GONOSUMDB, GOPRIVATE and GOSUMDB for later steps, and credentials
# for one host in ~/.netrc (or the file NETRC names), which go reads for a
# proxy and for modules it fetches straight from their host, and git reads
# when go fetches with it. Nothing changes unless every parameter is valid.
#
# The script is identical in go-security-orb and go-quality-orb, and needs
# neither orb's helpers, so a job can take the command from either orb.
# tests/configure_modules_test.sh, identical in both too, tests it.

set -euo pipefail

subst() {
    if command -v circleci > /dev/null 2>&1; then
        printf '%s' "$1" | circleci env subst
    else
        printf '%s\n' "$1"
    fi
}

# match VALUE REGEX: [[ VALUE =~ REGEX ]] in the C locale, where a range such
# as [a-z] matches ASCII letters only.
match() {
    local LC_ALL=C
    [[ "$1" =~ $2 ]]
}

env_var_name() {
    if ! match "$2" '^[A-Za-z_][A-Za-z0-9_]*$'; then
        echo "ERROR: ${1} must name an environment variable, not '${2}'." >&2
        exit 1
    fi
}

GOPROXY_VALUE=$(subst "${PARAM_GOPROXY}")
GONOSUMDB_VALUE=$(subst "${PARAM_GONOSUMDB}")
GOPRIVATE_VALUE=$(subst "${PARAM_GOPRIVATE}")
GOSUMDB_VALUE=$(subst "${PARAM_GOSUMDB}")
HOST=$(subst "${PARAM_HOST}")
env_var_name username "${PARAM_USERNAME}"
env_var_name password "${PARAM_PASSWORD}"

if [[ -z "${GOPROXY_VALUE}${GONOSUMDB_VALUE}${GOPRIVATE_VALUE}${GOSUMDB_VALUE}${HOST}" ]]; then
    echo "ERROR: There is nothing to configure: goproxy, gonosumdb, goprivate, gosumdb and host are all empty." >&2
    exit 1
fi

# Module paths on public hosts. A GONOSUMDB or GOPRIVATE pattern that matches
# one of these matches far more than an organization's own modules. The list
# is the one go-security-orb's mod_verify checks the job's settings against.
PUBLIC=(github.com/owner/repo gitlab.com/owner/repo bitbucket.org/owner/repo golang.org/x/net golang.org/toolchain
    google.golang.org/grpc gopkg.in/yaml.v3 go.googlesource.com/repo k8s.io/api sigs.k8s.io/yaml go.uber.org/zap
    cloud.google.com/go go.opentelemetry.io/otel honnef.co/go/tools)

# public_match PATTERNS: prints the first of PUBLIC that PATTERNS, a
# comma-separated list, matches, the way go matches them: a pattern with N
# slashes matches a module path whose first N+1 elements it matches as a
# glob. Prints nothing when it matches none.
public_match() {
    local glob target slashes prefix
    local -a globs=() parts=()
    IFS=, read -r -a globs <<< "$1"
    for target in "${PUBLIC[@]}"; do
        IFS=/ read -r -a parts <<< "${target}"
        for glob in ${globs[@]+"${globs[@]}"}; do
            glob=${glob%/}
            slashes=${glob//[^\/]/}
            if [[ -z "${glob}" ]] || ((${#parts[@]} < ${#slashes} + 1)); then
                continue
            fi
            prefix=$(IFS=/ && printf '%s' "${parts[*]:0:${#slashes}+1}")
            # shellcheck disable=SC2053 # a glob, as go matches it
            if [[ "${prefix}" == ${glob} ]]; then
                printf '%s\n' "${target}"
                return 0
            fi
        done
    done
}

# check_patterns PARAMETER VALUE WHAT: stops the step unless VALUE is a
# comma-separated list of module path patterns that match none of PUBLIC.
check_patterns() {
    local hit
    if [[ -z "$2" ]]; then
        return 0
    fi
    if [[ "$2" == *[[:space:]]* ]]; then
        echo "ERROR: ${1} must be separated by commas, without spaces." >&2
        exit 1
    fi
    hit=$(public_match "$2")
    if [[ -n "${hit}" ]]; then
        echo "ERROR: ${1} (${2}) matches public modules such as ${hit}, which go would then ${3}" >&2
        echo "  without checking them against the checksum database. Name your own modules, such as github.com/my-org/*." >&2
        exit 1
    fi
}
check_patterns gonosumdb "${GONOSUMDB_VALUE}" "fetch"
check_patterns goprivate "${GOPRIVATE_VALUE}" "fetch straight from their hosts,"

# GOPROXY: proxy URLs, direct and off, separated by commas or pipes. Plain
# HTTP only reaches this machine, and credentials belong in .netrc, where
# they never show in go env, go's error messages or the log.
if [[ -n "${GOPROXY_VALUE}" ]]; then
    IFS=',|' read -r -a PROXIES <<< "${GOPROXY_VALUE}"
    if [[ "${GOPROXY_VALUE}" == *[[:space:]]* || "${GOPROXY_VALUE}" == *[,\|] || ${#PROXIES[@]} -eq 0 ]]; then
        echo "ERROR: goproxy must be proxy URLs, direct or off, separated by commas or pipes, without spaces." >&2
        exit 1
    fi
    PATH_RE='(/[^?#@[:space:]]*)?$'
    for proxy in "${PROXIES[@]}"; do
        case "${proxy}" in
            direct | off) continue ;;
        esac
        if [[ "${proxy}" =~ ^[A-Za-z][A-Za-z0-9+.-]*://[^/]*@ ]]; then
            echo "ERROR: goproxy holds credentials in a URL, where go env and go's error messages would show them." >&2
            echo "  Give the proxy's host in host, and the credentials in the variables username and password name." >&2
            exit 1
        fi
        if match "${proxy}" "^https://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?${PATH_RE}" \
            || match "${proxy}" "^http://(localhost|127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|\[::1\])(:[0-9]{1,5})?${PATH_RE}" \
            || match "${proxy}" '^file:///[^?#[:space:]]*$'; then
            continue
        fi
        echo "ERROR: goproxy has '${proxy}', which is not direct, off, an https:// URL without a query or" >&2
        echo "  fragment, a file:/// URL, or an http:// URL on this machine." >&2
        exit 1
    done
fi

# GOSUMDB: the checksum database's name, with its key, and the URL to reach
# it through, such as a proxy of sum.golang.org. off is refused: it turns
# checksum verification off for every module.
if [[ -n "${GOSUMDB_VALUE}" ]]; then
    if [[ "${GOSUMDB_VALUE}" == off ]]; then
        echo "ERROR: gosumdb is off, which turns checksum verification off for every module. Name your own modules in gonosumdb instead." >&2
        exit 1
    fi
    if ! match "${GOSUMDB_VALUE}" '^[A-Za-z0-9.-]+(\+[A-Za-z0-9+/=._-]+)?( https://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?(/[^?#@[:space:]]*)?)?$'; then
        echo "ERROR: gosumdb must be a checksum database's name, with an optional +key, and an optional https:// URL" >&2
        echo "  after one space, such as 'sum.golang.org https://proxy.example.com/sumdb/sum.golang.org'." >&2
        exit 1
    fi
fi

# Credentials for host, read now so a missing one stops the step before it
# changes anything.
if [[ -n "${HOST}" ]]; then
    # The credentials must never reach the log.
    set +o xtrace
    if ! match "${HOST}" '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?$'; then
        echo "ERROR: host must be a host name, with an optional port, not '${HOST}'." >&2
        exit 1
    fi
    NETRC_USER=${!PARAM_USERNAME:-}
    NETRC_PASSWORD=${!PARAM_PASSWORD:-}
    if [[ -z "${NETRC_USER}" || -z "${NETRC_PASSWORD}" ]]; then
        echo "ERROR: host is ${HOST}, but ${PARAM_USERNAME} or ${PARAM_PASSWORD} is empty or unset." >&2
        echo "  Set both, such as in a CircleCI context or as GitHub Actions secrets, or leave host empty." >&2
        exit 1
    fi
    # .netrc has no quoting, and go reads everything after a # as a comment.
    if [[ "${NETRC_USER}${NETRC_PASSWORD}" == *[[:space:]#]* ]]; then
        echo "ERROR: ${PARAM_USERNAME} and ${PARAM_PASSWORD} can't hold spaces or #, which .netrc can't represent." >&2
        exit 1
    fi
    NETRC_FILE=${NETRC:-${HOME:-}/.netrc}
    if [[ "${NETRC_FILE}" != /?* ]]; then
        echo "ERROR: Neither NETRC nor HOME is set, so there is no .netrc to write the credentials to." >&2
        exit 1
    fi
fi

if [[ -z "${BASH_ENV:-}" && -n "${GOPROXY_VALUE}${GONOSUMDB_VALUE}${GOPRIVATE_VALUE}${GOSUMDB_VALUE}" ]]; then
    echo "ERROR: BASH_ENV is not set, so the settings can't reach later steps." >&2
    exit 1
fi

NETRC_TMP=""
cleanup() {
    if [[ -n "${NETRC_TMP}" ]]; then
        rm -f "${NETRC_TMP}"
    fi
}
trap cleanup EXIT

if [[ -n "${HOST}" ]]; then
    mkdir -p "${NETRC_FILE%/*}"
    NETRC_TMP=$(umask 077 && mktemp "${NETRC_FILE%/*}/.netrc.XXXXXX")
    # The entry goes first, since go and git use the first entry for a host,
    # and replaces the one an earlier run wrote, also by go-security-orb's
    # mod_verify before 0.2.0. A new file replaces the old one, so a .netrc
    # that is a symbolic link is replaced rather than written through.
    {
        printf '# configure_modules %s\n' "${HOST}"
        printf 'machine %s login %s password %s\n' "${HOST}" "${NETRC_USER}" "${NETRC_PASSWORD}"
        if [[ -f "${NETRC_FILE}" ]]; then
            awk -v marker="# configure_modules ${HOST}" -v old="# go-security-orb mod_verify ${HOST}" \
                'skip { skip = 0; next } $0 == marker || $0 == old { skip = 1; next } { print }' "${NETRC_FILE}"
        fi
    } > "${NETRC_TMP}"
    chmod 600 "${NETRC_TMP}"
    if ! mv -f -- "${NETRC_TMP}" "${NETRC_FILE}"; then
        echo "ERROR: Could not write ${NETRC_FILE}." >&2
        exit 1
    fi
    NETRC_TMP=""
    unset NETRC_USER NETRC_PASSWORD
    echo "Wrote the credentials in ${PARAM_USERNAME} and ${PARAM_PASSWORD} for ${HOST} to ${NETRC_FILE}, for this step and later ones."
    # GOAUTH (Go 1.24 and newer) names where go finds credentials; netrc is
    # its default.
    if [[ -n "${GOAUTH:-}" && ";${GOAUTH// /};" != *";netrc;"* ]]; then
        echo "WARN: GOAUTH is '${GOAUTH}', which leaves netrc out, so go won't read these credentials." >&2
    fi
    if [[ -n "${NETRC:-}" && "${NETRC}" != "${HOME:-}/.netrc" ]]; then
        echo "WARN: NETRC names ${NETRC}, which go reads, but git, which go runs for modules it fetches from their hosts, reads only ~/.netrc." >&2
    fi
fi

# export_setting NAME VALUE: exports NAME to later steps, when VALUE is set.
export_setting() {
    if [[ -n "$2" ]]; then
        printf 'export %s=%q\n' "$1" "$2" >> "${BASH_ENV}"
        echo "${1}=${2}, for later steps."
    fi
}
export_setting GOPROXY "${GOPROXY_VALUE}"
export_setting GONOSUMDB "${GONOSUMDB_VALUE}"
export_setting GOPRIVATE "${GOPRIVATE_VALUE}"
export_setting GOSUMDB "${GOSUMDB_VALUE}"
