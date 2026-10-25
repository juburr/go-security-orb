#!/usr/bin/env bash
#
# Tests the command scripts offline. go is real (Go 1.24 or newer must be on
# the PATH), and runs against copies of tests/fixtures and modules the tests
# write, none of which need the network: modules come from local
# directories, or from a file:// module proxy the tests build. gosec,
# govulncheck, go-licenses and the CircleCI CLI are stand-ins that record
# how they were run and answer with the scenario each test picks; the
# govulncheck stand-in answers with the real output in
# tests/fixtures/govulncheck. A go wrapper passes everything to the real go,
# except go version -m on a file with a .buildinfo beside it, which prints
# that instead, so fips_bin can be tested on builds this machine can't make.
#
# What the real tools print is checked by test-deploy.yml, which runs every
# command with them.
#
# Run from a checkout:
#   bash tests/commands_test.sh

set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
trap 'chmod -R u+w "${WORK}" 2> /dev/null; rm -rf "${WORK}"' EXIT
STUBS="${WORK}/stubs"
CALLS="${WORK}/calls"
OUT="${WORK}/out"
FIXTURES="${ROOT}/tests/fixtures"
mkdir -p "${STUBS}" "${CALLS}" "${WORK}/home"
export CALLS FIXTURES

if ! REAL_GO=$(command -v go); then
    echo "FAIL: these tests run the real go, and there is none on the PATH."
    exit 1
fi
export REAL_GO
# The tests pick the Go settings; the job's must not change what go does.
unset GOFLAGS GOEXPERIMENT GOWORK GOTOOLCHAIN CGO_ENABLED GOOS GOARCH GOPRIVATE GONOPROXY GONOSUMDB GOINSECURE \
    GODEBUG GOFIPS140 GOVERSION NETRC GO_SECURITY_VULN_DB BASH_ENV
export HOME="${WORK}/home" GOTOOLCHAIN=local GOPROXY=off GOCACHE="${WORK}/gocache" GOMODCACHE="${WORK}/modcache" \
    GOPATH="${WORK}/gopath" GOENV=off
if [[ "$("${REAL_GO}" env GOVERSION)" =~ ^go1\.([0-9]+) ]] && ((BASH_REMATCH[1] < 24)); then
    echo "FAIL: these tests need Go 1.24 or newer on the PATH, for FIPS 140-3 mode; this is $("${REAL_GO}" env GOVERSION)."
    exit 1
fi

FAILURES=0
OUTPUT=""
RC=0

begin() {
    echo "--- $1"
}
check() {
    local name=$1
    shift
    if "$@"; then
        echo "  ok: ${name}"
    else
        echo "  FAIL: ${name}"
        tail -n 25 <<< "${OUTPUT}" | while IFS= read -r line; do printf '    | %s\n' "${line}"; done
        FAILURES=$((FAILURES + 1))
    fi
}
succeeded() { [[ "${RC}" -eq 0 ]]; }
failed() { [[ "${RC}" -ne 0 ]]; }
said() { grep -qF -- "$1" <<< "${OUTPUT}"; }
# not_said leaves out the line run_command.sh starts with, which lists the
# parameters as given.
not_said() { ! grep -v '^Running scripts/' <<< "${OUTPUT}" | grep -qF -- "$1"; }
# called_with TOOL WORD...: some call of TOOL had every WORD among its arguments.
called_with() {
    local tool=$1 file word ok
    shift
    for file in "${CALLS}/${tool}".*; do
        [[ -f "${file}" ]] || continue
        ok=true
        for word in "$@"; do
            grep -qxF -- "${word}" "${file}" || ok=false
        done
        if [[ "${ok}" == true ]]; then
            return 0
        fi
    done
    OUTPUT+=$'\n'"calls of ${tool}:"$'\n'"$(for f in "${CALLS}/${tool}".*; do [[ -f "${f}" ]] && tr '\n' ' ' < "${f}" && echo; done)"
    return 1
}
not_called_with() {
    local saved=${OUTPUT}
    if called_with "$@"; then
        return 1
    fi
    OUTPUT=${saved}
}
call_count() { [[ "$(find "${CALLS}" -name "$1.[0-9]*" | wc -l)" -eq "$2" ]]; }
file_has() { grep -qF -- "$2" "$1"; }
not_file_has() { ! grep -qF -- "$2" "$1" 2> /dev/null; }
json_is() { [[ "$(jq -r "$2" "$1" 2> /dev/null)" == "$3" ]] || { OUTPUT+=$'\n'"$1: $2 is $(jq -c "$2" "$1" 2>&1)"; return 1; }; }
exists() { [[ -e "$1" ]]; }
absent() { [[ ! -e "$1" ]]; }
mode_is() { [[ "$(stat -c %a "$1")" == "$2" ]]; }

# Stand-ins. Each records its arguments, one per line, to CALLS/<tool>.<n>.
record() {
    cat << 'EOF'
n=$(find "${CALLS}" -name "${0##*/}.[0-9]*" | wc -l)
printf '%s\n' "$@" > "${CALLS}/${0##*/}.$((n + 1))"
EOF
}

# circleci: env subst expands $NAME and ${NAME} on stdin, as the real CLI does.
cat > "${STUBS}/circleci" << 'EOF'
#!/usr/bin/env bash
input=$(cat)
output=""
re='^([^$]*)\$(\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))(.*)$'
while [[ "${input}" =~ ${re} ]]; do
    name=${BASH_REMATCH[3]:-${BASH_REMATCH[4]}}
    output+="${BASH_REMATCH[1]}${!name-}"
    input=${BASH_REMATCH[5]}
done
printf '%s\n' "${output}${input}"
EOF

# go: the real go, except for go version -m FILE when FILE.buildinfo exists
# (it prints that, as go version -m would for such a build), and go env
# GOVERSION when STUB_GOVERSION is set.
cat > "${STUBS}/go" << 'EOF'
#!/usr/bin/env bash
if [[ "$1" == version && "$2" == -m && $# -eq 3 && -f "$3.buildinfo" ]]; then
    printf '%s: ' "$3"
    cat "$3.buildinfo"
    exit 0
fi
if [[ "$*" == "env GOVERSION" && -n "${STUB_GOVERSION:-}" ]]; then
    echo "${STUB_GOVERSION}"
    exit 0
fi
exec "${REAL_GO}" "$@"
EOF

# gosec: STUB_GOSEC is issues (default: one finding at etag.go:15, and one at
# etag.go:20 suppressed with the justification in STUB_JUSTIFICATION), clean,
# golangerrors (a type-check error, exit 1) or crash (exit 2, no report).
# Like gosec, it writes JSON on stdout and SARIF to -out, with absolute
# paths in the JSON and paths relative to the directory it ran in in SARIF.
{
    echo '#!/usr/bin/env bash'
    record
    cat << 'EOF'
if [[ "$1" == -version ]]; then
    printf 'Version: 2.30.0\nGit tag: v2.30.0\n'
    exit 0
fi
out=""
for arg in "$@"; do
    case "${arg}" in -out=*) out=${arg#-out=} ;; esac
done
file="${PWD}/etag.go"
errors='{}'
issues='[]'
case "${STUB_GOSEC:-issues}" in
    crash)
        echo "gosec: could not start" >&2
        exit 2
        ;;
    golangerrors)
        errors=$(jq -cn --arg f "${file}" '{($f): [{line: 3, column: 1, error: "undefined: x"}]}')
        ;;
    issues)
        issues=$(jq -cn --arg f "${file}" --arg j "${STUB_JUSTIFICATION:-}" '[
            {severity: "MEDIUM", confidence: "HIGH", cwe: {id: "328"}, rule_id: "G401", details: "Use of weak cryptographic primitive",
             file: $f, code: "15: x", line: "15", column: "27", nosec: false, suppressions: null},
            {severity: "MEDIUM", confidence: "HIGH", cwe: {id: "328"}, rule_id: "G401", details: "Use of weak cryptographic primitive",
             file: $f, code: "20: x", line: "20", column: "27", nosec: false, suppressions: [{kind: "inSource", justification: $j}]}]')
        ;;
esac
jq -n --argjson i "${issues}" --argjson e "${errors}" '{"Golang errors": $e, Issues: $i, Stats: {}}'
if [[ -n "${out}" ]]; then
    jq -n --argjson i "${issues}" '{version: "2.1.0", runs: [{tool: {driver: {name: "gosec", rules: ([$i[] | {id: .rule_id}] | unique)}},
        results: [$i[] | {ruleId: .rule_id, locations: [{physicalLocation: {artifactLocation: {uri: "etag.go"},
            region: {startLine: (.line | tonumber), startColumn: (.column | tonumber)}}}]}
            + (if .suppressions then {suppressions: [{kind: "inSource"}]} else {} end)]}]}' > "${out}"
fi
if [[ "${issues}" != '[]' || "${errors}" != '{}' ]]; then
    exit 1
fi
EOF
} > "${STUBS}/gosec"

# govulncheck: answers with the real streams in tests/fixtures/govulncheck,
# dated today: source-vulnerable in a module that requires golang.org/x/text,
# source-clean elsewhere, and binary-vulnerable for a file that starts with
# GOBINARY (anything else is not a Go binary to it). -mode convert writes
# the matching real SARIF or OpenVEX. STUB_VULN is stale (a database last
# modified in 2020), nostdlib (no standard library version) or error (exit 1).
{
    echo '#!/usr/bin/env bash'
    record
    cat << 'EOF'
mode=source
format=""
previous=""
last=""
for arg in "$@"; do
    case "${previous}" in
        -mode) mode=${arg} ;;
        -format) format=${arg} ;;
    esac
    previous=${arg}
    last=${arg}
done
dir="${FIXTURES}/govulncheck"
if [[ "${mode}" == convert ]]; then
    kind=source-clean
    if grep -q GO-2021-0113; then
        kind=source-vulnerable
    fi
    case "${format}" in
        sarif) cat "${dir}/${kind}.sarif" ;;
        openvex) cat "${dir}/${kind}.openvex.json" ;;
        *) echo "govulncheck: unknown format" >&2; exit 2 ;;
    esac
    exit 0
fi
if [[ "${STUB_VULN:-}" == error ]]; then
    echo "govulncheck: loading packages: there are errors in the packages" >&2
    exit 1
fi
if [[ "${mode}" == binary ]]; then
    if [[ "$(head -c 8 "${last}" 2> /dev/null)" != GOBINARY ]]; then
        echo "govulncheck: unrecognized binary format" >&2
        exit 1
    fi
    stream="${dir}/binary-vulnerable.json"
elif grep -q 'golang.org/x/text' go.mod 2> /dev/null; then
    stream="${dir}/source-vulnerable.json"
else
    stream="${dir}/source-clean.json"
fi
modified=$(date -u +%Y-%m-%dT%H:%M:%SZ)
if [[ "${STUB_VULN:-}" == stale ]]; then
    modified=2020-01-01T00:00:00Z
fi
jq -c --arg m "${modified}" --arg scenario "${STUB_VULN:-}" '
    if .config then .config.db_last_modified = $m else . end
    | if $scenario == "nostdlib" and .SBOM then
        .SBOM.go_version = "" | .SBOM.modules |= map(if .path == "stdlib" then .version = "" else . end) else . end' "${stream}"
EOF
} > "${STUBS}/govulncheck"

# go-licenses: report prints one row per library, as the orb's template
# asks: the module's own two packages (MIT) and golang.org/x/text, whose license
# STUB_LICENSES picks: ok (BSD-3-Clause, the default), gpl (GPL-3.0) or
# unknown. noown leaves out the module's own row, as a go-licenses that took
# it for the standard library does, garbled prints a row it can't have
# written, and crash exits 1. It records GOROOT, GOOS and GOARCH beside its
# arguments.
{
    echo '#!/usr/bin/env bash'
    record
    cat << 'EOF'
printf 'GOROOT=%s\nGOOS=%s\nGOARCH=%s\n' "${GOROOT:-}" "${GOOS:-}" "${GOARCH:-}" >> "${CALLS}/${0##*/}.$((n + 1))"
own=$(awk '$1 == "module" { print $2; exit }' go.mod)
license=BSD-3-Clause
case "${STUB_LICENSES:-ok}" in
    crash)
        echo "F1025 12:00:00.000000 1 main.go:77] cannot load packages" >&2
        exit 1
        ;;
    garbled)
        echo "not a row"
        exit 0
        ;;
    gpl) license=GPL-3.0 ;;
    unknown) license=Unknown ;;
esac
if [[ "${STUB_LICENSES:-ok}" != noown ]]; then
    printf '%s\tUnknown\tMIT\t%s/LICENSE\tUnknown\n' "${own}" "${PWD}"
    printf '%s/cmd/server\tUnknown\tMIT\t%s/LICENSE\tUnknown\n' "${own}" "${PWD}"
fi
printf 'golang.org/x/text\tv0.3.5\t%s\t%s/golang.org/x/text@v0.3.5/LICENSE\thttps://cs.opensource.google/go/x/text/+/v0.3.5:LICENSE\n' \
    "${license}" "${GOMODCACHE:-/nowhere}"
EOF
} > "${STUBS}/go-licenses"
chmod +x "${STUBS}"/*

# run COMMAND [NAME=VALUE ...] [-- VAR=value ...]: runs the command's script
# through tests/run_command.sh with the stand-ins first on the PATH, and
# output_dir set to OUT, which it empties first. Sets RC and OUTPUT.
run() {
    local command=$1 env=()
    shift
    local params=()
    if grep -q '^  output_dir:' "${ROOT}/src/commands/${command}.yml"; then
        params=("output_dir=${OUT}")
    fi
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == -- ]]; then
            shift
            env=("$@")
            break
        fi
        params+=("$1")
        shift
    done
    rm -rf "${CALLS:?}"/* "${OUT}"
    : > "${WORK}/bash_env"
    RC=0
    OUTPUT=$(env "PATH=${STUBS}:${PATH}" "BASH_ENV=${WORK}/bash_env" ${env[@]+"${env[@]}"} \
        bash "${ROOT}/tests/run_command.sh" "${command}" ${params[@]+"${params[@]}"} 2>&1) || RC=$?
    # Every run record is kept, to check against the schema at the end.
    for record in "${OUT}"/*.run-record.json; do
        [[ -f "${record}" ]] || continue
        RECORDS=$((RECORDS + 1))
        cp "${record}" "${WORK}/records/${RECORDS}-${command}.json"
    done
}
RECORDS=0
mkdir -p "${WORK}/records"
exported() { grep -qxF -- "$1" "${WORK}/bash_env"; }

# Copies of the fixtures, so nothing a test does reaches the checkout.
FIXTURES_BEFORE=$(git -C "${ROOT}" status --porcelain --untracked-files=all -- tests/fixtures 2> /dev/null)
cp -R "${FIXTURES}/clean" "${FIXTURES}/vulnerable" "${FIXTURES}/weakcrypto" "${WORK}/"
CLEAN="${WORK}/clean"
VULNERABLE="${WORK}/vulnerable"
WEAK="${WORK}/weakcrypto"

# ------------------------------------------------------------------- gosec
begin "gosec: findings fail the step"
run gosec "working_dir=${WEAK}"
check "it fails" failed
check "it names the finding" said "etag.go:15:27: G401 (medium severity, high confidence)"
check "and the suppressed one" said "etag.go:20: G401: no justification"
check "gosec ran on the package directory go list found" called_with gosec -fmt=sarif -stdout -verbose=json -track-suppressions -- ./
check "the JSON report counts one finding" json_is "${OUT}/gosec.json" '[.[] | select(.finding)] | length' 1
check "with the path relative to working_dir" json_is "${OUT}/gosec.json" '.[0].file' etag.go
check "the SARIF has both results" json_is "${OUT}/gosec.sarif" '.runs[0].results | length' 2
check "and the rule they belong to" json_is "${OUT}/gosec.sarif" '[.runs[0].tool.driver.rules[].id] | join(",")' G401
check "JUnit has the finding" file_has "${OUT}/junit/gosec.xml" 'failures="1"'
run gosec "working_dir=${WEAK}" report_only=true
check "report_only passes" succeeded
check "and says so" said "report_only is true, so this step passes"
run gosec "working_dir=${WEAK}" require_suppression_reasons=true report_only=true
check "require_suppression_reasons counts a suppression without a justification" json_is "${OUT}/gosec.json" '[.[] | select(.finding)] | length' 2
run gosec "working_dir=${WEAK}" require_suppression_reasons=true report_only=true -- "STUB_JUSTIFICATION=only names a cache entry"
check "but not one with a justification" json_is "${OUT}/gosec.json" '[.[] | select(.finding)] | length' 1
run gosec "working_dir=${WEAK}" require_suppression_reasons=true report_only=true -- "STUB_JUSTIFICATION=   "
check "and a justification of spaces is none" json_is "${OUT}/gosec.json" '[.[] | select(.finding)] | length' 2

begin "gosec: a clean module passes, and options reach gosec"
run gosec "working_dir=${CLEAN}" -- STUB_GOSEC=clean
check "it passes" succeeded
check "and says so" said "gosec found nothing in example.com/clean"
run gosec "working_dir=${CLEAN}" tests=true severity=medium confidence=high "include=G401 G501" exclude=G104 tags=a,b \
    run_record=true -- STUB_GOSEC=clean
check "the options reach gosec" called_with gosec -tests -severity=medium -confidence=high -include=G401,G501 -exclude=G104 -tags=a,b
check "the run record names the options" json_is "${OUT}/gosec.run-record.json" '.arguments | index("-tests") != null' true
check "and the outcome" json_is "${OUT}/gosec.run-record.json" .outcome passed
run gosec "working_dir=${CLEAN}" include=401 -- STUB_GOSEC=clean
check "a rule that isn't a gosec ID fails" said "include must list gosec rule IDs"
run gosec "working_dir=${CLEAN}" "extra_args=-fmt=text" -- STUB_GOSEC=clean
check "extra_args can't change the report format" said "extra_args can't set -fmt"
run gosec "working_dir=${CLEAN}" config=nothere.json -- STUB_GOSEC=clean
check "a config that isn't there fails" said "config names nothere.json, which is not a file"

begin "gosec: packages go list can't find fail, before gosec runs"
cp -R "${CLEAN}" "${WORK}/platform"
mkdir -p "${WORK}/platform/win"
printf '//go:build windows\n\npackage win\n' > "${WORK}/platform/win/win.go"
run gosec "working_dir=${WORK}/platform" packages=./missing report_only=true -- STUB_GOSEC=clean
check "a directory that isn't there fails" said "go list could not find some of the packages to check in example.com/clean"
check "naming it" said "./missing: stat"
check "and gosec never ran" not_called_with gosec -fmt=sarif
run gosec "working_dir=${WORK}/platform" "packages=./... ./missing" -- STUB_GOSEC=clean
check "even beside packages it finds" failed
run gosec "working_dir=${WORK}/platform" "packages=./cmd/..." -- STUB_GOSEC=clean
check "a pattern for a directory that isn't there fails" said "./cmd/...: pattern ./cmd/...: lstat ./cmd/: no such file or directory"
mkdir -p "${WORK}/platform/docs"
echo notes > "${WORK}/platform/docs/README.md"
run gosec "working_dir=${WORK}/platform" "packages=./docs/..." -- STUB_GOSEC=clean
check "a pattern that matches no packages fails" failed
check "saying so" said '"./docs/..." matched no packages'
run gosec "working_dir=${WORK}/platform" packages=./win -- STUB_GOSEC=clean
check "a package that only builds on another platform has nothing to check" succeeded
check "saying so" said "No packages to check in example.com/clean (./win)"

begin "gosec: a gosec that can't complete fails whatever report_only says"
run gosec "working_dir=${WEAK}" report_only=true -- STUB_GOSEC=golangerrors
check "type-check errors fail" failed
check "naming the error" said "gosec could not type-check example.com/weakcrypto"
run gosec "working_dir=${WEAK}" report_only=true run_record=true -- STUB_GOSEC=crash
check "a crash fails" failed
check "saying so" said "gosec could not complete in example.com/weakcrypto (exit code 2)"
check "the run record says error" json_is "${OUT}/gosec.run-record.json" .outcome error

# --------------------------------------------------------------- vulncheck
begin "vulncheck: a called vulnerability fails the step"
run vulncheck "working_dir=${VULNERABLE}"
check "it fails" failed
check "it names the vulnerability" said "GO-2021-0113 (called): Out-of-bounds read in golang.org/x/text/language"
check "and where it is called" said "called from example.com/vulnerable.main (main.go:18)"
check "govulncheck ran with the options" called_with govulncheck -format json -scan=symbol -db=https://vuln.go.dev ./...
check "the report counts one" json_is "${OUT}/govulncheck.json" '[.scans[].vulnerabilities[] | select(.counts)] | length' 1
check "SARIF is written" json_is "${OUT}/govulncheck.sarif" '.runs[0].results | map(.ruleId) | index("GO-2021-0113") != null' true
check "with govulncheck's rules" json_is "${OUT}/govulncheck.sarif" '[.runs[0].tool.driver.rules[].id] | index("GO-2021-0113") != null' true
check "OpenVEX names the module as the product" json_is "${OUT}/govulncheck.openvex.json" \
    '[.statements[] | select(.vulnerability.name == "GO-2021-0113") | .products[0]."@id"] | first' pkg:golang/example.com/vulnerable
check "govulncheck's own output is kept" json_is "${OUT}/govulncheck.raw.json" '.[0].messages | length > 0' true
check "it says which standard library it checked" said "The standard library was checked as go1.27.3, the go on the PATH"
check "and why that matters" said "Set go_version to that release"
run vulncheck "working_dir=${VULNERABLE}" report_only=true
check "report_only passes" succeeded
run vulncheck "working_dir=${VULNERABLE}" scan=package
check "a package scan counts imported vulnerabilities too" json_is "${OUT}/govulncheck.json" '[.scans[].vulnerabilities[] | select(.counts)] | length > 1' true
check "and runs with -scan=package" called_with govulncheck -scan=package

begin "vulncheck: ignore accepts vulnerabilities with a reason"
run vulncheck "working_dir=${VULNERABLE}" "ignore=GO-2021-0113 we never parse untrusted tags"
check "it passes" succeeded
check "saying why" said "GO-2021-0113 (called, accepted: we never parse untrusted tags)"
check "the SARIF result is suppressed" json_is "${OUT}/govulncheck.sarif" \
    '[.runs[0].results[] | select(.ruleId == "GO-2021-0113") | .suppressions[0].justification] | first' "we never parse untrusted tags"
run vulncheck "working_dir=${VULNERABLE}" "ignore=CVE-2021-38561 tags come from our own config"
check "an alias works too" succeeded
run vulncheck "working_dir=${VULNERABLE}" "ignore=GO-2021-0113"
check "an entry without a reason fails" said "ignore accepts GO-2021-0113 without a reason"
run vulncheck "working_dir=${VULNERABLE}" "ignore=nothing to see"
check "an entry that isn't an ID fails" said "ignore must start each line with a GO-, CVE- or GHSA- ID"

begin "vulncheck: what govulncheck can't vouch for fails whatever report_only says"
run vulncheck "working_dir=${CLEAN}" report_only=true -- STUB_VULN=stale
check "a stale database fails" failed
check "saying how old it is" said "more than max_db_age_days (14)"
run vulncheck "working_dir=${CLEAN}" max_db_age_days=0 -- STUB_VULN=stale
check "max_db_age_days 0 accepts it" succeeded
run vulncheck "working_dir=${CLEAN}" report_only=true -- STUB_VULN=nostdlib
check "no standard library version fails" said "could not tell which Go release's standard library to check"
run vulncheck "working_dir=${CLEAN}" report_only=true run_record=true -- STUB_VULN=error
check "govulncheck failing fails the step" failed
check "showing its output" said "there are errors in the packages"
check "the run record says error" json_is "${OUT}/govulncheck.run-record.json" .outcome error
run vulncheck "working_dir=${CLEAN}" -- GOFLAGS=-mod=mod
check "GOFLAGS=-mod=mod is refused" said "GOFLAGS has -mod=mod"
printf 'GOFLAGS=-mod=mod\n' > "${WORK}/goenv-modmod"
run vulncheck "working_dir=${CLEAN}" -- "GOENV=${WORK}/goenv-modmod"
check "and so is -mod=mod that go env -w saved" said "GOFLAGS has -mod=mod"
check "before govulncheck runs" call_count govulncheck 0
run vulncheck "working_dir=${CLEAN}" go_version=1.27
check "go_version sets GOVERSION" succeeded
check "and the check says so" said "The standard library was checked as go1.27.3"
run vulncheck "working_dir=${CLEAN}" go_version=latest
check "a go_version that isn't a release fails" said "go_version must be a Go release"
run vulncheck "working_dir=${CLEAN}" "extra_args=-db https://elsewhere"
check "extra_args can't set -db" said "extra_args can't set -db"
run vulncheck "working_dir=${CLEAN}" formats=html
check "an unknown format fails" said "formats can name sarif and openvex"
run vulncheck "working_dir=${CLEAN}" formats= test=true tags=integration
check "test and tags reach govulncheck" called_with govulncheck -test -tags=integration
check "formats empty writes no SARIF" absent "${OUT}/govulncheck.sarif"

begin "vulncheck: the database"
mkdir -p "${WORK}/emptydb"
run vulncheck "working_dir=${CLEAN}" "db=${WORK}/emptydb"
check "a local copy without its index fails" said "is not a copy of the Go vulnerability database"
run vulncheck "working_dir=${CLEAN}" "db=http://mirror.example.com"
check "plain HTTP fails" said "db must be an https:// URL, a file:/// URL or an absolute path"
run vulncheck "working_dir=${CLEAN}" "db=https://user:secret@mirror.example.com"
check "credentials in the URL fail" said "db must not hold credentials"
check "without showing them" not_said "secret"
run vulncheck "working_dir=${CLEAN}" -- GO_SECURITY_VULN_DB=https://mirror.example.com/vulndb
check "GO_SECURITY_VULN_DB is the default" called_with govulncheck -db=https://mirror.example.com/vulndb

# ----------------------------------------------------------- vulncheck_bin
begin "vulncheck_bin: binaries"
mkdir -p "${WORK}/bin"
printf 'GOBINARY vulnerable\n' > "${WORK}/bin/server"
printf 'not a binary\n' > "${WORK}/bin/README"
run vulncheck_bin "working_dir=${WORK}" "binaries=bin/server" run_record=true
check "a vulnerability linked in fails" failed
check "naming it" said "linked into the binary: golang.org/x/text/language.Parse"
check "and the Go that built it" said "Built with go1.27.3, whose standard library was checked"
check "govulncheck ran in binary mode" called_with govulncheck -mode binary -format json bin/server
check "the run record has the binary's SHA-256" json_is "${OUT}/govulncheck-bin.run-record.json" '.results[0].sha256' \
    "$(sha256sum "${WORK}/bin/server" | cut -c1-64)"
check "and its Go release" json_is "${OUT}/govulncheck-bin.run-record.json" '.results[0].go_version' go1.27.3
run vulncheck_bin "working_dir=${WORK}" "binaries=bin/*" report_only=true
check "a file that isn't a Go binary fails whatever report_only says" failed
check "saying so" said "govulncheck could not scan bin/README"
run vulncheck_bin "working_dir=${WORK}" "binaries=bin/server" report_only=true -- STUB_VULN=nostdlib
check "a binary without build information fails" said "bin/server has no Go build information"
run vulncheck_bin "working_dir=${WORK}" "binaries=dist/*"
check "a pattern that matches nothing fails" said "binaries names dist/*, which matches nothing"
cp "${WORK}/bin/server" "${WORK}/bin/-server"
run vulncheck_bin "working_dir=${WORK}/bin" "binaries=-server" report_only=true
check "a name starting with - is passed as a path" called_with govulncheck ./-server

# ---------------------------------------------------------------- licenses
begin "licenses: dependencies with allowed licenses pass"
run licenses "working_dir=${VULNERABLE}" run_record=true
check "it passes" succeeded
check "go-licenses ran report with the orb's template" called_with go-licenses report -- ./...
check "with the GOROOT of the go that runs in the module" called_with go-licenses "GOROOT=$(cd "${VULNERABLE}" && "${REAL_GO}" env GOROOT)"
check "the module's own package is its own" json_is "${OUT}/licenses.json" '[.[] | select(.name == "example.com/vulnerable") | .status] | first' own
check "the CSV lists the dependency" file_has "${OUT}/licenses.csv" '"golang.org/x/text","v0.3.5","BSD-3-Clause","allowed"'
check "and so are packages below its path" json_is "${OUT}/licenses.json" '[.[] | select(.name == "example.com/vulnerable/cmd/server") | .status] | first' own
run licenses "working_dir=${VULNERABLE}" allowed_licenses=BSD-3-Clause
check "so the module's own license needn't be on the list" succeeded
run licenses "working_dir=${VULNERABLE}" allowed_licenses=MIT
check "a license not on the list fails" failed
check "naming it" said "golang.org/x/text@v0.3.5: BSD-3-Clause (not in allowed_licenses)"
run licenses "working_dir=${VULNERABLE}" -- STUB_LICENSES=gpl
check "GPL isn't allowed by default" said "GPL-3.0 (not in allowed_licenses)"
run licenses "working_dir=${VULNERABLE}" -- STUB_LICENSES=unknown
check "an unknown license fails" said "no license found, or one go-licenses can't identify"
run licenses "working_dir=${VULNERABLE}" report_only=true -- STUB_LICENSES=gpl
check "report_only passes" succeeded
run licenses "working_dir=${VULNERABLE}" check_main_module=true allowed_licenses=BSD-3-Clause
check "check_main_module checks the module's own license too" said "example.com/vulnerable: MIT (not in allowed_licenses)"
run licenses "working_dir=${VULNERABLE}" "platforms=linux/amd64 windows/arm64" include_tests=true ignore=example.com/internal
check "platforms run go-licenses once each" call_count go-licenses 2
check "with GOOS and GOARCH" called_with go-licenses GOOS=windows GOARCH=arm64
check "include_tests and ignore reach go-licenses" called_with go-licenses --include_tests --ignore=example.com/internal
run licenses "working_dir=${VULNERABLE}" platforms=plan10/x
check "a platform go doesn't know fails" said "platforms names 'plan10/x'"
run licenses "working_dir=${VULNERABLE}" allowed_licenses=
check "an empty allowlist fails" said "allowed_licenses names no license"

begin "licenses: a go-licenses that checked nothing fails whatever report_only says"
run licenses "working_dir=${VULNERABLE}" report_only=true -- STUB_LICENSES=noown
check "a report without the module's own packages fails" said "go-licenses reported none of example.com/vulnerable's own packages"
run licenses "working_dir=${VULNERABLE}" report_only=true -- STUB_LICENSES=crash
check "a crash fails" said "go-licenses could not complete in example.com/vulnerable"
run licenses "working_dir=${VULNERABLE}" report_only=true -- STUB_LICENSES=garbled
check "a report it can't read fails" said "go-licenses' report for example.com/vulnerable could not be read"

# ----------------------------------------------------------- fetch_vuln_db
# mkdb DIR [ID...]: writes a copy of the database to DIR, modified now,
# listing the IDs (GO-2021-0113 when none are given).
mkdb() {
    local dir=$1 id ids=(GO-2021-0113)
    shift
    # Bash 4.0 reads an empty "$@" as unset.
    if [[ $# -gt 0 ]]; then
        ids=("$@")
    fi
    mkdir -p "${dir}/index" "${dir}/ID"
    jq -n --arg m "${DB_MODIFIED:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}" '{modified: $m}' > "${dir}/index/db.json"
    echo '[{"path":"golang.org/x/text","vulns":[{"id":"GO-2021-0113","modified":"2026-01-01T00:00:00Z","fixed":"0.3.7"}]}]' \
        > "${dir}/index/modules.json"
    printf '%s\n' "${ids[@]}" | jq -R '{id: ., modified: "2026-01-01T00:00:00Z", aliases: []}' | jq -s . > "${dir}/index/vulns.json"
    for id in "${ids[@]}"; do
        jq -n --arg id "${id}" '{schema_version: "1.3.1", id: $id, modified: "2026-01-01T00:00:00Z", affected: []}' > "${dir}/ID/${id}.json"
    done
}
# mkzip DIR ZIP [LINK=TARGET]: zips DIR's files, as vuln.go.dev's zip holds
# them, with go, since a CI image need not have zip. LINK=TARGET adds a
# symbolic link entry.
mkdir -p "${WORK}/mkzip"
cat > "${WORK}/mkzip/main.go" << 'EOF'
package main

import (
	"archive/zip"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

func main() {
	out, err := os.Create(os.Args[2])
	if err != nil {
		panic(err)
	}
	w := zip.NewWriter(out)
	err = filepath.WalkDir(os.Args[1], func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		name, _ := filepath.Rel(os.Args[1], path)
		f, err := w.Create(filepath.ToSlash(name))
		if err != nil {
			return err
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		_, err = f.Write(data)
		return err
	})
	if err != nil {
		panic(err)
	}
	for _, link := range os.Args[3:] {
		name, target, _ := strings.Cut(link, "=")
		h := &zip.FileHeader{Name: name, Method: zip.Store}
		h.SetMode(fs.ModeSymlink | 0o777)
		f, err := w.CreateHeader(h)
		if err != nil {
			panic(err)
		}
		f.Write([]byte(target))
	}
	if err := w.Close(); err != nil {
		panic(err)
	}
	out.Close()
}
EOF
printf 'module mkzip\n\ngo 1.24\n' > "${WORK}/mkzip/go.mod"
(cd "${WORK}/mkzip" && "${REAL_GO}" build -o "${WORK}/mkzip/mkzip" .) || echo "FAIL: could not build the zip writer"
mkzip() { "${WORK}/mkzip/mkzip" "$@"; }
mkdb "${WORK}/db-src"
mkzip "${WORK}/db-src" "${WORK}/vulndb.zip"
DB="${WORK}/home/.cache/go-vulndb"

begin "fetch_vuln_db: a local zip"
if command -v unzip > /dev/null 2>&1 || command -v python3 > /dev/null 2>&1; then
    run fetch_vuln_db "source=${WORK}/vulndb.zip"
    check "it succeeds" succeeded
    check "into the default path" exists "${DB}/index/db.json"
    check "with its entries" exists "${DB}/ID/GO-2021-0113.json"
    check "exporting its file:// URL" exported "export GO_SECURITY_VULN_DB=file://${DB}"
    check "the marker names the zip's SHA-256" json_is "${DB}/.go-security-orb.json" .zip_sha256 "$(sha256sum "${WORK}/vulndb.zip" | cut -c1-64)"
    check "and the number of entries" json_is "${DB}/.go-security-orb.json" .entries 1
    run fetch_vuln_db "source=${WORK}/vulndb.zip" "sha256=$(sha256sum "${WORK}/vulndb.zip" | cut -c1-64)" db_env_var=MY_DB
    check "a matching sha256 pin passes, replacing the earlier copy" succeeded
    check "db_env_var names the variable" exported "export MY_DB=file://${DB}"
    run fetch_vuln_db "source=${WORK}/vulndb.zip" "sha256=$(printf '0%.0s' {1..64})"
    check "a sha256 that doesn't match fails" said "not the 0000000000000000000000000000000000000000000000000000000000000000 that sha256 pins"
    check "and leaves the earlier copy" exists "${DB}/index/db.json"
    mkdb "${WORK}/db-extra"
    echo 'echo hi' > "${WORK}/db-extra/run.sh"
    mkzip "${WORK}/db-extra" "${WORK}/extra.zip"
    run fetch_vuln_db "source=${WORK}/extra.zip" "path=${WORK}/db-x"
    check "a zip with other files fails" said "holds what a copy of the Go vulnerability database doesn't"
    check "naming one" said "run.sh"
    check "and unpacks nothing" absent "${WORK}/db-x"
    mkzip "${WORK}/db-src" "${WORK}/link.zip" "ID/GO-2099-0001.json=/etc/passwd"
    run fetch_vuln_db "source=${WORK}/link.zip" "path=${WORK}/db-x"
    check "a zip with a symbolic link fails" failed
    check "and unpacks nothing" absent "${WORK}/db-x"
    mkdb "${WORK}/db-partial" GO-2021-0113 GO-2022-1059
    rm "${WORK}/db-partial/ID/GO-2022-1059.json"
    mkzip "${WORK}/db-partial" "${WORK}/partial.zip"
    run fetch_vuln_db "source=${WORK}/partial.zip" "path=${WORK}/db-x"
    check "a zip that lacks entries its index lists fails" said "lacks entries its index lists, such as: GO-2022-1059"
    echo "not a zip" > "${WORK}/junk.zip"
    run fetch_vuln_db "source=${WORK}/junk.zip" "path=${WORK}/db-x"
    check "a file that isn't a zip fails" said "is not a zip file"
else
    echo "  skip: neither unzip nor python3 is installed, which unpacking a zip needs"
fi

begin "fetch_vuln_db: a directory"
run fetch_vuln_db "source=${WORK}/db-src" "path=${WORK}/db-dir"
check "it succeeds" succeeded
check "copying the entries" exists "${WORK}/db-dir/ID/GO-2021-0113.json"
check "the marker has no zip SHA-256" json_is "${WORK}/db-dir/.go-security-orb.json" .zip_sha256 null
run fetch_vuln_db "source=${WORK}/db-dir" "path=${WORK}/db-dir"
check "a copy can be checked again in place, as one restored from a cache" succeeded
run fetch_vuln_db "source=${WORK}/db-dir/ID" "path=${WORK}/db-dir"
check "a source inside path fails" said "is inside path"
cp -R "${WORK}/db-src" "${WORK}/db-link"
ln -s /etc/passwd "${WORK}/db-link/ID/GO-2099-0002.json"
run fetch_vuln_db "source=${WORK}/db-link" "path=${WORK}/db-y"
check "a directory with a symbolic link fails" said "ID/GO-2099-0002.json (a symbolic link)"
DB_MODIFIED=2020-01-01T00:00:00Z mkdb "${WORK}/db-old"
run fetch_vuln_db "source=${WORK}/db-old" "path=${WORK}/db-y"
check "a stale copy fails" said "more than max_db_age_days (14)"
run fetch_vuln_db "source=${WORK}/db-old" "path=${WORK}/db-y" max_db_age_days=0
check "unless max_db_age_days is 0" succeeded
mkdir -p "${WORK}/notadb"
echo keep > "${WORK}/notadb/notes.txt"
run fetch_vuln_db "source=${WORK}/db-src" "path=${WORK}/notadb"
check "path holding something else fails" said "holds something other than a copy of the Go vulnerability database"
check "and keeps it" exists "${WORK}/notadb/notes.txt"
run fetch_vuln_db "source=${WORK}/db-src" path=relative
check "a relative path fails" said "path must be an absolute directory"
run fetch_vuln_db "source=http://vuln.go.dev/vulndb.zip"
check "plain HTTP fails" said "source must be an https:// URL, a zip file or a directory"
run fetch_vuln_db "source=https://user:secret@mirror.example.com/vulndb.zip"
check "credentials in the URL fail" said "source must not hold credentials"
check "without showing them" not_said "secret"
run fetch_vuln_db "source=${WORK}/nothere"
check "a source that isn't there fails" said "which doesn't exist"

begin "fetch_vuln_db: vulncheck reads the copy it exported"
run fetch_vuln_db "source=${WORK}/db-src" "path=${WORK}/db-dir"
DB_URL=$(sed -n 's/^export GO_SECURITY_VULN_DB=//p' "${WORK}/bash_env")
run vulncheck "working_dir=${CLEAN}" -- "GO_SECURITY_VULN_DB=${DB_URL}"
check "it scans with it" called_with govulncheck "-db=file://${WORK}/db-dir"

# -------------------------------------------------------------- mod_verify
# A module whose dependency comes from a file:// module proxy, with a go.sum
# made by go itself, and one whose dependency is a local directory.
PROXY="${WORK}/proxy"
mkdir -p "${PROXY}/example.com/lib/@v" "${WORK}/libsrc/example.com/lib@v1.0.0"
printf 'module example.com/lib\n\ngo 1.24\n' > "${WORK}/libsrc/example.com/lib@v1.0.0/go.mod"
printf 'package lib\n\n// Answer is the answer.\nfunc Answer() int { return 42 }\n' > "${WORK}/libsrc/example.com/lib@v1.0.0/lib.go"
mkzip "${WORK}/libsrc" "${PROXY}/example.com/lib/@v/v1.0.0.zip"
cp "${WORK}/libsrc/example.com/lib@v1.0.0/go.mod" "${PROXY}/example.com/lib/@v/v1.0.0.mod"
echo '{"Version":"v1.0.0","Time":"2026-01-01T00:00:00Z"}' > "${PROXY}/example.com/lib/@v/v1.0.0.info"
echo v1.0.0 > "${PROXY}/example.com/lib/@v/list"
APP="${WORK}/app"
mkdir -p "${APP}"
printf 'module example.com/app\n\ngo 1.24\n\nrequire example.com/lib v1.0.0\n' > "${APP}/go.mod"
printf 'package main\n\nimport (\n\t"fmt"\n\n\t"example.com/lib"\n)\n\nfunc main() { fmt.Println(lib.Answer()) }\n' > "${APP}/main.go"
(cd "${APP}" && GOPROXY="file://${PROXY}" GOSUMDB=off GOFLAGS=-mod=mod "${REAL_GO}" mod download example.com/lib \
    && GOPROXY="file://${PROXY}" GOSUMDB=off GOFLAGS=-mod=mod "${REAL_GO}" mod tidy) > /dev/null 2>&1 \
    || echo "FAIL: could not build the mod_verify fixture from the file:// proxy"
LOCAL="${WORK}/local"
mkdir -p "${LOCAL}/app" "${LOCAL}/dep"
printf 'module example.com/dep\n\ngo 1.24\n' > "${LOCAL}/dep/go.mod"
printf 'package dep\n\n// Name is a name.\nconst Name = "dep"\n' > "${LOCAL}/dep/dep.go"
printf 'module example.com/local\n\ngo 1.24\n\nrequire example.com/dep v1.0.0\n\nreplace example.com/dep => ../dep\n' > "${LOCAL}/app/go.mod"
printf 'package main\n\nimport (\n\t"fmt"\n\n\t"example.com/dep"\n)\n\nfunc main() { fmt.Println(dep.Name) }\n' > "${LOCAL}/app/main.go"
MV_ENV=("GOPROXY=file://${PROXY}")
LIBDIR="${GOMODCACHE}/example.com/lib@v1.0.0"

begin "mod_verify: a module whose dependencies match go.mod and go.sum passes"
run mod_verify "working_dir=${APP}" run_record=true -- "${MV_ENV[@]}"
check "it passes" succeeded
for name in toolchain download verify readonly; do
    check "${name} passed" json_is "${OUT}/mod-verify.json" ".modules[0].checks[] | select(.check == \"${name}\") | .status" passed
done
check "vendor was skipped" json_is "${OUT}/mod-verify.json" '.modules[0].checks[] | select(.check == "vendor") | .status' skipped
check "GOTOOLCHAIN=local is exported" exported "export GOTOOLCHAIN=local"
check "JUnit has a case per check" json_is "${OUT}/mod-verify.json" '.modules[0].checks | length' 5
check "the run record has go.sum's SHA-256" json_is "${OUT}/mod-verify.run-record.json" \
    '[.inputs[] | select(.role == "go.sum") | .sha256] | first' "$(sha256sum "${APP}/go.sum" | cut -c1-64)"
run mod_verify "working_dir=${LOCAL}/app" pin_toolchain=false -- "${MV_ENV[@]}"
check "a local replacement passes" succeeded
check "pin_toolchain false exports nothing" not_file_has "${WORK}/bash_env" GOTOOLCHAIN
check "and skips the toolchain check" json_is "${OUT}/mod-verify.json" '.modules[0].checks[0].status' skipped

begin "mod_verify: changed dependencies fail"
chmod -R u+w "${LIBDIR}"
cp "${LIBDIR}/lib.go" "${WORK}/lib.go.orig"
echo "// changed" >> "${LIBDIR}/lib.go"
run mod_verify "working_dir=${APP}" -- "${MV_ENV[@]}"
check "a module cache whose files changed fails" failed
check "go mod verify says which" said "example.com/lib v1.0.0: dir has been modified"
cp "${WORK}/lib.go.orig" "${LIBDIR}/lib.go"
run mod_verify "working_dir=${APP}" -- "${MV_ENV[@]}"
check "once restored, it passes" succeeded
cp "${APP}/go.sum" "${WORK}/go.sum.orig"
sed -i '1s/h1:[^ ]*/h1:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=/' "${APP}/go.sum"
run mod_verify "working_dir=${APP}" -- "${MV_ENV[@]}"
check "a go.sum that doesn't match fails" said "download: FAILED"
check "with go's SECURITY ERROR" said "SECURITY ERROR"
check "and the checks that need it are skipped" json_is "${OUT}/mod-verify.json" '.modules[0].checks[] | select(.check == "readonly") | .status' skipped
: > "${APP}/go.sum"
run mod_verify "working_dir=${APP}" -- "${MV_ENV[@]}"
check "a go.sum without the entries fails" said "readonly: FAILED"
check "skipping download, which would look them up" said "download: skipped, go.sum lacks entries"
check "naming the import" said "missing go.sum entry"
run mod_verify "working_dir=${APP}" report_only=true -- "${MV_ENV[@]}"
check "report_only passes" succeeded
cp "${WORK}/go.sum.orig" "${APP}/go.sum"
cp -R "${LOCAL}" "${WORK}/norequire"
sed -i '/^require/d' "${WORK}/norequire/app/go.mod"
run mod_verify "working_dir=${WORK}/norequire/app" -- "${MV_ENV[@]}"
check "an import go.mod lacks fails" said "go.mod or go.sum lacks what the packages import"

begin "mod_verify: the vendor directory"
cp -R "${LOCAL}" "${WORK}/vendored"
(cd "${WORK}/vendored/app" && "${REAL_GO}" mod vendor) || echo "FAIL: could not vendor the fixture"
run mod_verify "working_dir=${WORK}/vendored/app" -- "${MV_ENV[@]}"
check "a vendor directory go mod vendor would write passes" succeeded
check "and is checked" json_is "${OUT}/mod-verify.json" '.modules[0].checks[] | select(.check == "vendor") | .status' passed
echo "// changed" >> "${WORK}/vendored/app/vendor/example.com/dep/dep.go"
run mod_verify "working_dir=${WORK}/vendored/app" -- "${MV_ENV[@]}"
check "a changed vendored file fails" said "vendor: FAILED"
check "naming the file" said "vendor/example.com/dep/dep.go and (what go mod vendor writes)/example.com/dep/dep.go differ"
run mod_verify "working_dir=${WORK}/vendored/app" check_vendor=false -- "${MV_ENV[@]}"
check "check_vendor false skips it" succeeded

begin "mod_verify: the toolchain"
cp -R "${LOCAL}" "${WORK}/newer"
sed -i 's/^go 1.24$/go 1.99/' "${WORK}/newer/app/go.mod"
run mod_verify "working_dir=${WORK}/newer/app" -- "${MV_ENV[@]}"
check "a go.mod that needs a newer Go fails" said "toolchain: FAILED: go.mod requires a newer Go"
check "and go's own message" said "go.mod requires go >= 1.99"

begin "mod_verify: settings that weaken checksum verification"
run mod_verify "working_dir=${LOCAL}/app" -- "${MV_ENV[@]}" GOSUMDB=off
check "GOSUMDB=off fails" said "GOSUMDB: is off"
run mod_verify "working_dir=${LOCAL}/app" -- "${MV_ENV[@]}" GOPRIVATE=github.com
check "GOPRIVATE matching public modules fails" said "GOPRIVATE: (github.com) matches public modules such as github.com/owner/repo"
run mod_verify "working_dir=${LOCAL}/app" -- "${MV_ENV[@]}" "GOPRIVATE=github.com/*"
check "github.com/* matches them too" said "GOPRIVATE: (github.com/*) matches public modules"
run mod_verify "working_dir=${LOCAL}/app" -- "${MV_ENV[@]}" "GONOSUMDB=*"
check "GONOSUMDB=* fails" said "GONOSUMDB: (*) matches public modules"
run mod_verify "working_dir=${LOCAL}/app" -- "${MV_ENV[@]}" "GOPRIVATE=github.com/my-org/*,*.corp.example.com"
check "an organization's own patterns pass" succeeded
run mod_verify "working_dir=${LOCAL}/app" -- "${MV_ENV[@]}" "GONOSUMDB=github.com/my-org" "GOPRIVATE=*.com"
check "GOPRIVATE matching public modules only warns when GONOSUMDB is narrower" succeeded
check "warning that they skip the proxy" said "WARN: GOPRIVATE: (*.com) matches public modules such as github.com/owner/repo, which go then fetches straight"
run mod_verify "working_dir=${LOCAL}/app" -- "${MV_ENV[@]}" GOINSECURE=git.example.com
check "GOINSECURE fails" said "GOINSECURE: (git.example.com) lets go fetch"
run mod_verify "working_dir=${LOCAL}/app" -- "${MV_ENV[@]}" "GOFLAGS=-mod=mod -modcacherw"
check "GOFLAGS=-mod=mod fails" said "GOFLAGS: has -mod=mod"
check "and -modcacherw warns" said "WARN: GOFLAGS: has -modcacherw"
run mod_verify "working_dir=${LOCAL}/app" pin_toolchain=false -- "${MV_ENV[@]}" GOTOOLCHAIN=auto
check "an unpinned GOTOOLCHAIN warns" said "WARN: GOTOOLCHAIN: is auto"
run mod_verify "working_dir=${LOCAL}/app" -- "GOPROXY=http://proxy.example.com,direct"
check "an HTTP proxy warns" said "WARN: GOPROXY: lists http://proxy.example.com over plain HTTP"
run mod_verify "working_dir=${LOCAL}/app" report_only=true -- "${MV_ENV[@]}" GOSUMDB=off GOINSECURE=x.example.com
check "report_only passes" succeeded
check "the report lists both" json_is "${OUT}/mod-verify.json" '[.settings[] | select(.level == "fail") | .name] | join(",")' GOSUMDB,GOINSECURE

begin "mod_verify: private modules"
run mod_verify "working_dir=${LOCAL}/app" "private_modules=github.com/my-org/*" -- "${MV_ENV[@]}"
check "private_modules is exported as GOPRIVATE" exported 'export GOPRIVATE=github.com/my-org/\*'
run mod_verify "working_dir=${LOCAL}/app" private_modules=github.com -- "${MV_ENV[@]}"
check "private_modules matching public modules fails" said "private_modules (github.com) matches public modules"
check "before exporting it" not_file_has "${WORK}/bash_env" GOPRIVATE
printf 'machine other.example.com login a password b\n' > "${HOME}/.netrc"
run mod_verify "working_dir=${LOCAL}/app" private_host=git.example.com -- "${MV_ENV[@]}" \
    PRIVATE_MODULES_USERNAME=ci PRIVATE_MODULES_TOKEN=s3cret-token
check "private_host writes the credentials" file_has "${HOME}/.netrc" "machine git.example.com login ci password s3cret-token"
check "first, so go uses them" [ "$(sed -n 2p "${HOME}/.netrc")" == "machine git.example.com login ci password s3cret-token" ]
check "keeping the other entries" file_has "${HOME}/.netrc" "machine other.example.com login a password b"
check "with mode 0600" mode_is "${HOME}/.netrc" 600
check "never showing them" not_said "s3cret-token"
run mod_verify "working_dir=${LOCAL}/app" private_host=git.example.com username=MY_USER password=MY_TOKEN -- "${MV_ENV[@]}" \
    MY_USER=ci MY_TOKEN=n3w-token
check "a second run replaces its entry" [ "$(grep -c 'machine git.example.com' "${HOME}/.netrc")" -eq 1 ]
check "with the new token" file_has "${HOME}/.netrc" "password n3w-token"
run mod_verify "working_dir=${LOCAL}/app" private_host=git.example.com -- "${MV_ENV[@]}"
check "private_host without credentials fails" said "but PRIVATE_MODULES_USERNAME or PRIVATE_MODULES_TOKEN is empty or unset"
run mod_verify "working_dir=${LOCAL}/app" private_host=git.example.com -- "${MV_ENV[@]}" \
    PRIVATE_MODULES_USERNAME=ci "PRIVATE_MODULES_TOKEN=has space"
check "a token .netrc can't hold fails" said "can't hold spaces or #"
run mod_verify "working_dir=${LOCAL}/app" "private_host=bad host" -- "${MV_ENV[@]}"
check "a private_host that isn't a host fails" said "private_host must be a host name"

# ---------------------------------------------------------------- fips_bin
# buildinfo FILE GO [BUILD_LINE...] [-- DEP...]: a stand-in binary FILE, and
# what go version -m prints for it.
buildinfo() {
    local file=$1 go=$2 deps=false
    shift 2
    printf 'not really a binary\n' > "${file}"
    {
        printf '%s\n\tpath\texample.com/server\n\tmod\texample.com/server\t(devel)\t\n' "${go}"
        for line in "$@"; do
            if [[ "${line}" == -- ]]; then
                deps=true
            elif [[ "${deps}" == true ]]; then
                printf '\tdep\t%s\tv1.0.0\th1:x=\n' "${line}"
            else
                printf '\tbuild\t%s\n' "${line}"
            fi
        done
    } > "${file}.buildinfo"
}
mkdir -p "${WORK}/fips"
cd "${WORK}/fips" || exit 1
FIPS_ON=("DefaultGODEBUG=fips140=on,tlssha1=1" "CGO_ENABLED=0" "GOFIPS140=v1.0.0-c2097c7c")
buildinfo good go1.27.3 "${FIPS_ON[@]}"
buildinfo go124 go1.24.7 "DefaultGODEBUG=fips140=on" "CGO_ENABLED=1" "GOFIPS140=v1.0.0"
buildinfo nofips go1.27.3 "DefaultGODEBUG=tlssha1=1" "CGO_ENABLED=0"
buildinfo latest go1.27.3 "DefaultGODEBUG=fips140=on" "CGO_ENABLED=0" "GOFIPS140=latest"
buildinfo inprocess go1.27.3 "DefaultGODEBUG=fips140=on" "CGO_ENABLED=0" "GOFIPS140=v1.26.0"
buildinfo godebugoff go1.27.3 "DefaultGODEBUG=fips140=off" "CGO_ENABLED=0" "GOFIPS140=v1.0.0-c2097c7c"
buildinfo only go1.27.3 "DefaultGODEBUG=fips140=only" "CGO_ENABLED=0" "GOFIPS140=v1.0.0-c2097c7c"
buildinfo old go1.22.12 "CGO_ENABLED=0"
buildinfo cgo go1.27.3 "DefaultGODEBUG=fips140=on" "CGO_ENABLED=1" "GOFIPS140=v1.0.0-c2097c7c"
buildinfo boring go1.27.3-X:boringcrypto "CGO_ENABLED=1" "GOEXPERIMENT=boringcrypto"
buildinfo xcrypto go1.27.3 "${FIPS_ON[@]}" -- golang.org/x/crypto github.com/cloudflare/circl golang.org/x/crypto/x509roots/fallback \
    github.com/decred/dcrd/dcrec/secp256k1/v4 golang.org/x/text
buildinfo quoted go1.27.3 "${FIPS_ON[@]}" '-ldflags="-s -w"'
cd "${ROOT}" || exit 1

begin "fips_bin: binaries built for FIPS 140-3 pass"
run fips_bin "working_dir=${WORK}/fips" "binaries=good go124 quoted"
check "they pass" succeeded
check "Go 1.24's v1.0.0 and Go 1.25's v1.0.0-c2097c7c are both v1.0.0" said "links the Go Cryptographic Module v1.0.0"
check "the run record is on by default" json_is "${OUT}/fips-bin.run-record.json" '.results | length' 3
check "with each binary's SHA-256" json_is "${OUT}/fips-bin.run-record.json" '.results[0].sha256' "$(sha256sum "${WORK}/fips/good" | cut -c1-64)"
check "and settings" json_is "${OUT}/fips-bin.run-record.json" '.results[0].gofips140' v1.0.0-c2097c7c
check "the report keeps the build settings" json_is "${OUT}/fips-bin.json" \
    '.binaries[] | select(.target == "quoted") | .build_settings[] | select(.Key == "-ldflags") | .Value' "-s -w"
check "JUnit has a case per check" file_has "${OUT}/junit/fips-bin.xml" 'tests="15"'

begin "fips_bin: builds outside a validated module fail"
for case in "nofips:built without GOFIPS140" "latest:built with GOFIPS140=latest" \
    "inprocess:GOFIPS140=v1.26.0, which gofips140 (v1.0.0, v1.0.0-c2097c7c) does not allow" \
    "godebugoff:defaults to fips140=off, not on (or only)" "old:built with go1.22.12, older than min_go_version (1.24)" \
    "boring:GOEXPERIMENT=boringcrypto: Go+BoringCrypto"; do
    run fips_bin "working_dir=${WORK}/fips" "binaries=${case%%:*}"
    check "${case%%:*} fails" failed
    check "${case%%:*}: ${case#*:}" said "${case#*:}"
done
run fips_bin "working_dir=${WORK}/fips" binaries=inprocess "gofips140=v1.0.0 v1.0.0-c2097c7c v1.26.0"
check "gofips140 can accept the module in process" succeeded
run fips_bin "working_dir=${WORK}/fips" binaries=good fips140=only
check "fips140 only refuses a binary that defaults to on" said "defaults to fips140=on, not only"
run fips_bin "working_dir=${WORK}/fips" binaries=only fips140=only
check "and passes one that defaults to only" succeeded
run fips_bin "working_dir=${WORK}/fips" binaries=cgo
check "cgo passes by default" succeeded
run fips_bin "working_dir=${WORK}/fips" binaries=cgo require_cgo_disabled=true
check "unless require_cgo_disabled is true" said "built with CGO_ENABLED=1: C code linked through cgo"
run fips_bin "working_dir=${WORK}/fips" binaries=good min_go_version=1.27.4
check "min_go_version takes a patch release" said "older than min_go_version (1.27.4)"
run fips_bin "working_dir=${WORK}/fips" binaries=good report_only=true min_go_version=1.28
check "report_only passes" succeeded

begin "fips_bin: cryptography modules outside the standard library"
run fips_bin "working_dir=${WORK}/fips" binaries=xcrypto
check "they fail" said "links cryptography modules outside the standard library: github.com/cloudflare/circl, github.com/decred/dcrd/dcrec/secp256k1/v4, golang.org/x/crypto"
check "but not x/crypto's root certificates or x/text" not_said "x509roots"
run fips_bin "working_dir=${WORK}/fips" binaries=xcrypto "allowed_crypto_modules=golang.org/x/crypto ssh host keys only
github.com/cloudflare/circl reviewed for HPKE in tests
github.com/decred/dcrd/dcrec/secp256k1/v4 wallet signatures, outside the boundary"
check "allowed_crypto_modules accepts them with a reason" succeeded
check "saying which and why" said "accepted golang.org/x/crypto: ssh host keys only"
run fips_bin "working_dir=${WORK}/fips" binaries=xcrypto "allowed_crypto_modules=golang.org/x/crypto"
check "an entry without a reason fails" said "allowed_crypto_modules accepts golang.org/x/crypto without a reason"

begin "fips_bin: what it can't read fails, and settings it refuses"
run fips_bin "working_dir=${WORK}/fips" binaries=good.buildinfo report_only=true
check "a file that isn't a Go binary fails whatever report_only says" said "good.buildinfo is not a Go binary with build information"
run fips_bin "working_dir=${WORK}/fips" binaries=good gofips140=latest
check "gofips140 can't allow latest" said "gofips140 can't allow latest"
run fips_bin "working_dir=${WORK}/fips" binaries=good gofips140=certified
check "or an alias" said "not the certified alias"
run fips_bin "working_dir=${WORK}/fips" binaries=good min_go_version=1
check "a min_go_version that isn't a release fails" said "min_go_version must be a Go release"

begin "fips_bin: a real build"
(cd "${CLEAN}" && GOFIPS140=v1.0.0 CGO_ENABLED=0 "${REAL_GO}" build -o "${WORK}/real-fips" . \
    && CGO_ENABLED=0 "${REAL_GO}" build -o "${WORK}/real-plain" .) || echo "FAIL: could not build the clean fixture"
run fips_bin "working_dir=${WORK}" binaries=real-fips require_cgo_disabled=true
check "built with GOFIPS140 passes" succeeded
run fips_bin "working_dir=${WORK}" binaries=real-plain
check "built without it fails" said "built without GOFIPS140"

# --------------------------------------------------------------- fips_test
begin "fips_test: tests that use algorithms FIPS 140-3 doesn't allow"
run fips_test "working_dir=${WEAK}" run_record=true
check "are reported, and pass by default" succeeded
check "with report_only's warning" said "WARN: 2 tests failed with GOFIPS140=v1.0.0 and GODEBUG=fips140=only"
check "naming the algorithm" said "crypto/md5: use of MD5 is not allowed in FIPS 140-only mode"
check "after running the package again without the test that panicked" said "TestLegacy panicked in example.com/weakcrypto"
check "so every algorithm is found" json_is "${OUT}/fips-test.json" '.refused | length' 2
check "and the passing test still counts" json_is "${OUT}/fips-test.json" '.modules[0].tests.passed' 1
check "JUnit has every test" file_has "${OUT}/junit/fips-test.xml" 'tests="3" failures="2"'
check "go test's output is kept" exists "${OUT}/fips-test.test.json"
check "the run record names GODEBUG" json_is "${OUT}/fips-test.run-record.json" '.results[0].godebug' fips140=only
run fips_test "working_dir=${WEAK}" report_only=false
check "report_only false fails" failed
run fips_test "working_dir=${WEAK}" "extra_args=-run=^TestStrong$" report_only=false
check "extra_args reaches go test" succeeded
run fips_test "working_dir=${WEAK}" fips140=on report_only=false
check "fips140 on lets them run" succeeded
run fips_test "working_dir=${WEAK}" "extra_args=-skip=TestStrong"
check "with -skip in extra_args, the package isn't run again" not_said "panicked in example.com/weakcrypto, so"

begin "fips_test: what it can't test fails whatever report_only says"
cp -R "${CLEAN}" "${WORK}/broken"
echo 'func broken() int { return undefined }' >> "${WORK}/broken/main.go"
run fips_test "working_dir=${WORK}/broken"
check "code that doesn't build fails" failed
check "saying so" said "does not build"
run fips_test "working_dir=${CLEAN}" -- STUB_GOVERSION=go1.23.12
check "a Go before 1.24 fails" said "Go releases before 1.24 have no FIPS 140-3 mode"
run fips_test "working_dir=${CLEAN}" gofips140=latest
check "gofips140 latest is refused" said "off and latest link no validated module"
run fips_test "working_dir=${CLEAN}" gofips140=v9.9.9
check "a version go doesn't have fails" said "invalid GOFIPS140"
run fips_test "working_dir=${CLEAN}" "extra_args=-json"
check "extra_args can't set -json" said "extra_args can't set -json"
run fips_test "working_dir=${CLEAN}" report_only=false
check "a module whose tests pass passes" succeeded

# ------------------------------------------------------------ shared checks
begin "every reporting command checks output_dir and report_name"
for command in gosec vulncheck licenses mod_verify fips_test; do
    run "${command}" "working_dir=${CLEAN}" output_dir=relative
    check "${command}: refuses a relative output_dir" said "output_dir must be an absolute path"
    run "${command}" "working_dir=${CLEAN}" report_name=../x
    check "${command}: refuses a report_name that is a path" said "report_name must be letters, digits"
done
for command in vulncheck_bin fips_bin; do
    run "${command}" "working_dir=${WORK}/fips" binaries=good output_dir=relative
    check "${command}: refuses a relative output_dir" said "output_dir must be an absolute path"
done
check "nothing reached the fixtures in the checkout" \
    [ "$(git -C "${ROOT}" status --porcelain --untracked-files=all -- tests/fixtures 2> /dev/null)" == "${FIXTURES_BEFORE}" ]

begin "every run record matches schemas/run-record.v1.json"
SCHEMA="${ROOT}/schemas/run-record.v1.json"
# shellcheck disable=SC2016 # jq program, not shell
SCHEMA_CHECK='
    [($schema.required[] as $key | select(has($key) | not) | "no \($key)"),
     (select(.schema != $schema.properties.schema.const) | "schema is \(.schema)"),
     (select(.command as $c | $schema.properties.command.enum | index($c) | not) | "command \(.command)"),
     (select(.outcome as $o | $schema.properties.outcome.enum | index($o) | not) | "outcome \(.outcome)"),
     (.inputs[] | select(.role as $r | $schema.properties.inputs.items.properties.role.enum | index($r) | not) | "input role \(.role)"),
     (.inputs[] | select(.sha256 != null and (.sha256 | test("^[0-9a-f]{64}$") | not)) | "input sha256 \(.sha256)"),
     (.reports[] | select(.sha256 | test("^[0-9a-f]{64}$") | not) | "report sha256 \(.sha256)"),
     (select(.tool != null and (.tool | has("sha512") and has("install") | not)) | "tool without sha512 or install")]
    | join("; ")'
problems=""
commands_seen=""
for record in "${WORK}/records"/*.json; do
    [[ -f "${record}" ]] || continue
    problem=$(jq -r --slurpfile schema "${SCHEMA}" "\$schema[0] as \$schema | ${SCHEMA_CHECK}" "${record}" 2>&1)
    if [[ -n "${problem}" ]]; then
        problems+="${record##*/}: ${problem}"$'\n'
    fi
    commands_seen+=" $(jq -r .command "${record}")"
done
OUTPUT=${problems}
check "every record has the fields and values the schema allows" [ -z "${problems}" ]
for command in gosec licenses vulncheck vulncheck_bin mod_verify fips_bin fips_test; do
    check "${command} wrote one" [ -n "$(tr ' ' '\n' <<< "${commands_seen}" | grep -x "${command}")" ]
done
if command -v python3 > /dev/null 2>&1 && python3 -c 'import jsonschema' 2> /dev/null; then
    OUTPUT=$(python3 -I -c '
import json, sys, jsonschema
schema = json.load(open(sys.argv[1]))
validator = jsonschema.Draft202012Validator(schema)
bad = 0
for path in sys.argv[2:]:
    for error in validator.iter_errors(json.load(open(path))):
        print("%s: %s at %s" % (path.rsplit("/", 1)[-1], error.message, "/".join(map(str, error.absolute_path))))
        bad += 1
sys.exit(1 if bad else 0)' "${SCHEMA}" "${WORK}/records"/*.json 2>&1)
    check "and validates against it with jsonschema" [ $? -eq 0 ]
else
    echo "  skip: Python's jsonschema is not installed, so only the checks above ran"
fi

if [[ "${FAILURES}" -gt 0 ]]; then
    echo "${FAILURES} failure(s)"
    exit 1
fi
echo "All command tests passed."
