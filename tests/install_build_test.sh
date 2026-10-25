#!/usr/bin/env bash
#
# Install tests for the tools go-security-orb builds from source
# (src/install/<tool>/install.sh for govulncheck and go-licenses), run
# offline. They publish no binaries, so their installs build them, and the
# shared install contract test, which serves release assets, does not apply.
# These tests cover the same contract for a build:
#
#   - the checksum tables are well formed and list the default version, and
#     install.sh checks for bash, sets -euo pipefail and stays small enough
#     for CircleCI to launch
#   - install_<tool>.yml defaults to strict verification, passes every
#     parameter, and caches the directory install.sh uses under one key
#   - strict mode, which an unset verify_checksums also means, refuses an
#     unlisted version before downloading or building anything
#   - known_versions and false build unlisted versions, with a warning, and
#     cache nothing unverified
#   - a listed version is installed only when the build matches its checksum
#   - the job's go builds it when it is the pinned Go release, and the
#     pinned release is downloaded and builds it again when the job's build
#     doesn't match
#   - a downloaded Go toolchain is checked against its own checksum before it
#     builds anything, whatever verify_checksums says, comes from
#     download_base_url when that is set, and a failed download stops the
#     install
#   - the build gets the package for the version and every setting that
#     shapes the binary, whatever the job's Go settings, while the job's
#     GOPROXY reaches it
#   - uname -m picks the amd64 or arm64 toolchain and build; other CPUs and
#     non-Linux systems fail
#   - a verified binary is cached, a cached one is verified again and used
#     without building, and a bad one is discarded and built again
#   - a failed build shows Go's output; a binary that cannot run fails the
#     install before it replaces an existing install
#   - install_path is added to the PATH of later steps, and nothing is left
#     in the working directory or TMPDIR
#
# Downloads, uname, the circleci CLI and the Go toolchains are stubbed, so no
# network is needed.
#
# Run from a checkout, for every tool built from source or the ones named:
#   bash tests/install_build_test.sh [TOOL...]

set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BUILD_TOOLS=(govulncheck go-licenses)
if [[ $# -gt 1 ]]; then
    for tool in "$@"; do
        bash "${BASH_SOURCE[0]}" "${tool}" || exit 1
    done
    exit 0
elif [[ $# -eq 0 ]]; then
    for tool in "${BUILD_TOOLS[@]}"; do
        bash "${BASH_SOURCE[0]}" "${tool}" || exit 1
    done
    exit 0
fi
TOOL=$1
if [[ " ${BUILD_TOOLS[*]} " != *" ${TOOL} "* ]]; then
    echo "FAIL: ${TOOL} is not built from source (${BUILD_TOOLS[*]})."
    exit 1
fi
INSTALL_SH="${ROOT}/src/install/${TOOL}/install.sh"
INSTALL_YML="${ROOT}/src/commands/install_${TOOL//-/_}.yml"
echo "=== ${TOOL}"

# The tool definition, for the Go version and the package.
# shellcheck source=/dev/null
source <(sed -n '/^# >>> tool definition >>>$/,/^# <<< tool definition <<<$/p' "${INSTALL_SH}")

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
STUBS="${WORK}/stubs"
JOB_GO="${WORK}/job-go"
SERVE="${WORK}/serve"
BINARIES="${WORK}/binaries"
mkdir -p "${STUBS}" "${JOB_GO}" "${SERVE}" "${BINARIES}"

FAILURES=0
RC=0
OUTPUT=""

begin() {
    echo "--- $1"
}

check() {
    local description=$1 line
    shift
    if "$@"; then
        echo "  ok: ${description}"
    else
        echo "  FAIL: ${description}"
        while IFS= read -r line; do
            echo "    | ${line}"
        done <<< "${OUTPUT}"
        FAILURES=$((FAILURES + 1))
    fi
}

LISTED="0.0.0-20990101000000-000000000001"   # in the table, and the build matches
TAMPERED="0.0.0-20990101000000-000000000002" # in the table, but the build differs
BROKEN="0.0.0-20990101000000-000000000003"   # in the table and matches, but cannot run
UNLISTED="0.0.0-20990101000000-000000000004" # not in the table

# Stand-in binaries the fake Go "builds", one per version and architecture.
for version in "${LISTED}" "${TAMPERED}" "${UNLISTED}"; do
    for arch in amd64 arm64; do
        printf '#!/bin/sh\necho "Usage: %s -mode report (fake %s %s)" >&2\n' "${TOOL}" "${version}" "${arch}" > "${BINARIES}/${version}-${arch}"
    done
done
for arch in amd64 arm64; do
    printf '#!/bin/sh\necho "broken" >&2\nexit 3\n' > "${BINARIES}/${BROKEN}-${arch}"
    # What a Go built differently (a distribution's) gives for the listed version.
    printf '#!/bin/sh\necho "Usage: %s -mode report (built differently)" >&2\n' "${TOOL}" > "${BINARIES}/different-${arch}"
done
chmod +x "${BINARIES}/"*

# fake_go ARCH VERSION WHICH: a stand-in go that records each call's
# arguments and Go settings (tagged with WHICH) to FAKE_GO_LOG, answers
# go env GOVERSION and GOHOSTARCH, and for go install copies the stand-in
# binary for the requested version where go install would put it.
# FAKE_GO_FAIL makes the build fail with that message, and
# FAKE_JOB_GO_DIFFERENT makes the job's go build a binary that differs.
fake_go() {
    cat << EOF
#!/bin/bash
{
    printf '%s ARGS:' "$3"
    printf ' [%s]' "\$@"
    printf '\n'
    env | grep -E '^(GO[A-Z0-9_]*|CGO_ENABLED|XDG_CONFIG_HOME)=' | sed 's/^/$3 /' | sort
} >> "\${FAKE_GO_LOG}"
case "\$1" in
    env)
        case "\$2" in
            GOVERSION) echo "go$2" ;;
            GOHOSTARCH) echo "$1" ;;
        esac
        ;;
    install)
        if [[ -n "\${FAKE_GO_FAIL:-}" ]]; then
            echo "go: downloading something" >&2
            echo "go: \${FAKE_GO_FAIL}" >&2
            exit 1
        fi
        target=\${*: -1}
        version=\${target##*@v}
        out="\${GOPATH}/bin/${TOOL}"
        if [[ "\${GOARCH}" != "$1" ]]; then
            out="\${GOPATH}/bin/linux_\${GOARCH}/${TOOL}"
        fi
        mkdir -p "\${out%/*}"
        if [[ "$3" == job && -n "\${FAKE_JOB_GO_DIFFERENT:-}" ]]; then
            cp "${BINARIES}/different-\${GOARCH}" "\${out}"
        else
            cp "${BINARIES}/\${version}-\${GOARCH}" "\${out}"
        fi
        ;;
esac
EOF
}

# A fake Go release per architecture, as the tarball the install downloads.
make_go() {
    local arch=$1 dir
    dir=$(mktemp -d "${WORK}/go.XXXXXX")
    mkdir -p "${dir}/go/bin"
    fake_go "${arch}" "${GS_BUILD_GO_VERSION}" pinned > "${dir}/go/bin/go"
    chmod +x "${dir}/go/bin/go"
    tar -czf "${WORK}/go-${arch}.tar.gz" -C "${dir}" go
}
make_go amd64
make_go arm64
# The job's go: the pinned Go release, or another one.
fake_go amd64 "${GS_BUILD_GO_VERSION}" job > "${JOB_GO}/go"
mkdir -p "${WORK}/old-go"
fake_go amd64 1.20.0 job > "${WORK}/old-go/go"
chmod +x "${JOB_GO}/go" "${WORK}/old-go/go"

# url_file URL: where the curl stub serves URL from.
url_file() {
    printf '%s/%s\n' "${SERVE}" "$(printf '%s' "$1" | sha256sum | cut -c1-16)"
}
GO_URL="https://dl.google.com/go/go${GS_BUILD_GO_VERSION}.linux-%s.tar.gz"
MIRROR="https://mirror.example/go"
MIRROR_URL="${MIRROR}/go${GS_BUILD_GO_VERSION}.linux-%s.tar.gz"
# serve URL FILE: the curl stub answers URL with FILE.
serve() { cp "$2" "$(url_file "$1")"; }
unserve_all() { rm -f "${SERVE}/"*; }
serve_go() {
    unserve_all
    # shellcheck disable=SC2059 # the URL templates hold the %s
    for arch in amd64 arm64; do
        serve "$(printf "${GO_URL}" "${arch}")" "${WORK}/go-${arch}.tar.gz"
        serve "$(printf "${MIRROR_URL}" "${arch}")" "${WORK}/go-${arch}.tar.gz"
    done
}

# Stubs. curl serves files from SERVE_DIR by URL and logs each URL to
# DOWNLOAD_LOG; an unknown URL is a 404 (curl exit code 22).
cat > "${STUBS}/curl" << 'EOF'
#!/usr/bin/env bash
out="" url=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help) printf '%s\n' " -f, --fail" " -o, --output <file>" " --retry-connrefused"; exit 0 ;;
        -o) out=$2; shift 2 ;;
        --retry | --retry-max-time | --connect-timeout | --speed-limit | --speed-time | --proto | --proto-redir) shift 2 ;;
        -*) shift ;;
        *) url=$1; shift ;;
    esac
done
printf '%s\n' "${url}" >> "${DOWNLOAD_LOG}"
file="${SERVE_DIR}/$(printf '%s' "${url}" | sha256sum | cut -c1-16)"
if [[ ! -f "${file}" ]]; then
    echo "curl: (22) The requested URL returned error: 404" >&2
    exit 22
fi
cp "${file}" "${out}"
EOF
cat > "${STUBS}/uname" << 'EOF'
#!/bin/sh
case "$1" in
    -s) echo "${FAKE_OS:-Linux}" ;;
    -m) echo "${FAKE_ARCH:-x86_64}" ;;
    *) echo "${FAKE_OS:-Linux}" ;;
esac
EOF
printf '#!/bin/sh\ncat\n' > "${STUBS}/circleci"
chmod +x "${STUBS}/"*

# A directory to use as the PATH that holds the stubs and every other
# command except go, so a go installed on this machine is never run.
NO_GO="${WORK}/path-without-go"
mkdir "${NO_GO}"
IFS=: read -r -a PATH_DIRS <<< "${STUBS}:${PATH}"
for dir in "${PATH_DIRS[@]}"; do
    [[ "${dir}" == /* && -d "${dir}" ]] || continue
    for file in "${dir}"/*; do
        name=${file##*/}
        if [[ "${name}" != go && -x "${file}" && ! -d "${file}" && ! -e "${NO_GO}/${name}" ]]; then
            ln -s "${file}" "${NO_GO}/${name}"
        fi
    done
done

# The script under test: install.sh with fixture entries in its checksum
# table, and the fake Go releases' checksums in place of the real ones.
{
    for version in "${LISTED}" "${BROKEN}"; do
        for arch in amd64 arm64; do
            printf '    ["%s/%s"]="%s"\n' "${version}" "${arch}" "$(sha512sum "${BINARIES}/${version}-${arch}" | awk '{ print $1 }')"
        done
    done
    for arch in amd64 arm64; do
        printf '    ["%s/%s"]="%s"\n' "${TAMPERED}" "${arch}" "$(printf 'not the build' | sha512sum | awk '{ print $1 }')"
    done
} > "${WORK}/entries"
SCRIPT="${WORK}/install.sh"
sed "/^declare -A sha512sums=($/r ${WORK}/entries" "${INSTALL_SH}" > "${SCRIPT}"
for arch in amd64 arm64; do
    sed -i "s|^\(    \[\"${GS_BUILD_GO_VERSION}/${arch}\"\]=\"\)[0-9a-f]*\"|\1$(sha512sum "${WORK}/go-${arch}.tar.gz" | awk '{ print $1 }')\"|" "${SCRIPT}"
done

CASE=""
new_case() {
    CASE=$(mktemp -d "${WORK}/case.XXXXXX")
    mkdir -p "${CASE}/home" "${CASE}/tmp" "${CASE}/work"
    : > "${CASE}/downloads.log"
    : > "${CASE}/go.log"
    : > "${CASE}/bash_env"
    serve_go
}

# run_install [VAR=value ...]: runs the install with default parameters,
# overridden by the given assignments, and sets RC and OUTPUT. No go is on
# the PATH unless PATH is given.
run_install() {
    OUTPUT=$(cd "${CASE}/work" && env -u GOFLAGS -u GOEXPERIMENT -u GOPROXY -u GOCACHEPROG -u GOTOOLDIR -u GOROOT \
        "HOME=${CASE}/home" "BASH_ENV=${CASE}/bash_env" "TMPDIR=${CASE}/tmp" "PATH=${NO_GO}" \
        "DOWNLOAD_LOG=${CASE}/downloads.log" "SERVE_DIR=${SERVE}" "FAKE_GO_LOG=${CASE}/go.log" FAKE_OS=Linux FAKE_ARCH=x86_64 \
        "PARAM_VERSION=${LISTED}" PARAM_VERIFY_CHECKSUMS=strict "PARAM_INSTALL_PATH=${CASE}/bin" PARAM_CACHING=false \
        PARAM_DOWNLOAD_BASE_URL= "$@" bash "${SCRIPT}" 2>&1)
    RC=$?
}

succeeded() { [[ "${RC}" -eq 0 ]]; }
failed() { [[ "${RC}" -ne 0 ]]; }
said() { grep -qF -- "$1" <<< "${OUTPUT}"; }
# installed VERSION ARCH: the stand-in binary for VERSION and ARCH is installed.
installed() { cmp -s "${CASE}/bin/${TOOL}" "${BINARIES}/${1:-${LISTED}}-${2:-amd64}"; }
not_installed() { [[ ! -e "${CASE}/bin/${TOOL}" ]]; }
downloaded() { grep -qxF -- "$1" "${CASE}/downloads.log"; }
no_downloads() { [[ ! -s "${CASE}/downloads.log" ]]; }
# built_by WHICH ARG...: go install of WHICH (job or pinned) got exactly these arguments.
built_by() {
    local which=$1 expected
    shift
    expected="${which} ARGS:$(printf ' [%s]' "$@")"
    grep -qxF -- "${expected}" "${CASE}/go.log"
}
not_built() { ! grep -q 'ARGS: \[install\]' "${CASE}/go.log"; }
not_built_by() { ! grep -q "^$1 ARGS: \[install\]" "${CASE}/go.log"; }
go_saw() { grep -qxF -- "pinned $1" "${CASE}/go.log"; }
go_never_saw() { ! grep -q -- "^[a-z]* $1=" "${CASE}/go.log"; }
CACHE_DIR="home/.cache/go-security-orb-${TOOL}"
cached() { cmp -s "${CASE}/${CACHE_DIR}/${1:-${LISTED}}/${2:-amd64}/${TOOL}" "${BINARIES}/${1:-${LISTED}}-${2:-amd64}"; }
nothing_cached() { [[ -z "$(find "${CASE}/home/.cache" -type f 2> /dev/null)" ]]; }
path_exported() { grep -qF "${CASE}/bin" "${CASE}/bash_env"; }
clean_tmp() { [[ -z "$(ls -A "${CASE}/tmp")" ]]; }
clean_work() { [[ -z "$(ls -A "${CASE}/work")" ]]; }

begin "the checksum tables are well formed and list the default version"
declare -A sha512sums=()
# shellcheck source=/dev/null
source <(sed -n '/^# >>> checksum table >>>$/,/^# <<< checksum table <<<$/p' "${INSTALL_SH}")
bad=""
for key in "${!sha512sums[@]}"; do
    if [[ ! "${key}" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?/(amd64|arm64)$ || ! "${sha512sums[${key}]}" =~ ^[0-9a-f]{128}$ ]]; then
        bad+=" ${key}"
    fi
done
OUTPUT="malformed:${bad}"
check "every entry is <version>/<amd64|arm64> and 128 hex digits" test -z "${bad}"
check "the table has entries" test "${#sha512sums[@]}" -gt 0
DEFAULT_VERSION=$(awk '/^  version:/ { found = 1 } found && /default:/ { gsub(/"/, "", $2); print $2; exit }' "${INSTALL_YML}")
for arch in amd64 arm64; do
    check "the default version ${DEFAULT_VERSION} is listed for ${arch}" test -n "${sha512sums["${DEFAULT_VERSION}/${arch}"]:-}"
    check "Go ${GS_BUILD_GO_VERSION} has a checksum for ${arch}" \
        test -n "$(grep -E "^    \[\"${GS_BUILD_GO_VERSION}/${arch}\"\]=\"[0-9a-f]{128}\"$" "${INSTALL_SH}")"
done
check "amd64 and arm64 have different checksums" \
    test "${sha512sums["${DEFAULT_VERSION}/amd64"]:-a}" != "${sha512sums["${DEFAULT_VERSION}/arm64"]:-a}"

begin "install.sh and install_${TOOL//-/_}.yml"
OUTPUT=""
check "install.sh checks for bash 4 first" grep -q 'BASH_VERSINFO:-0}" -lt 4' "${INSTALL_SH}"
check "install.sh sets -euo pipefail" grep -qx 'set -euo pipefail' "${INSTALL_SH}"
check "install.sh stays under 100 KB, which CircleCI can launch" test "$(wc -c < "${INSTALL_SH}")" -lt 100000
check "install_${TOOL//-/_}.yml defaults to strict verification" grep -Eq '^    default: strict$' "${INSTALL_YML}"
for param in CACHING DOWNLOAD_BASE_URL INSTALL_PATH VERIFY_CHECKSUMS VERSION; do
    check "install_${TOOL//-/_}.yml passes PARAM_${param}" grep -q "PARAM_${param}: << parameters\." "${INSTALL_YML}"
done
check "install_${TOOL//-/_}.yml runs install.sh" grep -q "command: << include(install/${TOOL}/install.sh) >>" "${INSTALL_YML}"
check "install_${TOOL//-/_}.yml caches the directory install.sh uses" grep -qx "              - ~/.cache/go-security-orb-${TOOL}" "${INSTALL_YML}"
KEYS=$(grep -E '^ +key: ' "${INSTALL_YML}" | sed -E 's/^ +key: //' | sort -u)
OUTPUT=${KEYS}
check "install_${TOOL//-/_}.yml restores and saves the cache under one key" test "$(wc -l <<< "${KEYS}")" -eq 1

begin "without the pinned Go on the PATH, a listed version is built with it, verified and installed"
new_case
run_install
check "succeeds" succeeded
check "verifies the build" said "Checksum verification passed."
check "installs the build" installed
# shellcheck disable=SC2059 # the URL template holds the %s
check "downloads the amd64 Go release" downloaded "$(printf "${GO_URL}" amd64)"
check "checks the Go release" said "Go ${GS_BUILD_GO_VERSION} (amd64) matches its SHA-512 checksum."
check "builds the package at the version" built_by pinned install "${GS_BUILD_PACKAGE}@v${LISTED}"
for setting in CGO_ENABLED=0 "GOFLAGS=-trimpath -modcacherw" GOTOOLCHAIN=local GOOS=linux GOARCH=amd64 \
    GOAMD64=v1 GOARM64=v8.0 GOENV=off GOWORK=off GOFIPS140=off; do
    check "builds with ${setting}" go_saw "${setting}"
done
check "adds the install directory to the PATH of later steps" path_exported
RECORD=$(cat "${CASE}/bin/.${TOOL}.install.json" 2>&1)
check "records a source-built install beside the binary" grep -qF '"method":"source-built"' <<< "${RECORD}"
check "with the Go release that built it" grep -qF "\"build_go_version\":\"${GS_BUILD_GO_VERSION}\"" <<< "${RECORD}"
check "and the installed binary's SHA-512" grep -qF "\"binary_sha512\":\"$(sha512sum "${CASE}/bin/${TOOL}" | awk '{ print $1 }')\"" <<< "${RECORD}"
check "caches nothing with caching off" nothing_cached
check "leaves no temporary files" clean_tmp
check "writes nothing to the working directory" clean_work

begin "the job's Go settings don't shape the build, but its GOPROXY reaches it"
new_case
run_install GOFLAGS=-mod=vendor GOEXPERIMENT=nocoverageredesign GOAMD64=v3 GOCACHEPROG=/usr/bin/false \
    GOTOOLDIR=/tmp/tools GOROOT=/opt/elsewhere GOPROXY=https://proxy.example
check "succeeds" succeeded
check "replaces the job's GOFLAGS" go_saw "GOFLAGS=-trimpath -modcacherw"
check "drops the job's GOEXPERIMENT" go_never_saw GOEXPERIMENT
check "drops the job's GOCACHEPROG" go_never_saw GOCACHEPROG
check "drops the job's GOTOOLDIR" go_never_saw GOTOOLDIR
check "drops the job's GOROOT" go_never_saw GOROOT
check "replaces the job's GOAMD64" go_saw GOAMD64=v1
check "passes the job's GOPROXY" go_saw GOPROXY=https://proxy.example

begin "the job's go builds it when it is the pinned Go release"
new_case
run_install "PATH=${JOB_GO}:${NO_GO}"
check "succeeds" succeeded
check "says it uses the job's Go" said "with this job's Go ${GS_BUILD_GO_VERSION} (${JOB_GO}/go)"
check "builds with it" built_by job install "${GS_BUILD_PACKAGE}@v${LISTED}"
check "downloads no Go release" no_downloads
check "verifies the build" said "Checksum verification passed."
check "installs the build" installed
new_case
run_install "PATH=${JOB_GO}:${NO_GO}" FAKE_JOB_GO_DIFFERENT=1 PARAM_CACHING=true
check "a job's go whose build doesn't match still installs" succeeded
check "with a warning" said "This job's Go did not build the binary this orb's checksum table pins."
# shellcheck disable=SC2059 # the URL template holds the %s
check "by downloading the pinned Go release" downloaded "$(printf "${GO_URL}" amd64)"
check "and building with it" built_by pinned install "${GS_BUILD_PACKAGE}@v${LISTED}"
check "installs the pinned release's build" installed
check "and caches that one" cached
new_case
run_install "PATH=${WORK}/old-go:${NO_GO}"
check "another Go release on the PATH is not used" not_built_by job
check "the pinned one is downloaded instead" succeeded

begin "download_base_url"
new_case
run_install "PARAM_DOWNLOAD_BASE_URL=${MIRROR}/"
check "succeeds" succeeded
# shellcheck disable=SC2059 # the URL template holds the %s
check "downloads Go from the mirror" downloaded "$(printf "${MIRROR_URL}" amd64)"
check "and nothing else" test "$(wc -l < "${CASE}/downloads.log")" -eq 1
check "says which mirror it uses" said "download mirror:  ${MIRROR} (in place of https://dl.google.com/go)"
new_case
run_install "PARAM_DOWNLOAD_BASE_URL=https://user:s3cret@mirror.example/go"
check "refuses credentials in it" failed
check "without printing them" test "${OUTPUT}" == "${OUTPUT//s3cret/}"
check "before downloading anything" no_downloads

begin "strict mode refuses an unlisted version before downloading"
new_case
run_install PARAM_VERSION="${UNLISTED}"
check "fails" failed
check "says there is no checksum" said "no checksum for ${TOOL} ${UNLISTED}"
check "downloads nothing" no_downloads
check "builds nothing" not_built
check "installs nothing" not_installed
new_case
run_install PARAM_VERSION="${UNLISTED}" PARAM_VERIFY_CHECKSUMS=
check "an unset verify_checksums means strict" failed
check "and downloads nothing" no_downloads

begin "an invalid version is rejected"
new_case
run_install PARAM_VERSION="0.0.0;touch pwned"
check "fails" failed
check "says the version is invalid" said "Invalid ${TOOL} version"
check "downloads nothing" no_downloads

begin "known_versions builds an unlisted version unverified, with a warning"
new_case
run_install PARAM_VERSION="${UNLISTED}" PARAM_VERIFY_CHECKSUMS=known_versions PARAM_CACHING=true
check "succeeds" succeeded
check "warns that it is unverified" said "Installing an UNVERIFIED binary"
check "installs the build" installed "${UNLISTED}"
check "caches nothing unverified" nothing_cached

begin "false builds without verifying, but still checks Go"
new_case
run_install PARAM_VERSION="${TAMPERED}" PARAM_VERIFY_CHECKSUMS=false
check "succeeds" succeeded
check "warns that nothing is verified" said "WITHOUT checksum verification"
check "installs the build" installed "${TAMPERED}"
check "checks the Go release" said "Go ${GS_BUILD_GO_VERSION} (amd64) matches its SHA-512 checksum."

begin "a build that doesn't match the table is not installed"
new_case
run_install PARAM_VERSION="${TAMPERED}" PARAM_CACHING=true
check "fails" failed
check "says the build doesn't match" said "is not the binary this orb's checksum table pins"
check "installs nothing" not_installed
check "caches nothing" nothing_cached

begin "a Go release that doesn't match its checksum builds nothing"
for mode in strict false; do
    new_case
    # shellcheck disable=SC2059 # the URL template holds the %s
    serve "$(printf "${GO_URL}" amd64)" "${WORK}/go-arm64.tar.gz"
    run_install PARAM_VERIFY_CHECKSUMS="${mode}"
    check "fails (verify_checksums ${mode})" failed
    check "says Go doesn't match (verify_checksums ${mode})" said "does not match this orb's checksum, so ${TOOL} was not built"
    check "builds nothing (verify_checksums ${mode})" not_built
    check "installs nothing (verify_checksums ${mode})" not_installed
done

begin "a failed Go download stops the install"
new_case
unserve_all
run_install
check "fails" failed
check "says Go could not be downloaded" said "Could not download Go ${GS_BUILD_GO_VERSION} (amd64)"
check "builds nothing" not_built
check "installs nothing" not_installed

begin "an arm64 machine gets the arm64 Go and build"
new_case
run_install FAKE_ARCH=aarch64
check "succeeds" succeeded
# shellcheck disable=SC2059 # the URL template holds the %s
check "downloads the arm64 Go release" downloaded "$(printf "${GO_URL}" arm64)"
check "builds for arm64" go_saw GOARCH=arm64
check "installs the arm64 build" installed "${LISTED}" arm64

begin "other CPUs and systems fail"
new_case
run_install FAKE_ARCH=riscv64
check "an unsupported CPU fails" failed
check "and names it" said "Unsupported CPU architecture 'riscv64'"
new_case
run_install FAKE_OS=Darwin
check "a system other than Linux fails" failed
check "and downloads nothing" no_downloads

begin "a verified build is cached and used by the next install"
new_case
run_install PARAM_CACHING=true
check "the first install succeeds" succeeded
check "caches the verified build" cached
: > "${CASE}/downloads.log"
: > "${CASE}/go.log"
rm -f "${CASE}/bin/${TOOL}"
run_install PARAM_CACHING=true
check "the second install succeeds" succeeded
check "uses the cache" said "Using ${TOOL} ${LISTED} from the cache."
check "verifies the cached binary" said "Checksum verification passed."
check "downloads nothing" no_downloads
check "builds nothing" not_built
check "installs the cached binary" installed

begin "a bad cached binary is discarded and built again"
new_case
mkdir -p "${CASE}/${CACHE_DIR}/${LISTED}/amd64"
printf 'tampered' > "${CASE}/${CACHE_DIR}/${LISTED}/amd64/${TOOL}"
run_install PARAM_CACHING=true
check "succeeds" succeeded
check "warns about the cached binary" said "failed verification. Discarding it and building it again."
check "builds again" built_by pinned install "${GS_BUILD_PACKAGE}@v${LISTED}"
check "installs the build" installed
check "replaces the cached binary with the build" cached

begin "the cache isn't read when there is nothing to verify it against"
new_case
mkdir -p "${CASE}/${CACHE_DIR}/${UNLISTED}/amd64"
printf 'planted' > "${CASE}/${CACHE_DIR}/${UNLISTED}/amd64/${TOOL}"
run_install PARAM_VERSION="${UNLISTED}" PARAM_VERIFY_CHECKSUMS=known_versions PARAM_CACHING=true
check "succeeds" succeeded
check "builds instead of using the cache" installed "${UNLISTED}"

begin "a failed build shows Go's output"
new_case
run_install FAKE_GO_FAIL="unknown revision v${LISTED}"
check "fails" failed
check "shows Go's error" said "go: unknown revision v${LISTED}"
check "says the build failed" said "Could not build ${TOOL} ${LISTED}"
check "installs nothing" not_installed
check "leaves no temporary files" clean_tmp

begin "a binary that cannot run leaves an existing install in place"
new_case
mkdir -p "${CASE}/bin"
printf 'existing' > "${CASE}/bin/${TOOL}"
run_install PARAM_VERSION="${BROKEN}"
check "fails" failed
check "says the binary cannot run" said "cannot run on this machine"
check "leaves the existing install" test "$(cat "${CASE}/bin/${TOOL}")" == "existing"
check "doesn't touch the PATH" test ! -s "${CASE}/bash_env"

begin "install_path"
new_case
run_install PARAM_INSTALL_PATH="relative/bin"
check "a relative install_path fails" failed
check "and says it must be absolute" said "install_path must be an absolute path"
new_case
# shellcheck disable=SC2088 # the ~ is for install.sh to expand
run_install PARAM_INSTALL_PATH="~/tools"
check "a leading ~/ means HOME" succeeded
check "and installs there" cmp -s "${CASE}/home/tools/${TOOL}" "${BINARIES}/${LISTED}-amd64"
new_case
run_install PATH="${CASE}/bin:${NO_GO}"
check "an install_path already on the PATH succeeds" succeeded
check "and is not added again" test ! -s "${CASE}/bash_env"

if [[ "${FAILURES}" -gt 0 ]]; then
    echo "${FAILURES} failure(s)"
    exit 1
fi
echo "All ${TOOL} install tests passed."
