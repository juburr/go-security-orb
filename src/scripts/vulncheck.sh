#!/bin/bash
#
# Runs govulncheck on each module's source, for the vulncheck command, and
# reports what it finds. govulncheck writes its findings as a JSON stream
# and exits 0 with -format json whatever it finds, so a non-zero exit means
# it couldn't scan, which fails the step whatever report_only says. The
# stream is read the way govulncheck's text summary reads it, and turned into
# SARIF and OpenVEX with its convert mode, so each module is scanned once.
#
# govulncheck fails open in a few ways this guards against: it runs in the
# module's directory, since with -C it takes the standard library's version
# from another directory's go; a database without its index, or a go that
# rewrites go.mod during the scan (GOFLAGS=-mod=mod), reports nothing; and a
# standard library version it can't read (GOVERSION set to something else)
# leaves the standard library unchecked.

set -euo pipefail

if [[ -z "${SCRIPT_GO_SECURITY_LIB:-}" ]]; then
    echo "ERROR: The shared helpers were not loaded: SCRIPT_GO_SECURITY_LIB is empty." >&2
    exit 1
fi
eval "${SCRIPT_GO_SECURITY_LIB}"

# shellcheck disable=SC2034 # read by gs_vuln_report
STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# shellcheck disable=SC2034 # read by gs_vuln_report
JUNIT=$(gs_bool junit "${PARAM_JUNIT}")
# shellcheck disable=SC2034 # read by gs_vuln_report
REPORT_ONLY=$(gs_bool report_only "${PARAM_REPORT_ONLY}")
# shellcheck disable=SC2034 # read by gs_vuln_report
RUN_RECORD=$(gs_bool run_record "${PARAM_RUN_RECORD}")
TEST=$(gs_bool test "${PARAM_TEST}")
TAGS=$(gs_subst "${PARAM_TAGS}")
case "${PARAM_SCAN}" in
    symbol | package | module) ;;
    *)
        echo "ERROR: scan must be symbol, package or module, not '${PARAM_SCAN}'." >&2
        exit 1
        ;;
esac
gs_uint max_db_age_days "${PARAM_MAX_DB_AGE_DAYS}"
GO_VERSION=$(gs_subst "${PARAM_GO_VERSION}")
if [[ -n "${GO_VERSION}" ]]; then
    GO_VERSION=go${GO_VERSION#go}
    if ! gs_match "${GO_VERSION}" '^go1\.[0-9]+(\.[0-9]+)?$'; then
        echo "ERROR: go_version must be a Go release such as go1.27.3, not '${PARAM_GO_VERSION}'." >&2
        echo "  govulncheck checks no standard library vulnerabilities for a version it can't read." >&2
        exit 1
    fi
fi
gs_output "${PARAM_OUTPUT_DIR}" "${PARAM_REPORT_NAME}"
gs_require_jq
gs_go
gs_vuln_setup "${PARAM_FORMATS}"
GOVULNCHECK=${GS_TOOL}
gs_vuln_db "${PARAM_DB}"
gs_ignore "${PARAM_IGNORE}"
GS_VULN_LEVEL=$(gs_vuln_level "${PARAM_SCAN}")
gs_modules "${PARAM_MODULES}"
gs_packages "${PARAM_PACKAGES}"
# The flags go applies: the environment's GOFLAGS, or else what go env -w
# saved in Go's environment file.
if ! EFFECTIVE_GOFLAGS=$(go env GOFLAGS 2> /dev/null); then
    echo "ERROR: go env could not report GOFLAGS in $(pwd)." >&2
    exit 1
fi
if [[ " ${EFFECTIVE_GOFLAGS} " =~ [[:space:]]--?mod=mod[[:space:]] ]]; then
    echo "ERROR: GOFLAGS has -mod=mod (${EFFECTIVE_GOFLAGS}), which lets go list change go.mod during the scan, so" >&2
    echo "  govulncheck could scan module versions you don't build with. Remove it from GOFLAGS, or from Go's" >&2
    echo "  environment file with go env -u GOFLAGS if go env -w set it." >&2
    exit 1
fi

gs_words extra_args "$(gs_subst "${PARAM_EXTRA_ARGS}")"
for word in ${GS_WORDS[@]+"${GS_WORDS[@]}"}; do
    case "${word%%=*}" in
        -format | --format | -json | --json | -mode | --mode | -scan | --scan | -db | --db | -show | --show \
            | -C | --C | -test | --test | -tags | --tags)
            echo "ERROR: extra_args can't set ${word%%=*}: this command sets it, from its own parameters." >&2
            exit 1
            ;;
    esac
done

ARGS=(-format json "-scan=${PARAM_SCAN}" "-db=${GS_DB}")
if [[ "${TEST}" == true ]]; then
    ARGS+=(-test)
fi
if [[ -n "${TAGS}" ]]; then
    ARGS+=("-tags=${TAGS}")
fi
ARGS+=(${GS_WORDS[@]+"${GS_WORDS[@]}"})
PATTERNS=("${GS_PACKAGES[@]}")
if [[ "${PARAM_SCAN}" == module ]]; then
    # A module scan takes no package patterns.
    PATTERNS=()
fi
# What govulncheck's environment says about the standard library: GOVERSION
# overrides the version of the go on the PATH.
if [[ -n "${GO_VERSION}" ]]; then
    RUN_ENV=(env "GOVERSION=${GO_VERSION}")
else
    RUN_ENV=(env -u GOVERSION)
fi

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/results" "${WORK}/streams" "${WORK}/sarif" "${WORK}/vex" "${WORK}/meta"
ERRORS=()
GS_INPUTS=()
# shellcheck disable=SC2034 # read by gs_vuln_report
GS_ARGS=("${ARGS[@]}" ${PATTERNS[@]+"${PATTERNS[@]}"})
n=0
for module in "${GS_MODULES[@]}"; do
    n=$((n + 1))
    id=$(printf '%03d' "${n}")
    label=$(gs_label "${module}")
    GS_INPUTS+=("go.mod:${module}/go.mod" "go.sum:${module}/go.sum")
    gs_go_version "${module}"
    # A symbol scan type-checks the code with the go/types govulncheck was
    # built with, which can't read the standard library of a newer Go.
    if [[ "${PARAM_SCAN}" == symbol && -n "${GS_VULN_BUILD_GO}" ]] && gs_match "${GS_VULN_BUILD_GO}" '^go1\.([0-9]+)' \
        && ((GS_GO_MINOR != 999 && GS_GO_MINOR > 10#${BASH_REMATCH[1]})); then
        ERRORS+=("${module}")
        echo "ERROR: ${GS_GO_VERSION} runs in ${label}, and govulncheck was built with ${GS_VULN_BUILD_GO}, which can't type-check" >&2
        echo "  code for a newer Go. Install a govulncheck built with Go ${GS_GO_VERSION#go} or newer (a newer orb release), or scan with scan: package." >&2
        continue
    fi
    echo "Running govulncheck (${PARAM_SCAN} scan) in ${label}, with ${GS_GO_VERSION} on the PATH..."
    rc=0
    (cd "${module}" && "${RUN_ENV[@]}" "${GOVULNCHECK}" "${ARGS[@]}" ${PATTERNS[@]+"${PATTERNS[@]}"}) \
        > "${WORK}/stream.json" 2> "${WORK}/err.log" || rc=$?
    if [[ "${rc}" -ne 0 ]] || ! jq -s -c . "${WORK}/stream.json" > "${WORK}/messages.json" 2> /dev/null \
        || ! gs_json_is "${WORK}/messages.json" 'any(.[]; .config)'; then
        ERRORS+=("${module}")
        echo "ERROR: govulncheck could not scan ${label} (exit code ${rc}). Its output:" >&2
        gs_tail "${WORK}/err.log"
        if grep -q 'mismatch between the Go version used to build govulncheck' "${WORK}/err.log"; then
            echo "  govulncheck was built with ${GS_VULN_BUILD_GO:-an older Go}; install one built with Go ${GS_GO_VERSION#go} or newer." >&2
        fi
        continue
    fi
    jq -c --arg target "${label}" --arg path "${module}" '{target: $target, kind: "module", path: $path, messages: .}' \
        "${WORK}/messages.json" > "${WORK}/streams/${id}.json"
    # shellcheck disable=SC2016 # jq program, not shell
    if ! jq -c --arg target "${label}" --argjson ignore "${GS_IGNORE_JSON}" --arg level "${GS_VULN_LEVEL}" --arg path "${module}" \
        "${GS_VULN_JQ} | .kind = \"module\" | .path = \$path" "${WORK}/messages.json" > "${WORK}/result.json" 2> "${WORK}/jq.err"; then
        ERRORS+=("${module}")
        echo "ERROR: govulncheck's output for ${label} could not be read: $(head -c 300 "${WORK}/jq.err")" >&2
        continue
    fi
    gs_db_fresh "$(jq -r '.config.db_last_modified // ""' "${WORK}/result.json")" "${PARAM_MAX_DB_AGE_DAYS}"
    # The standard library is checked only when govulncheck read its version.
    if ! gs_json_is "${WORK}/result.json" 'any(.sbom.modules[]; .path == "stdlib" and .version != "")'; then
        ERRORS+=("${module}")
        echo "ERROR: govulncheck could not tell which Go release's standard library to check in ${label}" >&2
        echo "  (go_version: ${GO_VERSION:-the go on the PATH}), so it checked none of it." >&2
        continue
    fi
    # A module replaced with a local directory has no version, and govulncheck
    # never reports a vulnerability in one.
    unversioned=$(jq -r '[.sbom.modules[] | select(.version == "" and .path != "stdlib") | .path] - [.sbom.roots[]?] | join(", ")' "${WORK}/result.json")
    if [[ -n "${unversioned}" ]]; then
        echo "WARN: ${label} uses modules without a version, which govulncheck can't check: ${unversioned}." >&2
        echo "WARN: These are modules replaced with a local directory, or the workspace's other modules." >&2
    fi
    mv "${WORK}/result.json" "${WORK}/results/${id}.json"
    gs_vuln_print "${WORK}/results/${id}.json"
    echo "  The standard library was checked as $(jq -r '.go_version' "${WORK}/results/${id}.json")$([[ -z "${GO_VERSION}" ]] && echo ", the go on the PATH")."
    printf '%s\n' "$(gs_join "${module}" "")" > "${WORK}/meta/${id}.prefix"
    printf 'pkg:golang/%s\n' "$(awk '$1 == "module" { gsub(/"/, "", $2); print $2; exit }' "${module}/go.mod")" > "${WORK}/meta/${id}.product"
    for format in ${GS_FORMATS[@]+"${GS_FORMATS[@]}"}; do
        out="${WORK}/sarif/${id}.sarif"
        if [[ "${format}" == openvex ]]; then
            out="${WORK}/vex/${id}.json"
        fi
        if ! "${GOVULNCHECK}" -mode convert -format "${format}" < "${WORK}/stream.json" > "${out}" 2> "${WORK}/convert.log"; then
            ERRORS+=("${module}")
            echo "ERROR: govulncheck could not write ${label}'s ${format} report: $(head -c 300 "${WORK}/convert.log")" >&2
        fi
    done
done
if [[ -z "${GO_VERSION}" ]]; then
    echo "NOTE: Standard library vulnerabilities are for the go on the PATH, which may not be the Go you build with."
    echo "  Set go_version to that release, or scan the binaries with vulncheck_bin, which reads it from each one."
fi
gs_vuln_report vulncheck
