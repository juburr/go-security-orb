#!/bin/bash

# Shared helpers for the go-security-orb commands. Each command passes this
# file to its step as SCRIPT_GO_SECURITY_LIB, and its script evals it after
# set -euo pipefail, so it only defines functions.

# gs_subst VALUE: prints VALUE with environment variables expanded. The value
# is piped in on stdin: passed as an argument, a value starting with "-" would
# be parsed as a flag. Without the CircleCI CLI (GitHub Actions and local
# runs), the value is used as is.
gs_subst() {
    if command -v circleci > /dev/null 2>&1; then
        printf '%s' "$1" | circleci env subst
    else
        printf '%s\n' "$1"
    fi
}

# gs_bool NAME VALUE: prints true or false. CircleCI passes boolean parameters
# as 1 or 0; GitHub Actions and local callers use true or false.
gs_bool() {
    case "$2" in
        1 | true) echo true ;;
        0 | false) echo false ;;
        *)
            echo "ERROR: ${1} must be true or false, not '${2}'." >&2
            exit 1
            ;;
    esac
}

# split_shell_words STRING: splits STRING into the SHELL_WORDS array the way
# the shell splits a command line into words, but expands and executes
# nothing. Single quotes keep everything literal. Inside double quotes a
# backslash escapes only ", \, $, ` and newline, as in bash. Outside quotes a
# backslash escapes the next character, and a backslash-newline joins lines.
# A # that starts a word starts a comment, which runs to the end of the line.
# Spaces, tabs and newlines separate words, and '' is an empty word. Returns 1
# if a quote is never closed, 2 if the input ends in a backslash outside
# quotes (which escapes nothing), 3 for bash's $'...' or $"..." quoting, which
# it does not implement, 4 for a $(...) or backtick outside quotes, which it
# would not run, and 5 for a shell operator (| & ; < > ( )) outside quotes,
# such as a redirection or a <(...) process substitution.
split_shell_words() {
    local input=$1 word="" in_word=false quote="" char next i
    SHELL_WORDS=()
    for ((i = 0; i < ${#input}; i++)); do
        char=${input:i:1}
        if [[ "${quote}" == "'" ]]; then
            if [[ "${char}" == "'" ]]; then quote=""; else word+=${char}; fi
        elif [[ "${quote}" == '"' ]]; then
            if [[ "${char}" == '"' ]]; then
                quote=""
            elif [[ "${char}" == "\\" ]] && ((i + 1 < ${#input})); then
                next=${input:i+1:1}
                case "${next}" in
                    '"' | "\\" | '$' | '`') word+=${next}; i=$((i + 1)) ;;
                    $'\n') i=$((i + 1)) ;;
                    *) word+=${char} ;;
                esac
            else
                word+=${char}
            fi
        else
            case "${char}" in
                ' ' | $'\t' | $'\n')
                    if [[ "${in_word}" == true ]]; then
                        SHELL_WORDS+=("${word}")
                        word=""
                        in_word=false
                    fi
                    ;;
                "'" | '"') quote=${char}; in_word=true ;;
                "#")
                    if [[ "${in_word}" == true ]]; then
                        word+=${char}
                    else
                        while ((i + 1 < ${#input})) && [[ "${input:i+1:1}" != $'\n' ]]; do
                            i=$((i + 1))
                        done
                    fi
                    ;;
                "\\")
                    ((i + 1 < ${#input})) || return 2
                    i=$((i + 1))
                    if [[ "${input:i:1}" != $'\n' ]]; then
                        word+=${input:i:1}
                        in_word=true
                    fi
                    ;;
                '$')
                    case "${input:i+1:1}" in
                        "'" | '"') return 3 ;;
                        "(") return 4 ;;
                    esac
                    word+=${char}
                    in_word=true
                    ;;
                '`') return 4 ;;
                '|' | '&' | ';' | '<' | '>' | '(' | ')') return 5 ;;
                *) word+=${char}; in_word=true ;;
            esac
        fi
    done
    [[ -z "${quote}" ]] || return 1
    if [[ "${in_word}" == true ]]; then
        SHELL_WORDS+=("${word}")
    fi
}

# gs_words PARAMETER VALUE: sets GS_WORDS to VALUE split like shell words
# (see split_shell_words), naming PARAMETER in any error. Nothing in it is
# expanded or executed: a $(...) or backtick that reached a parameter through
# an environment variable (a branch name, a commit message) reaches the tool as
# text inside quotes, and fails the step outside them.
gs_words() {
    local status=0
    split_shell_words "$2" || status=$?
    case "${status}" in
        0) ;;
        1)
            echo "ERROR: ${1} could not be split into arguments: it has a quote that is never closed." >&2
            echo "  A literal ' or \" needs a backslash before it, or quotes of the other kind around it." >&2
            exit 1
            ;;
        2)
            echo "ERROR: ${1} could not be split into arguments: it ends in a backslash." >&2
            echo "  A literal \\ at the end needs another \\ before it." >&2
            exit 1
            ;;
        3)
            echo "ERROR: ${1} could not be split into arguments: \$'...' and \$\"...\" quoting is not supported." >&2
            echo "  Use '...' or \"...\" instead." >&2
            exit 1
            ;;
        4)
            echo "ERROR: ${1} could not be split into arguments: it has a \$(...) or backtick outside quotes." >&2
            echo "  ${1} is not run as shell code, so the command would not run. Quote it to pass it to the tool as text." >&2
            exit 1
            ;;
        *)
            echo "ERROR: ${1} could not be split into arguments: it has one of | & ; < > ( ) outside quotes." >&2
            echo "  ${1} is not run as shell code, so pipes, redirections and <(...) would not work. Quote it to pass it to the tool as text." >&2
            exit 1
            ;;
    esac
    # shellcheck disable=SC2034 # read by the script that evals this file
    GS_WORDS=(${SHELL_WORDS[@]+"${SHELL_WORDS[@]}"})
}

# gs_match VALUE REGEX: [[ VALUE =~ REGEX ]] in the C locale, setting
# BASH_REMATCH. In other locales a range such as [a-z] can match letters such
# as é (cimg images set LC_ALL=en_US.UTF-8), so checks with ranges use this.
gs_match() {
    local LC_ALL=C
    [[ "$1" =~ $2 ]]
}

# gs_list PARAMETER VALUE: sets GS_LIST to VALUE, with environment variables
# expanded, split on commas and spaces.
gs_list() {
    local value
    GS_LIST=()
    value=$(gs_subst "$2")
    if [[ "${value}" == *$'\n'* ]]; then
        echo "ERROR: ${1} must be separated by commas or spaces, not newlines." >&2
        exit 1
    fi
    # shellcheck disable=SC2034 # read by the script that evals this file
    read -r -a GS_LIST <<< "${value//,/ }"
}

# gs_tool BINARY: sets GS_TOOL to BINARY's path on the PATH, or stops the
# step saying how to install it. Warns when that binary is not one this
# orb's install verified, such as a copy that came with the image and comes
# first on the PATH: the install leaves a record beside each binary it
# installs, naming the binary's SHA-512.
gs_tool() {
    if ! GS_TOOL=$(command -v "$1"); then
        echo "ERROR: $1 is not on the PATH. Install it in an earlier step with this orb's install (tools: $1)," >&2
        echo "  or with install_${1//-/_}." >&2
        exit 1
    fi
    gs_tool_verified "$1" "${GS_TOOL}"
}

# gs_tool_verified NAME PATH: warns unless PATH is a NAME this orb's install
# verified, as the install record it leaves beside the binary says.
gs_tool_verified() {
    local record sha
    record="$(dirname "$2")/.$1.install.json"
    sha=$(sha512sum -- "$2" 2> /dev/null | awk '{ print $1 }') || sha=""
    if [[ -z "${sha}" || ! -f "${record}" ]] || ! grep -qF "\"binary_sha512\":\"${sha}\"" "${record}"; then
        echo "WARN: $2 is not the $1 this orb's install verified against its checksum table." >&2
        echo "WARN: Install $1 with this orb's install, and put its install_path first on the PATH, to run a verified one." >&2
    fi
}

# gs_go: stops the step unless go is on the PATH.
gs_go() {
    if ! command -v go > /dev/null 2>&1; then
        echo "ERROR: go is not on the PATH. Use an image with Go, such as cimg/go, or install it in an earlier step" >&2
        echo "  with this orb's install_go." >&2
        exit 1
    fi
}

# gs_require_jq: stops the step unless jq, which the reports are built with,
# is on the PATH.
gs_require_jq() {
    if ! command -v jq > /dev/null 2>&1; then
        echo "ERROR: jq is not on the PATH, and this command needs it to write its reports." >&2
        echo "  CircleCI's cimg images and GitHub's hosted runners have it; elsewhere, install jq in an earlier step." >&2
        exit 1
    fi
}

# gs_output DIR NAME: checks output_dir and report_name, creates DIR, and sets
# GS_OUT to DIR and GS_BASE to the path every report of this run starts with.
gs_output() {
    if [[ "$1" != /* || "$1" == *$'\n'* ]]; then
        echo "ERROR: output_dir must be an absolute path, not '$1'." >&2
        exit 1
    fi
    if ! gs_match "$2" '^[A-Za-z0-9][A-Za-z0-9._-]*$'; then
        echo "ERROR: report_name must be letters, digits, '.', '_' and '-', not '$2'." >&2
        exit 1
    fi
    if ! mkdir -p "$1"; then
        echo "ERROR: Could not create output_dir $1." >&2
        exit 1
    fi
    GS_OUT=${1%/}
    GS_OUT=${GS_OUT:-/}
    # shellcheck disable=SC2034 # read by the script that evals this file
    GS_BASE="${GS_OUT%/}/$2"
}

# gs_uint PARAMETER VALUE [MIN]: stops the step unless VALUE is a whole number
# of at least MIN (default 0).
gs_uint() {
    if ! gs_match "$2" '^[0-9]{1,9}$' || ((10#$2 < ${3:-0})); then
        echo "ERROR: ${1} must be a whole number of at least ${3:-0}, not '$2'." >&2
        exit 1
    fi
}

# gs_duration PARAMETER VALUE: stops the step unless VALUE looks like a Go
# duration (30s, 1m30s, 500ms), or, for flags that take one, a count of runs
# (100x). Go checks it exactly; this catches a value that isn't one at all.
gs_duration() {
    if ! gs_match "$2" '^([0-9]+(\.[0-9]+)?(ns|us|ms|s|m|h))+$|^[0-9]+x$'; then
        echo "ERROR: ${1} must be a Go duration such as 30s, 5m or 1h30m, not '$2'." >&2
        exit 1
    fi
}

# gs_regex PARAMETER VALUE: stops the step unless VALUE can be passed to go
# test or go generate as one regular expression argument.
gs_regex() {
    if [[ "$2" == *$'\n'* ]]; then
        echo "ERROR: ${1} must be one line." >&2
        exit 1
    fi
}

# gs_modules VALUE: sets GS_MODULES to the module directories VALUE names,
# relative to the working directory, and stops the step if one isn't a
# module. VALUE is a list separated by commas or spaces ("." when empty), or
# "all" for every go.mod below the working directory, skipping the
# directories the go command skips in ./... patterns: vendor, testdata, and
# names that start with "." or "_".
gs_modules() {
    local entry dir found
    local -A seen=()
    GS_MODULES=()
    gs_list modules "$1"
    if [[ ${#GS_LIST[@]} -eq 0 ]]; then
        GS_LIST=(.)
    fi
    if [[ ${#GS_LIST[@]} -eq 1 && "${GS_LIST[0]}" == all ]]; then
        while IFS= read -r -d '' found; do
            dir=${found%/go.mod}
            dir=${dir#./}
            GS_MODULES+=("${dir}")
        done < <(find . -mindepth 1 -type d \( -name vendor -o -name testdata -o -name '.*' -o -name '_*' \) -prune \
            -o -type f -name go.mod -print0 | LC_ALL=C sort -z)
        if [[ ${#GS_MODULES[@]} -eq 0 ]]; then
            echo "ERROR: modules is all, but there is no go.mod in $(pwd) or below it." >&2
            exit 1
        fi
        # find prints the working directory's own go.mod as ./go.mod.
        for entry in "${!GS_MODULES[@]}"; do
            if [[ "${GS_MODULES[${entry}]}" == go.mod ]]; then
                GS_MODULES[entry]=.
            fi
        done
        return 0
    fi
    for entry in "${GS_LIST[@]}"; do
        dir=${entry}
        while [[ "${dir}" == */ && "${dir}" != / ]]; do
            dir=${dir%/}
        done
        while [[ "${dir}" == ./* ]]; do
            dir=${dir#./}
        done
        if [[ "${dir}" == all ]]; then
            echo "ERROR: modules can be all, or a list of module directories, not both." >&2
            exit 1
        fi
        if [[ "${dir}" == /* || "/${dir}/" == */../* ]]; then
            echo "ERROR: modules must name directories inside the working directory, without '..', not '${entry}'." >&2
            exit 1
        fi
        if [[ ! -f "${dir}/go.mod" ]]; then
            echo "ERROR: modules names ${entry}, which has no go.mod (in $(pwd))." >&2
            if [[ "${dir}" == . ]]; then
                echo "  For a repository without a go.mod at its top, set modules to all, or list the module directories." >&2
            fi
            exit 1
        fi
        if [[ -z "${seen[${dir}]+set}" ]]; then
            seen[${dir}]=1
            GS_MODULES+=("${dir}")
        fi
    done
}

# gs_label DIR: prints how messages name the module in DIR: its module path,
# from its go.mod, and DIR when it isn't the working directory, such as
# "example.com/api (services/api)".
gs_label() {
    local path
    path=$(awk '$1 == "module" { gsub(/"/, "", $2); print $2; exit }' "$1/go.mod" 2> /dev/null) || path=""
    if [[ -z "${path}" ]]; then
        printf '%s\n' "$1"
    elif [[ "$1" == . ]]; then
        printf '%s\n' "${path}"
    else
        printf '%s (%s)\n' "${path}" "$1"
    fi
}

# gs_labels DIR...: prints the labels of the modules in DIR..., separated by
# commas.
gs_labels() {
    local dir out=""
    for dir in "$@"; do
        out+="${out:+, }$(gs_label "${dir}")"
    done
    printf '%s\n' "${out}"
}

# gs_join MODULE PATH: prints PATH, which is relative to MODULE, relative to
# the working directory instead.
gs_join() {
    if [[ "$1" == . ]]; then
        printf '%s\n' "$2"
    else
        printf '%s/%s\n' "$1" "$2"
    fi
}

# gs_packages VALUE: sets GS_PACKAGES to the package patterns VALUE names,
# separated by commas or spaces ("./..." when empty). A pattern can't start
# with "-", which the go command would read as a flag.
gs_packages() {
    local pattern
    gs_list packages "$1"
    GS_PACKAGES=(${GS_LIST[@]+"${GS_LIST[@]}"})
    if [[ ${#GS_PACKAGES[@]} -eq 0 ]]; then
        GS_PACKAGES=(./...)
    fi
    for pattern in "${GS_PACKAGES[@]}"; do
        if [[ "${pattern}" == -* ]]; then
            echo "ERROR: packages names '${pattern}', which the go command would read as a flag. Put flags in extra_args." >&2
            exit 1
        fi
    done
}

# gs_go_version DIR: sets GS_GO_VERSION to the Go release that runs in DIR,
# such as go1.27.3 (go.mod's toolchain line can make go switch to another,
# as GOTOOLCHAIN allows), and GS_GO_MINOR to its minor version, such as 27,
# or 999 for a development build. Stops the step if go can't say.
gs_go_version() {
    if ! GS_GO_VERSION=$(cd "$1" && go env GOVERSION) || [[ -z "${GS_GO_VERSION}" ]]; then
        echo "ERROR: go could not say which Go release runs in $1 (go env GOVERSION)." >&2
        exit 1
    fi
    if gs_match "${GS_GO_VERSION}" '^go1\.([0-9]+)'; then
        GS_GO_MINOR=$((10#${BASH_REMATCH[1]}))
    else
        # shellcheck disable=SC2034 # read by the script that evals this file
        GS_GO_MINOR=999
    fi
}

# gs_junit FILE SUITE CASES: writes JUnit XML to FILE, for CircleCI's Tests
# tab or any other JUnit reader, from CASES, a JSON array of test cases:
#   {"classname": ..., "name": ..., "status": "failed" | "skipped" | "passed",
#    "message": ..., "detail": ...}
# A run with no cases gets one passing case, so the tab shows it ran.
gs_junit() {
    local dir=${1%/*}
    mkdir -p "${dir}"
    # shellcheck disable=SC2016 # jq program, not shell
    jq -r --arg suite "$2" '
        (if length == 0 then [{classname: $suite, name: "no findings", status: "passed"}] else . end) as $cases
        | "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
          "<testsuites>",
          "  <testsuite name=\"\($suite | @html)\" tests=\"\($cases | length)\" failures=\"\([$cases[] | select(.status == "failed")] | length)\" skipped=\"\([$cases[] | select(.status == "skipped")] | length)\">",
          ($cases[] |
            "    <testcase classname=\"\(.classname | @html)\" name=\"\(.name | @html)\">"
            + (if .status == "failed" then "<failure message=\"\((.message // "") | @html)\">\((.detail // "") | @html)</failure>"
               elif .status == "skipped" then "<skipped message=\"\((.message // "") | @html)\"/>"
               else "" end)
            + "</testcase>"),
          "  </testsuite>",
          "</testsuites>"
    ' <<< "$3" > "$1"
}

# gs_gate FINDINGS REPORT_ONLY SUMMARY: ends a check. Without findings it
# succeeds. With findings it fails with SUMMARY, unless REPORT_ONLY is true,
# when it only warns: the reports are written either way.
gs_gate() {
    if [[ "$1" == false ]]; then
        echo "Passed: $3"
        exit 0
    fi
    if [[ "$2" == true ]]; then
        echo "WARN: $3" >&2
        echo "WARN: report_only is true, so this step passes. The reports are in ${GS_OUT}." >&2
        exit 0
    fi
    echo "ERROR: $3" >&2
    echo "  The reports are in ${GS_OUT}. Set report_only to true to report findings without failing." >&2
    exit 1
}

# gs_plural COUNT SINGULAR PLURAL: prints COUNT and the word that goes with
# it, such as "1 file" or "2 files".
gs_plural() {
    if [[ "$1" -eq 1 ]]; then
        printf '%s %s\n' "$1" "$2"
    else
        printf '%s %s\n' "$1" "$3"
    fi
}

# gs_tail FILE [LINES]: prints the last LINES (default 40) lines of FILE to
# stderr, indented, to show why a tool failed.
gs_tail() {
    tail -n "${2:-40}" "$1" | sed 's/^/  /' >&2
}

# gs_export NAME VALUE: exports NAME=VALUE, shell-quoted, to later steps
# through BASH_ENV (on GitHub Actions, the action passes it on through
# GITHUB_ENV).
gs_export() {
    if [[ -z "${BASH_ENV:-}" ]]; then
        echo "WARN: BASH_ENV is not set, so ${1} is not exported to later steps." >&2
        return 0
    fi
    printf 'export %s=%q\n' "$1" "$2" >> "${BASH_ENV}"
}

# gs_env_var_name PARAMETER VALUE: stops the step unless VALUE can name an
# environment variable.
gs_env_var_name() {
    if ! gs_match "$2" '^[A-Za-z_][A-Za-z0-9_]*$'; then
        echo "ERROR: ${1} must name an environment variable, not '${2}'." >&2
        exit 1
    fi
}

# gs_json_is FILE FILTER [JQ_OPTION...]: whether FILE holds one JSON value for
# which FILTER is true. It compares jq's output instead of using -e, since jq
# 1.6 (as on Ubuntu 22.04 and some cimg images) exits 0 with -e when the file
# is empty, as a tool that failed before writing its report leaves it.
gs_json_is() {
    local file=$1 filter=$2 options=()
    if [[ $# -gt 2 ]]; then
        options=("${@:3}")
    fi
    [[ "$(jq -c ${options[@]+"${options[@]}"} "(${filter}) | if . then true else false end" "${file}" 2> /dev/null)" == true ]]
}

# gs_sha256 FILE: prints FILE's SHA-256.
gs_sha256() {
    sha256sum -- "$1" | awk '{ print $1 }'
}

# gs_url_public URL: prints URL without the userinfo, query and fragment,
# which can hold credentials, so it can go in a log or an artifact.
gs_url_public() {
    local url=$1
    if [[ "${url}" =~ ^([A-Za-z][A-Za-z0-9+.-]*://)([^/?#]*@)?([^?#]*) ]]; then
        printf '%s%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}"
    else
        printf '%s\n' "${url%%[?#]*}"
    fi
}

# gs_ci_json: describes the CI job this runs in, for run records: a CircleCI
# job or a GitHub Actions run, or null elsewhere.
gs_ci_json() {
    if [[ -n "${CIRCLE_BUILD_URL:-}" ]]; then
        jq -cn --arg url "${CIRCLE_BUILD_URL}" --arg sha "${CIRCLE_SHA1:-}" --arg job "${CIRCLE_JOB:-}" \
            --arg repo "${CIRCLE_PROJECT_USERNAME:-}${CIRCLE_PROJECT_REPONAME:+/${CIRCLE_PROJECT_REPONAME}}" \
            '{provider: "circleci", build_url: $url, sha1: $sha, job: $job, repository: $repo}'
    elif [[ "${GITHUB_ACTIONS:-}" == true ]]; then
        jq -cn --arg url "${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}/attempts/${GITHUB_RUN_ATTEMPT:-1}" \
            --arg sha "${GITHUB_SHA:-}" --arg job "${GITHUB_JOB:-}" --arg repo "${GITHUB_REPOSITORY:-}" \
            '{provider: "github-actions", build_url: $url, sha1: $sha, job: $job, repository: $repo}'
    else
        echo null
    fi
}

# gs_tool_json PATH VERSION: describes a binary that ran for the run record:
# its SHA-512, and how the orb installed it, from the install record beside
# it when that record describes this very binary.
gs_tool_json() {
    local sha="" install="null" entry
    if [[ -n "$1" && -f "$1" ]]; then
        # Without sha512sum the record says so with a null SHA-512, as gs_tool
        # only warns.
        sha=$(sha512sum -- "$1" 2> /dev/null | awk '{ print $1 }') || sha=""
        entry="$(dirname "$1")/.${1##*/}.install.json"
        # shellcheck disable=SC2016 # jq program, not shell
        if [[ -f "${entry}" ]] && gs_json_is "${entry}" '.binary_sha512 == $sha' --arg sha "${sha}"; then
            install=$(jq -c 'del(.binary_sha512)' "${entry}")
        fi
    fi
    jq -cn --arg name "${1##*/}" --arg path "$1" --arg version "$2" --arg sha "${sha}" --argjson install "${install}" \
        '{name: $name, path: $path, version: $version, sha512: (if $sha == "" then null else $sha end), install: $install}'
}

# gs_toolchain_json: the go on the PATH and the Go settings that decide what
# it fetches and builds, for the run record; null without go. Proxy and
# checksum database URLs lose their userinfo, query and fragment, which can
# hold credentials.
gs_toolchain_json() {
    local go env
    if ! go=$(command -v go) || ! env=$(go env -json GOVERSION GOROOT GOTOOLCHAIN GOFLAGS GOPROXY GOSUMDB GOPRIVATE \
        GONOPROXY GONOSUMDB GOINSECURE GOFIPS140 GODEBUG GOEXPERIMENT CGO_ENABLED GOOS GOARCH GOWORK 2> /dev/null); then
        echo null
        return 0
    fi
    # shellcheck disable=SC2016 # jq program, not shell
    jq -c --argjson go "$(gs_tool_json "${go}" "")" '
        def public: gsub("(?<scheme>[A-Za-z][A-Za-z0-9+.-]*://)[^/?#,|\\s]*@"; "\(.scheme)")
            | gsub("(?<url>[A-Za-z][A-Za-z0-9+.-]*://[^?#,|\\s]*)[?#][^,|\\s]*"; "\(.url)");
        {go: $go, env: (. | .GOPROXY |= public | .GOSUMDB |= public)}' <<< "${env}"
}

# gs_args_json ARG...: the arguments as a JSON array. They pass through jq
# NUL-separated, so arguments that start with "-" never reach jq's own option
# parsing, and a URL among them loses its userinfo, query and fragment.
gs_args_json() {
    if [[ $# -eq 0 ]]; then
        echo '[]'
        return 0
    fi
    # Ended by a word rather than a NUL, which jq 1.6 drops from the end of
    # raw input.
    { printf '%s\0' "$@"; printf 'end'; } | jq -Rsc 'split("\u0000") | .[:-1]
        | map(gsub("(?<scheme>[A-Za-z][A-Za-z0-9+.-]*://)[^/?#\\s]*@"; "\(.scheme)")
            | gsub("(?<url>[A-Za-z][A-Za-z0-9+.-]*://[^?#\\s]*)[?#]\\S*"; "\(.url)"))'
}

# gs_run_record FILE COMMAND OUTCOME EXIT_CODE STARTED: writes a run record,
# the JSON document schemas/run-record.v1.json describes, saying what exactly
# this command checked, so a reviewer can tell without running it again. It
# reads what the command set:
#   GS_TOOL          the tool binary that ran, if any
#   GS_TOOL_VERSION  what it reports as its version
#   GS_ARGS          the arguments it ran with, as an array
#   GS_INPUTS        "role:path" entries, such as "go.mod:api/go.mod"
#   GS_REPORTS       the report files written
#   GS_DB_JSON       the vulnerability database read, as JSON, if any
#   GS_COUNTS        a JSON object of the command's counts
#   GS_RESULTS       a JSON array of per-item results, such as one per binary
# OUTCOME is passed, findings, findings-reported (findings with report_only)
# or error.
gs_run_record() {
    local file=$1 entry path role sha inputs="[]" reports="[]" args
    for entry in ${GS_INPUTS[@]+"${GS_INPUTS[@]}"}; do
        role=${entry%%:*}
        path=${entry#*:}
        sha=""
        if [[ -f "${path}" ]]; then
            sha=$(gs_sha256 "${path}")
        fi
        if [[ -d "$(dirname "${path}")" ]]; then
            path=$(cd "$(dirname "${path}")" && pwd)/${path##*/}
        fi
        inputs=$(jq -c --arg role "${role}" --arg path "${path}" --arg sha "${sha}" \
            '. + [{role: $role, path: $path, sha256: (if $sha == "" then null else $sha end)}]' <<< "${inputs}")
    done
    for path in ${GS_REPORTS[@]+"${GS_REPORTS[@]}"}; do
        if [[ -f "${path}" ]]; then
            reports=$(jq -c --arg path "${path}" --arg sha "$(gs_sha256 "${path}")" '. + [{path: $path, sha256: $sha}]' <<< "${reports}")
        fi
    done
    args=$(gs_args_json ${GS_ARGS[@]+"${GS_ARGS[@]}"})
    if ! jq -n --arg command "$2" --arg outcome "$3" --argjson code "$4" --arg started "$5" \
        --arg finished "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg cwd "$(pwd)" --argjson ci "$(gs_ci_json)" \
        --argjson tool "$(if [[ -n "${GS_TOOL:-}" ]]; then gs_tool_json "${GS_TOOL}" "${GS_TOOL_VERSION:-}"; else echo null; fi)" \
        --argjson toolchain "$(gs_toolchain_json)" --argjson db "${GS_DB_JSON:-null}" \
        --argjson inputs "${inputs}" --argjson reports "${reports}" --argjson counts "${GS_COUNTS:-null}" \
        --argjson results "${GS_RESULTS:-null}" --argjson args "${args}" '{
            schema: "https://github.com/juburr/go-security-orb/blob/main/schemas/run-record.v1.json",
            command: $command, outcome: $outcome, exit_code: $code,
            started_at: $started, finished_at: $finished, ci: $ci, working_directory: $cwd,
            tool: $tool, arguments: $args, toolchain: $toolchain, vuln_db: $db,
            inputs: $inputs, counts: $counts, results: $results, reports: $reports
        }' > "${file}"; then
        echo "WARN: Could not write the run record ${file}." >&2
        return 0
    fi
    echo "Run record: ${file}"
}

# gs_vuln_db VALUE: sets GS_DB to the vulnerability database to scan with,
# as the URL govulncheck's -db takes: VALUE, or else the copy
# fetch_vuln_db exported in GO_SECURITY_VULN_DB, or else
# https://vuln.go.dev. An absolute path is a local copy. Only https:// and
# file:// are accepted: the database is not signed, so HTTPS is all that
# keeps a mirror's copy intact on the way. A local copy needs its index:
# without index/modules.json govulncheck falls back to reading the directory
# as loose entries, and an empty or wrong directory then reports nothing.
gs_vuln_db() {
    local value dir
    value=$(gs_subst "$1")
    value=${value:-${GO_SECURITY_VULN_DB:-https://vuln.go.dev}}
    value=${value%/}
    if [[ "${value}" == /* ]]; then
        value="file://${value}"
    fi
    case "${value}" in
        https://*)
            if [[ "${value#https://}" == *@* || "${value}" == *[?#]* ]]; then
                echo "ERROR: db must not hold credentials, a query or a fragment, which would show in the log and the reports." >&2
                exit 1
            fi
            ;;
        file:///*)
            dir=${value#file://}
            if [[ ! -f "${dir}/index/modules.json" || ! -f "${dir}/index/db.json" ]]; then
                echo "ERROR: ${dir} is not a copy of the Go vulnerability database: it has no index/modules.json and index/db.json." >&2
                echo "  Fetch one with fetch_vuln_db, which checks what it fetches." >&2
                exit 1
            fi
            ;;
        *)
            echo "ERROR: db must be an https:// URL, a file:/// URL or an absolute path, not '${value}'." >&2
            exit 1
            ;;
    esac
    # shellcheck disable=SC2034 # read by the script that evals this file
    GS_DB=${value}
}

# gs_db_json DB LAST_MODIFIED: describes the database a scan read, for the
# run record: its URL, when govulncheck says it was last modified, and, for
# a copy fetch_vuln_db made, where it came from and when.
gs_db_json() {
    local fetched=null marker
    if [[ "$1" == file://* ]]; then
        marker="${1#file://}/.go-security-orb.json"
        if [[ -f "${marker}" ]] && jq -e . "${marker}" > /dev/null 2>&1; then
            fetched=$(jq -c . "${marker}")
        fi
    fi
    jq -cn --arg url "$(gs_url_public "$1")" --arg modified "$2" --argjson fetched "${fetched}" \
        '{url: $url, last_modified: (if $modified == "" then null else $modified end), fetched: $fetched}'
}

# gs_db_fresh LAST_MODIFIED MAX_AGE_DAYS: stops the step when the database a
# scan read is older than MAX_AGE_DAYS (0 for no limit), or doesn't say how
# old it is, as an empty or broken copy doesn't: a stale copy finds nothing
# published since. The age is the database's own last-modified time, which
# lags the newest entry by a few days at most.
gs_db_fresh() {
    local modified=$1 seconds now age
    if [[ -z "${modified}" || "${modified}" == 0001-* ]] || ! seconds=$(date -u -d "${modified}" +%s 2> /dev/null); then
        echo "ERROR: The vulnerability database doesn't say when it was last modified (${modified:-nothing}), so it may be" >&2
        echo "  empty or broken, and nothing it would report can be trusted to be there." >&2
        exit 1
    fi
    if [[ "$2" -eq 0 ]]; then
        return 0
    fi
    now=$(date -u +%s)
    age=$(((now - seconds) / 86400))
    if ((age > $2)); then
        echo "ERROR: The vulnerability database was last modified ${modified}, ${age} days ago, more than max_db_age_days (${2})." >&2
        echo "  Fetch a fresh copy, or raise max_db_age_days (0 means no limit)." >&2
        exit 1
    fi
    echo "Vulnerability database: last modified ${modified} (${age} days ago)."
}

# gs_ignore VALUE: sets GS_IGNORE_JSON to the vulnerabilities VALUE accepts,
# as a JSON array of {id, reason}. VALUE has one per line: an ID (GO-, CVE-
# or GHSA-) and the reason it is accepted. Blank lines and lines starting
# with # are skipped. A line without a reason fails the step: an accepted
# vulnerability without one can't be reviewed later.
gs_ignore() {
    local value line id reason entries=()
    value=$(gs_subst "$1")
    while IFS= read -r line || [[ -n "${line}" ]]; do
        line=${line#"${line%%[![:space:]]*}"}
        [[ -z "${line}" || "${line}" == \#* ]] && continue
        id=${line%%[[:space:]]*}
        reason=${line#"${id}"}
        reason=${reason#"${reason%%[![:space:]]*}"}
        reason=${reason#:}
        reason=${reason#"${reason%%[![:space:]]*}"}
        if ! gs_match "${id}" '^(GO-[0-9]{4}-[0-9]{4,}|CVE-[0-9]{4}-[0-9]{4,}|GHSA(-[23456789cfghjmpqrvwx]{4}){3})$'; then
            echo "ERROR: ignore must start each line with a GO-, CVE- or GHSA- ID, not '${id}'." >&2
            exit 1
        fi
        if [[ -z "${reason}" ]]; then
            echo "ERROR: ignore accepts ${id} without a reason. Give one after the ID, such as:" >&2
            echo "  ${id} only reachable from the admin CLI, which never parses untrusted input" >&2
            exit 1
        fi
        entries+=("$(jq -cn --arg id "${id}" --arg reason "${reason}" '{id: $id, reason: $reason}')")
    done <<< "${value}"
    # shellcheck disable=SC2034 # read by the script that evals this file
    GS_IGNORE_JSON=$(printf '%s\n' ${entries[@]+"${entries[@]}"} | jq -s -c .)
}

# GS_VULN_JQ: reads one govulncheck -format json stream (slurped) and prints
# what it found: the scan's settings, and one entry per vulnerability, with
# the level govulncheck's text summary counts it at. A vulnerability is
# called when any of its findings' traces starts at a function, imported
# when one starts at a package, and only required otherwise. It takes
# $target (what was scanned), $ignore (gs_ignore's list) and $level (the
# lowest level that counts: called, imported or required).
# shellcheck disable=SC2016,SC2034 # jq program, read by the scripts
GS_VULN_JQ='
    def rank: {called: 3, imported: 2, required: 1}[.];
    def frame: (.package // .module // "")
        + (if (.receiver // "") != "" then "." + .receiver else "" end)
        + (if (.function // "") != "" then "." + .function else "" end)
        + (if .position.filename? then " (\(.position.filename):\(.position.line // 0))" else "" end);
    (map(select(.config)) | first | .config // {}) as $config
    | (map(select(.SBOM)) | first | .SBOM // {}) as $sbom
    | (map(select(.osv)) | map(.osv) | map({key: .id, value: .}) | from_entries) as $osv
    | {target: $target, config: $config,
       go_version: ($config.go_version // $sbom.go_version // null),
       sbom: {go_version: ($sbom.go_version // null), roots: ($sbom.roots // []),
              modules: [($sbom.modules // [])[] | {path, version: (.version // "")}]},
       vulnerabilities: (map(select(.finding)) | map(.finding) | group_by(.osv) | map(
           (.[0].osv) as $id | ($osv[$id] // {}) as $entry
           | (if any(.[]; .trace[0].function) then "called" elif any(.[]; .trace[0].package) then "imported" else "required" end) as $found
           | ([$ignore[] | . as $rule | select($rule.id == $id or any(($entry.aliases // [])[]; . == $rule.id))] | first) as $accepted
           | {id: $id, aliases: ($entry.aliases // []), summary: ($entry.summary // ""), url: "https://pkg.go.dev/vuln/\($id)",
              level: $found,
              modules: ([.[] | .trace[0] | {path: .module, version: (.version // "")}] | unique),
              fixed_version: ([.[] | .fixed_version // empty] | unique | first // null),
              trace: ([.[] | select(.trace[0].function) | .trace | map(frame)] | first // null),
              ignored: ($accepted != null), reason: ($accepted.reason // null)}
           | .counts = ((.level | rank) >= ($level | rank) and (.ignored | not))))}'

# gs_vuln_level SCAN: the lowest level that counts for a -scan level: what a
# symbol scan calls a finding is a called vulnerability, a package scan's an
# imported one, and a module scan's a required one.
gs_vuln_level() {
    case "$1" in
        symbol) echo called ;;
        package) echo imported ;;
        *) echo required ;;
    esac
}

# gs_vuln_print RESULT: prints a scan's vulnerabilities, from GS_VULN_JQ's
# output, most serious first.
gs_vuln_print() {
    jq -r '.vulnerabilities | sort_by({called: 0, imported: 1, required: 2}[.level]) | .[]
        | select(.counts or .ignored or .level == "called")
        | "  \(.id) (\(.level)\(if .ignored then ", accepted: \(.reason)" else "" end)): \(.summary)",
          "    in \([.modules[] | "\(.path)@\(if .version == "" then "?" else .version end)"] | join(", "))\(if .fixed_version then ", fixed in \(.fixed_version)" else "" end)",
          (if .trace == null then empty elif (.trace | length) > 1 then "    called from \(.trace | last)"
           else "    linked into the binary: \(.trace[0])" end)' "$1"
}

# gs_vuln_sarif PREFIXES ACCEPTED FILE...: merges SARIF reports from
# govulncheck's convert mode into one run. PREFIXES is a JSON array with
# what to put before each file's paths to make them relative to the working
# directory, and ACCEPTED a JSON object of the vulnerabilities ignore
# accepts, by ID, with their reasons, which mark their results suppressed.
gs_vuln_sarif() {
    # shellcheck disable=SC2016 # jq program, not shell
    jq -s --argjson prefixes "$1" --argjson accepted "$2" '
        [to_entries[] | .key as $i | .value.runs[]? | .results = ((.results // []) | map(
            .locations = ((.locations // []) | map(if .physicalLocation.artifactLocation.uri? then
                .physicalLocation.artifactLocation.uri |= ($prefixes[$i] + .) else . end))
            | if $accepted[.ruleId] then .suppressions = [{kind: "external", justification: $accepted[.ruleId]}] else . end))]
        | {version: "2.1.0", "$schema": "https://json.schemastore.org/sarif-2.1.0.json",
           runs: (if length == 0 then [{tool: {driver: {name: "govulncheck", informationUri: "https://golang.org/x/vuln", rules: []}}, results: []}]
                  else [.[0] + {tool: (.[0].tool | .driver.rules = ([.[] | .tool.driver.rules // [] | .[]] | unique_by(.id))),
                      results: [.[] | .results // [] | .[]]}] end)}' "${@:3}"
}

# gs_vuln_vex PRODUCTS FILE...: merges OpenVEX documents from govulncheck's
# convert mode into one, naming each document's product (PRODUCTS, a JSON
# array with one ID per file) in place of govulncheck's "Unknown Product".
gs_vuln_vex() {
    # shellcheck disable=SC2016 # jq program, not shell
    jq -s --argjson products "$1" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        (if length > 0 then .[0] else {"@context": "https://openvex.dev/ns/v0.2.0"} end) as $first
        | {"@context": $first."@context", "@id": ($first."@id" // "https://openvex.dev/docs/public/go-security-orb"),
           author: "go-security-orb (govulncheck)", timestamp: $now, version: 1,
           tooling: ($first.tooling // "govulncheck"),
           statements: [to_entries[] | .key as $i | .value.statements[]?
               | .products |= map(if ."@id" == "Unknown Product" then ."@id" = $products[$i] else . end)]}' "${@:2}"
}

# gs_vuln_setup FORMATS: what vulncheck and vulncheck_bin share before they
# scan: GS_FORMATS from the formats parameter, and govulncheck's path
# (GS_TOOL), version (GS_TOOL_VERSION) and the Go release it was built with
# (GS_VULN_BUILD_GO, such as go1.27.3), from the record its install left, or
# else its build information.
gs_vuln_setup() {
    local format record
    gs_list formats "$1"
    GS_FORMATS=(${GS_LIST[@]+"${GS_LIST[@]}"})
    for format in ${GS_FORMATS[@]+"${GS_FORMATS[@]}"}; do
        case "${format}" in
            sarif | openvex) ;;
            *)
                echo "ERROR: formats can name sarif and openvex, not '${format}'." >&2
                exit 1
                ;;
        esac
    done
    gs_tool govulncheck
    GS_TOOL_VERSION=""
    # shellcheck disable=SC2034 # read by the script that evals this file
    GS_VULN_BUILD_GO=""
    record="$(dirname "${GS_TOOL}")/.govulncheck.install.json"
    # shellcheck disable=SC2016 # jq program, not shell
    if [[ -f "${record}" ]] && gs_json_is "${record}" '.binary_sha512 == $sha' \
        --arg sha "$(sha512sum -- "${GS_TOOL}" 2> /dev/null | awk '{ print $1 }')"; then
        GS_TOOL_VERSION=$(jq -r '.version' "${record}")
        GS_VULN_BUILD_GO=go$(jq -r '.build_go_version' "${record}")
    elif command -v go > /dev/null 2>&1; then
        GS_TOOL_VERSION=$(go version -m "${GS_TOOL}" 2> /dev/null | awk '$1 == "mod" { sub(/^v/, "", $3); print $3; exit }') || true
        # shellcheck disable=SC2034 # read by the script that evals this file
        GS_VULN_BUILD_GO=$(go version "${GS_TOOL}" 2> /dev/null | awk '{ print $2; exit }') || true
    fi
    # shellcheck disable=SC2034 # read by the script that evals this file
    GS_FORMATS=(${GS_FORMATS[@]+"${GS_FORMATS[@]}"})
}

# gs_has_format FORMAT: whether formats names FORMAT.
gs_has_format() {
    [[ " ${GS_FORMATS[*]-} " == *" $1 "* ]]
}

# gs_vuln_report COMMAND: what vulncheck and vulncheck_bin share after they
# scan: reads each scan's results from WORK/results/ID.json (GS_VULN_JQ's
# output), govulncheck's own output from WORK/streams/ID.json, and its SARIF
# and OpenVEX from WORK/sarif/ID.sarif and WORK/vex/ID.json, with what to put
# before each SARIF's paths in WORK/meta/ID.prefix and the product to name in
# each VEX document in WORK/meta/ID.product. Writes the reports and the run
# record, then ends the step: ERRORS fails it whatever report_only says.
gs_vuln_report() {
    local command=$1 report="${GS_BASE}.json" count file accepted
    shopt -s nullglob
    local results=("${WORK}"/results/*.json) streams=("${WORK}"/streams/*.json)
    local sarifs=("${WORK}"/sarif/*.sarif) vexes=("${WORK}"/vex/*.json)
    shopt -u nullglob
    jq -s '{scans: .}' ${results[@]+"${results[@]}"} < /dev/null > "${report}"
    GS_REPORTS=("${report}")
    jq -s '.' ${streams[@]+"${streams[@]}"} < /dev/null > "${GS_BASE}.raw.json"
    GS_REPORTS+=("${GS_BASE}.raw.json")
    count=$(jq '[.scans[].vulnerabilities[] | select(.counts)] | length' "${report}")
    accepted=$(jq -c '[.scans[].vulnerabilities[] | select(.ignored) | {key: .id, value: .reason}] | from_entries' "${report}")
    if gs_has_format sarif; then
        for file in ${sarifs[@]+"${sarifs[@]}"}; do
            file=${file##*/}
            cat "${WORK}/meta/${file%.sarif}.prefix"
        done | jq -R . | jq -s -c . > "${WORK}/prefixes.json"
        gs_vuln_sarif "$(cat "${WORK}/prefixes.json")" "${accepted}" ${sarifs[@]+"${sarifs[@]}"} < /dev/null > "${GS_BASE}.sarif"
        GS_REPORTS+=("${GS_BASE}.sarif")
    fi
    if gs_has_format openvex; then
        for file in ${vexes[@]+"${vexes[@]}"}; do
            file=${file##*/}
            cat "${WORK}/meta/${file%.json}.product"
        done | jq -R . | jq -s -c . > "${WORK}/products.json"
        gs_vuln_vex "$(cat "${WORK}/products.json")" ${vexes[@]+"${vexes[@]}"} < /dev/null > "${GS_BASE}.openvex.json"
        GS_REPORTS+=("${GS_BASE}.openvex.json")
    fi
    if [[ "${JUNIT}" == true ]]; then
        gs_junit "${GS_OUT}/junit/${PARAM_REPORT_NAME}.xml" "govulncheck" \
            "$(jq -c '[.scans[] | .target as $target | .vulnerabilities[] | select(.counts) | {classname: $target, name: .id, status: "failed",
                message: "\(.level): \(.summary)",
                detail: "\(.id) (\(.aliases | join(", "))): \(.summary)\nin \([.modules[] | "\(.path)@\(.version)"] | join(", "))\(if .fixed_version then ", fixed in \(.fixed_version)" else "" end)\n\(.url)\(if .trace then "\ncalled from:\n  " + (.trace | join("\n  ")) else "" end)"}]' "${report}")"
        GS_REPORTS+=("${GS_OUT}/junit/${PARAM_REPORT_NAME}.xml")
    fi
    if [[ ${#ERRORS[@]} -gt 0 ]]; then
        OUTCOME=error
    elif [[ "${count}" -gt 0 && "${REPORT_ONLY}" == true ]]; then
        OUTCOME=findings-reported
    elif [[ "${count}" -gt 0 ]]; then
        OUTCOME=findings
    else
        OUTCOME=passed
    fi
    if [[ "${RUN_RECORD}" == true ]]; then
        GS_DB_JSON=$(gs_db_json "${GS_DB}" "$(jq -r '[.scans[].config.db_last_modified // empty] | first // ""' "${report}")")
        GS_COUNTS=$(jq -c --argjson errors "${#ERRORS[@]}" '{counted: [.scans[].vulnerabilities[] | select(.counts)] | length,
            accepted: [.scans[].vulnerabilities[] | select(.ignored)] | length,
            called: [.scans[].vulnerabilities[] | select(.level == "called")] | length,
            imported: [.scans[].vulnerabilities[] | select(.level == "imported")] | length,
            required: [.scans[].vulnerabilities[] | select(.level == "required")] | length,
            not_scanned: $errors}' "${report}")
        GS_RESULTS=$(jq -c '[.scans[] | {target, path: (.path // null), sha256: (.sha256 // null), go_version, goos: (.goos // null),
            goarch: (.goarch // null), scan_level: .config.scan_level, scan_mode: .config.scan_mode,
            counted: [.vulnerabilities[] | select(.counts) | .id], accepted: [.vulnerabilities[] | select(.ignored) | {id, reason}]}]' "${report}")
        gs_run_record "${GS_BASE}.run-record.json" "${command}" "${OUTCOME}" "$([[ "${OUTCOME}" == error ]] && echo 1 || echo 0)" "${STARTED}"
    fi
    if [[ ${#ERRORS[@]} -gt 0 ]]; then
        echo "ERROR: govulncheck could not scan ${ERRORS[*]}, so the step fails whatever report_only says." >&2
        exit 1
    fi
    if [[ "${count}" -gt 0 ]]; then
        gs_gate true "${REPORT_ONLY}" "govulncheck found $(gs_plural "${count}" vulnerability vulnerabilities) that $([[ "${count}" -eq 1 ]] && echo counts || echo count) at the ${GS_VULN_LEVEL} level."
    fi
    gs_gate false "${REPORT_ONLY}" "govulncheck found no vulnerabilities at the ${GS_VULN_LEVEL} level$([[ "${accepted}" != "{}" ]] && echo " that ignore doesn't accept")."
}

# gs_binaries VALUE: sets GS_BINARIES to the files VALUE names: paths and
# glob patterns, separated by commas or spaces, with environment variables
# expanded. A pattern that matches nothing, or names something that isn't a
# file, stops the step: a binary that isn't there would go unchecked.
gs_binaries() {
    local pattern file matches
    local -A seen=()
    GS_BINARIES=()
    gs_list binaries "$1"
    if [[ ${#GS_LIST[@]} -eq 0 ]]; then
        echo "ERROR: binaries names no binary." >&2
        exit 1
    fi
    for pattern in "${GS_LIST[@]}"; do
        shopt -s nullglob
        # shellcheck disable=SC2206 # the pattern is meant to expand
        matches=(${pattern})
        shopt -u nullglob
        if [[ ${#matches[@]} -eq 0 ]]; then
            echo "ERROR: binaries names ${pattern}, which matches nothing in $(pwd)." >&2
            exit 1
        fi
        for file in "${matches[@]}"; do
            if [[ ! -f "${file}" ]]; then
                echo "ERROR: binaries names ${file}, which is not a file." >&2
                exit 1
            fi
            if [[ -z "${seen[${file}]+set}" ]]; then
                seen[${file}]=1
                GS_BINARIES+=("${file}")
            fi
        done
    done
}
