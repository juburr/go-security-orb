#!/bin/bash
#
# Fetches a copy of the Go vulnerability database, for the fetch_vuln_db
# command, checks it, and swaps it into place. The database is a zip of
# JSON files (index/db.json, index/modules.json, index/vulns.json and one
# ID/<id>.json per entry), with no signatures or checksums of its own, so
# what is checked is its layout: only those files, as plain files, the index
# complete, and every entry the index lists present. govulncheck reads a
# directory without the index as loose entries, and reports nothing for an
# empty or wrong one, so a copy that isn't complete must never reach it.

set -euo pipefail

if [[ -z "${SCRIPT_GO_SECURITY_LIB:-}" ]]; then
    echo "ERROR: The shared helpers were not loaded: SCRIPT_GO_SECURITY_LIB is empty." >&2
    exit 1
fi
eval "${SCRIPT_GO_SECURITY_LIB}"

SOURCE=$(gs_subst "${PARAM_SOURCE}")
SOURCE=${SOURCE:-https://vuln.go.dev/vulndb.zip}
SHA256=$(gs_subst "${PARAM_SHA256}")
gs_uint max_db_age_days "${PARAM_MAX_DB_AGE_DAYS}"
gs_env_var_name db_env_var "${PARAM_DB_ENV_VAR}"
gs_require_jq
if [[ -n "${SHA256}" ]] && ! gs_match "${SHA256}" '^[0-9a-f]{64}$'; then
    echo "ERROR: sha256 must be 64 lowercase hex digits, not '${SHA256}'." >&2
    exit 1
fi

DEST=$(gs_subst "${PARAM_PATH}")
if [[ -z "${DEST}" || "${DEST}" == \~ || "${DEST}" == \~/* ]]; then
    if [[ -z "${HOME:-}" ]]; then
        echo "ERROR: HOME is not set, so path has no default. Set path to an absolute path." >&2
        exit 1
    fi
    if [[ -z "${DEST}" ]]; then
        DEST="${HOME}/.cache/go-vulndb"
    else
        DEST="${HOME}${DEST:1}"
    fi
fi
while [[ "${DEST}" == */ && "${DEST}" != / ]]; do
    DEST=${DEST%/}
done
if [[ "${DEST}" != /* || "${DEST}" == / || "${DEST}" == *$'\n'* ]]; then
    echo "ERROR: path must be an absolute directory other than /, not '${DEST}'." >&2
    exit 1
fi
if [[ -L "${DEST}" || (-e "${DEST}" && ! -d "${DEST}") ]]; then
    echo "ERROR: path ${DEST} exists and is not a directory." >&2
    exit 1
fi
# Never replace a directory that holds something else, such as a mistyped
# path that names the home directory.
if [[ -d "${DEST}" && ! -f "${DEST}/.go-security-orb.json" && ! -f "${DEST}/index/db.json" ]] \
    && [[ -n "$(find "${DEST}" -mindepth 1 -print -quit 2>&1)" ]]; then
    echo "ERROR: path ${DEST} holds something other than a copy of the Go vulnerability database, which this would replace." >&2
    echo "  Choose a new or empty directory, or one fetch_vuln_db fetched into before." >&2
    exit 1
fi
PARENT=${DEST%/*}
PARENT=${PARENT:-/}
if ! mkdir -p "${PARENT}"; then
    echo "ERROR: Could not create ${PARENT}." >&2
    exit 1
fi

# The new copy is staged, and the earlier one moved aside, beside path, so
# both moves are renames within one file system.
WORK=$(mktemp -d)
STAGE=$(mktemp -d "${PARENT%/}/.${DEST##*/}.new.XXXXXX")
OLD=$(mktemp -d "${PARENT%/}/.${DEST##*/}.old.XXXXXX")
trap 'rm -rf "${WORK}" "${STAGE}" "${OLD}"' EXIT

# The names a copy holds: its index, its entries, and the two directories
# (with a trailing /). Nothing else is unpacked or copied.
ENTRY='^(index/(db|modules|vulns)\.json|ID/[A-Z]+-[0-9]{4}-[0-9]+\.json|index/|ID/)$'

# check_tree DIR: stops the step unless DIR holds only what a copy holds, as
# plain files and directories, besides the marker this command writes.
check_tree() {
    local entry name bad=()
    if ! (cd "$1" && find . -mindepth 1 -print0) > "${WORK}/tree" 2> "${WORK}/find.err"; then
        echo "ERROR: Could not read ${SOURCE_PUBLIC}: $(head -c 300 "${WORK}/find.err")" >&2
        exit 1
    fi
    while IFS= read -r -d '' entry; do
        entry=${entry#./}
        if [[ -L "$1/${entry}" ]]; then
            name="${entry} (a symbolic link)"
        elif [[ -d "$1/${entry}" ]]; then
            name="${entry}/"
        elif [[ -f "$1/${entry}" ]]; then
            name=${entry}
        else
            name="${entry} (not a plain file)"
        fi
        if [[ "${name}" != .go-security-orb.json ]] && ! gs_match "${name}" "${ENTRY}"; then
            bad+=("${name}")
        fi
    done < "${WORK}/tree"
    if [[ ${#bad[@]} -gt 0 ]]; then
        echo "ERROR: ${SOURCE_PUBLIC} holds what a copy of the Go vulnerability database doesn't, such as:" >&2
        printf '%s\n' "${bad[@]:0:5}" | sed 's/^/  /' >&2
        exit 1
    fi
}

# unpack ZIP DIR: unpacks ZIP into DIR, after checking that it names only
# what a copy holds, once each, and no symbolic links, which unzip would
# create and later entries could be written through.
unpack() {
    local names bad
    if command -v unzip > /dev/null 2>&1; then
        if ! names=$(unzip -Z1 "$1" 2> "${WORK}/zip.err"); then
            echo "ERROR: ${SOURCE_PUBLIC} is not a zip file: $(head -c 300 "${WORK}/zip.err")" >&2
            exit 1
        fi
        if unzip -Z "$1" | awk 'NR > 2 && $1 ~ /^l/ { found = 1 } END { exit !found }'; then
            echo "ERROR: ${SOURCE_PUBLIC} holds symbolic links, which a copy of the Go vulnerability database doesn't." >&2
            exit 1
        fi
    elif command -v python3 > /dev/null 2>&1; then
        # Python's zipfile writes symbolic links as plain files.
        if ! names=$(python3 -I -c 'import sys, zipfile; print("\n".join(zipfile.ZipFile(sys.argv[1]).namelist()))' "$1" 2> "${WORK}/zip.err"); then
            echo "ERROR: ${SOURCE_PUBLIC} is not a zip file: $(tail -n 1 "${WORK}/zip.err")" >&2
            exit 1
        fi
    else
        echo "ERROR: Unpacking the database needs unzip or python3, and neither is installed. Install unzip in an earlier step." >&2
        exit 1
    fi
    bad=$(LC_ALL=C grep -Ev -- "${ENTRY}" <<< "${names}" | awk 'NR <= 5' || true)
    if [[ -z "${bad}" ]]; then
        bad=$(LC_ALL=C sort <<< "${names}" | uniq -d | awk 'NR <= 5')
    fi
    if [[ -n "${bad}" ]]; then
        echo "ERROR: ${SOURCE_PUBLIC} holds what a copy of the Go vulnerability database doesn't, or holds it twice, such as:" >&2
        awk '{ print "  " $0 }' <<< "${bad}" >&2
        exit 1
    fi
    if command -v unzip > /dev/null 2>&1; then
        if ! unzip -q "$1" -d "$2" > "${WORK}/zip.err" 2>&1; then
            echo "ERROR: Could not unpack ${SOURCE_PUBLIC}: $(head -c 300 "${WORK}/zip.err")" >&2
            exit 1
        fi
    elif ! python3 -I -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$1" "$2" 2> "${WORK}/zip.err"; then
        echo "ERROR: Could not unpack ${SOURCE_PUBLIC}: $(tail -n 1 "${WORK}/zip.err")" >&2
        exit 1
    fi
}

ZIP=""
ZIP_SHA=""
case "${SOURCE}" in
    https://*)
        if [[ "${SOURCE#https://}" == *@* || "${SOURCE}" == *[?#]* ]]; then
            echo "ERROR: source must not hold credentials, a query or a fragment, which would show in the log." >&2
            exit 1
        fi
        SOURCE_PUBLIC=${SOURCE}
        echo "Downloading ${SOURCE}"
        if ! curl -fsSL --proto '=https' --proto-redir '=https' --retry 5 --connect-timeout 30 --max-time 600 \
            -o "${WORK}/vulndb.zip" "${SOURCE}" 2> "${WORK}/curl.err"; then
            echo "ERROR: Could not download ${SOURCE}: $(head -c 300 "${WORK}/curl.err")" >&2
            exit 1
        fi
        ZIP=${WORK}/vulndb.zip
        ;;
    *://*)
        echo "ERROR: source must be an https:// URL, a zip file or a directory, not '${SOURCE}'." >&2
        exit 1
        ;;
    *)
        if [[ ! -e "${SOURCE}" ]]; then
            echo "ERROR: source names ${SOURCE}, which doesn't exist in $(pwd)." >&2
            exit 1
        fi
        SOURCE_PUBLIC=$(realpath -- "${SOURCE}")
        # A directory can be path itself, as a copy restored from a cache is,
        # since it is copied before path is replaced.
        case "${SOURCE_PUBLIC}" in
            "$(realpath -m -- "${DEST}")"/*)
                echo "ERROR: source ${SOURCE} is inside path ${DEST}, which this replaces." >&2
                exit 1
                ;;
        esac
        if [[ -f "${SOURCE}" ]]; then
            ZIP=${SOURCE}
        elif [[ ! -d "${SOURCE}" ]]; then
            echo "ERROR: source ${SOURCE} is neither a zip file nor a directory." >&2
            exit 1
        fi
        ;;
esac

if [[ -n "${ZIP}" ]]; then
    ZIP_SHA=$(gs_sha256 "${ZIP}")
    if [[ -n "${SHA256}" && "${ZIP_SHA}" != "${SHA256}" ]]; then
        echo "ERROR: ${SOURCE_PUBLIC} has SHA-256 ${ZIP_SHA}, not the ${SHA256} that sha256 pins." >&2
        exit 1
    fi
    unpack "${ZIP}" "${STAGE}"
    check_tree "${STAGE}"
else
    if [[ -n "${SHA256}" ]]; then
        echo "ERROR: sha256 pins a zip file, and source names a directory." >&2
        exit 1
    fi
    check_tree "${SOURCE}"
    mkdir -p "${STAGE}/index" "${STAGE}/ID"
    while IFS= read -r -d '' entry; do
        entry=${entry#./}
        if [[ -f "${SOURCE}/${entry}" && "${entry}" != .go-security-orb.json ]]; then
            cp -- "${SOURCE}/${entry}" "${STAGE}/${entry}"
        fi
    done < "${WORK}/tree"
fi

# The index must be complete, and every entry it lists present.
for index in db modules vulns; do
    if [[ ! -f "${STAGE}/index/${index}.json" ]]; then
        echo "ERROR: ${SOURCE_PUBLIC} has no index/${index}.json, so it is not a whole copy of the database." >&2
        exit 1
    fi
done
if ! gs_json_is "${STAGE}/index/db.json" '.modified | type == "string"' \
    || ! gs_json_is "${STAGE}/index/modules.json" 'type == "array"' \
    || ! gs_json_is "${STAGE}/index/vulns.json" 'type == "array" and length > 0 and all(.[]; .id | type == "string")'; then
    echo "ERROR: The index of ${SOURCE_PUBLIC} is not what the Go vulnerability database's index looks like." >&2
    exit 1
fi
jq -r '.[].id' "${STAGE}/index/vulns.json" | LC_ALL=C sort -u > "${WORK}/listed"
(cd "${STAGE}" && find ID -type f -name '*.json') | sed -e 's|^ID/||' -e 's|\.json$||' | LC_ALL=C sort > "${WORK}/present"
missing=$(LC_ALL=C comm -23 "${WORK}/listed" "${WORK}/present" | awk 'NR <= 5')
if [[ -n "${missing}" ]]; then
    echo "ERROR: ${SOURCE_PUBLIC} lacks entries its index lists, such as: $(tr '\n' ' ' <<< "${missing}")" >&2
    exit 1
fi
ENTRIES=$(wc -l < "${WORK}/listed" | tr -d ' ')
MODIFIED=$(jq -r '.modified' "${STAGE}/index/db.json")
gs_db_fresh "${MODIFIED}" "${PARAM_MAX_DB_AGE_DAYS}"

jq -n --arg source "${SOURCE_PUBLIC}" --arg sha "${ZIP_SHA}" --arg fetched "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg modified "${MODIFIED}" --argjson entries "${ENTRIES}" \
    '{source: $source, zip_sha256: (if $sha == "" then null else $sha end), fetched_at: $fetched,
      modified: $modified, entries: $entries}' > "${STAGE}/.go-security-orb.json"
chmod -R u=rwX,go=rX "${STAGE}"

# The earlier copy moves aside, where the EXIT trap removes it, and comes
# back if the new one can't take its place.
if [[ -d "${DEST}" ]] && ! mv -- "${DEST}" "${OLD}/db"; then
    echo "ERROR: Could not replace ${DEST}." >&2
    exit 1
fi
if ! mv -- "${STAGE}" "${DEST}"; then
    if [[ -d "${OLD}/db" ]]; then
        mv -- "${OLD}/db" "${DEST}" || true
    fi
    echo "ERROR: Could not move the database into ${DEST}." >&2
    exit 1
fi
gs_export "${PARAM_DB_ENV_VAR}" "file://${DEST}"
echo "Fetched the Go vulnerability database (${ENTRIES} entries, last modified ${MODIFIED}) into ${DEST}."
echo "  ${PARAM_DB_ENV_VAR}=file://${DEST} for later steps."
if [[ -n "${ZIP_SHA}" ]]; then
    echo "  SHA-256 of the zip: ${ZIP_SHA} (pin it with sha256 to use exactly this copy)."
fi
