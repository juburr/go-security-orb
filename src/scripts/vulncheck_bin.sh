#!/bin/bash
#
# Runs govulncheck on Go binaries, for the vulncheck_bin command, and reports
# what it finds. Every Go binary records the Go release and the module
# versions it was built with, which govulncheck's binary mode reads, so the
# standard library checked is the one that built the binary. govulncheck
# writes its findings as a JSON stream and exits 0 with -format json
# whatever it finds, so a non-zero exit means it couldn't scan the file.
#
# A binary without its build information (the .go.buildinfo section
# removed) is reported by govulncheck as having an unknown Go version, and
# nothing found: that fails the step here, since nothing was checked.

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
case "${PARAM_SCAN}" in
    symbol | package | module) ;;
    *)
        echo "ERROR: scan must be symbol, package or module, not '${PARAM_SCAN}'." >&2
        exit 1
        ;;
esac
gs_uint max_db_age_days "${PARAM_MAX_DB_AGE_DAYS}"
gs_output "${PARAM_OUTPUT_DIR}" "${PARAM_REPORT_NAME}"
gs_require_jq
gs_vuln_setup "${PARAM_FORMATS}"
GOVULNCHECK=${GS_TOOL}
gs_vuln_db "${PARAM_DB}"
gs_ignore "${PARAM_IGNORE}"
GS_VULN_LEVEL=$(gs_vuln_level "${PARAM_SCAN}")
gs_binaries "${PARAM_BINARIES}"

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
ARGS=(-mode binary -format json "-scan=${PARAM_SCAN}" "-db=${GS_DB}" ${GS_WORDS[@]+"${GS_WORDS[@]}"})

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/results" "${WORK}/streams" "${WORK}/sarif" "${WORK}/vex" "${WORK}/meta"
ERRORS=()
GS_INPUTS=()
# shellcheck disable=SC2034 # read by gs_vuln_report
GS_ARGS=("${ARGS[@]}")
n=0
for binary in "${GS_BINARIES[@]}"; do
    n=$((n + 1))
    id=$(printf '%03d' "${n}")
    GS_INPUTS+=("binary:${binary}")
    # A name that starts with "-" would be read as an option.
    file=${binary}
    if [[ "${file}" == -* ]]; then
        file=./${file}
    fi
    sha256=$(gs_sha256 "${binary}")
    echo "Running govulncheck on ${binary}..."
    rc=0
    "${GOVULNCHECK}" "${ARGS[@]}" "${file}" > "${WORK}/stream.json" 2> "${WORK}/err.log" || rc=$?
    if [[ "${rc}" -ne 0 ]] || ! jq -s -c . "${WORK}/stream.json" > "${WORK}/messages.json" 2> /dev/null \
        || ! gs_json_is "${WORK}/messages.json" 'any(.[]; .config)'; then
        ERRORS+=("${binary}")
        echo "ERROR: govulncheck could not scan ${binary} (exit code ${rc}). Its output:" >&2
        gs_tail "${WORK}/err.log"
        continue
    fi
    jq -c --arg target "${binary}" '{target: $target, kind: "binary", path: $target, messages: .}' \
        "${WORK}/messages.json" > "${WORK}/streams/${id}.json"
    if ! jq -c --arg target "${binary}" --argjson ignore "${GS_IGNORE_JSON}" --arg level "${GS_VULN_LEVEL}" --arg sha "${sha256}" \
        "${GS_VULN_JQ} | .kind = \"binary\" | .path = \$target | .sha256 = \$sha" "${WORK}/messages.json" > "${WORK}/result.json" 2> "${WORK}/jq.err"; then
        ERRORS+=("${binary}")
        echo "ERROR: govulncheck's output for ${binary} could not be read: $(head -c 300 "${WORK}/jq.err")" >&2
        continue
    fi
    gs_db_fresh "$(jq -r '.config.db_last_modified // ""' "${WORK}/result.json")" "${PARAM_MAX_DB_AGE_DAYS}"
    if ! gs_json_is "${WORK}/result.json" '(.sbom.go_version // "") | test("^go1\\.")'; then
        ERRORS+=("${binary}")
        echo "ERROR: ${binary} has no Go build information that says which Go release built it, so govulncheck" >&2
        echo "  checked nothing in it. It is not a Go binary, or its .go.buildinfo section was removed." >&2
        continue
    fi
    mv "${WORK}/result.json" "${WORK}/results/${id}.json"
    gs_vuln_print "${WORK}/results/${id}.json"
    echo "  Built with $(jq -r '.sbom.go_version' "${WORK}/results/${id}.json"), whose standard library was checked."
    : > "${WORK}/meta/${id}.prefix"
    main=$(jq -r '.sbom.roots[0] // empty' "${WORK}/results/${id}.json")
    printf '%s\n' "${main:+pkg:golang/${main}}" | sed "s|^$|${binary##*/}|" > "${WORK}/meta/${id}.product"
    for format in ${GS_FORMATS[@]+"${GS_FORMATS[@]}"}; do
        out="${WORK}/sarif/${id}.sarif"
        if [[ "${format}" == openvex ]]; then
            out="${WORK}/vex/${id}.json"
        fi
        if ! "${GOVULNCHECK}" -mode convert -format "${format}" < "${WORK}/stream.json" > "${out}" 2> "${WORK}/convert.log"; then
            ERRORS+=("${binary}")
            echo "ERROR: govulncheck could not write ${binary}'s ${format} report: $(head -c 300 "${WORK}/convert.log")" >&2
        fi
    done
done
gs_vuln_report vulncheck_bin
