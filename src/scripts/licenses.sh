#!/bin/bash
#
# Finds the licenses of each module's dependencies with go-licenses, for the
# licenses command, and checks them against allowed_licenses. It runs
# go-licenses report, whose inventory names every library the packages build
# with and the licenses it found for each, and applies the allowlist itself:
# go-licenses check exits 1 for a license that isn't allowed and for an error
# alike, and its default policy lets GPL through.
#
# go-licenses tells the standard library apart from dependencies by its
# GOROOT, which a -trimpath build doesn't know and a toolchain switch moves:
# then it fails, or reports nothing and passes. So it always runs with the
# GOROOT of the go that runs in the module, and a report that doesn't name
# the module's own packages fails the step.

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
INCLUDE_TESTS=$(gs_bool include_tests "${PARAM_INCLUDE_TESTS}")
CHECK_MAIN=$(gs_bool check_main_module "${PARAM_CHECK_MAIN_MODULE}")
TAGS=$(gs_subst "${PARAM_TAGS}")
gs_output "${PARAM_OUTPUT_DIR}" "${PARAM_REPORT_NAME}"
gs_require_jq
gs_go
gs_tool go-licenses
LICENSES_TOOL=${GS_TOOL}
# shellcheck disable=SC2034 # read by gs_run_record
GS_TOOL_VERSION=$(go version -m "${LICENSES_TOOL}" 2> /dev/null | awk '$1 == "mod" { print $3; exit }') || GS_TOOL_VERSION=""
gs_modules "${PARAM_MODULES}"
gs_packages "${PARAM_PACKAGES}"

gs_list allowed_licenses "${PARAM_ALLOWED_LICENSES}"
ALLOWED=(${GS_LIST[@]+"${GS_LIST[@]}"})
if [[ ${#ALLOWED[@]} -eq 0 ]]; then
    echo "ERROR: allowed_licenses names no license. It is required: go-licenses' own default lets GPL through." >&2
    exit 1
fi
for license in "${ALLOWED[@]}"; do
    if ! gs_match "${license}" '^[A-Za-z0-9][A-Za-z0-9.+-]*$'; then
        echo "ERROR: allowed_licenses must list SPDX identifiers such as MIT or Apache-2.0, not '${license}'." >&2
        exit 1
    fi
done
gs_list ignore "${PARAM_IGNORE}"
IGNORE=(${GS_LIST[@]+"${GS_LIST[@]}"})
for prefix in ${IGNORE[@]+"${IGNORE[@]}"}; do
    if [[ "${prefix}" == -* ]]; then
        echo "ERROR: ignore names '${prefix}', which go-licenses would read as a flag." >&2
        exit 1
    fi
done
gs_list platforms "${PARAM_PLATFORMS}"
PLATFORMS=(${GS_LIST[@]+"${GS_LIST[@]}"})
if [[ ${#PLATFORMS[@]} -gt 0 ]]; then
    KNOWN_PLATFORMS=" $(go tool dist list | tr '\n' ' ') "
    for platform in "${PLATFORMS[@]}"; do
        if [[ "${KNOWN_PLATFORMS}" != *" ${platform} "* ]]; then
            echo "ERROR: platforms names '${platform}', which isn't a GOOS/GOARCH pair this go supports (go tool dist list)." >&2
            exit 1
        fi
    done
else
    PLATFORMS=("")
fi
if [[ -n "${TAGS}" && " ${GOFLAGS:-} " == *" -tags"* ]]; then
    echo "ERROR: tags is set, and GOFLAGS already sets -tags (${GOFLAGS}). Set the tags in one of them." >&2
    exit 1
fi

ARGS=(report)
if [[ "${INCLUDE_TESTS}" == true ]]; then
    ARGS+=(--include_tests)
fi
for prefix in ${IGNORE[@]+"${IGNORE[@]}"}; do
    ARGS+=("--ignore=${prefix}")
done

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
# One line per library and license, tab-separated: no field holds a tab.
printf '{{range .}}{{.Name}}\t{{.Version}}\t{{.LicenseName}}\t{{.LicensePath}}\t{{.LicenseURL}}\n{{end}}' > "${WORK}/report.tmpl"
GOMODCACHE_DIR=$(go env GOMODCACHE 2> /dev/null || true)
: > "${WORK}/rows.json"
ERRORS=()
GS_INPUTS=()
# shellcheck disable=SC2034 # read by gs_run_record
GS_ARGS=("${ARGS[@]}" "--template=<inventory template>")
MAIN_PATHS=()
for module in "${GS_MODULES[@]}"; do
    label=$(gs_label "${module}")
    GS_INPUTS+=("go.mod:${module}/go.mod" "go.sum:${module}/go.sum")
    module_path=$(awk '$1 == "module" { gsub(/"/, "", $2); print $2; exit }' "${module}/go.mod")
    MAIN_PATHS+=("${module_path}")
    if ! goroot=$(cd "${module}" && go env GOROOT) || [[ -z "${goroot}" ]]; then
        ERRORS+=("${module}")
        echo "ERROR: go could not say which GOROOT runs in ${label} (go env GOROOT)." >&2
        continue
    fi
    for platform in "${PLATFORMS[@]}"; do
        where=${platform:-$(cd "${module}" && go env GOOS)/$(cd "${module}" && go env GOARCH)}
        echo "Running go-licenses in ${label} for ${where}..."
        env_args=("GOROOT=${goroot}")
        if [[ -n "${TAGS}" ]]; then
            env_args+=("GOFLAGS=${GOFLAGS:+${GOFLAGS} }-tags=${TAGS}")
        fi
        if [[ -n "${platform}" ]]; then
            env_args+=("GOOS=${platform%/*}" "GOARCH=${platform#*/}")
        fi
        rc=0
        (cd "${module}" && env "${env_args[@]}" "${LICENSES_TOOL}" "${ARGS[@]}" "--template=${WORK}/report.tmpl" \
            -- "${GS_PACKAGES[@]}") > "${WORK}/out.tsv" 2> "${WORK}/err.log" || rc=$?
        if [[ "${rc}" -ne 0 ]]; then
            ERRORS+=("${module}")
            echo "ERROR: go-licenses could not complete in ${label} for ${where} (exit code ${rc}). Its output:" >&2
            grep -vE '^W[0-9]{4} ' "${WORK}/err.log" > "${WORK}/err.short" || true
            gs_tail "${WORK}/err.short"
            continue
        fi
        if awk -F'\t' 'NF != 5 { bad = 1 } END { exit !bad }' "${WORK}/out.tsv"; then
            ERRORS+=("${module}")
            echo "ERROR: go-licenses' report for ${label} could not be read:" >&2
            gs_tail "${WORK}/out.tsv" 5
            continue
        fi
        # The fail-open guard: the module's own packages are always in the
        # inventory, unless ignore leaves them out.
        own=$(awk -F'\t' -v path="${module_path}" '$1 == path || index($1, path "/") == 1 { n++ } END { print n + 0 }' "${WORK}/out.tsv")
        covered=false
        for prefix in ${IGNORE[@]+"${IGNORE[@]}"}; do
            if [[ "${module_path}" == "${prefix}"* ]]; then
                covered=true
            fi
        done
        if [[ "${own}" -eq 0 && "${covered}" == false ]]; then
            ERRORS+=("${module}")
            echo "ERROR: go-licenses reported none of ${label}'s own packages, so it checked nothing:" >&2
            echo "  it may have taken every package for part of the standard library. Its output:" >&2
            gs_tail "${WORK}/err.log"
            continue
        fi
        # shellcheck disable=SC2016 # jq program, not shell
        jq -R -c --arg mod "${module}" --arg platform "${where}" --arg cache "${GOMODCACHE_DIR%/}/" '
            split("\t") | {module: $mod, platform: $platform, name: .[0], version: .[1], license: .[2],
                license_path: (.[3] | if startswith($cache) then .[($cache | length):] else . end), license_url: .[4]}' \
            "${WORK}/out.tsv" >> "${WORK}/rows.json"
    done
done

REPORT="${GS_BASE}.json"
CSV_REPORT="${GS_BASE}.csv"
# One entry per library and version, with every license found for it on
# any platform: a library needs all of them on the list.
# shellcheck disable=SC2016 # jq program, not shell
jq -s --argjson allowed "$(printf '%s\n' "${ALLOWED[@]}" | jq -R 'ascii_downcase' | jq -s -c .)" \
    --argjson main "$(printf '%s\n' "${MAIN_PATHS[@]}" | jq -R . | jq -s -c .)" --argjson check_main "${CHECK_MAIN}" '
    group_by([.name, .version]) | map(
        (.[0].name) as $name
        | {name: $name, version: (.[0].version | if . == "Unknown" then null else . end),
           licenses: ([.[].license] | unique), platforms: ([.[].platform] | unique), modules: ([.[].module] | unique),
           license_path: ([.[].license_path | select(. != "Unknown")] | first // null),
           license_url: ([.[].license_url | select(. != "Unknown")] | first // null),
           own: any($main[]; $name == . or ($name | startswith(. + "/")))}
        | .status = (if .own and ($check_main | not) then "own"
            elif any(.licenses[]; . == "Unknown") then "unknown"
            elif all(.licenses[]; ascii_downcase as $l | any($allowed[]; . == $l)) then "allowed"
            else "not-allowed" end)
        | .finding = (.status == "unknown" or .status == "not-allowed"))' "${WORK}/rows.json" > "${REPORT}"
{
    echo 'library,version,licenses,status,license_url'
    jq -r '.[] | [.name, (.version // ""), (.licenses | join(" ")), .status, (.license_url // "")] | @csv' "${REPORT}"
} > "${CSV_REPORT}"
GS_REPORTS=("${REPORT}" "${CSV_REPORT}")
COUNT=$(jq '[.[] | select(.finding)] | length' "${REPORT}")
DEPENDENCIES=$(jq '[.[] | select(.own | not)] | length' "${REPORT}")
if [[ "${DEPENDENCIES}" -eq 0 ]]; then
    echo "No dependencies found."
else
    echo "$(gs_plural "${DEPENDENCIES}" dependency dependencies) found:" \
        "$(jq -r '[.[] | select(.own | not) | .status] | group_by(.) | map("\(length) \(.[0])") | join(", ")' "${REPORT}")."
fi
jq -r '.[] | select(.finding) | "  \(.name)\(if .version then "@" + .version else "" end): \(.licenses | join(", "))\(
    if .status == "unknown" then " (no license found, or one go-licenses can'"'"'t identify)" else " (not in allowed_licenses)" end)"' "${REPORT}"
if [[ "${JUNIT}" == true ]]; then
    gs_junit "${GS_OUT}/junit/${PARAM_REPORT_NAME}.xml" "go-licenses" \
        "$(jq -c '[.[] | select(.finding) | {classname: .status, name: "\(.name)\(if .version then "@" + .version else "" end)", status: "failed",
            message: (if .status == "unknown" then "no license found, or one go-licenses cannot identify" else "license not allowed: \(.licenses | join(", "))" end),
            detail: "\(.name) \(.version // "") on \(.platforms | join(", ")), used by \(.modules | join(", ")): \(.licenses | join(", ")) (\(.license_path // "no license file"))"}]' "${REPORT}")"
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
    GS_COUNTS=$(jq -c --argjson errors "${#ERRORS[@]}" '{dependencies: [.[] | select(.own | not)] | length,
        allowed: [.[] | select(.status == "allowed")] | length, not_allowed: [.[] | select(.status == "not-allowed")] | length,
        unknown: [.[] | select(.status == "unknown")] | length, modules_not_checked: $errors}' "${REPORT}")
    gs_run_record "${GS_BASE}.run-record.json" licenses "${OUTCOME}" "$([[ "${OUTCOME}" == error ]] && echo 1 || echo 0)" "${STARTED}"
fi

if [[ ${#ERRORS[@]} -gt 0 ]]; then
    echo "ERROR: go-licenses could not check $(printf '%s\n' "${ERRORS[@]}" | sort -u | tr '\n' ' '), so the step fails whatever report_only says." >&2
    exit 1
fi
if [[ "${COUNT}" -gt 0 ]]; then
    gs_gate true "${REPORT_ONLY}" "$(gs_plural "${COUNT}" dependency dependencies) of $(gs_labels "${GS_MODULES[@]}") $([[ "${COUNT}" -eq 1 ]] && echo has || echo have) a license that isn't allowed, or none go-licenses can identify."
fi
gs_gate false "${REPORT_ONLY}" "every dependency of $(gs_labels "${GS_MODULES[@]}") has an allowed license."
