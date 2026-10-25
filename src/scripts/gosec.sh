#!/bin/bash
#
# Runs gosec in each module, for the gosec command, and reports what it
# finds. gosec exits 1 both for findings and when it couldn't type-check the
# code (a compile error, or export data it can't read), so the report tells
# them apart: findings are its Issues, and anything under "Golang errors"
# means rules that need type information didn't run, which fails the step
# whatever report_only says. The packages come from go list, so ./... means
# what it means to the go command: gosec's own ./... walks every directory,
# testdata and nested modules included.

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
SARIF=$(gs_bool sarif "${PARAM_SARIF}")
TESTS=$(gs_bool tests "${PARAM_TESTS}")
EXCLUDE_GENERATED=$(gs_bool exclude_generated "${PARAM_EXCLUDE_GENERATED}")
REQUIRE_REASONS=$(gs_bool require_suppression_reasons "${PARAM_REQUIRE_SUPPRESSION_REASONS}")
TAGS=$(gs_subst "${PARAM_TAGS}")
CONFIG=$(gs_subst "${PARAM_CONFIG}")
for setting in "severity:${PARAM_SEVERITY}" "confidence:${PARAM_CONFIDENCE}"; do
    case "${setting#*:}" in
        low | medium | high) ;;
        *)
            echo "ERROR: ${setting%%:*} must be low, medium or high, not '${setting#*:}'." >&2
            exit 1
            ;;
    esac
done
gs_output "${PARAM_OUTPUT_DIR}" "${PARAM_REPORT_NAME}"
gs_require_jq
gs_go
gs_tool gosec
GOSEC=${GS_TOOL}
# shellcheck disable=SC2034 # read by gs_run_record
GS_TOOL_VERSION=$("${GOSEC}" -version 2> /dev/null | sed -n 's/^Version: //p' | head -n 1) || GS_TOOL_VERSION=""
gs_modules "${PARAM_MODULES}"
gs_packages "${PARAM_PACKAGES}"

# rules VALUE PARAMETER: VALUE's rule IDs, joined with commas.
rules() {
    local rule out=""
    gs_list "$2" "$1"
    for rule in ${GS_LIST[@]+"${GS_LIST[@]}"}; do
        if ! gs_match "${rule}" '^G[0-9]{3}$'; then
            echo "ERROR: $2 must list gosec rule IDs such as G101, not '${rule}'." >&2
            exit 1
        fi
        out+="${out:+,}${rule}"
    done
    printf '%s\n' "${out}"
}
INCLUDE=$(rules "${PARAM_INCLUDE}" include)
EXCLUDE=$(rules "${PARAM_EXCLUDE}" exclude)

gs_words extra_args "$(gs_subst "${PARAM_EXTRA_ARGS}")"
for word in ${GS_WORDS[@]+"${GS_WORDS[@]}"}; do
    case "${word}" in
        -fmt | -fmt=* | --fmt | --fmt=* | -out | -out=* | --out | --out=* | -stdout | -stdout=* | --stdout | --stdout=* \
            | -verbose | -verbose=* | --verbose | --verbose=* | -quiet | -quiet=* | --quiet | --quiet=* \
            | -no-fail | -no-fail=* | --no-fail | --no-fail=* | -track-suppressions | -track-suppressions=* \
            | --track-suppressions | --track-suppressions=*)
            echo "ERROR: extra_args can't set ${word%%=*}: this command sets gosec's report formats itself, and reads its JSON." >&2
            exit 1
            ;;
    esac
done

# The options that shape what gosec checks. The run record lists these; the
# report options are added for each run.
OPTIONS=(-track-suppressions "-severity=${PARAM_SEVERITY}" "-confidence=${PARAM_CONFIDENCE}")
if [[ "${EXCLUDE_GENERATED}" == true ]]; then
    OPTIONS+=(-exclude-generated)
fi
if [[ "${TESTS}" == true ]]; then
    OPTIONS+=(-tests)
fi
if [[ -n "${TAGS}" ]]; then
    OPTIONS+=("-tags=${TAGS}")
fi
if [[ -n "${INCLUDE}" ]]; then
    OPTIONS+=("-include=${INCLUDE}")
fi
if [[ -n "${EXCLUDE}" ]]; then
    OPTIONS+=("-exclude=${EXCLUDE}")
fi
GS_INPUTS=()
if [[ -n "${CONFIG}" ]]; then
    if [[ ! -f "${CONFIG}" ]]; then
        echo "ERROR: config names ${CONFIG}, which is not a file in $(pwd)." >&2
        exit 1
    fi
    GS_INPUTS+=("config:${CONFIG}")
    CONFIG=$(cd "$(dirname "${CONFIG}")" && pwd)/${CONFIG##*/}
    OPTIONS+=("-conf=${CONFIG}")
fi
OPTIONS+=(${GS_WORDS[@]+"${GS_WORDS[@]}"})

# Which files go list counts: with tests, a package of test files alone has
# something to check; without, gosec would be handed no files for it, and
# check the module's root package again instead.
if [[ "${TESTS}" == true ]]; then
    TEMPLATE='{{if or .GoFiles .CgoFiles .TestGoFiles .XTestGoFiles}}{{.Dir}}{{end}}'
else
    TEMPLATE='{{if or .GoFiles .CgoFiles}}{{.Dir}}{{end}}'
fi
LIST_ARGS=(list -find -e -f "${TEMPLATE}")
if [[ -n "${TAGS}" ]]; then
    LIST_ARGS+=("-tags=${TAGS}")
fi

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
REPORT="${GS_BASE}.json"
SARIF_REPORT="${GS_BASE}.sarif"
echo '[]' > "${WORK}/issues.json"
echo '[]' > "${WORK}/runs.json"
ERRORS=()
# shellcheck disable=SC2034 # read by gs_run_record
GS_ARGS=(${OPTIONS[@]+"${OPTIONS[@]}"})
for module in "${GS_MODULES[@]}"; do
    label=$(gs_label "${module}")
    GS_INPUTS+=("go.mod:${module}/go.mod" "go.sum:${module}/go.sum")
    root=$(cd "${module}" && pwd)
    physical=$(cd "${module}" && pwd -P)
    if ! (cd "${module}" && go "${LIST_ARGS[@]}" -- "${GS_PACKAGES[@]}") > "${WORK}/dirs" 2> "${WORK}/list.err"; then
        ERRORS+=("${module}")
        echo "ERROR: go list could not find the packages to check in ${label}. Its output:" >&2
        gs_tail "${WORK}/list.err"
        continue
    fi
    DIRS=()
    while IFS= read -r dir; do
        [[ -n "${dir}" ]] || continue
        if [[ "${dir}" == "${root}" || "${dir}" == "${physical}" ]]; then
            DIRS+=(./)
        elif [[ "${dir}" == "${root}/"* ]]; then
            DIRS+=("./${dir#"${root}/"}")
        elif [[ "${dir}" == "${physical}/"* ]]; then
            DIRS+=("./${dir#"${physical}/"}")
        else
            DIRS+=("${dir}")
        fi
    done < "${WORK}/dirs"
    if [[ ${#DIRS[@]} -eq 0 ]]; then
        echo "No packages to check in ${label} (${GS_PACKAGES[*]})."
        continue
    fi
    echo "Running gosec in ${label} on $(gs_plural "${#DIRS[@]}" package packages)..."
    rc=0
    (cd "${module}" && "${GOSEC}" -fmt=sarif "-out=${WORK}/module.sarif" -stdout -verbose=json \
        "${OPTIONS[@]}" -- "${DIRS[@]}") > "${WORK}/module.json" 2> "${WORK}/gosec.err" || rc=$?
    # 0 is no findings and 1 findings or errors; anything else, or no
    # report, is gosec stopping before it checked anything.
    if [[ "${rc}" -gt 1 ]] || ! gs_json_is "${WORK}/module.json" 'has("Issues") and has("Golang errors")'; then
        ERRORS+=("${module}")
        echo "ERROR: gosec could not complete in ${label} (exit code ${rc}). Its output:" >&2
        gs_tail "${WORK}/gosec.err"
        continue
    fi
    errors=$(jq -r '."Golang errors" // {} | to_entries[] | .key as $file | .value[]?
        | "  \(if $file == "" or $file == "-" then "" else $file + ":\(.line):\(.column): " end)\(.error)"' "${WORK}/module.json")
    if [[ -n "${errors}" ]]; then
        ERRORS+=("${module}")
        echo "ERROR: gosec could not type-check ${label}, so rules that need type information did not run:" >&2
        head -n 20 <<< "${errors}" >&2
        continue
    fi
    # Paths are absolute in the JSON, and relative to the module in the
    # SARIF; both are made relative to the working directory.
    # shellcheck disable=SC2016 # jq program, not shell
    jq -c --arg mod "${module}" --arg label "${label}" --arg prefix "$(gs_join "${module}" "")" \
        --arg root "${root}/" --arg physical "${physical}/" '
        def relative: if startswith($root) then $prefix + .[($root | length):]
            elif startswith($physical) then $prefix + .[($physical | length):] else . end;
        [.Issues[] | {module: $mod, rule_id, severity, confidence, cwe: (.cwe.id // null), details,
            file: (.file | relative), line: (.line | tostring), column: (.column | tostring), code,
            suppressions: (.suppressions // [])}]' "${WORK}/module.json" > "${WORK}/found.json"
    jq -s -c '.[0] + .[1]' "${WORK}/issues.json" "${WORK}/found.json" > "${WORK}/next.json"
    mv "${WORK}/next.json" "${WORK}/issues.json"
    if [[ "${SARIF}" == true ]]; then
        # shellcheck disable=SC2016 # jq program, not shell
        if ! jq -c --arg prefix "$(gs_join "${module}" "")" '[.runs[]? | .results |= map(.locations |= map(
                if .physicalLocation.artifactLocation.uri? then
                    .physicalLocation.artifactLocation.uri |= ($prefix + ltrimstr("./")) else . end))]' \
            "${WORK}/module.sarif" > "${WORK}/module-runs.json" 2> "${WORK}/jq.err"; then
            ERRORS+=("${module}")
            echo "ERROR: gosec's SARIF report for ${label} could not be read: $(head -c 300 "${WORK}/jq.err")" >&2
            continue
        fi
        jq -s -c '.[0] + .[1]' "${WORK}/runs.json" "${WORK}/module-runs.json" > "${WORK}/next.json"
        mv "${WORK}/next.json" "${WORK}/runs.json"
    fi
done

# With tests, a finding in a file both builds see is reported twice, once
# per package variant.
# shellcheck disable=SC2016 # jq program, not shell
jq --argjson require "${REQUIRE_REASONS}" '
    unique_by([.file, (.line | tonumber? // .line), (.column | tonumber? // .column), .rule_id])
    | map(. + {suppressed: (.suppressions | length > 0),
        unjustified: ([.suppressions[] | select(.kind == "inSource" and ((.justification // "") | test("^\\s*$")))] | length > 0)})
    | map(. + {finding: ((.suppressed | not) or ($require and .unjustified))})' "${WORK}/issues.json" > "${REPORT}"
GS_REPORTS=("${REPORT}")
COUNT=$(jq '[.[] | select(.finding)] | length' "${REPORT}")
SUPPRESSED=$(jq '[.[] | select(.suppressed)] | length' "${REPORT}")
UNJUSTIFIED=$(jq '[.[] | select(.unjustified)] | length' "${REPORT}")
jq -r '.[] | select(.finding and (.suppressed | not))
    | "  \(.file):\(.line):\(.column): \(.rule_id) (\(.severity | ascii_downcase) severity, \(.confidence | ascii_downcase) confidence): \(.details)"' "${REPORT}"
if [[ "${SUPPRESSED}" -gt 0 ]]; then
    echo "$(gs_plural "${SUPPRESSED}" finding findings) suppressed, $(gs_plural "${UNJUSTIFIED}" "without a justification" "without a justification"):"
    jq -r '.[] | select(.suppressed)
        | "  \(.file):\(.line): \(.rule_id): \([.suppressions[] | if .kind == "external" then "excluded by the exclude parameter or the config"
            elif ((.justification // "") | test("^\\s*$")) then "no justification" else .justification end] | join("; "))"' "${REPORT}"
fi
if [[ "${REQUIRE_REASONS}" == true && "${UNJUSTIFIED}" -gt 0 ]]; then
    echo "require_suppression_reasons is true, so each of the $(gs_plural "${UNJUSTIFIED}" suppression suppressions) without a justification counts as a finding." >&2
    echo "  Give one after --, as in: // #nosec G401 -- the hash only names a cache entry" >&2
fi

if [[ "${SARIF}" == true ]]; then
    # One run, so code scanning tools see one gosec analysis.
    # shellcheck disable=SC2016 # jq program, not shell
    jq '{version: "2.1.0", "$schema": "https://json.schemastore.org/sarif-2.1.0.json",
         runs: (if length == 0 then [{tool: {driver: {name: "gosec", informationUri: "https://github.com/securego/gosec", rules: []}}, results: []}]
                else [.[0] + {tool: (.[0].tool | .driver.rules = ([.[] | .tool.driver.rules // [] | .[]] | unique_by(.id))),
                    results: ([.[] | .results // [] | .[]]
                        | unique_by([.ruleId, (.locations[0].physicalLocation.artifactLocation.uri // ""),
                            (.locations[0].physicalLocation.region.startLine // 0), (.locations[0].physicalLocation.region.startColumn // 0)]))}]
                end)}' "${WORK}/runs.json" > "${SARIF_REPORT}"
    GS_REPORTS+=("${SARIF_REPORT}")
fi
if [[ "${JUNIT}" == true ]]; then
    gs_junit "${GS_OUT}/junit/${PARAM_REPORT_NAME}.xml" "gosec" \
        "$(jq -c '[.[] | select(.finding) | {classname: .rule_id, name: "\(.file):\(.line):\(.column)",
            status: "failed", message: (if .suppressed then "suppressed without a justification: \(.details)" else .details end),
            detail: "\(.file):\(.line):\(.column): \(.rule_id) (\(.severity), CWE-\(.cwe // "?")): \(.details)\n\(.code // "")"}]' "${REPORT}")"
    GS_REPORTS+=("${GS_OUT}/junit/${PARAM_REPORT_NAME}.xml")
fi

if [[ ${#ERRORS[@]} -gt 0 ]]; then
    OUTCOME=error
elif [[ "${COUNT}" -gt 0 && "${REPORT_ONLY}" == true ]]; then
    OUTCOME=findings-reported
elif [[ "${COUNT}" -gt 0 ]]; then
    OUTCOME=findings
else
    OUTCOME=passed
fi
if [[ "${RUN_RECORD}" == true ]]; then
    # shellcheck disable=SC2034 # read by gs_run_record
    GS_COUNTS=$(jq -c --argjson errors "${#ERRORS[@]}" '{findings: [.[] | select(.finding)] | length,
        suppressed: [.[] | select(.suppressed)] | length, unjustified_suppressions: [.[] | select(.unjustified)] | length,
        by_severity: ([.[] | select(.finding) | .severity] | group_by(.) | map({key: ., value: length}) | map({(.key[0]): .value}) | add // {}),
        modules_not_checked: $errors}' "${REPORT}")
    gs_run_record "${GS_BASE}.run-record.json" gosec "${OUTCOME}" "$([[ "${OUTCOME}" == error ]] && echo 1 || echo 0)" "${STARTED}"
fi

if [[ ${#ERRORS[@]} -gt 0 ]]; then
    echo "ERROR: gosec could not check ${ERRORS[*]}, so the step fails whatever report_only says." >&2
    exit 1
fi
if [[ "${COUNT}" -gt 0 ]]; then
    gs_gate true "${REPORT_ONLY}" "gosec found $(gs_plural "${COUNT}" problem problems) in $(gs_labels "${GS_MODULES[@]}")."
fi
gs_gate false "${REPORT_ONLY}" "gosec found nothing in $(gs_labels "${GS_MODULES[@]}")."
