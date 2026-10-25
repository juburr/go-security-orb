#!/bin/bash
#
# Runs each module's tests in FIPS 140-3 mode, for the fips_test command:
# linked with the Go Cryptographic Module GOFIPS140 names, and with
# GODEBUG=fips140=only, where the standard library returns an error or
# panics for algorithms the mode doesn't allow. go test -json tells failing
# tests from code that doesn't build (build-fail events, Go 1.24 and later),
# so only test failures are findings. Go releases before 1.24 ignore both
# settings, and would pass every test, so they fail the step.

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
TAGS=$(gs_subst "${PARAM_TAGS}")
case "${PARAM_FIPS140}" in
    on | only) ;;
    *)
        echo "ERROR: fips140 must be only or on, not '${PARAM_FIPS140}'." >&2
        exit 1
        ;;
esac
GOFIPS=$(gs_subst "${PARAM_GOFIPS140}")
case "${GOFIPS}" in
    "" | off | latest)
        echo "ERROR: gofips140 must name a Go Cryptographic Module version, such as v1.0.0, not '${GOFIPS}':" >&2
        echo "  off and latest link no validated module." >&2
        exit 1
        ;;
esac
if ! gs_match "${GOFIPS}" '^(v[0-9]+\.[0-9]+\.[0-9]+(-[0-9a-f]+)?|certified|inprocess)$'; then
    echo "ERROR: gofips140 must be a module version such as v1.0.0, or certified or inprocess, not '${GOFIPS}'." >&2
    exit 1
fi
if [[ "${TAGS}" == *[[:space:]]* ]]; then
    echo "ERROR: tags must be separated by commas, not spaces." >&2
    exit 1
fi
gs_output "${PARAM_OUTPUT_DIR}" "${PARAM_REPORT_NAME}"
gs_require_jq
gs_go
gs_modules "${PARAM_MODULES}"
gs_packages "${PARAM_PACKAGES}"
gs_words extra_args "$(gs_subst "${PARAM_EXTRA_ARGS}")"
for word in ${GS_WORDS[@]+"${GS_WORDS[@]}"}; do
    case "${word%%=*}" in
        -json | --json | -v | --v | -tags | --tags)
            echo "ERROR: extra_args can't set ${word%%=*}: this command sets it." >&2
            exit 1
            ;;
    esac
done

# A test that panics ends its package's test binary, and with it the tests
# after it, so packages are run again without the tests that panicked, as
# long as extra_args doesn't choose tests to skip itself.
RERUN=true
for word in ${GS_WORDS[@]+"${GS_WORDS[@]}"}; do
    case "${word%%=*}" in
        -skip | --skip | -test.skip | --test.skip) RERUN=false ;;
    esac
done
MAX_RERUNS=20

ARGS=(-json)
if [[ -n "${TAGS}" ]]; then
    ARGS+=("-tags=${TAGS}")
fi
ARGS+=(${GS_WORDS[@]+"${GS_WORDS[@]}"})
# Later GODEBUG settings win, so the mode goes last.
GODEBUG_VALUE="${GODEBUG:+${GODEBUG},}fips140=${PARAM_FIPS140}"

# Reads one module's go test -json events: top-level tests, with their
# subtests' output, and the algorithms the mode refused in it.
# shellcheck disable=SC2016 # jq program, not shell
ANALYZE_JQ='
    def refused: [.[] | match("[A-Za-z0-9_/.-]+: use of .*? is not allowed in FIPS 140-only mode"; "g") | .string] | unique;
    def top: split("/")[0];
    . as $events
    | (reduce ($events[] | select(.Action == "output")) as $e ({};
        .[($e.Package // "") + "\u0000" + (($e.Test // "") | top)] += [$e.Output // ""])) as $out
    | [$events[] | select(.Test != null and (.Test | contains("/") | not)
        and (.Action == "pass" or .Action == "fail" or .Action == "skip"))]
        | group_by([.Package, .Test]) | map(if any(.[]; .Action == "fail") then (map(select(.Action == "fail")) | last) else last end)
        | . as $tests
    | [$events[] | select(.Test == null and .Package != null and (.Action == "pass" or .Action == "fail" or .Action == "skip"))]
        | group_by(.Package) | map(if any(.[]; .Action == "fail") then (map(select(.Action == "fail")) | last) else last end)
        | . as $packages
    | ([($events[] | select(.Action == "build-fail") | .ImportPath), ($packages[] | select(.FailedBuild != null) | .FailedBuild)]
        | unique) as $build
    | [$tests[] | select(.Action == "fail") | ($out[.Package + "\u0000" + .Test] // []) as $o
        | {package: .Package, test: .Test, refused: ($o | refused), panicked: any($o[]; startswith("panic: ")),
           rerun: (.Test as $t | (($rerun[.Package] // []) | index($t)) != null), output: ($o[-40:] | join(""))}] as $failed
    | [$packages[] | select(.Action == "fail" and .FailedBuild == null) | .Package as $p
        | select([$failed[] | select(.package == $p)] | length == 0)
        | ($out[$p + "\u0000"] // []) as $o
        | {package: $p, refused: ($o | refused), output: ($o[-40:] | join(""))}] as $package_failures
    | {module: $mod, path: $path, go_version: $go,
       tests: {passed: [$tests[] | select(.Action == "pass")] | length, failed: ($failed | length),
               skipped: [$tests[] | select(.Action == "skip")] | length},
       packages: {passed: [$packages[] | select(.Action == "pass")] | length,
                  failed: [$packages[] | select(.Action == "fail")] | length,
                  without_tests: [$packages[] | select(.Action == "skip")] | length},
       failed_tests: $failed, failed_packages: $package_failures, build_failed: $build,
       refused: ([$failed[].refused[], $package_failures[].refused[]] | unique),
       junit: ([$tests[] | {classname: .Package, name: .Test,
                 status: (if .Action == "pass" then "passed" elif .Action == "skip" then "skipped" else "failed" end)}
                 + (if .Action == "fail" then (.Package as $p | .Test as $t | [$failed[] | select(.package == $p and .test == $t)][0]
                     | {message: (if (.refused | length) > 0 then .refused | join("; ") else "failed in FIPS 140-3 mode" end), detail: .output})
                   else {} end)]
               + [$package_failures[] | {classname: .package, name: "(package)", status: "failed",
                   message: "failed outside any test, such as in an init function or TestMain", detail: .output}]
               + [$build[] | {classname: ., name: "build", status: "failed", message: "does not build"}])}'

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/results"
ERRORS=()
GS_INPUTS=()
: > "${WORK}/all-events.json"
n=0
for module in "${GS_MODULES[@]}"; do
    n=$((n + 1))
    id=$(printf '%03d' "${n}")
    label=$(gs_label "${module}")
    GS_INPUTS+=("go.mod:${module}/go.mod" "go.sum:${module}/go.sum")
    gs_go_version "${module}"
    if ((GS_GO_MINOR < 24)); then
        ERRORS+=("${label}")
        echo "ERROR: ${GS_GO_VERSION} runs in ${label}, and Go releases before 1.24 have no FIPS 140-3 mode: they ignore" >&2
        echo "  GOFIPS140 and GODEBUG=fips140, so every test would pass without it. Test with Go 1.24 or newer." >&2
        continue
    fi
    echo "Testing ${label} with GOFIPS140=${GOFIPS} and GODEBUG=fips140=${PARAM_FIPS140} (${GS_GO_VERSION})..."
    rc=0
    (cd "${module}" && GOFIPS140="${GOFIPS}" GODEBUG="${GODEBUG_VALUE}" go test "${ARGS[@]}" "${GS_PACKAGES[@]}") \
        > "${WORK}/raw.json" 2> "${WORK}/err.log" || rc=$?
    jq -c -R 'fromjson? // empty' "${WORK}/raw.json" > "${WORK}/events.json"
    # Packages whose run a panic ended run again, without the tests that
    # panicked, until none panics.
    declare -A SKIP=()
    reruns=0
    while [[ "${RERUN}" == true ]] && ((reruns < MAX_RERUNS)); do
        jq -r 'select(.Action == "output" and .Test != null and ((.Output // "") | startswith("panic: ")))
            | "\(.Package)\t\(.Test | split("/")[0])"' "${WORK}/events.json" | LC_ALL=C sort -u > "${WORK}/panicked"
        added=()
        while IFS=$'\t' read -r package test; do
            if [[ "|${SKIP[${package}]:-}|" != *"|${test}|"* ]]; then
                SKIP[${package}]="${SKIP[${package}]:+${SKIP[${package}]}|}${test}"
                added+=("${package}")
                echo "  ${test} panicked in ${package}, so the package's other tests run again without it."
            fi
        done < "${WORK}/panicked"
        if [[ ${#added[@]} -eq 0 ]]; then
            break
        fi
        for package in $(printf '%s\n' "${added[@]}" | LC_ALL=C sort -u); do
            reruns=$((reruns + 1))
            (cd "${module}" && GOFIPS140="${GOFIPS}" GODEBUG="${GODEBUG_VALUE}" go test "${ARGS[@]}" \
                "-skip=^(${SKIP[${package}]})\$" "${package}") > "${WORK}/rerun.json" 2>> "${WORK}/err.log" || true
            jq -c -R 'fromjson? // empty' "${WORK}/rerun.json" >> "${WORK}/events.json"
        done
    done
    if ((reruns >= MAX_RERUNS)); then
        echo "WARN: Stopped running packages again after ${MAX_RERUNS} panics in ${label}: tests after the last one did not run." >&2
    fi
    RERUN_JSON=$(for package in "${!SKIP[@]}"; do
        jq -cn --arg package "${package}" --arg tests "${SKIP[${package}]}" '{($package): ($tests | split("|"))}'
    done | jq -s -c 'add // {}')
    unset SKIP
    cat "${WORK}/events.json" >> "${WORK}/all-events.json"
    if ! jq -s -c --argjson rerun "${RERUN_JSON}" --arg mod "$(awk '$1 == "module" { gsub(/"/, "", $2); print $2; exit }' "${module}/go.mod")" \
        --arg path "${module}" --arg go "${GS_GO_VERSION}" "${ANALYZE_JQ}" "${WORK}/events.json" > "${WORK}/result.json" 2> "${WORK}/jq.err"; then
        ERRORS+=("${label}")
        echo "ERROR: go test's output for ${label} could not be read: $(head -c 300 "${WORK}/jq.err")" >&2
        continue
    fi
    if [[ "${rc}" -ne 0 ]] && gs_json_is "${WORK}/result.json" '.tests.failed == 0 and (.failed_packages | length) == 0 and (.build_failed | length) == 0'; then
        ERRORS+=("${label}")
        echo "ERROR: go test failed in ${label} (exit code ${rc}) without reporting a failing test. Its output:" >&2
        gs_tail "${WORK}/err.log"
        gs_tail "${WORK}/raw.json" 10
        continue
    fi
    mv "${WORK}/result.json" "${WORK}/results/${id}.json"
    jq -r '"  \(.tests.passed) passed, \(.tests.failed) failed, \(.tests.skipped) skipped in \(.packages.passed + .packages.failed) package\(if .packages.passed + .packages.failed == 1 then "" else "s" end)",
        (.failed_tests[] | "  FAIL \(.package) \(.test): \(if (.refused | length) > 0 then .refused | join("; ") else "failed in FIPS 140-3 mode (output below)" end)",
            (if (.refused | length) == 0 then (.output | split("\n") | .[-11:-1][] | "    \(.)") else empty end),
            (if .panicked and .rerun then "    It panicked, so the other tests of its package ran again without it."
             elif .panicked then "    It panicked, which ended the run of its package: later tests there did not run." else empty end)),
        (.failed_packages[] | "  FAIL \(.package), outside any test: \(if (.refused | length) > 0 then .refused | join("; ") else "see its output in the report" end)")' \
        "${WORK}/results/${id}.json"
    if gs_json_is "${WORK}/results/${id}.json" '(.build_failed | length) > 0'; then
        ERRORS+=("${label}")
        echo "ERROR: Some of ${label} does not build: $(jq -r '.build_failed | join(", ")' "${WORK}/results/${id}.json")" >&2
        jq -r 'select(.Action == "build-output") | .Output // ""' "${WORK}/events.json" | tail -n 40 | awk '{ print "  " $0 }' >&2
    fi
done

REPORT="${GS_BASE}.json"
EVENTS="${GS_BASE}.test.json"
cp "${WORK}/all-events.json" "${EVENTS}"
GS_REPORTS=("${REPORT}" "${EVENTS}")
find "${WORK}/results" -name '*.json' | LC_ALL=C sort | xargs -r cat | jq -s --arg gofips "${GOFIPS}" --arg mode "${PARAM_FIPS140}" \
    '{gofips140: $gofips, fips140: $mode, refused: ([.[].refused[]] | unique), modules: map(del(.junit))}' > "${REPORT}"
FINDINGS=$(jq '[.modules[] | .tests.failed + (.failed_packages | length)] | add // 0' "${REPORT}")
echo "Report: ${REPORT}"
if [[ "$(jq '.refused | length' "${REPORT}")" -gt 0 ]]; then
    echo "FIPS 140-3 only mode refused:"
    jq -r '.refused[] | "  \(.)"' "${REPORT}"
fi
if [[ "${JUNIT}" == true ]]; then
    gs_junit "${GS_OUT}/junit/${PARAM_REPORT_NAME}.xml" "fips_test" \
        "$(find "${WORK}/results" -name '*.json' | LC_ALL=C sort | xargs -r cat | jq -s -c '[.[].junit[]]')"
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
    GS_TOOL_VERSION=$(go env GOVERSION 2> /dev/null) || GS_TOOL_VERSION=""
    # shellcheck disable=SC2034 # read by gs_run_record
    GS_ARGS=(test "${ARGS[@]}" "${GS_PACKAGES[@]}")
    # shellcheck disable=SC2034 # read by gs_run_record
    GS_RESULTS=$(jq -c --arg godebug "${GODEBUG_VALUE}" --arg gofips "${GOFIPS}" '[.modules[]
        | del(.failed_tests[].output, .failed_packages[].output) + {gofips140: $gofips, godebug: $godebug}]' "${REPORT}")
    # shellcheck disable=SC2034 # read by gs_run_record
    GS_COUNTS=$(jq -c --argjson errors "${#ERRORS[@]}" '{tests_passed: ([.modules[].tests.passed] | add // 0),
        tests_failed: ([.modules[].tests.failed] | add // 0), packages_failed_outside_tests: ([.modules[].failed_packages | length] | add // 0),
        refused: (.refused | length), modules_not_completed: $errors}' "${REPORT}")
    gs_run_record "${GS_BASE}.run-record.json" fips_test "${OUTCOME}" "$([[ "${OUTCOME}" == error ]] && echo 1 || echo 0)" "${STARTED}"
fi

if [[ ${#ERRORS[@]} -gt 0 ]]; then
    echo "ERROR: The tests could not run in FIPS 140-3 mode in $(printf '%s\n' "${ERRORS[@]}" | awk '!seen[$0]++' | paste -sd, - | sed 's/,/, /g'), so the step fails whatever report_only says." >&2
    exit 1
fi
if [[ "${FINDINGS}" -gt 0 ]]; then
    gs_gate true "${REPORT_ONLY}" "$(gs_plural "${FINDINGS}" test tests) failed with GOFIPS140=${GOFIPS} and GODEBUG=fips140=${PARAM_FIPS140} in $(gs_labels "${GS_MODULES[@]}")."
fi
gs_gate false "${REPORT_ONLY}" "every test passed with GOFIPS140=${GOFIPS} and GODEBUG=fips140=${PARAM_FIPS140} in $(gs_labels "${GS_MODULES[@]}")."
