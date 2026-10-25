#!/bin/bash
#
# Prints checksum table entries for a go-licenses version, ready to paste into the
# sha512sums table in install.sh. A development helper: the orb never runs
# it.
#
#   src/install/go-licenses/install_hash.sh -v <version> [-a "<arch> ..."]
#   src/install/go-licenses/install_hash.sh -g <go version>
#
#   -v  builds go-licenses <version> the way the install command does, with
#       install.sh's gs_build and the Go release it pins
#       (GS_BUILD_GO_VERSION), and prints the SHA-512 of each binary
#   -a  architectures to build (default: every one install.sh supports);
#       the ones this machine doesn't run are cross-compiled
#   -g  prints gs_go_sha512sums entries for a Go release, for a change of
#       GS_BUILD_GO_VERSION, which also means generating every -v entry
#       again and bumping the cache key version in the install command
#
# go-licenses publishes no binaries, so unlike a release tool's install_hash.sh
# there is no release asset to check against what the project published. The
# build is anchored instead: the Go archive must match the SHA-256 that go.dev
# publishes for it (and, with -v, install.sh's gs_go_sha512sums), and the
# source and every module it uses must match Go's checksum database,
# sum.golang.org, a public log of the content of every module version.
# Modules come from proxy.golang.org with the checksum database on, whatever
# the environment says. Entries go to stdout and everything else to stderr,
# so the output can be pasted as is.

set -euo pipefail

# >>> source build install_hash logic >>>
# Identical in the install_hash.sh of every tool go-security-orb builds from
# source. The tool definition is read from install.sh.

hash_die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

hash_usage() {
    printf 'Usage: %s -v <version> [-a "<arch> ..."] | -g <go version>\n' "$0" >&2
    exit 1
}

# Loads install.sh's tool definition and shared functions, without its
# checksum table or main call, so the build here is the one install runs.
INSTALL_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/install.sh"
# shellcheck source=/dev/null
source <(sed -n '/^# >>> tool definition >>>$/,/^# <<< shared install logic <<<$/p' "${INSTALL_SCRIPT}")
if ! declare -F gs_build > /dev/null || [[ -z "${GS_BUILD_PACKAGE:-}" ]]; then
    hash_die "Could not load the tool definition from ${INSTALL_SCRIPT}."
fi

VERSION=""
ARCHES=""
GO_VERSION=""
while getopts ':v:a:g:' flag; do
    case "${flag}" in
        v) VERSION=${OPTARG#v} ;;
        a) ARCHES=${OPTARG} ;;
        g) GO_VERSION=${OPTARG#go} ;;
        *) hash_usage ;;
    esac
done
if [[ -n "${VERSION}" && -n "${GO_VERSION}" ]] || [[ -z "${VERSION}" && -z "${GO_VERSION}" ]]; then
    hash_usage
fi
ARCHES=${ARCHES:-${TOOL_ARCHES}}
read -r -a ARCH_LIST <<< "${ARCHES}"
if [[ "${#ARCH_LIST[@]}" -eq 0 ]]; then
    hash_die "-a names no architecture. Supported: ${TOOL_ARCHES}."
fi
for arch in "${ARCH_LIST[@]}"; do
    if [[ " ${TOOL_ARCHES} " != *" ${arch} "* ]]; then
        hash_die "Unsupported architecture '${arch}'. Supported: ${TOOL_ARCHES}."
    fi
done
for tool in curl jq sha256sum sha512sum tar gzip; do
    command -v "${tool}" > /dev/null || hash_die "${tool} is required."
done

HASH_WORK_DIR=$(mktemp -d)
trap 'rm -rf "${HASH_WORK_DIR}"' EXIT

GO_RELEASES="${HASH_WORK_DIR}/go-releases.json"
curl -fsSL --proto '=https' --retry 5 -o "${GO_RELEASES}" 'https://go.dev/dl/?mode=json&include=all' \
    || hash_die "Could not download the list of Go releases from go.dev."

# go_published_sha256 GO_VERSION FILE: the SHA-256 go.dev publishes for FILE.
go_published_sha256() {
    jq -r --arg v "go$1" --arg f "$2" \
        '.[] | select(.version == $v) | .files[] | select(.filename == $f and .kind == "archive") | .sha256' \
        "${GO_RELEASES}"
}

# go_download GO_VERSION ARCH: downloads the Go archive for ARCH, checks it
# against go.dev's SHA-256, and prints its path.
go_download() {
    local file="go$1.linux-$2.tar.gz" published actual
    published=$(go_published_sha256 "$1" "${file}")
    if [[ ! "${published}" =~ ^[0-9a-f]{64}$ ]]; then
        hash_die "go.dev publishes no SHA-256 for ${file}. Check the Go version."
    fi
    orb_download "${HASH_WORK_DIR}/${file}" "https://dl.google.com/go/${file}" >&2 \
        || hash_die "Could not download ${file}."
    actual=$(sha256sum "${HASH_WORK_DIR}/${file}" | awk '{ print $1 }')
    if [[ "${actual}" != "${published}" ]]; then
        hash_die "${file} does not match the SHA-256 go.dev publishes for it (${actual})."
    fi
    printf 'ok: %s matches the SHA-256 go.dev publishes for it.\n' "${file}" >&2
    printf '%s\n' "${HASH_WORK_DIR}/${file}"
}

ENTRIES=()
if [[ -n "${GO_VERSION}" ]]; then
    for arch in "${ARCH_LIST[@]}"; do
        archive=$(go_download "${GO_VERSION}" "${arch}")
        ENTRIES+=("$(printf '    ["%s/%s"]="%s"' "${GO_VERSION}" "${arch}" "$(sha512sum "${archive}" | awk '{ print $1 }')")")
    done
    printf '%s\n' "${ENTRIES[@]}"
    exit 0
fi

if [[ ! "${VERSION}" =~ ^[0-9]+(\.[0-9]+){1,2}(-[0-9A-Za-z][0-9A-Za-z.-]*)?$ ]]; then
    hash_die "Invalid version '${VERSION}'."
fi

# The toolchain runs here, so it is the one for this machine. It builds the
# other architectures as cross-compiles, which give the same bytes as a
# build on that architecture.
orb_detect_arch >&2
archive=$(go_download "${GS_BUILD_GO_VERSION}" "${ORB_ARCH}")
if [[ "$(sha512sum "${archive}" | awk '{ print $1 }')" != "${gs_go_sha512sums["${GS_BUILD_GO_VERSION}/${ORB_ARCH}"]:-}" ]]; then
    hash_die "${archive##*/} does not match gs_go_sha512sums in install.sh."
fi
tar -xzf "${archive}" -C "${HASH_WORK_DIR}" || hash_die "Could not extract ${archive##*/}."

# Modules come from the public proxy and are checked against the public
# checksum database, whatever the environment says.
export GOPROXY=https://proxy.golang.org GOSUMDB=sum.golang.org GONOSUMDB="" GONOPROXY="" GOPRIVATE="" GOINSECURE=""
for arch in "${ARCH_LIST[@]}"; do
    printf 'Building %s %s for %s with Go %s...\n' "${TOOL_NAME}" "${VERSION}" "${arch}" "${GS_BUILD_GO_VERSION}" >&2
    if ! gs_build "${VERSION}" "${arch}" "${HASH_WORK_DIR}/go/bin/go" "${HASH_WORK_DIR}/build"; then
        tail -n 40 "${HASH_WORK_DIR}/build/build.log" >&2
        hash_die "Could not build ${TOOL_NAME} ${VERSION} for ${arch}."
    fi
    # A binary for this machine must run.
    if [[ "${arch}" == "${ORB_ARCH}" ]] && ! tool_version "${GS_BUILT_FILE}" > "${HASH_WORK_DIR}/version.log" 2>&1; then
        cat "${HASH_WORK_DIR}/version.log" >&2
        hash_die "The ${TOOL_NAME} ${VERSION} build does not run."
    fi
    ENTRIES+=("$(printf '    ["%s/%s"]="%s"' "${VERSION}" "${arch}" "$(sha512sum "${GS_BUILT_FILE}" | awk '{ print $1 }')")")
done
# Nothing is printed until every architecture has passed.
printf '%s\n' "${ENTRIES[@]}"
# <<< source build install_hash logic <<<
