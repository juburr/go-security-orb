#!/bin/bash
#
# Checks Go binaries for FIPS 140-3, for the fips_bin command, from the
# build information go version -m reads out of each one. What decides
# whether a binary uses a validated Go Cryptographic Module is recorded
# there: the Go release, GOFIPS140 (the module version linked in; absent
# when it was off, latest when it is the in-tree code), the default GODEBUG
# (fips140=on unless a go.mod or //go:debug line turned it off), cgo, and
# the modules linked in, among which cryptography from outside the standard
# library is outside the module's boundary.

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
NO_CGO=$(gs_bool require_cgo_disabled "${PARAM_REQUIRE_CGO_DISABLED}")
case "${PARAM_FIPS140}" in
    on | only) ;;
    *)
        echo "ERROR: fips140 must be on or only, not '${PARAM_FIPS140}'." >&2
        exit 1
        ;;
esac
MIN_GO=$(gs_subst "${PARAM_MIN_GO_VERSION}")
if ! gs_match "${MIN_GO}" '^(go)?1\.([0-9]+)(\.([0-9]+))?$'; then
    echo "ERROR: min_go_version must be a Go release such as 1.24 or 1.25.2, not '${MIN_GO}'." >&2
    exit 1
fi
MIN_MINOR=$((10#${BASH_REMATCH[2]}))
MIN_PATCH=$((10#${BASH_REMATCH[4]:-0}))
gs_list gofips140 "${PARAM_GOFIPS140}"
if [[ ${#GS_LIST[@]} -eq 0 ]]; then
    echo "ERROR: gofips140 names no module version." >&2
    exit 1
fi
for version in "${GS_LIST[@]}"; do
    case "${version}" in
        off | latest)
            echo "ERROR: gofips140 can't allow ${version}, which links no validated Go Cryptographic Module." >&2
            exit 1
            ;;
        certified | inprocess)
            echo "ERROR: gofips140 must name module versions, not the ${version} alias: build information records the" >&2
            echo "  version an alias stood for, such as v1.0.0-c2097c7c for certified in Go 1.25 and later." >&2
            exit 1
            ;;
    esac
    if ! gs_match "${version}" '^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9a-f]+)?$'; then
        echo "ERROR: gofips140 must list module versions such as v1.0.0, not '${version}'." >&2
        exit 1
    fi
done
ALLOWED_JSON=$(printf '%s\n' "${GS_LIST[@]}" | jq -R . | jq -s -c .)
gs_output "${PARAM_OUTPUT_DIR}" "${PARAM_REPORT_NAME}"
gs_require_jq
gs_go
gs_binaries "${PARAM_BINARIES}"

# Accepted cryptography modules: one per line, the module path and a reason.
entries=()
while IFS= read -r line || [[ -n "${line}" ]]; do
    line=${line#"${line%%[![:space:]]*}"}
    [[ -z "${line}" || "${line}" == \#* ]] && continue
    path=${line%%[[:space:]]*}
    reason=${line#"${path}"}
    reason=${reason#"${reason%%[![:space:]]*}"}
    if ! gs_match "${path}" '^[A-Za-z0-9][A-Za-z0-9._~/-]*$'; then
        echo "ERROR: allowed_crypto_modules must start each line with a module path, not '${path}'." >&2
        exit 1
    fi
    if [[ -z "${reason}" ]]; then
        echo "ERROR: allowed_crypto_modules accepts ${path} without a reason. Give one after the path, such as:" >&2
        echo "  ${path} only used for SSH host keys, outside the FIPS boundary by policy" >&2
        exit 1
    fi
    entries+=("$(jq -cn --arg path "${path}" --arg reason "${reason}" '{path: $path, reason: $reason}')")
done <<< "$(gs_subst "${PARAM_ALLOWED_CRYPTO_MODULES}")"
ACCEPTED_JSON=$(printf '%s\n' ${entries[@]+"${entries[@]}"} | jq -s -c .)

# Cryptography modules outside the standard library, by module path (a /vN
# major version suffix matches too). Their algorithms are outside the Go
# Cryptographic Module, whatever GOFIPS140 says.
CRYPTO_MODULES='[
    "golang.org/x/crypto", "github.com/cloudflare/circl", "filippo.io/edwards25519", "filippo.io/nistec",
    "filippo.io/bigmod", "filippo.io/mlkem768", "github.com/ProtonMail/go-crypto", "lukechampine.com/blake3",
    "github.com/zeebo/blake3", "github.com/minio/sha256-simd", "github.com/aead/chacha20",
    "github.com/aead/chacha20poly1305", "github.com/consensys/gnark-crypto", "github.com/decred/dcrd/dcrec/secp256k1",
    "github.com/btcsuite/btcd/btcec", "gitlab.com/yawning/secp256k1-voi", "github.com/golang-fips/openssl",
    "github.com/microsoft/go-crypto-openssl", "github.com/microsoft/go-crypto-winnative", "github.com/tink-crypto/tink-go",
    "github.com/google/tink/go", "github.com/emmansun/gmsm", "github.com/tjfoc/gmsm", "github.com/refraction-networking/utls"
]'

# Reads go version -m's text: "FILE: goVERSION", then tab-separated lines,
# into the shape of runtime/debug.BuildInfo. Keys and values that hold
# spaces or quotes are quoted Go strings.
# shellcheck disable=SC2016 # jq program, not shell
BUILDINFO_JQ='
    def unq: if startswith("\"") then (try fromjson catch .) else . end;
    [inputs] as $lines
    | reduce ($lines[1:][] | select(startswith("\t")) | ltrimstr("\t") | split("\t")) as $f
        ({GoVersion: ($lines[0] | sub("^.*: "; "")), Path: "", Main: null, Deps: [], Settings: []};
        if $f[0] == "path" then .Path = $f[1]
        elif $f[0] == "mod" then .Main = {Path: $f[1], Version: ($f[2] // "")}
        elif $f[0] == "dep" then .Deps += [{Path: $f[1], Version: ($f[2] // "")}]
        elif $f[0] == "=>" and (.Deps | length) > 0 then .Deps[(.Deps | length) - 1].Replace = {Path: $f[1], Version: ($f[2] // "")}
        elif $f[0] == "build" then ($f[1:] | join("\t")) as $kv
            | ($kv | index("=")) as $i
            | if $i == null then . else .Settings += [{Key: ($kv[:$i] | unq), Value: ($kv[$i + 1:] | unq)}] end
        else . end)'

# The checks, from the build information.
# shellcheck disable=SC2016 # jq program, not shell
CHECK_JQ='
    def setting($k): [.Settings[] | select(.Key == $k) | .Value // ""] | last;
    def godebug($k): [(setting("DefaultGODEBUG") // "") | split(",")[] | select(startswith($k + "=")) | ltrimstr($k + "=")] | last;
    def crypto($p): any($crypto[]; . as $c | $p == $c
        or (($p | startswith($c + "/v")) and ($p | ltrimstr($c + "/v") | test("^[0-9]+$"))));
    ((.GoVersion | capture("^go1\\.(?<minor>[0-9]+)(\\.(?<patch>[0-9]+))?")) // null) as $v
    | setting("GOFIPS140") as $gofips
    | (godebug("fips140") // "off") as $mode
    | setting("CGO_ENABLED") as $cgo
    | ((setting("-tags") // "") | split(",")) as $tags
    | (setting("GOEXPERIMENT") // "") as $experiment
    | ([.Deps[] | ., (.Replace // empty) | select(crypto(.Path)) | .Path] | unique) as $found
    | [$found[] | . as $p | {path: $p, accepted: any($accepted[]; .path == $p),
        reason: ([$accepted[] | select(.path == $p) | .reason] | first)}] as $modules
    | {target: $target, sha256: $sha, go_version: .GoVersion, path: .Path, main_module: .Main,
       gofips140: $gofips, fips140: $mode, cgo_enabled: $cgo, goos: setting("GOOS"), goarch: setting("GOARCH"),
       goexperiment: (if $experiment == "" then null else $experiment end), tags: $tags, crypto_modules: $modules,
       notes: [
         (if ($experiment | split(",") | index("boringcrypto")) != null then
            "GOEXPERIMENT=boringcrypto: Go+BoringCrypto, which is incompatible with the native FIPS 140-3 mode" else empty end),
         (if ($tags | index("purego")) != null then "built with the purego tag, which GOFIPS140 refuses" else empty end),
         (if setting("microsoft_systemcrypto") != null then
            "microsoft_systemcrypto=\(setting("microsoft_systemcrypto")): Microsoft Go, which uses the platform cryptography library" else empty end)
       ],
       checks: [
         {check: "go_version"} + if $v == null then {status: "failed", message: "built with \(.GoVersion), not a Go release"}
           elif (($v.minor | tonumber) < $min_minor) or (($v.minor | tonumber) == $min_minor and (($v.patch // "0") | tonumber) < $min_patch)
           then {status: "failed", message: "built with \(.GoVersion), older than min_go_version (\($min_go))"}
           else {status: "passed", message: "built with \(.GoVersion), at least \($min_go)"} end,
         {check: "gofips140"} + if $gofips == null then {status: "failed",
             message: "built without GOFIPS140, so it links the in-tree crypto/internal/fips140 code, not a validated Go Cryptographic Module"}
           elif $gofips == "latest" then {status: "failed",
             message: "built with GOFIPS140=latest: FIPS 140-3 mode on the in-tree crypto/internal/fips140 code, which no validation covers"}
           elif ($allowed | index($gofips)) == null then {status: "failed",
             message: "built with GOFIPS140=\($gofips), which gofips140 (\($allowed | join(", "))) does not allow"}
           else {status: "passed", message: "links the Go Cryptographic Module \($gofips)"} end,
         {check: "fips140"} + if ($want == "on" and ($mode == "on" or $mode == "only")) or $mode == $want
           then {status: "passed", message: "defaults to fips140=\($mode)"}
           elif $gofips == null and $mode == "off" then {status: "failed", message: "defaults to fips140=off, as a build without GOFIPS140 does"}
           else {status: "failed", message: "defaults to fips140=\($mode), not \($want)\(if $want == "on" then " (or only)" else "" end): a go.mod godebug line or a //go:debug directive set it"} end,
         {check: "cgo"} + if $nocgo | not then {status: "skipped", message: "CGO_ENABLED=\($cgo // "unknown"), and require_cgo_disabled is false"}
           elif $cgo == "0" then {status: "passed", message: "built with CGO_ENABLED=0"}
           else {status: "failed", message: "built with CGO_ENABLED=\($cgo // "unknown"): C code linked through cgo can carry cryptography outside the module"} end,
         {check: "crypto_modules"} + if ([$modules[] | select(.accepted | not)] | length) > 0
           then {status: "failed", message: "links cryptography modules outside the standard library: \([$modules[] | select(.accepted | not) | .path] | join(", "))"}
           elif ($modules | length) > 0 then {status: "passed", message: "links only accepted cryptography modules outside the standard library: \([$modules[].path] | join(", "))"}
           else {status: "passed", message: "links no cryptography modules outside the standard library"} end
       ],
       build_settings: .Settings}'

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/results"
ERRORS=()
GS_INPUTS=()
n=0
for binary in "${GS_BINARIES[@]}"; do
    n=$((n + 1))
    GS_INPUTS+=("binary:${binary}")
    file=${binary}
    if [[ "${file}" == -* ]]; then
        file=./${file}
    fi
    if ! go version -m "${file}" > "${WORK}/info.txt" 2> "${WORK}/err.log" || [[ ! -s "${WORK}/info.txt" ]]; then
        ERRORS+=("${binary}")
        echo "ERROR: ${binary} is not a Go binary with build information (go version -m could not read it)." >&2
        gs_tail "${WORK}/err.log"
        continue
    fi
    if ! jq -R -n -c "${BUILDINFO_JQ}" "${WORK}/info.txt" > "${WORK}/info.json" 2> "${WORK}/err.log" \
        || ! jq -c --arg target "${binary}" --arg sha "$(gs_sha256 "${binary}")" --argjson min_minor "${MIN_MINOR}" \
            --argjson min_patch "${MIN_PATCH}" --arg min_go "${MIN_GO#go}" --argjson allowed "${ALLOWED_JSON}" \
            --arg want "${PARAM_FIPS140}" --argjson nocgo "${NO_CGO}" --argjson crypto "${CRYPTO_MODULES}" \
            --argjson accepted "${ACCEPTED_JSON}" "${CHECK_JQ}" "${WORK}/info.json" > "${WORK}/results/$(printf '%03d' "${n}").json" 2> "${WORK}/err.log"; then
        ERRORS+=("${binary}")
        echo "ERROR: The build information of ${binary} could not be read: $(head -c 300 "${WORK}/err.log")" >&2
        continue
    fi
    jq -r '"\(.target): \(.go_version), GOFIPS140=\(.gofips140 // "unset"), fips140=\(.fips140), CGO_ENABLED=\(.cgo_enabled // "unknown") (SHA-256 \(.sha256))",
        (.checks[] | "  \(.check): \(if .status == "failed" then "FAILED: " elif .status == "skipped" then "skipped, " else "" end)\(.message)"),
        (.crypto_modules[] | select(.accepted) | "    accepted \(.path): \(.reason)"),
        (.notes[] | "  note: \(.)")' "${WORK}/results/$(printf '%03d' "${n}").json"
done

REPORT="${GS_BASE}.json"
GS_REPORTS=("${REPORT}")
find "${WORK}/results" -name '*.json' | LC_ALL=C sort | xargs -r cat | jq -s \
    --arg min_go "${MIN_GO#go}" --argjson allowed "${ALLOWED_JSON}" --arg want "${PARAM_FIPS140}" --argjson nocgo "${NO_CGO}" \
    --argjson accepted "${ACCEPTED_JSON}" \
    '{policy: {min_go_version: $min_go, gofips140: $allowed, fips140: $want, require_cgo_disabled: $nocgo,
        allowed_crypto_modules: $accepted}, binaries: .}' > "${REPORT}"
FINDINGS=$(jq '[.binaries[].checks[] | select(.status == "failed")] | length' "${REPORT}")
FAILED_BINARIES=$(jq '[.binaries[] | select(any(.checks[]; .status == "failed"))] | length' "${REPORT}")
echo "Report: ${REPORT}"
if [[ "${JUNIT}" == true ]]; then
    ERRORS_JSON='[]'
    if [[ ${#ERRORS[@]} -gt 0 ]]; then
        ERRORS_JSON=$(printf '%s\n' "${ERRORS[@]}" | jq -R . | jq -s -c .)
    fi
    gs_junit "${GS_OUT}/junit/${PARAM_REPORT_NAME}.xml" "fips_bin" \
        "$(jq -c --argjson errors "${ERRORS_JSON}" \
            '[(.binaries[] | .target as $target | .checks[] | {classname: $target, name: .check, status: .status,
                message: .message, detail: "\($target): \(.message)"}),
              ($errors[] | {classname: ., name: "build information", status: "failed",
                message: "not a Go binary with build information"})]' "${REPORT}")"
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
    GS_ARGS=(version -m)
    # shellcheck disable=SC2034 # read by gs_run_record
    GS_RESULTS=$(jq -c '[.binaries[] | del(.build_settings) + {policy_failed: [.checks[] | select(.status == "failed") | .check]}]' "${REPORT}")
    # shellcheck disable=SC2034 # read by gs_run_record
    GS_COUNTS=$(jq -c --argjson errors "${#ERRORS[@]}" '{binaries: (.binaries | length),
        binaries_failed: [.binaries[] | select(any(.checks[]; .status == "failed"))] | length,
        checks_failed: [.binaries[].checks[] | select(.status == "failed")] | length, binaries_not_read: $errors}' "${REPORT}")
    gs_run_record "${GS_BASE}.run-record.json" fips_bin "${OUTCOME}" "$([[ "${OUTCOME}" == error ]] && echo 1 || echo 0)" "${STARTED}"
fi

if [[ ${#ERRORS[@]} -gt 0 ]]; then
    echo "ERROR: $(gs_plural "${#ERRORS[@]}" file files) could not be checked (${ERRORS[*]}), so the step fails whatever report_only says." >&2
    exit 1
fi
if [[ "${FINDINGS}" -gt 0 ]]; then
    gs_gate true "${REPORT_ONLY}" "$(gs_plural "${FAILED_BINARIES}" binary binaries) of ${#GS_BINARIES[@]} failed $(gs_plural "${FINDINGS}" check checks) for FIPS 140-3."
fi
gs_gate false "${REPORT_ONLY}" "$(gs_plural "${#GS_BINARIES[@]}" binary binaries) built for FIPS 140-3, defaulting to fips140=${PARAM_FIPS140}."
