#!/bin/bash
#
# Checks each module's dependencies, for the mod_verify command. go mod
# verify alone proves little: it compares the module cache with the hashes
# the cache itself recorded at download, not with go.sum, and passes when
# go.sum lacks entries. So go mod download runs too, which checks go.sum
# against what it fetches or finds in the cache; go mod verify then finds a
# cache whose files changed since (as one restored from a CI cache can be);
# and go list -mod=readonly, which runs first, finds imports that go.mod or
# go.sum lack, which download and verify would look up instead of checking.
# Then the vendor directory is compared with what go mod vendor writes.
# Before any of that, the job's settings are checked, since several turn the
# checksum database off for some or all modules without any message.

set -euo pipefail

if [[ -z "${SCRIPT_GO_SECURITY_LIB:-}" ]]; then
    echo "ERROR: The shared helpers were not loaded: SCRIPT_GO_SECURITY_LIB is empty." >&2
    exit 1
fi
eval "${SCRIPT_GO_SECURITY_LIB}"

STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
JUNIT=$(gs_bool junit "${PARAM_JUNIT}")
REPORT_ONLY=$(gs_bool report_only "${PARAM_REPORT_ONLY}")
RUN_RECORD=$(gs_bool run_record "${PARAM_RUN_RECORD}")
PIN_TOOLCHAIN=$(gs_bool pin_toolchain "${PARAM_PIN_TOOLCHAIN}")
CHECK_VENDOR=$(gs_bool check_vendor "${PARAM_CHECK_VENDOR}")
TAGS=$(gs_subst "${PARAM_TAGS}")
PRIVATE_MODULES=$(gs_subst "${PARAM_PRIVATE_MODULES}")
PRIVATE_HOST=$(gs_subst "${PARAM_PRIVATE_HOST}")
gs_env_var_name username "${PARAM_USERNAME}"
gs_env_var_name password "${PARAM_PASSWORD}"
gs_output "${PARAM_OUTPUT_DIR}" "${PARAM_REPORT_NAME}"
gs_require_jq
gs_go
gs_modules "${PARAM_MODULES}"
gs_packages "${PARAM_PACKAGES}"
if [[ "${TAGS}" == *[[:space:]]* ]]; then
    echo "ERROR: tags must be separated by commas, not spaces." >&2
    exit 1
fi

WORK=$(mktemp -d)
NETRC_TMP=""
cleanup() {
    rm -rf "${WORK}"
    if [[ -n "${NETRC_TMP}" ]]; then
        rm -f "${NETRC_TMP}"
    fi
}
trap cleanup EXIT

# Module paths on public hosts. A GOPRIVATE, GONOSUMDB or GONOPROXY pattern
# that matches one of these matches far more than an organization's own
# modules.
PUBLIC=(github.com/owner/repo gitlab.com/owner/repo bitbucket.org/owner/repo golang.org/x/net golang.org/toolchain
    google.golang.org/grpc gopkg.in/yaml.v3 go.googlesource.com/repo k8s.io/api sigs.k8s.io/yaml go.uber.org/zap
    cloud.google.com/go go.opentelemetry.io/otel honnef.co/go/tools)

# public_match PATTERNS: prints the first of PUBLIC that PATTERNS, a
# comma-separated GOPRIVATE list, matches, the way go matches them: a
# pattern with N slashes matches a module path whose first N+1 elements it
# matches as a glob. Prints nothing when it matches none.
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

# Private modules: GOPRIVATE, and credentials for their host.
if [[ -n "${PRIVATE_MODULES}" ]]; then
    if [[ "${PRIVATE_MODULES}" == *[[:space:]]* ]]; then
        echo "ERROR: private_modules must be separated by commas, without spaces." >&2
        exit 1
    fi
    hit=$(public_match "${PRIVATE_MODULES}")
    if [[ -n "${hit}" ]]; then
        echo "ERROR: private_modules (${PRIVATE_MODULES}) matches public modules such as ${hit}, which go would then" >&2
        echo "  fetch without checking them against the checksum database. Name your own modules, such as github.com/my-org/*." >&2
        exit 1
    fi
    export GOPRIVATE=${PRIVATE_MODULES}
    gs_export GOPRIVATE "${PRIVATE_MODULES}"
    echo "GOPRIVATE=${PRIVATE_MODULES}, here and in later steps."
fi
if [[ -n "${PRIVATE_HOST}" ]]; then
    # The credentials must never reach the log.
    set +o xtrace
    if ! gs_match "${PRIVATE_HOST}" '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?$'; then
        echo "ERROR: private_host must be a host name, with an optional port, not '${PRIVATE_HOST}'." >&2
        exit 1
    fi
    NETRC_USER=${!PARAM_USERNAME:-}
    NETRC_PASSWORD=${!PARAM_PASSWORD:-}
    if [[ -z "${NETRC_USER}" || -z "${NETRC_PASSWORD}" ]]; then
        echo "ERROR: private_host is ${PRIVATE_HOST}, but ${PARAM_USERNAME} or ${PARAM_PASSWORD} is empty or unset." >&2
        echo "  Set both, such as in a CircleCI context or as GitHub Actions secrets, or leave private_host empty." >&2
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
    mkdir -p "${NETRC_FILE%/*}"
    NETRC_TMP=$(umask 077 && mktemp "${NETRC_FILE%/*}/.netrc.XXXXXX")
    # The entry goes first, since go and git use the first entry for a host,
    # and replaces the one an earlier run of this command wrote.
    {
        printf '# go-security-orb mod_verify %s\n' "${PRIVATE_HOST}"
        printf 'machine %s login %s password %s\n' "${PRIVATE_HOST}" "${NETRC_USER}" "${NETRC_PASSWORD}"
        if [[ -f "${NETRC_FILE}" ]]; then
            awk -v marker="# go-security-orb mod_verify ${PRIVATE_HOST}" \
                'skip { skip = 0; next } $0 == marker { skip = 1; next } { print }' "${NETRC_FILE}"
        fi
    } > "${NETRC_TMP}"
    chmod 600 "${NETRC_TMP}"
    if ! mv -f -- "${NETRC_TMP}" "${NETRC_FILE}"; then
        echo "ERROR: Could not write ${NETRC_FILE}." >&2
        exit 1
    fi
    NETRC_TMP=""
    unset NETRC_USER NETRC_PASSWORD
    echo "Wrote the credentials in ${PARAM_USERNAME} and ${PARAM_PASSWORD} for ${PRIVATE_HOST} to ${NETRC_FILE}, for this step and later ones."
fi
if [[ "${PIN_TOOLCHAIN}" == true ]]; then
    export GOTOOLCHAIN=local
    gs_export GOTOOLCHAIN local
    echo "GOTOOLCHAIN=local, here and in later steps."
fi

# The settings go fetches modules with, from the environment and go env -w.
# go env runs in an empty directory, where no go.mod can switch toolchains.
if ! ENV_JSON=$(cd "${WORK}" && go env -json GOVERSION GOFLAGS GOPRIVATE GONOPROXY GONOSUMDB GOSUMDB GOINSECURE \
    GOPROXY GOTOOLCHAIN 2> "${WORK}/err.log"); then
    echo "ERROR: go env could not report the module settings:" >&2
    gs_tail "${WORK}/err.log"
    exit 1
fi
env_value() {
    jq -r --arg name "$1" '.[$name] // ""' <<< "${ENV_JSON}"
}
GO_VERSION=$(env_value GOVERSION)
SETTINGS='[]'
# setting LEVEL NAME MESSAGE: records a setting that fails the check (fail)
# or only weakens it (warn), and says so.
setting() {
    SETTINGS=$(jq -c --arg level "$1" --arg name "$2" --arg value "$(env_value "$2")" --arg message "$3" \
        '. + [{name: $name, value: $value, level: $level, message: $message}]' <<< "${SETTINGS}")
    if [[ "$1" == fail ]]; then
        echo "  ${2}: ${3}"
    else
        echo "WARN: ${2}: ${3}" >&2
    fi
}
echo "Checking the module settings of ${GO_VERSION}..."
if [[ "$(env_value GOSUMDB)" == off ]]; then
    setting fail GOSUMDB "is off, so go checks new go.sum entries against nothing, and trusts a module served altered."
fi
# go env reports GONOSUMDB and GONOPROXY as GOPRIVATE when they are unset.
PRIVATE=$(env_value GOPRIVATE)
NOSUMDB=$(env_value GONOSUMDB)
NOSUMDB_NAME=GONOSUMDB
if [[ -z "${NOSUMDB}" || "${NOSUMDB}" == "${PRIVATE}" ]]; then
    NOSUMDB=${PRIVATE}
    NOSUMDB_NAME=GOPRIVATE
fi
hit=$(public_match "${NOSUMDB}")
if [[ -n "${hit}" ]]; then
    setting fail "${NOSUMDB_NAME}" "(${NOSUMDB}) matches public modules such as ${hit}, which go then fetches without checking them against the checksum database."
fi
NOPROXY=$(env_value GONOPROXY)
NOPROXY_NAME=GONOPROXY
if [[ -z "${NOPROXY}" || "${NOPROXY}" == "${PRIVATE}" ]]; then
    NOPROXY=${PRIVATE}
    NOPROXY_NAME=GOPRIVATE
fi
hit=$(public_match "${NOPROXY}")
if [[ -n "${hit}" && ("${NOPROXY_NAME}" != "${NOSUMDB_NAME}" || -z "$(public_match "${NOSUMDB}")") ]]; then
    setting warn "${NOPROXY_NAME}" "(${NOPROXY}) matches public modules such as ${hit}, which go then fetches straight from their hosts instead of the proxy."
fi
if [[ -n "$(env_value GOINSECURE)" ]]; then
    setting fail GOINSECURE "($(env_value GOINSECURE)) lets go fetch the modules it matches over plain HTTP, or without checking the server's certificate."
fi
read -r -a FLAGS <<< "$(env_value GOFLAGS)"
for flag in ${FLAGS[@]+"${FLAGS[@]}"}; do
    case "${flag#-}" in
        -mod=mod | mod=mod)
            setting fail GOFLAGS "has ${flag}, which lets every go command add to go.mod and go.sum as it runs, so a build can use dependencies nobody reviewed."
            ;;
        -modcacherw | modcacherw | -modcacherw=true | modcacherw=true)
            setting warn GOFLAGS "has ${flag}, which leaves the module cache writable, so a later step can change dependency sources until go mod verify runs again."
            ;;
        -insecure* | insecure*)
            setting warn GOFLAGS "has ${flag}, which older go releases read as permission to fetch over plain HTTP."
            ;;
    esac
done
IFS=',|' read -r -a PROXIES <<< "$(env_value GOPROXY)"
for proxy in ${PROXIES[@]+"${PROXIES[@]}"}; do
    if [[ "${proxy}" == http://* ]]; then
        setting warn GOPROXY "lists $(gs_url_public "${proxy}") over plain HTTP, so anything on the way can change the modules it serves that the checksum database doesn't cover."
    fi
done
if [[ "${PIN_TOOLCHAIN}" != true && "$(env_value GOTOOLCHAIN)" != local ]]; then
    setting warn GOTOOLCHAIN "is $(env_value GOTOOLCHAIN), so a go or toolchain line in go.mod can make go download and run another Go release. Set pin_toolchain to true to prevent it."
fi
SETTINGS_FAILED=$(jq '[.[] | select(.level == "fail")] | length' <<< "${SETTINGS}")
if [[ "${SETTINGS_FAILED}" -eq 0 ]]; then
    echo "  No setting turns checksum verification off."
fi

# result CHECK STATUS MESSAGE [DETAIL_FILE]: records how a check went in the
# module being checked, and says so.
result() {
    local detail=""
    if [[ -n "${4:-}" && -s "${4:-}" ]]; then
        detail=$(tail -n 40 "$4")
    fi
    jq -cn --arg module "${MODULE_PATH}" --arg path "${module}" --arg check "$1" --arg status "$2" --arg message "$3" \
        --arg detail "${detail}" '{module: $module, path: $path, check: $check, status: $status, message: $message,
            detail: (if $detail == "" then null else $detail end)}' >> "${WORK}/results.jsonl"
    case "$2" in
        passed) echo "  ${1}: ${3}" ;;
        skipped) echo "  ${1}: skipped, ${3}" ;;
        failed)
            echo "  ${1}: FAILED: ${3}"
            if [[ -n "${detail}" ]]; then
                awk '{ print "    " $0 }' <<< "${detail}"
            fi
            ;;
        *)
            ERRORS+=("${label}")
            echo "ERROR: ${label}: ${1}: ${3}" >&2
            if [[ -n "${detail}" ]]; then
                awk '{ print "  " $0 }' <<< "${detail}" >&2
            fi
            ;;
    esac
}
# skip_rest REASON CHECK...: records the remaining checks as skipped.
skip_rest() {
    local reason=$1 check
    shift
    for check in "$@"; do
        result "${check}" skipped "${reason}"
    done
}

LIST_ARGS=(-mod=readonly -deps -test)
if [[ -n "${TAGS}" ]]; then
    LIST_ARGS+=("-tags=${TAGS}")
fi
ERRORS=()
GS_INPUTS=()
: > "${WORK}/results.jsonl"
n=0
for module in "${GS_MODULES[@]}"; do
    n=$((n + 1))
    label=$(gs_label "${module}")
    GS_INPUTS+=("go.mod:${module}/go.mod" "go.sum:${module}/go.sum")
    if [[ -f "${module}/vendor/modules.txt" ]]; then
        GS_INPUTS+=("vendor/modules.txt:${module}/vendor/modules.txt")
    fi
    echo "Checking ${label}..."
    MODULE_PATH=$(awk '$1 == "module" { gsub(/"/, "", $2); print $2; exit }' "${module}/go.mod")
    if ! (cd "${module}" && go mod edit -json) > "${WORK}/edit.json" 2> "${WORK}/err.log"; then
        result toolchain error "go could not read go.mod" "${WORK}/err.log"
        skip_rest "go.mod could not be read" download verify readonly vendor
        continue
    fi
    GO_LINE=$(jq -r '.Go // ""' "${WORK}/edit.json")
    TOOLCHAIN_LINE=$(jq -r '.Toolchain // ""' "${WORK}/edit.json")

    # With GOTOOLCHAIN=local, go refuses a go.mod (or go.work) that needs a
    # newer Go instead of downloading it.
    if [[ "${PIN_TOOLCHAIN}" != true ]]; then
        result toolchain skipped "pin_toolchain is false, so go can switch to the release go.mod's go and toolchain lines name"
    elif (cd "${module}" && go list -m) > /dev/null 2> "${WORK}/err.log"; then
        result toolchain passed "${GO_VERSION} on the PATH meets go.mod's go ${GO_LINE:-line}, and GOTOOLCHAIN=local keeps it"
        if [[ -n "${TOOLCHAIN_LINE}" && "${TOOLCHAIN_LINE}" != "${GO_VERSION}" ]]; then
            echo "    go.mod's toolchain line names ${TOOLCHAIN_LINE}; ${GO_VERSION} builds instead, as GOTOOLCHAIN=local says."
        fi
    elif grep -q 'requires go >= ' "${WORK}/err.log"; then
        result toolchain failed "go.mod requires a newer Go than ${GO_VERSION} on the PATH, which go would otherwise download and run. Build with that release." "${WORK}/err.log"
        skip_rest "go.mod needs a newer Go" download verify readonly vendor
        continue
    else
        result toolchain error "go could not read the module" "${WORK}/err.log"
        skip_rest "go could not read the module" download verify readonly vendor
        continue
    fi

    # Imports that go.mod or go.sum lack: go list -mod=readonly finds them
    # without looking anything up. It runs first, since go mod download and
    # go mod verify look up what go.sum lacks in the checksum database
    # instead of checking it, and fail for a module the database doesn't
    # know, such as a private one.
    rc=0
    (cd "${module}" && go list "${LIST_ARGS[@]}" -f '{{.ImportPath}}' -- "${GS_PACKAGES[@]}") > /dev/null 2> "${WORK}/list.log" || rc=$?
    INCOMPLETE=false
    if [[ "${rc}" -ne 0 ]] && grep -qE 'missing go\.sum entry|import lookup disabled by -mod=readonly|updates to go\.(mod|sum) needed|no required module provides package|is replaced but not required' "${WORK}/list.log"; then
        INCOMPLETE=true
    fi

    # go mod download checks each module it fetches, or finds in the cache,
    # against go.sum.
    SUMS_MATCH=true
    if (cd "${module}" && go mod download) > "${WORK}/out.log" 2>&1; then
        result download passed "every dependency matches its go.sum hash"
    elif grep -qE 'SECURITY ERROR|checksum mismatch' "${WORK}/out.log"; then
        result download failed "a dependency doesn't match its go.sum hash: it changed since go.sum recorded it, or go.sum was edited" "${WORK}/out.log"
        SUMS_MATCH=false
    elif [[ "${INCOMPLETE}" == true ]]; then
        result download skipped "go.sum lacks entries, which go looks up instead of checking"
    else
        result download error "go mod download failed, so the dependencies could not be checked" "${WORK}/out.log"
        skip_rest "the dependencies could not be downloaded" verify readonly vendor
        continue
    fi

    # go mod verify checks the module cache's files against the hashes it
    # recorded when go downloaded them.
    if [[ "${INCOMPLETE}" == true ]]; then
        result verify skipped "go.sum lacks entries, which go looks up instead of checking"
    elif (cd "${module}" && go mod verify) > "${WORK}/out.log" 2>&1; then
        result verify passed "the module cache holds every dependency as go downloaded it"
    elif grep -qE 'has been modified|missing ziphash' "${WORK}/out.log"; then
        result verify failed "files in the module cache changed after go downloaded them, so builds would use sources go.sum doesn't describe. Delete the module cache (and any CI cache of it)." "${WORK}/out.log"
    else
        result verify error "go mod verify failed" "${WORK}/out.log"
    fi

    # Every other go command stops at the same mismatch.
    if [[ "${SUMS_MATCH}" != true ]]; then
        skip_rest "a dependency doesn't match its go.sum hash" readonly vendor
        continue
    fi
    if [[ "${rc}" -eq 0 ]]; then
        result readonly passed "go.mod and go.sum hold everything ${GS_PACKAGES[*]} and their tests import"
    elif [[ "${INCOMPLETE}" == true ]]; then
        result readonly failed "go.mod or go.sum lacks what the packages import. Run go mod tidy and commit the result." "${WORK}/list.log"
        result vendor skipped "go mod vendor needs a complete go.mod and go.sum"
        continue
    else
        result readonly error "go list could not load the packages" "${WORK}/list.log"
    fi

    # The vendor directory, compared with what go mod vendor writes, outside
    # any workspace, since vendor/ belongs to the module.
    if [[ ! -f "${module}/vendor/modules.txt" ]]; then
        result vendor skipped "there is no vendor directory"
    elif [[ "${CHECK_VENDOR}" != true ]]; then
        result vendor skipped "check_vendor is false"
    elif ! (cd "${module}" && GOWORK=off go mod vendor -o "${WORK}/vendor-${n}") > "${WORK}/err.log" 2>&1; then
        if grep -q 'flag provided but not defined: -o' "${WORK}/err.log"; then
            result vendor error "go mod vendor -o needs Go 1.18 or newer, to write a vendor directory to compare with" "${WORK}/err.log"
        else
            result vendor error "go mod vendor could not write a vendor directory to compare with" "${WORK}/err.log"
        fi
    else
        rc=0
        diff -r -q "${module}/vendor" "${WORK}/vendor-${n}" > "${WORK}/diff.log" 2>&1 || rc=$?
        sed -i "s|${WORK}/vendor-${n}|(what go mod vendor writes)|g" "${WORK}/diff.log"
        if [[ "${rc}" -eq 0 ]]; then
            result vendor passed "vendor holds exactly what go mod vendor writes"
        elif [[ "${rc}" -eq 1 ]]; then
            result vendor failed "vendor isn't what go mod vendor writes. Run go mod vendor and commit the result." "${WORK}/diff.log"
        else
            result vendor error "diff could not compare the vendor directories" "${WORK}/diff.log"
        fi
    fi
done

REPORT="${GS_BASE}.json"
GS_REPORTS=("${REPORT}")
jq -s --arg go "${GO_VERSION}" --argjson pinned "$([[ "${PIN_TOOLCHAIN}" == true ]] && echo true || echo false)" \
    --argjson settings "${SETTINGS}" \
    '{go_version: $go, pin_toolchain: $pinned, settings: $settings,
      modules: (group_by(.path) | map({module: .[0].module, path: .[0].path,
          checks: map(del(.module, .path))}))}' "${WORK}/results.jsonl" > "${REPORT}"
FINDINGS=$(jq '([.settings[] | select(.level == "fail")] | length) + ([.modules[].checks[] | select(.status == "failed")] | length)' "${REPORT}")
echo "Report: ${REPORT}"
if [[ "${JUNIT}" == true ]]; then
    gs_junit "${GS_OUT}/junit/${PARAM_REPORT_NAME}.xml" "mod_verify" \
        "$(jq -c '[(.settings[] | select(.level == "fail") | {classname: "settings", name: .name, status: "failed",
                message: .message, detail: "\(.name)=\(.value): \(.message)"}),
            (if ([.settings[] | select(.level == "fail")] | length) == 0 then {classname: "settings", name: "module settings", status: "passed"} else empty end),
            (.modules[] | (if .module == "" then .path else .module end) as $mod | .checks[] | {classname: $mod, name: .check,
                status: (if .status == "error" then "failed" else .status end),
                message: (if .status == "error" then "could not check: \(.message)" else .message end),
                detail: (.detail // .message)})]' "${REPORT}")"
    GS_REPORTS+=("${GS_OUT}/junit/${PARAM_REPORT_NAME}.xml")
fi

if [[ ${#ERRORS[@]} -gt 0 ]]; then
    OUTCOME=error
elif [[ "${FINDINGS}" -gt 0 && "${REPORT_ONLY}" == true ]]; then
    OUTCOME=findings-reported
elif [[ "${FINDINGS}" -gt 0 ]]; then
    OUTCOME=findings
else
    OUTCOME=passed
fi
if [[ "${RUN_RECORD}" == true ]]; then
    # shellcheck disable=SC2034 # read by gs_run_record
    GS_TOOL=$(command -v go)
    # shellcheck disable=SC2034 # read by gs_run_record
    GS_TOOL_VERSION=${GO_VERSION}
    # shellcheck disable=SC2034 # read by gs_run_record
    GS_ARGS=("${LIST_ARGS[@]}" "${GS_PACKAGES[@]}")
    # shellcheck disable=SC2034 # read by gs_run_record
    GS_RESULTS=$(jq -c '.modules' "${REPORT}")
    # shellcheck disable=SC2034 # read by gs_run_record
    GS_COUNTS=$(jq -c --argjson errors "${#ERRORS[@]}" '{findings: (([.settings[] | select(.level == "fail")] | length)
            + ([.modules[].checks[] | select(.status == "failed")] | length)),
        settings_failed: ([.settings[] | select(.level == "fail")] | length),
        settings_warned: ([.settings[] | select(.level == "warn")] | length),
        checks_failed: ([.modules[].checks[] | select(.status == "failed")] | length),
        checks_not_completed: $errors}' "${REPORT}")
    gs_run_record "${GS_BASE}.run-record.json" mod_verify "${OUTCOME}" "$([[ "${OUTCOME}" == error ]] && echo 1 || echo 0)" "${STARTED}"
fi

if [[ ${#ERRORS[@]} -gt 0 ]]; then
    echo "ERROR: go could not complete every check in $(printf '%s\n' "${ERRORS[@]}" | awk '!seen[$0]++' | paste -sd, - | sed 's/,/, /g'), so the step fails whatever report_only says." >&2
    exit 1
fi
if [[ "${FINDINGS}" -gt 0 ]]; then
    gs_gate true "${REPORT_ONLY}" "mod_verify found $(gs_plural "${FINDINGS}" problem problems) in the settings and $(gs_labels "${GS_MODULES[@]}")."
fi
gs_gate false "${REPORT_ONLY}" "the settings and $(gs_labels "${GS_MODULES[@]}") build with exactly the dependencies go.mod and go.sum name."
