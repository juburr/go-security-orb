#!/usr/bin/env bash
#
# Runs a command's script the way the command's step runs it: with every
# PARAM_ variable set from the command's parameter defaults, overridden by
# NAME=VALUE arguments, and SCRIPT_GO_SECURITY_LIB set to the shared
# helpers. test-deploy.yml uses it to check steps that must fail, since a
# failing orb step would fail the test job itself. working_dir, like the
# step's working_directory, is where the script runs.
#
# Usage, from a checkout:
#   bash tests/run_command.sh COMMAND [NAME=VALUE ...]
#
# Exits with the script's exit code.

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if [[ $# -lt 1 ]]; then
    echo "ERROR: Usage: bash tests/run_command.sh COMMAND [NAME=VALUE ...]" >&2
    exit 2
fi
COMMAND=$1
shift
YML="${ROOT}/src/commands/${COMMAND}.yml"
if [[ ! -f "${YML}" ]]; then
    echo "ERROR: There is no command ${COMMAND} (${YML})." >&2
    exit 2
fi
# The step's script: an install command's install/<tool>/install.sh (its
# scripts/cache_key.sh only prepares the cache key), or else its one script.
SCRIPT=$(grep -oE '<< include\((install/[a-z0-9-]+/install|scripts/[a-z_]+)\.sh\) >>' "${YML}" \
    | grep -v -e 'scripts/lib/' -e 'scripts/cache_key.sh' | sed -E 's/<< include\((.*)\) >>/\1/' | head -n 1)

# Every parameter, as NAME<TAB>DEFAULT, without the quotes YAML allows; a
# parameter without a default has the value "<required>" until it is given.
declare -A VALUES=()
while IFS=$'\t' read -r name value; do
    VALUES[${name}]=${value}
done < <(awk '
    function flush() { if (name != "") { printf "%s\t%s\n", name, value } }
    /^parameters:/ { p = 1; next }
    /^[^ ]/ { if (p) { flush() } p = 0; name = "" }
    p && /^  [a-z_0-9]+:$/ { flush(); name = $1; sub(/:$/, "", name); value = "<required>" }
    p && /^    default:/ {
        value = $0
        sub(/^    default: */, "", value)
        if (value ~ /^".*"$/) { value = substr(value, 2, length(value) - 2) }
    }' "${YML}")
for setting in "$@"; do
    name=${setting%%=*}
    if [[ "${setting}" != *=* || -z "${VALUES[${name}]+set}" ]]; then
        echo "ERROR: ${COMMAND} has no parameter ${name}." >&2
        exit 2
    fi
    VALUES[${name}]=${setting#*=}
done
for name in "${!VALUES[@]}"; do
    if [[ "${VALUES[${name}]}" == "<required>" ]]; then
        echo "ERROR: ${COMMAND} needs ${name}=VALUE." >&2
        exit 2
    fi
done

ENVIRONMENT=()
while IFS= read -r line; do
    var=${line%%:*}
    name=${line##*parameters.}
    name=${name% >>}
    ENVIRONMENT+=("${var}=${VALUES[${name}]}")
done < <(grep -oE 'PARAM_[A-Z0-9_]+: << parameters\.[a-z0-9_]+ >>' "${YML}")

DIR=${VALUES[working_dir]:-.}
echo "Running ${SCRIPT} in ${DIR} with ${ENVIRONMENT[*]-}"
cd "${DIR}"
STATUS=0
env ${ENVIRONMENT[@]+"${ENVIRONMENT[@]}"} SCRIPT_GO_SECURITY_LIB="$(cat "${ROOT}/src/scripts/lib/go_security.sh")" \
    bash "${ROOT}/src/${SCRIPT}" || STATUS=$?
echo "${SCRIPT} exited with ${STATUS}."
exit "${STATUS}"
