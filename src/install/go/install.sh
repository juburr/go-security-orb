#!/bin/bash
#
# Installs Go for the install_go command, verified against the checksum table
# in this file before it is installed.
#
# Every juburr orb's install.sh has the same three parts:
#   1. tool definition: what to download and how to install it (Go only)
#   2. shared install logic: identical in every orb
#   3. checksum table: one SHA-512 per release and architecture
#
# go-security-orb installs several tools, so it has one such script per tool,
# in src/install/<tool>/.
#
# Add the checksums for a new release with:
#   src/install/go/install_hash.sh -v <version>

# CircleCI runs steps with /bin/sh when the image has no bash, and macOS ships
# bash 3, which lacks associative arrays.
if [ -z "${BASH_VERSION:-}" ] || [ "${BASH_VERSINFO:-0}" -lt 4 ]; then
    echo "ERROR: Installing Go needs bash 4 or newer. Use an executor image that has it." >&2
    exit 1
fi
set -euo pipefail

# >>> tool definition >>>
ORB_NAME="go-security-orb-go"
TOOL_NAME="Go"
TOOL_BINARY="go"
TOOL_ARCHES="amd64 arm64"
# The default install_path, under HOME. It is the Go installation's root
# (GOROOT), and its bin directory goes on the PATH.
TOOL_DEFAULT_INSTALL_DIR="sdk/go"

# tool_asset_name VERSION ARCH: the release archive to download.
tool_asset_name() {
    printf 'go%s.linux-%s.tar.gz\n' "$1" "$2"
}

# tool_asset_urls VERSION ARCH ASSET: where to download it, one URL per line,
# tried in order. go.dev/dl redirects to the same files.
tool_asset_urls() {
    printf '%s/%s\n' "${GS_DOWNLOAD_BASE_URL:-https://dl.google.com/go}" "$3"
}

# tool_archive_member VERSION ARCH: empty, since the archive holds a whole
# tree: the checksum table holds the SHA-512 of the archive itself, the file
# go.dev publishes a SHA-256 for.
tool_archive_member() {
    :
}

# tool_version BINARY: prints the installed version without using the network.
tool_version() {
    "$1" version
}

# >>> go-security-orb install helpers >>>
# Identical in every tool definition of go-security-orb, so change them in
# all of them together. They run inside the shared install logic, through
# tool_install, and only after orb_init has read the parameters. A tool that
# is built from source sets GS_BUILD_PACKAGE, GS_BUILD_GO_VERSION and
# gs_go_sha512sums in its tool definition.

# gs_download_base_url DEFAULT: sets GS_DOWNLOAD_BASE_URL from the
# download_base_url parameter, which replaces DEFAULT (https://github.com for
# a GitHub release, https://dl.google.com/go for a Go release) in the
# download URL, so the same file comes from an internal mirror such as
# Artifactory, Nexus or S3. The checksum table, not the mirror, decides what
# is installed.
gs_download_base_url() {
    local authority
    GS_DOWNLOAD_BASE_URL=$(orb_subst "${PARAM_DOWNLOAD_BASE_URL:-}")
    GS_DOWNLOAD_BASE_URL=${GS_DOWNLOAD_BASE_URL%/}
    if [[ -z "${GS_DOWNLOAD_BASE_URL}" ]]; then
        return 0
    fi
    # Credentials in the URL would show in the log and on curl's command
    # line, so they are refused before the URL is printed anywhere.
    authority=${GS_DOWNLOAD_BASE_URL#*://}
    if [[ "${authority%%/*}" == *@* ]]; then
        orb_die "download_base_url must not hold credentials (user:password@ before the host): they would show in the log and on curl's command line."
    fi
    # Nor can a query or fragment, which can hold a token too, and would end
    # up in the middle of every download URL.
    if [[ "${GS_DOWNLOAD_BASE_URL}" == *[?#]* ]]; then
        orb_die "download_base_url must not have a query or fragment (? or #): it could hold a token, which would show in the log."
    fi
    if [[ ! "${GS_DOWNLOAD_BASE_URL}" =~ ^https://[^[:space:]\"\'\<\>\\]+$ ]]; then
        orb_die "download_base_url must be an https:// URL, not '${GS_DOWNLOAD_BASE_URL}'."
    fi
    orb_info "  download mirror:  ${GS_DOWNLOAD_BASE_URL} (in place of $1)"
}

# gs_install_record METHOD: writes what was installed, and how, beside the
# binary as .<binary>.install.json, for the commands' run records. METHOD is
# prebuilt or source-built. Every value is one this script validated or
# computed, so none needs JSON escaping.
gs_install_record() {
    local file="${ORB_BIN_DIR}/.${TOOL_BINARY}.install.json" sha512=""
    if command -v sha512sum > /dev/null 2>&1; then
        sha512=$(sha512sum "${ORB_BIN_DIR}/${TOOL_BINARY}" | awk '{ print $1 }')
    fi
    if ! orb_temp_beside "${file}" || ! printf '{"tool":"%s","version":"%s","arch":"%s","method":"%s","asset":"%s","asset_sha512":"%s","verify_checksums":"%s","build_go_version":"%s","binary_sha512":"%s"}\n' \
        "${TOOL_NAME}" "${ORB_VERSION}" "${ORB_ARCH}" "$1" "${ORB_ASSET_NAME}" "${ORB_EXPECTED_SHA512}" \
        "${ORB_VERIFY_CHECKSUMS}" "${GS_BUILD_GO_VERSION:-}" "${sha512}" > "${ORB_TEMP}" || ! mv -f "${ORB_TEMP}" "${file}"; then
        orb_warn "Could not write ${file}; run records will not say how ${TOOL_NAME} was installed."
    fi
}

# gs_install_prebuilt: installs the release binary the shared install logic
# downloads and verifies, from the mirror when download_base_url is set.
gs_install_prebuilt() {
    gs_download_base_url https://github.com
    orb_install_binary
    gs_install_record prebuilt
}

# gs_fetch_go GO_VERSION ARCH DIR: downloads Go GO_VERSION for ARCH, checks it
# against gs_go_sha512sums, and extracts it into DIR, so the toolchain is
# DIR/go.
gs_fetch_go() {
    local go_version=$1 arch=$2 dir=$3 archive expected actual
    archive="${dir}/go${go_version}.linux-${arch}.tar.gz"
    expected=${gs_go_sha512sums["${go_version}/${arch}"]:-}
    if [[ ! "${expected}" =~ ^[0-9a-f]{128}$ ]]; then
        orb_die "This orb has no valid checksum for Go ${go_version} (${arch}), which builds ${TOOL_NAME}."
    fi
    mkdir -p "${dir}"
    if ! orb_download "${archive}" "${GS_DOWNLOAD_BASE_URL:-https://dl.google.com/go}/go${go_version}.linux-${arch}.tar.gz"; then
        orb_die "Could not download Go ${go_version} (${arch}), which builds ${TOOL_NAME}. Re-run the job if the download host was failing."
    fi
    actual=$(sha512sum "${archive}" | awk '{ print $1 }')
    if [[ "${actual}" != "${expected}" ]]; then
        orb_die "The Go ${go_version} (${arch}) download does not match this orb's checksum, so ${TOOL_NAME} was not built." \
            "Expected ${expected}, got ${actual}."
    fi
    orb_info "Go ${go_version} (${arch}) matches its SHA-512 checksum."
    if ! tar -xzf "${archive}" -o -C "${dir}" 2> "${dir}/tar.log"; then
        orb_die "Could not extract Go ${go_version}: $(head -c 300 "${dir}/tar.log")"
    fi
    rm -f "${archive}"
}

# gs_build VERSION ARCH GO DIR: builds GS_BUILD_PACKAGE at VERSION for ARCH
# with the go binary GO, working in DIR, and sets GS_BUILT_FILE to the
# binary. Go's output goes to DIR/build.log. Every setting that shapes the
# binary is pinned here, so Go settings in the job's environment can't change
# it. The download settings (GOPROXY, GOSUMDB, GOPRIVATE and the like) are
# left as the job sets them, for jobs behind a module proxy: the checksum
# check covers whatever they fetch.
gs_build() {
    local version=$1 arch=$2 go=$3 dir=$4 host_arch
    local -a go_env
    mkdir -p "${dir}/gopath" "${dir}/gocache" "${dir}/config"
    go_env=(env -u GOROOT -u GOEXPERIMENT -u GODEBUG -u GOROOT_FINAL -u GOCACHEPROG -u GOTOOLDIR
        GOPATH="${dir}/gopath" GOMODCACHE="${dir}/gopath/pkg/mod" GOCACHE="${dir}/gocache"
        GOBIN="" GOENV=off GOWORK=off GOTOOLCHAIN=local XDG_CONFIG_HOME="${dir}/config"
        GOFLAGS="-trimpath -modcacherw" CGO_ENABLED=0 GOOS=linux GOARCH="${arch}" GOAMD64=v1 GOARM64=v8.0
        GOFIPS140=off)
    if ! "${go_env[@]}" "${go}" install "${GS_BUILD_PACKAGE}@v${version}" > "${dir}/build.log" 2>&1; then
        return 1
    fi
    # go install puts a binary built for another architecture in a
    # subdirectory named after it.
    host_arch=$("${go_env[@]}" "${go}" env GOHOSTARCH)
    GS_BUILT_FILE="${dir}/gopath/bin/${TOOL_BINARY}"
    if [[ "${host_arch}" != "${arch}" ]]; then
        GS_BUILT_FILE="${dir}/gopath/bin/linux_${arch}/${TOOL_BINARY}"
    fi
    [[ -f "${GS_BUILT_FILE}" ]]
}

# gs_build_verified GO DIR: builds the tool with the go binary GO in DIR, and
# copies it to GS_BINARY_FILE when it is the binary the checksum table pins
# (or, without a checksum, when the build worked). Returns 1 when the build
# fails, showing Go's output, and 2 when the binary doesn't match.
gs_build_verified() {
    if ! gs_build "${ORB_VERSION}" "${ORB_ARCH}" "$1" "$2"; then
        orb_warn "The last lines of the Go build:"
        tail -n 40 "$2/build.log" | sed 's/^/  /' >&2
        return 1
    fi
    if ! cp "${GS_BUILT_FILE}" "${GS_BINARY_FILE}" || [[ ! -s "${GS_BINARY_FILE}" ]]; then
        orb_die "The ${TOOL_NAME} ${ORB_VERSION} build produced no binary."
    fi
    orb_verify "${GS_BINARY_FILE}" || return 2
}

# gs_install_source_built: installs a tool that publishes no release
# binaries. Go builds are reproducible: the same source, Go release and
# settings give the same bytes on any machine, so the checksum table pins the
# binary that GS_BUILD_GO_VERSION builds, and the source comes through the
# job's module proxy, checked against Go's public checksum database. A
# verified binary comes from the cache when there is one; a cached binary
# that fails verification is discarded and built again, like a cached
# download. The job's go builds it when it is the pinned Go release, which
# saves downloading one; when its binary doesn't match (a Go built
# differently, as a Linux distribution's can be), the pinned release is
# downloaded, checked against gs_go_sha512sums, and builds it again.
gs_install_source_built() {
    local job_go="" rc=0
    GS_BINARY_FILE="${ORB_WORK_DIR}/${ORB_ASSET_NAME}"
    gs_download_base_url https://dl.google.com/go
    if [[ "${ORB_CACHING}" == "true" && -n "${ORB_EXPECTED_SHA512}" && -f "${ORB_CACHE_FILE}" ]]; then
        if cp "${ORB_CACHE_FILE}" "${GS_BINARY_FILE}" && orb_info "Using ${TOOL_NAME} ${ORB_VERSION} from the cache." \
            && orb_verify "${GS_BINARY_FILE}"; then
            orb_install_file "${GS_BINARY_FILE}" "${ORB_INSTALL_PATH}/${TOOL_BINARY}"
            gs_install_record source-built
            return 0
        fi
        orb_warn "The cached ${TOOL_NAME} ${ORB_VERSION} could not be read or failed verification. Discarding it and building it again."
        orb_warn "A saved cache can't be replaced, so later jobs will do the same until it expires." \
            "Set caching to false to skip it until then."
        rm -f "${ORB_CACHE_FILE}" 2> /dev/null || true
    fi

    orb_require_tools sha512sum tar gzip
    if job_go=$(command -v go) && [[ "$(env -u GOROOT GOTOOLCHAIN=local GOENV=off "${job_go}" env GOVERSION 2> /dev/null)" == "go${GS_BUILD_GO_VERSION}" ]]; then
        orb_info "Building ${TOOL_NAME} ${ORB_VERSION} with this job's Go ${GS_BUILD_GO_VERSION} (${job_go})..."
        gs_build_verified "${job_go}" "${ORB_WORK_DIR}/job-build" || rc=$?
        if [[ "${rc}" -eq 0 ]]; then
            orb_store_cache "${GS_BINARY_FILE}"
            orb_install_file "${GS_BINARY_FILE}" "${ORB_INSTALL_PATH}/${TOOL_BINARY}"
            gs_install_record source-built
            return 0
        fi
        orb_warn "This job's Go did not build the binary this orb's checksum table pins. Building it with the Go ${GS_BUILD_GO_VERSION} release instead."
    fi
    orb_info "Building ${TOOL_NAME} ${ORB_VERSION} from source with Go ${GS_BUILD_GO_VERSION}. With caching on, later jobs install" \
        "the verified binary from the cache instead."
    gs_fetch_go "${GS_BUILD_GO_VERSION}" "${ORB_ARCH}" "${ORB_WORK_DIR}/build"
    rc=0
    gs_build_verified "${ORB_WORK_DIR}/build/go/bin/go" "${ORB_WORK_DIR}/build" || rc=$?
    case "${rc}" in
        0) ;;
        1)
            orb_die "Could not build ${TOOL_NAME} ${ORB_VERSION}. If the log above shows a network error, re-run the job;" \
                "if it says the version is unknown, check that ${GS_BUILD_PACKAGE} has that version."
            ;;
        *) orb_die "The ${TOOL_NAME} ${ORB_VERSION} build is not the binary this orb's checksum table pins for it, so it was not installed." ;;
    esac
    orb_store_cache "${GS_BINARY_FILE}"
    orb_install_file "${GS_BINARY_FILE}" "${ORB_INSTALL_PATH}/${TOOL_BINARY}"
    gs_install_record source-built
}
# <<< go-security-orb install helpers <<<

# gs_go_tree DIR: whether DIR is a Go installation this script may replace:
# one with the VERSION file and bin/go every Go release archive has.
gs_go_tree() {
    [[ -f "$1/VERSION" && -f "$1/bin/go" ]]
}

# Installs the verified release archive as the Go installation in
# install_path. The archive is unpacked in a private directory beside
# install_path, and its go binary run once (orb_smoke_test), before it takes
# install_path's place, so an archive that can't run here leaves an existing
# installation in place. install_path must be missing, hold no files (only
# empty directories, if any), or be an earlier Go installation, so that a
# mistyped install_path such as $HOME is never moved aside and deleted.
tool_install() {
    local dir=${ORB_INSTALL_PATH%/*} name=${ORB_INSTALL_PATH##*/} staging="" goroot
    gs_download_base_url https://dl.google.com/go
    ORB_BIN_DIR="${ORB_INSTALL_PATH}/bin"
    if [[ -L "${ORB_INSTALL_PATH}" ]]; then
        orb_die "install_path ${ORB_INSTALL_PATH} is a symbolic link. Point install_path at the directory itself."
    fi
    if [[ -e "${ORB_INSTALL_PATH}" && ! -d "${ORB_INSTALL_PATH}" ]]; then
        orb_die "install_path ${ORB_INSTALL_PATH} exists and is not a directory."
    fi
    # Empty directories hold nothing to lose, such as a bin directory put on
    # the PATH before the install.
    if [[ -d "${ORB_INSTALL_PATH}" ]] && ! gs_go_tree "${ORB_INSTALL_PATH}" \
        && [[ -n "$(find "${ORB_INSTALL_PATH}" -mindepth 1 ! -type d -print -quit 2>&1)" ]]; then
        orb_die "install_path ${ORB_INSTALL_PATH} holds something other than a Go installation, which this install would replace." \
            "Choose a new or empty directory, or one an earlier install_go installed into."
    fi
    orb_require_tools tar gzip
    orb_fetch_verified
    dir=${dir:-/}
    if ! mkdir -p "${dir}"; then
        orb_die "Could not create ${dir}. Choose an install_path this job's user can write to without root."
    fi
    if staging=$(mktemp -d "${dir%/}/.${name}.XXXXXX"); then
        ORB_CLEANUP+=("${staging}")
    else
        orb_die "Could not install Go to ${ORB_INSTALL_PATH}. Choose an install_path this job's user can write to without root."
    fi
    # -o (don't restore the archive's owner) is spelled the same in GNU tar,
    # bsdtar and BusyBox tar.
    if ! tar -xzf "${ORB_VERIFIED_FILE}" -o -C "${staging}" 2> "${ORB_WORK_DIR}/tar.log"; then
        orb_die "Could not unpack ${ORB_ASSET_NAME}: $(head -c 300 "${ORB_WORK_DIR}/tar.log")"
    fi
    if [[ -L "${staging}/go" ]] || ! gs_go_tree "${staging}/go" || [[ -L "${staging}/go/bin/go" ]]; then
        orb_die "${ORB_ASSET_NAME} does not hold a Go installation (go/VERSION and go/bin/go)."
    fi
    orb_smoke_test "${staging}/go/bin/go"
    # The earlier installation moves into the staging directory, which the
    # EXIT trap removes, and comes back if the new one can't take its place.
    if [[ -d "${ORB_INSTALL_PATH}" ]] && ! mv "${ORB_INSTALL_PATH}" "${staging}/previous"; then
        orb_die "Could not replace ${ORB_INSTALL_PATH}. Choose an install_path this job's user can write to without root."
    fi
    if ! mv "${staging}/go" "${ORB_INSTALL_PATH}"; then
        if [[ -d "${staging}/previous" ]]; then
            mv "${staging}/previous" "${ORB_INSTALL_PATH}" || true
        fi
        orb_die "Could not install Go to ${ORB_INSTALL_PATH}. Choose an install_path this job's user can write to without root."
    fi
    gs_install_record prebuilt
    # A GOROOT set in the environment would make the new go read another
    # installation's standard library, so later steps get this one.
    goroot=${GOROOT:-}
    if [[ -n "${goroot}" && "${goroot%/}" != "${ORB_INSTALL_PATH}" ]]; then
        if [[ -n "${BASH_ENV:-}" ]]; then
            printf 'export GOROOT=%q\n' "${ORB_INSTALL_PATH}" >> "${BASH_ENV}"
            orb_info "GOROOT was ${goroot}; set it to ${ORB_INSTALL_PATH} for later steps."
        else
            orb_warn "GOROOT is ${goroot}, so the go installed here would use that installation's standard library. Unset GOROOT."
        fi
    fi
}
# <<< tool definition <<<

# >>> shared install logic >>>
# Everything from here to the end marker is identical in the install.sh of
# every juburr orb, so change it in all of them together. Tool-specific
# behavior belongs in the tool definition above.
#
# Parameters arrive as PARAM_VERSION, PARAM_VERIFY_CHECKSUMS,
# PARAM_INSTALL_PATH and PARAM_CACHING. The checksum table (sha512sums) is
# defined after this block.

orb_info() { printf '%s\n' "$*"; }
orb_warn() { printf 'WARN: %s\n' "$*" >&2; }
orb_die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

# Expands environment variables in a parameter value. The value is piped in
# on stdin: passed as an argument, a value starting with "-" would be parsed
# as a flag. Without the CircleCI CLI (local runs), the value is used as is.
orb_subst() {
    if command -v circleci > /dev/null 2>&1; then
        printf '%s' "$1" | circleci env subst
    else
        printf '%s\n' "$1"
    fi
}

# CircleCI passes boolean parameters as 1/0; local callers use true/false.
orb_bool() {
    case "$2" in
        1 | true) echo true ;;
        0 | false) echo false ;;
        *) orb_die "${1} must be true or false, not '${2}'." ;;
    esac
}

# Reads an absolute directory parameter: NAME VALUE HOME_SUBDIR. Environment
# variables and a leading ~/ are expanded, trailing slashes are removed, and
# an empty value means $HOME/HOME_SUBDIR.
orb_dir_param() {
    local value
    value=$(orb_subst "$2")
    if [[ -z "${value}" || "${value}" == \~ || "${value}" == \~/* ]]; then
        if [[ -z "${HOME:-}" ]]; then
            orb_die "HOME is not set, so ${1} has no default. Set ${1} to an absolute path."
        fi
        if [[ -z "${value}" ]]; then
            value="${HOME}/${3}"
        else
            value="${HOME}${value:1}"
        fi
    fi
    while [[ "${value}" == */ && "${value}" != "/" ]]; do
        value=${value%/}
    done
    if [[ "${value}" != /* ]]; then
        orb_die "${1} must be an absolute path, not '${value}'."
    fi
    # The directory may be added to the PATH, where ":" separates entries.
    if [[ "${value}" == *:* ]]; then
        orb_die "${1} can't contain ':', which separates PATH entries: '${value}'."
    fi
    printf '%s\n' "${value}"
}

orb_require_tools() {
    local tool package
    for tool in "$@"; do
        if ! command -v "${tool}" > /dev/null 2>&1; then
            case "${tool}" in
                tar | gzip) package=${tool} ;;
                *) package=coreutils ;;
            esac
            orb_die "Installing ${TOOL_NAME} needs '${tool}', which is not available. Install it in an earlier step," \
                "for example with 'microdnf install -y ${package}' on Red Hat UBI images."
        fi
    done
}

# Newest version in the checksum table.
orb_latest_version() {
    local key
    for key in "${!sha512sums[@]}"; do
        printf '%s\n' "${key%/*}"
    done | sort -uV | tail -n 1
}

orb_detect_arch() {
    local os machine
    os=$(uname -s)
    machine=$(uname -m)
    if [[ "${os}" != "Linux" ]]; then
        orb_die "This orb installs Linux builds of ${TOOL_NAME}, but this machine runs ${os}."
    fi
    if [[ "${TOOL_ARCHES}" == "noarch" ]]; then
        ORB_ARCH="noarch"
        orb_info "  platform:         noarch (${os} ${machine})"
        return 0
    fi
    case "${machine}" in
        x86_64 | amd64) ORB_ARCH="amd64" ;;
        aarch64 | arm64) ORB_ARCH="arm64" ;;
        *) orb_die "Unsupported CPU architecture '${machine}'. Supported: x86_64 (amd64), aarch64/arm64 (arm64)." ;;
    esac
    if [[ " ${TOOL_ARCHES} " != *" ${ORB_ARCH} "* ]]; then
        orb_die "${TOOL_NAME} is not published for ${ORB_ARCH}. Supported: ${TOOL_ARCHES}."
    fi
    orb_info "  platform:         linux/${ORB_ARCH} (uname -m: ${machine})"
}

# Decides how this install is verified, before anything is downloaded.
orb_lookup_checksum() {
    ORB_EXPECTED_SHA512=${sha512sums["${ORB_VERSION}/${ORB_ARCH}"]:-}
    if [[ -n "${ORB_EXPECTED_SHA512}" && ! "${ORB_EXPECTED_SHA512}" =~ ^[0-9a-f]{128}$ ]]; then
        orb_die "The checksum table entry for ${ORB_VERSION}/${ORB_ARCH} is malformed."
    fi
    if [[ "${ORB_VERIFY_CHECKSUMS}" == "false" ]]; then
        orb_warn "verify_checksums is false, so ${TOOL_NAME} will be installed WITHOUT checksum verification. This is not recommended."
        ORB_EXPECTED_SHA512=""
    elif [[ -z "${ORB_EXPECTED_SHA512}" ]]; then
        if [[ "${ORB_VERIFY_CHECKSUMS}" == "known_versions" ]]; then
            orb_warn "This orb has no checksum for ${TOOL_NAME} ${ORB_VERSION} (${ORB_ARCH}), and verify_checksums is known_versions."
            orb_warn "Installing an UNVERIFIED binary. Upgrade this orb, or submit a PR with the checksum."
        else
            orb_die "This orb has no checksum for ${TOOL_NAME} ${ORB_VERSION} (${ORB_ARCH}), so it cannot be verified (verify_checksums: strict)." \
                "Use a version this orb lists (the newest is $(orb_latest_version)), upgrade the orb, or opt out with verify_checksums: known_versions."
        fi
    fi
}

orb_init() {
    ORB_VERSION=$(orb_subst "${PARAM_VERSION:-}")
    ORB_VERSION=${ORB_VERSION#v}
    # The version is part of the download URL, so only release versions pass.
    if [[ ! "${ORB_VERSION}" =~ ^[0-9]+(\.[0-9]+){1,2}(-[0-9A-Za-z][0-9A-Za-z.-]*)?$ ]]; then
        orb_die "Invalid ${TOOL_NAME} version '${ORB_VERSION}'. Expected a release version such as $(orb_latest_version)."
    fi
    ORB_VERIFY_CHECKSUMS=${PARAM_VERIFY_CHECKSUMS:-strict}
    case "${ORB_VERIFY_CHECKSUMS}" in
        strict | known_versions | false) ;;
        *) orb_die "verify_checksums must be strict, known_versions or false, not '${ORB_VERIFY_CHECKSUMS}'." ;;
    esac
    ORB_INSTALL_PATH=$(orb_dir_param install_path "${PARAM_INSTALL_PATH:-}" "${TOOL_DEFAULT_INSTALL_DIR}")
    ORB_BIN_DIR=${ORB_INSTALL_PATH}
    ORB_CACHING=$(orb_bool caching "${PARAM_CACHING:-false}")

    orb_info "Installing ${TOOL_NAME} ${ORB_VERSION}"
    orb_info "  install_path:     ${ORB_INSTALL_PATH}"
    orb_info "  verify_checksums: ${ORB_VERIFY_CHECKSUMS}"
    orb_info "  caching:          ${ORB_CACHING}"
    orb_detect_arch
    orb_lookup_checksum

    ORB_ASSET_NAME=$(tool_asset_name "${ORB_VERSION}" "${ORB_ARCH}")
    ORB_ARCHIVE_MEMBER=$(tool_archive_member "${ORB_VERSION}" "${ORB_ARCH}")
    orb_require_tools mktemp
    # Only verification needs sha512sum, so the opt-out modes run without it.
    if [[ -n "${ORB_EXPECTED_SHA512}" ]]; then
        orb_require_tools sha512sum
    fi
    if [[ -n "${ORB_ARCHIVE_MEMBER}" ]]; then
        orb_require_tools tar gzip
    fi

    ORB_WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/${ORB_NAME}.XXXXXX")
    ORB_CLEANUP=("${ORB_WORK_DIR}")
    trap 'rm -rf "${ORB_CLEANUP[@]}"' EXIT

    # Restored and saved by install.yml. Files are stored by version and
    # architecture, so a cache restored for another version is never used.
    # Nothing is created here unless a verified asset is stored, so an
    # unverified install leaves nothing for save_cache to save.
    ORB_CACHE_FILE=""
    if [[ "${ORB_CACHING}" == "true" && -z "${HOME:-}" ]]; then
        orb_warn "HOME is not set, so the cache is not used."
        ORB_CACHING=false
    elif [[ "${ORB_CACHING}" == "true" ]]; then
        ORB_CACHE_FILE="${HOME}/.cache/${ORB_NAME}/${ORB_VERSION}/${ORB_ARCH}/${ORB_ASSET_NAME}"
    fi
}

# orb_download DEST URL...: downloads the first URL that works to DEST.
# Transient failures are retried with backoff; a 404 moves on to the next URL.
orb_download() {
    local dest=$1 url help option attempt rc
    local -a fetch
    shift
    if command -v curl > /dev/null 2>&1; then
        # A stalled transfer counts as a failure and is retried.
        fetch=(curl -fsSL --proto '=https' --proto-redir '=https' --retry 8 --retry-max-time 300
            --connect-timeout 30 --speed-limit 1 --speed-time 60)
        # curl added --retry-connrefused in 7.52, and lists it under --help all
        # since 7.73. The output is captured, not piped, so curl can't hit a
        # closed pipe.
        help=$({ curl --help all || curl --help; } 2>&1) || true
        if [[ "${help}" == *--retry-connrefused* ]]; then
            fetch+=(--retry-connrefused)
        fi
        fetch+=(-o)
    elif command -v wget > /dev/null 2>&1; then
        fetch=(wget -q)
        # Only the retry options this wget supports (BusyBox wget has none).
        help=$(wget --help 2>&1) || true
        for option in --tries=20 --waitretry=30 --retry-connrefused --timeout=60 --retry-on-http-error=429,500,502,503,504; do
            if [[ "${help}" == *"${option%%=*}"* ]]; then
                fetch+=("${option}")
            fi
        done
        fetch+=(-O)
    else
        orb_die "Neither curl nor wget is available. Install one of them in an earlier step."
    fi
    for url in "$@"; do
        # curl retries timeouts and HTTP 5xx itself, but not a connection
        # dropped partway through, so that gets two more attempts here. An
        # HTTP error such as a 404 (curl exit code 22) moves on to the next
        # URL. wget retries both itself.
        for attempt in 1 2 3; do
            orb_info "Downloading ${url}"
            rc=0
            "${fetch[@]}" "${dest}.partial" "${url}" || rc=$?
            if [[ "${rc}" -eq 0 ]]; then
                mv -f "${dest}.partial" "${dest}"
                return 0
            fi
            if [[ "${fetch[0]}" != "curl" || "${rc}" -eq 22 || "${attempt}" -eq 3 ]]; then
                break
            fi
            orb_warn "The download failed (curl exit code ${rc}). Retrying in $((attempt * 10)) seconds."
            sleep $((attempt * 10))
        done
        orb_warn "Could not download ${url}."
    done
    rm -f "${dest}.partial"
    return 1
}

# orb_extract ASSET MEMBER: sets ORB_VERIFIED_FILE to the file the checksum
# table describes, which is MEMBER extracted from ASSET, or ASSET itself
# when MEMBER is empty. An empty file is refused, which matters when there
# is no checksum to catch it.
orb_extract() {
    local asset=$1 member=$2 dir
    ORB_VERIFIED_FILE=${asset}
    if [[ -n "${member}" ]]; then
        dir="${ORB_WORK_DIR}/extract"
        rm -rf "${dir}"
        mkdir "${dir}"
        # -o (don't restore the archive's owner) is spelled the same in GNU
        # tar, bsdtar and BusyBox tar, even one built without long options.
        if ! tar -xzf "${asset}" -o -C "${dir}" -- "${member}" 2> "${ORB_WORK_DIR}/tar.log"; then
            orb_warn "Could not extract ${member} from ${ORB_ASSET_NAME}: $(head -c 300 "${ORB_WORK_DIR}/tar.log")"
            return 1
        fi
        ORB_VERIFIED_FILE="${dir}/${member}"
        if [[ ! -f "${ORB_VERIFIED_FILE}" || -L "${ORB_VERIFIED_FILE}" ]]; then
            orb_warn "${member} in ${ORB_ASSET_NAME} is not a regular file."
            return 1
        fi
    fi
    if [[ ! -s "${ORB_VERIFIED_FILE}" ]]; then
        orb_warn "${ORB_VERIFIED_FILE##*/} is empty."
        return 1
    fi
}

# orb_verify FILE: checks FILE against the checksum table, when verifying.
orb_verify() {
    local actual
    if [[ -z "${ORB_EXPECTED_SHA512}" ]]; then
        return 0
    fi
    actual=$(sha512sum "$1" | awk '{ print $1 }')
    orb_info "Verifying the SHA-512 checksum of ${1##*/}..."
    orb_info "  expected: ${ORB_EXPECTED_SHA512}"
    orb_info "  actual:   ${actual}"
    if [[ "${actual}" != "${ORB_EXPECTED_SHA512}" ]]; then
        orb_warn "Checksum verification failed."
        return 1
    fi
    orb_info "Checksum verification passed."
}

# orb_temp_beside FILE: sets ORB_TEMP to a new, empty file in FILE's
# directory, to be renamed over FILE, and registers it for cleanup. mktemp
# creates it exclusively, so a file planted in a shared directory isn't
# written through.
orb_temp_beside() {
    ORB_TEMP=$(mktemp "${1%/*}/.${1##*/}.XXXXXX") || return 1
    ORB_CLEANUP+=("${ORB_TEMP}")
}

# Saves a downloaded asset for save_cache. Only verified assets are kept, so
# the cache never supplies a file the checksum table didn't vouch for.
orb_store_cache() {
    if [[ "${ORB_CACHING}" != "true" ]]; then
        return 0
    fi
    if [[ -z "${ORB_EXPECTED_SHA512}" ]]; then
        orb_info "Not caching ${ORB_ASSET_NAME}, since it was not verified."
        return 0
    fi
    if mkdir -p "${ORB_CACHE_FILE%/*}" && orb_temp_beside "${ORB_CACHE_FILE}" \
        && cp "$1" "${ORB_TEMP}" && mv -f "${ORB_TEMP}" "${ORB_CACHE_FILE}"; then
        return 0
    fi
    orb_warn "Could not save ${ORB_ASSET_NAME} to ${ORB_CACHE_FILE%/*}; continuing without the cache."
}

# Fetches the release asset, from the cache when possible, and verifies it.
# Leaves the verified file in ORB_VERIFIED_FILE. A cached asset that fails
# verification is discarded and downloaded again. The cache is only read
# when there is a checksum to verify the cached asset against.
orb_fetch_verified() {
    local asset="${ORB_WORK_DIR}/${ORB_ASSET_NAME}" use_cache=${ORB_CACHING} from_cache urls
    if [[ -z "${ORB_EXPECTED_SHA512}" ]]; then
        use_cache=false
    fi
    while true; do
        from_cache=false
        rm -f "${asset}"
        if [[ "${use_cache}" == "true" && -f "${ORB_CACHE_FILE}" ]]; then
            if ! cp "${ORB_CACHE_FILE}" "${asset}"; then
                orb_warn "Could not read the cached ${ORB_ASSET_NAME}. Downloading it instead."
                use_cache=false
                continue
            fi
            orb_info "Using ${ORB_ASSET_NAME} from the cache."
            from_cache=true
        else
            mapfile -t urls < <(tool_asset_urls "${ORB_VERSION}" "${ORB_ARCH}" "${ORB_ASSET_NAME}")
            if ! orb_download "${asset}" "${urls[@]}"; then
                orb_die "Could not download ${TOOL_NAME} ${ORB_VERSION} (${ORB_ARCH}). Check that this version" \
                    "was published for ${ORB_ARCH}, or re-run the job if the download host was failing."
            fi
        fi
        if orb_extract "${asset}" "${ORB_ARCHIVE_MEMBER}" && orb_verify "${ORB_VERIFIED_FILE}"; then
            break
        fi
        if [[ "${from_cache}" == "true" ]]; then
            orb_warn "The cached ${ORB_ASSET_NAME} failed verification. Discarding it and downloading it again."
            orb_warn "CircleCI can't replace a saved cache, so later jobs will do the same until it expires." \
                "Set caching to false to skip it until then."
            # Like saving it, removing it is best-effort: a read-only cache
            # directory only means the download isn't cached.
            rm -f "${ORB_CACHE_FILE}" 2> /dev/null || true
            use_cache=false
            continue
        fi
        orb_die "The ${TOOL_NAME} ${ORB_VERSION} (${ORB_ARCH}) download was rejected and not installed."
    done
    if [[ "${from_cache}" == "false" ]]; then
        orb_store_cache "${asset}"
    fi
}

# orb_install_file SOURCE DEST: installs SOURCE as the executable DEST. The
# file is staged under DEST's name in a private directory beside DEST and run
# once (orb_smoke_test) before a single rename replaces DEST, so a binary
# that can't run here leaves an existing install in place.
orb_install_file() {
    local dir=${2%/*} name=${2##*/} staging=""
    if ! mkdir -p "${dir}"; then
        orb_die "Could not create ${dir}. Choose an install_path this job's user can write to without root."
    fi
    if [[ -d "$2" ]]; then
        orb_die "Cannot install to $2, which is a directory."
    fi
    if staging=$(mktemp -d "${dir}/.${name}.XXXXXX"); then
        ORB_CLEANUP+=("${staging}")
    fi
    if [[ -z "${staging}" ]] || ! { cp "$1" "${staging}/${name}" && chmod 0755 "${staging}/${name}"; }; then
        orb_die "Could not install ${TOOL_BINARY} to ${dir}. Choose an install_path this job's user can write to without root."
    fi
    orb_smoke_test "${staging}/${name}"
    if ! mv -f "${staging}/${name}" "$2"; then
        orb_die "Could not install ${TOOL_BINARY} to ${dir}. Choose an install_path this job's user can write to without root."
    fi
}

# The default for tools that ship a single binary.
orb_install_binary() {
    orb_fetch_verified
    orb_install_file "${ORB_VERIFIED_FILE}" "${ORB_INSTALL_PATH}/${TOOL_BINARY}"
}

# Adds DIR to the PATH of later steps, unless it is already there.
orb_export_path() {
    local found
    if [[ ":${PATH}:" == *":$1:"* ]]; then
        # Later steps see this PATH, so an earlier copy of the binary wins.
        # -ef accepts the same file reached through a symlinked directory.
        found=$(command -v "${TOOL_BINARY}" || true)
        if [[ -n "${found}" && ! "${found}" -ef "$1/${TOOL_BINARY}" ]]; then
            orb_warn "${found} comes before $1 on the PATH, so later steps will run it instead of the ${TOOL_BINARY} installed here."
        fi
        return 0
    fi
    if [[ -n "${BASH_ENV:-}" ]]; then
        # ${PATH} is expanded when BASH_ENV is sourced, not now.
        # shellcheck disable=SC2016
        printf 'export PATH=%q:"${PATH}"\n' "$1" >> "${BASH_ENV}"
        orb_info "Added $1 to the PATH for later steps."
    else
        orb_warn "$1 is not on the PATH. Add it to run ${TOOL_BINARY} by name."
    fi
}

# orb_smoke_test FILE: runs the new binary once, which catches a build that
# can't run here: one for another architecture (exit code 126), or one that
# crashes, such as with SIGILL on a CPU it doesn't support. tool_version
# needs no network, so any failure means the binary doesn't work.
orb_smoke_test() {
    local output rc=0 line
    if ! declare -F tool_version > /dev/null; then
        return 0
    fi
    output=$(tool_version "$1" 2>&1) || rc=$?
    if [[ "${rc}" -ne 0 ]]; then
        orb_die "The downloaded ${TOOL_BINARY} cannot run on this machine: asking it for its version" \
            "exited with code ${rc}. ${output}"
    fi
    orb_info "${TOOL_BINARY} reports:"
    while IFS= read -r line; do
        orb_info "  ${line}"
    done <<< "${output}"
}

orb_install_main() {
    orb_init
    if declare -F tool_install > /dev/null; then
        tool_install
    else
        orb_install_binary
    fi
    orb_export_path "${ORB_BIN_DIR}"
    orb_info "Installed ${TOOL_NAME} ${ORB_VERSION} to ${ORB_INSTALL_PATH}."
}
# <<< shared install logic <<<

# >>> checksum table >>>
# SHA-512 checksums keyed "<version>/<arch>", newest release first, where arch
# is amd64, arm64, or noarch for a release that is the same everywhere.
# tool_archive_member says which file each checksum covers.
declare -A sha512sums=(
    ["1.27.3/amd64"]="1270262f20a6ef23f5901c146c5e2a18225be92ccf63d03543cdb4ff17f1165c2e7ead97b7164f50ced861f8cbef93f76a7552614a257d66e5d1e9357c1b34e0"
    ["1.27.3/arm64"]="75caaff42ec918db37d087d397270b63c40191065abb56db15564e246a4728667d54dd9f1432dfd38e5db490a4bf1737d86f4ca920517007c2c97810dc06b7a2"
    ["1.27.2/amd64"]="964462296f6a256e9af4c58343e0b52cb33092f1aceaee25249aa21818e6551b728e4ae7588f45532268c31c29976a97642698484c3323dc4d554f89a98006a9"
    ["1.27.2/arm64"]="c7f7b7ffd2d3bb8707d01bd68b13a6b727124d60cb0a4bb194cf5adfad6d1aea804732b70b925d6af234e38a2c7a7fe6d27110d101b9c69edac1fc279eb9782d"
    ["1.27.1/amd64"]="3f63b31c8675e10535d132138176a9606f9008690e73e064dbee5b0c852588e9292732c1fcf79ec9e9b369a2b053a77123eef609e98905f8062cafc90f541735"
    ["1.27.1/arm64"]="d3f19c6b9554f076c481bf58f86483df996087976307fe1e5e59b937a7c0d18f7852f9dad2bdb388aafa3a7075d1d4f349faa23b9ed94b62e3abaf7537ad3a0b"
    ["1.27.0/amd64"]="986a27008f5e4b19658e289bb2d6340ff353eff3a3a43d6c8696c17b5b6a7d00f9064cfabcacb4bb3bcef6f6814a0de07ea0842896b17acf938728760054500a"
    ["1.27.0/arm64"]="41bba489cea189abe1c19ff1bb1306712fa02b5ccd51ec59c6e2119f11ee22ed3876a656e26ac0013ddb09da35aa8eb8e3288c63cbe4059cbf37c51629e8fa5b"
    ["1.26.10/amd64"]="fff91a8d62212b2b8f66f2a7029173eb6ce6e13767f04e7ec321cb1682d16b843fc3499370c56b385c47303b65f4f6a64b4a745adb3eb4adde2438284fa873b7"
    ["1.26.10/arm64"]="7d6aa72a27027fd032189d651354a93fad837d4ca3bae032e067d55e2d1ee78b3ddae7588324c93b367f4167182addd482632fd42b77780135707f6e0f669c1d"
    ["1.26.9/amd64"]="460fd028b1e31c71153f8fb6d3e8695cf7bc3b0e6ac60146aa3739d00e0899da5e77de7eea420d70a0ea8becf43cb9db63ffaedb1cf68b293d12d7d6dfdd9ab9"
    ["1.26.9/arm64"]="6f4539d68240d5f72cbdb5c1f57b77c5f1766ce970860bdacaefef13009c48ee47bb290c41d2ed76c1b097d28a46603cdc8e9ade92642f1bfa78dbee3c3d8d14"
    ["1.26.8/amd64"]="bfed9e8e85e05c5bedf2b853062b879a223db41e63085b74ffdf2a3b4f816032d4df3816fcbf7e484e2a34782803f39531705dc873bbd9dc7f3031bc4edadcdf"
    ["1.26.8/arm64"]="9b77bfe592785400a65ff3abd1b9f9a2ff440db7b37ef34ee009a94bf41b88f3801ec4227ffc55316001379123c7cf3bd2ce3226a317a6ba86f68d8d178193d6"
    ["1.26.7/amd64"]="d3bbe7f22f8334c30255dbe4e593b4cd68c30bee1cc734a8f86615b16544770d60b3212526386d1004fbd679db08201a1ed7b66fc426fba89caa633e71ddc78e"
    ["1.26.7/arm64"]="69478ce4d6e126e9f93a8cf3accf8d7b4e250a716c8f8656bc8d4921ee581d2cdab3b87d4cc1b63c312ace765d944c985bd753e9cdc796e4425bbca0634354c1"
    ["1.26.6/amd64"]="cf7e45e63e5d2c01169e96b1d9cad57f42e4e6a98cf04daeaa0fcc979f7fdd46b11fee691731b2f9447bd262329609c8e05b3cd2f84a73e7c98e5b7293712964"
    ["1.26.6/arm64"]="d8b1f699e2a0d9c4e1233b3f637230ffcfebacbc216847a08a83d2e09ad740cbe6871beceeb0d7c8c2ee49a57d8f7a44297208628a76f0b2c18f7e302d3963fe"
    ["1.26.5/amd64"]="03c09e3868bd195e670a869afb741d95765d2431d3a538ab452b3dac52c51902848663565b62da20ae28b0b2f538c8a52f4d1bea546ed125f1c76f5b6ca6299d"
    ["1.26.5/arm64"]="d250f0d6c697dfaeb66c77939a02ce3210fe633b43012a31b70d9256975f068a64c2d387ab741a8594830fd845b8d088853075a26f555a1427ddcb9c2a4c1c5b"
    ["1.26.4/amd64"]="823788a773ad531b035acfb42d2d0a5292608f6c561dfb48dcf4fffdc567bd8a9c426a87b96f234df74468aafd88729c2fbcb793d81efbe2b8bd687c5a474aa6"
    ["1.26.4/arm64"]="5097ed5fda2e6b1ce72d0207e4dedcf1891fb9b8e91ec6f5238b089ae78afa0d86c2d56fa12ced48b34c3be3ba7e4107b8311d55f75f130b416f091adfe86ac0"
    ["1.26.3/amd64"]="cc49ca9764b1dff5983d7635bc6e8f9fe71754bf48ec310a43512cef6103c4a88ed446e9b759742affa9bbcac507957fb9993011cb94343b88ba938c17632c28"
    ["1.26.3/arm64"]="443ebe1f87b426cf21954048d1fee8a122e3f082fb285eae3ef7ba8f793a8efcd5599f46f85777560f38de573011a6dba4a1a6effc457c4367f34d621a66f976"
    ["1.26.2/amd64"]="3ebd76820f842f34a2c1a6ce83a67ff0d406cbb0c7c5f412f0f7eefb211a8bbfcabf7a8dea8d2a6bf531e8b3a80cf52aa867564a7e7c93f89f201b5ba1ded18f"
    ["1.26.2/arm64"]="61a08880ad0f83f57c688f4e9d356c8a9a08ac749809004d768f65fd40b5c7d60e9ddd95eee805cc55b065351a9b0842f5807175bd7bfdf3f45643eead7d2d23"
    ["1.26.1/amd64"]="6d23a21dff22f7732cba03305efa158ae21432042b8e5c069567640cacdea507c7330c90e03c0bebb2c731f68035b67f0a753238131e3602c64eebeab6715d93"
    ["1.26.1/arm64"]="0f7f35f794f1d6c84eff1fa9635ecddba356688abe15dbbc5da6dc98b558f8b88502b8dfc7e7c7e1023abf92e0b9841ae01ded99e715aa58b5408b2db69a8185"
    ["1.26.0/amd64"]="025821d2896248483b72f3787f3c84aeceb900d95071c7d182c1a0752b72589cd1577a0aaf7d583692ca0b557eec69fb639f4f2db8d485bb0b961d3a7ac021d5"
    ["1.26.0/arm64"]="d13ddeb1370e3ff2eb329555ee8f410602f0dcddece352602b36c6f5363fba65c82e9e5ab08ada430c0bde281dc2d96e8b65bf5f695fd73d56e18534cc4b366b"
)
# <<< checksum table <<<

orb_install_main
