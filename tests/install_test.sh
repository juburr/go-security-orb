#!/usr/bin/env bash
#
# Runs the install contract every juburr orb's install command meets
# (tests/install_contract.sh, a copy of the tests/install_test.sh the
# single-tool orbs share, never edited here) once for each tool this orb
# downloads, and checks what keeps the per-tool scripts consistent.
# govulncheck and go-licenses are built instead of downloaded, so
# tests/install_build_test.sh covers them.
#
# The contract expects one tool per orb: src/scripts/install.sh and
# src/commands/install.yml. So each tool gets a temporary tree laid out that
# way, holding its install.sh, its install_<tool>.yml with the include
# pointed at scripts/install.sh, the orb's cache_key.sh, and a copy of the
# contract whose tool fixture section comes from tests/install_fixtures:
# release.sh for every download (the download_base_url mirror and the install
# record), then <tool>.sh for anything else, such as Go's release archive.
#
# Run from a checkout:
#   bash tests/install_test.sh [TOOL...]

set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CONTRACT="${ROOT}/tests/install_contract.sh"
FIXTURES="${ROOT}/tests/install_fixtures"

# tool, then how it installs: release (a download the shared logic installs)
# or build (govulncheck and go-licenses, which tests/install_build_test.sh
# covers).
TOOLS=(
    go:release
    gosec:release
    govulncheck:build
    go-licenses:build
)

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
FAILURES=0
fail() {
    printf 'FAIL: %s\n' "$*"
    FAILURES=$((FAILURES + 1))
}

# block FILE START END: the lines from START to END in FILE.
block() {
    sed -n "/^$2\$/,/^$3\$/p" "$1"
}

echo "=== per-tool scripts"
first=""
for entry in "${TOOLS[@]}"; do
    tool=${entry%%:*}
    for file in install.sh install_hash.sh; do
        if [[ ! -f "${ROOT}/src/install/${tool}/${file}" ]]; then
            fail "src/install/${tool}/${file} is missing"
        fi
    done
    if [[ ! -f "${ROOT}/src/commands/install_${tool//-/_}.yml" ]]; then
        fail "src/commands/install_${tool//-/_}.yml is missing"
    fi
    if [[ -z "${first}" ]]; then
        first=${tool}
        continue
    fi
    for part in "shared install logic:${ROOT}/src/install/%s/install.sh" \
        "go-security-orb install helpers:${ROOT}/src/install/%s/install.sh" \
        "shared install_hash logic:${ROOT}/src/install/%s/install_hash.sh"; do
        name=${part%%:*}
        # The install_hash.sh of a tool built from source builds instead, so
        # it has the part every such tool shares in place of the shared one.
        if [[ "${name}" == "shared install_hash logic" && "${entry#*:}" == build ]]; then
            continue
        fi
        # shellcheck disable=SC2059 # the path template holds the %s
        if ! diff -q <(block "$(printf "${part#*:}" "${first}")" "# >>> ${name} >>>" "# <<< ${name} <<<") \
            <(block "$(printf "${part#*:}" "${tool}")" "# >>> ${name} >>>" "# <<< ${name} <<<") > /dev/null; then
            fail "the ${name} of ${tool} differs from ${first}'s"
        fi
    done
done
first_build=""
for entry in "${TOOLS[@]}"; do
    [[ "${entry#*:}" == build ]] || continue
    tool=${entry%%:*}
    if [[ -z "${first_build}" ]]; then
        first_build=${tool}
        continue
    fi
    if ! diff -q <(block "${ROOT}/src/install/${first_build}/install_hash.sh" "# >>> source build install_hash logic >>>" "# <<< source build install_hash logic <<<") \
        <(block "${ROOT}/src/install/${tool}/install_hash.sh" "# >>> source build install_hash logic >>>" "# <<< source build install_hash logic <<<") > /dev/null; then
        fail "the source build install_hash logic of ${tool} differs from ${first_build}'s"
    fi
done
for tool_yml in "${ROOT}"/src/commands/install_*.yml; do
    tool=${tool_yml##*/install_}
    tool=${tool%.yml}
    if [[ " ${TOOLS[*]//:*/} " != *" ${tool//_/-} "* ]]; then
        fail "${tool_yml##*/} installs a tool this test doesn't know"
    fi
done
for dir in "${ROOT}"/src/install/*/; do
    tool=${dir%/}
    tool=${tool##*/}
    if [[ " ${TOOLS[*]//:*/} " != *" ${tool} "* ]]; then
        fail "src/install/${tool} holds a tool this test doesn't know"
    fi
done
if [[ "${FAILURES}" -eq 0 ]]; then
    echo "ok: every tool has its install.sh, install_hash.sh and command, and their shared parts are identical"
fi

SELECTED=()
# Bash 4.0 calls an empty "$@" unbound under set -u.
if [[ $# -gt 0 ]]; then
    SELECTED=("$@")
fi
for entry in "${TOOLS[@]}"; do
    tool=${entry%%:*}
    kind=${entry#*:}
    if [[ ${#SELECTED[@]} -gt 0 && " ${SELECTED[*]} " != *" ${tool} "* ]] || [[ "${kind}" == build ]]; then
        continue
    fi
    tree="${WORK}/${tool}"
    mkdir -p "${tree}/src/scripts" "${tree}/src/commands" "${tree}/tests"
    cp "${ROOT}/src/@orb.yml" "${tree}/src/"
    cp "${ROOT}/src/install/${tool}/install.sh" "${tree}/src/scripts/install.sh"
    cp "${ROOT}/src/scripts/cache_key.sh" "${tree}/src/scripts/"
    sed "s|<< include(install/${tool}/install.sh) >>|<< include(scripts/install.sh) >>|" \
        "${ROOT}/src/commands/install_${tool//-/_}.yml" > "${tree}/src/commands/install.yml"
    fixture="${WORK}/${tool}.fixture"
    {
        echo "# >>> tool fixture >>>"
        cat "${FIXTURES}/release.sh"
        if [[ -f "${FIXTURES}/${tool}.sh" ]]; then
            cat "${FIXTURES}/${tool}.sh"
        fi
        echo "# <<< tool fixture <<<"
    } > "${fixture}"
    {
        sed -n '1,/^# >>> tool fixture >>>$/p' "${CONTRACT}" | sed '$d'
        cat "${fixture}"
        sed -n '/^# <<< tool fixture <<<$/,$p' "${CONTRACT}" | sed '1d'
    } > "${tree}/tests/install_test.sh"
    if ! bash "${tree}/tests/install_test.sh"; then
        fail "the install contract for ${tool}"
    fi
done

if [[ "${FAILURES}" -gt 0 ]]; then
    echo "${FAILURES} failure(s)"
    exit 1
fi
echo "Every tool meets the install contract."
