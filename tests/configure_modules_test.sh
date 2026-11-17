#!/usr/bin/env bash
#
# Tests src/scripts/configure_modules.sh offline: the settings it exports,
# the .netrc entry it writes, and every check that stops it before it changes
# anything. It runs the script with the bash first on the PATH, with a
# stand-in CircleCI CLI and without one. The script and this test are
# identical in go-security-orb and go-quality-orb.
#
# Run from a checkout:
#   bash tests/configure_modules_test.sh

set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="${ROOT}/src/scripts/configure_modules.sh"
WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/stubs" "${WORK}/home"

# A PATH without any circleci, and one with a stand-in that expands $NAME and
# ${NAME} on stdin, as the real CLI does. A directory that holds a circleci,
# such as /usr/bin on CircleCI's images, which holds bash too, is replaced by
# one of links to everything else in it.
CLEAN_PATH=""
IFS=: read -r -a DIRS <<< "${PATH}"
for i in "${!DIRS[@]}"; do
    dir=${DIRS[${i}]}
    [[ -n "${dir}" && -d "${dir}" ]] || continue
    if [[ -e "${dir}/circleci" ]]; then
        mkdir -p "${WORK}/path/${i}"
        for file in "${dir}"/*; do
            if [[ "${file##*/}" != circleci && -x "${file}" ]]; then
                ln -s "${file}" "${WORK}/path/${i}/${file##*/}"
            fi
        done
        dir="${WORK}/path/${i}"
    fi
    CLEAN_PATH+="${CLEAN_PATH:+:}${dir}"
done
cat > "${WORK}/stubs/circleci" << 'EOF'
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
chmod +x "${WORK}/stubs/circleci"

FAILURES=0
OUTPUT=""
RC=0
CLI=true

check() {
    local name=$1
    shift
    if "$@"; then
        echo "  ok: ${name}"
    else
        echo "  FAIL: ${name}"
        tail -n 15 <<< "${OUTPUT}" | while IFS= read -r line; do printf '    | %s\n' "${line}"; done
        FAILURES=$((FAILURES + 1))
    fi
}
succeeded() { [[ "${RC}" -eq 0 ]]; }
failed() { [[ "${RC}" -ne 0 ]]; }
said() { grep -qF -- "$1" <<< "${OUTPUT}"; }
not_said() { ! grep -qF -- "$1" <<< "${OUTPUT}"; }
file_has() { grep -qxF -- "$2" "$1"; }
not_file_has() { ! grep -qF -- "$2" "$1" 2> /dev/null; }
mode_is() { [[ "$(stat -c %a "$1")" == "$2" ]]; }
empty() { [[ ! -s "$1" ]]; }
# exported NAME VALUE: sourcing BASH_ENV sets NAME to VALUE.
exported() {
    local got
    # shellcheck disable=SC2016 # expanded by the inner bash
    got=$(env -i bash -c 'source "$1" && printf "%s" "${!2-<unset>}"' _ "${WORK}/bash_env" "$1")
    [[ "${got}" == "$2" ]] || { OUTPUT+=$'\n'"${1} is '${got}', not '${2}'"; return 1; }
}

# run [NAME=VALUE...] [-- VAR=VALUE...]: runs the script with every PARAM_
# set to the command's default, NAME=VALUE overriding parameters and
# VAR=VALUE adding to the environment.
run() {
    local -A params=([goproxy]="" [gonosumdb]="" [goprivate]="" [gosumdb]="" [host]=""
        [username]=PRIVATE_MODULES_USERNAME [password]=PRIVATE_MODULES_TOKEN)
    local env=() name path
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == -- ]]; then
            shift
            env=("$@")
            break
        fi
        params[${1%%=*}]=${1#*=}
        shift
    done
    for name in "${!params[@]}"; do
        env+=("PARAM_${name^^}=${params[${name}]}")
    done
    path=${CLEAN_PATH}
    if [[ "${CLI}" == true ]]; then
        path="${WORK}/stubs:${CLEAN_PATH}"
    fi
    : > "${WORK}/bash_env"
    RC=0
    OUTPUT=$(env -i "PATH=${path}" "HOME=${WORK}/home" "BASH_ENV=${WORK}/bash_env" "${env[@]}" \
        bash "${SCRIPT}" 2>&1) || RC=$?
}

echo "--- settings"
run
check "nothing to configure fails" failed
check "saying so" said "There is nothing to configure"
run "goproxy=https://artifactory.example.com/artifactory/api/go/go-virtual" "gonosumdb=github.com/my-org/*,*.corp.example.com" \
    "goprivate=git.corp.example.com/team" "gosumdb=sum.golang.org https://artifactory.example.com/artifactory/api/go/gosumdb"
check "it passes" succeeded
check "GOPROXY is exported" exported GOPROXY https://artifactory.example.com/artifactory/api/go/go-virtual
check "GONOSUMDB is exported" exported GONOSUMDB 'github.com/my-org/*,*.corp.example.com'
check "GOPRIVATE is exported" exported GOPRIVATE git.corp.example.com/team
check "GOSUMDB is exported, space and all" exported GOSUMDB "sum.golang.org https://artifactory.example.com/artifactory/api/go/gosumdb"
check "no .netrc without host" [ ! -e "${WORK}/home/.netrc" ]
run "goproxy=https://proxy.example.com|https://proxy2.example.com:8443/go,direct"
check "several proxies, a port and direct pass" succeeded
run "goproxy=http://127.0.0.1:8080/go,file:///tmp/proxy,off"
check "loopback HTTP, file:/// and off pass" succeeded
run "goproxy=\$PROXY_URL" -- PROXY_URL=https://proxy.example.com
check "environment variables are expanded" exported GOPROXY https://proxy.example.com

echo "--- refused settings"
refused() {
    local name=$1 message=$2
    shift 2
    run "$@"
    check "${name} fails" failed
    check "  saying ${message}" said "${message}"
    check "  before exporting anything" empty "${WORK}/bash_env"
}
refused "credentials in a proxy URL" "goproxy holds credentials in a URL" "goproxy=https://ci:t0ken@proxy.example.com"
check "  never showing them" not_said t0ken
refused "plain HTTP to another machine" "goproxy has http://proxy.example.com, which" "goproxy=http://proxy.example.com,direct"
refused "a proxy URL with a query" "goproxy has https://proxy.example.com/ (with its query or fragment left out here)" \
    "goproxy=https://proxy.example.com/?token=qu3ry-secret"
check "  never showing the query" not_said qu3ry-secret
refused "a proxy URL with a fragment" "goproxy has" "goproxy=https://proxy.example.com/go#fr4g-secret"
check "  never showing the fragment" not_said fr4g-secret
refused "a trailing comma" "goproxy must be" "goproxy=https://proxy.example.com,"
refused "spaces in goproxy" "goproxy must be" "goproxy=https://a.example.com https://b.example.com"
refused "gonosumdb matching public modules" "gonosumdb (github.com) matches public modules such as github.com/owner/repo" \
    gonosumdb=github.com "goproxy=https://proxy.example.com"
refused "goprivate matching public modules" "goprivate (*) matches public modules" "goprivate=*"
refused "goprivate with spaces" "goprivate must be separated by commas" "goprivate=a.example.com, b.example.com"
refused "gosumdb=off" "gosumdb is off" gosumdb=off
refused "a gosumdb URL over HTTP" "gosumdb must be" "gosumdb=sum.golang.org http://proxy.example.com/sumdb"

echo "--- credentials"
NETRC_FILE="${WORK}/home/.netrc"
printf 'machine other.example.com login a password b\n' > "${NETRC_FILE}"
run host=artifactory.example.com -- PRIVATE_MODULES_USERNAME=ci PRIVATE_MODULES_TOKEN=s3cret-token
check "it passes" succeeded
check "host gets the credentials" file_has "${NETRC_FILE}" "machine artifactory.example.com login ci password s3cret-token"
check "first, so go uses them" [ "$(sed -n 2p "${NETRC_FILE}")" == "machine artifactory.example.com login ci password s3cret-token" ]
check "keeping the other entries" file_has "${NETRC_FILE}" "machine other.example.com login a password b"
check "with mode 0600" mode_is "${NETRC_FILE}" 600
check "never showing them" not_said s3cret-token
check "exporting nothing" empty "${WORK}/bash_env"
run host=artifactory.example.com username=JF_USER password=JF_ACCESS_TOKEN -- JF_USER=ci JF_ACCESS_TOKEN=n3w-token
check "a second run replaces its entry" [ "$(grep -c 'machine artifactory.example.com' "${NETRC_FILE}")" -eq 1 ]
check "with the new token" file_has "${NETRC_FILE}" "machine artifactory.example.com login ci password n3w-token"
printf '# go-security-orb mod_verify github.com\nmachine github.com login old password old-token\n' >> "${NETRC_FILE}"
run host=github.com -- PRIVATE_MODULES_USERNAME=ci PRIVATE_MODULES_TOKEN=gh-token
check "the entry mod_verify wrote is replaced too" not_file_has "${NETRC_FILE}" old-token
check "by the new one" file_has "${NETRC_FILE}" "machine github.com login ci password gh-token"
OUTPUT=$(env -i "PATH=${CLEAN_PATH}" "HOME=${WORK}/home" "BASH_ENV=${WORK}/bash_env" PARAM_GOPROXY= PARAM_GONOSUMDB= \
    PARAM_GOPRIVATE= PARAM_GOSUMDB= PARAM_HOST=github.com PARAM_USERNAME=U PARAM_PASSWORD=P U=ci P=traced-token \
    bash -x "${SCRIPT}" 2>&1) && RC=0 || RC=$?
check "xtrace doesn't show the token" not_said traced-token
cp "${NETRC_FILE}" "${WORK}/before"
run host=artifactory.example.com goproxy=http://proxy.example.com -- PRIVATE_MODULES_USERNAME=ci PRIVATE_MODULES_TOKEN=x
check "a refused setting leaves .netrc as it was" cmp -s "${NETRC_FILE}" "${WORK}/before"
run host=artifactory.example.com
check "host without credentials fails" said "but PRIVATE_MODULES_USERNAME or PRIVATE_MODULES_TOKEN is empty or unset"
run host=artifactory.example.com -- PRIVATE_MODULES_USERNAME=ci "PRIVATE_MODULES_TOKEN=has space"
check "a token .netrc can't hold fails" said "can't hold spaces or #"
run host=artifactory.example.com -- PRIVATE_MODULES_USERNAME=ci 'PRIVATE_MODULES_TOKEN="quoted"'
check "a token that starts with a quote fails" said "or start with a double quote"
run host=artifactory.example.com -- 'PRIVATE_MODULES_USERNAME="ci' PRIVATE_MODULES_TOKEN=x
check "so does a user name that starts with one" said "or start with a double quote"
run host=artifactory.example.com -- PRIVATE_MODULES_USERNAME=ci 'PRIVATE_MODULES_TOKEN=a"b'
check "a quote inside a token passes, as both read it the same" succeeded
run "host=bad host" -- PRIVATE_MODULES_USERNAME=ci PRIVATE_MODULES_TOKEN=x
check "a host that isn't a host fails" said "host must be a host name"
run host=artifactory.example.com username=1BAD
check "a username that can't name a variable fails" said "username must name an environment variable"
run host=artifactory.example.com -- PRIVATE_MODULES_USERNAME=ci PRIVATE_MODULES_TOKEN=x GOAUTH=off
check "GOAUTH without netrc warns" said "WARN: GOAUTH is 'off'"
run host=artifactory.example.com -- PRIVATE_MODULES_USERNAME=ci PRIVATE_MODULES_TOKEN=x "GOAUTH=git /src;netrc"
check "GOAUTH with netrc doesn't" not_said "WARN: GOAUTH"
run host=artifactory.example.com -- PRIVATE_MODULES_USERNAME=ci PRIVATE_MODULES_TOKEN=nt-token "NETRC=${WORK}/netrc/file"
check "NETRC names the file" file_has "${WORK}/netrc/file" "machine artifactory.example.com login ci password nt-token"
check "warning that git doesn't read it" said "WARN: NETRC names"
rm -f "${NETRC_FILE}"
printf 'machine target.example.com login keep password keep\n' > "${WORK}/target"
ln -s "${WORK}/target" "${NETRC_FILE}"
run host=artifactory.example.com -- PRIVATE_MODULES_USERNAME=ci PRIVATE_MODULES_TOKEN=x
check "a symbolic link .netrc is replaced" [ ! -L "${NETRC_FILE}" ]
check "not written through" not_file_has "${WORK}/target" artifactory.example.com

echo "--- without the CircleCI CLI"
CLI=false
run "goproxy=https://proxy.example.com" "gonosumdb=github.com/my-org/*"
check "it passes" succeeded
check "values are used as they are" exported GONOSUMDB 'github.com/my-org/*'
run
check "nothing to configure still fails" said "There is nothing to configure"
CLI=true

echo
if [[ "${FAILURES}" -gt 0 ]]; then
    echo "${FAILURES} check(s) failed."
    exit 1
fi
echo "All configure_modules checks passed."
