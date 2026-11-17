#!/usr/bin/env bash
#
# Runs gosec's install.sh with the real curl against a local HTTPS mirror
# that needs a login, as an Artifactory remote repository can, and that
# redirects each download to another host, as an Artifactory that keeps its
# files in cloud storage does. The mirror is https://localhost:PORT and the
# storage https://127.0.0.1:PORT: one server, two host names, so curl treats
# them as different hosts. It checks that:
#
#   - without a .netrc entry for the mirror, the install fails and says how
#     to give it one
#   - with one, the mirror gets the login and the storage host never does,
#     even though the .netrc also holds the entries that make curl 7.76.0
#     to 8.11.1 send the mirror's password to a redirect target (an entry
#     for it without a password, CVE-2024-11053, and a default entry
#     without a login, CVE-2025-0167), and even when a ~/.curlrc says
#     location-trusted
#   - NETRC names the file, as it does for go
#   - a wrong password fails the install
#   - the login never reaches the log
#
# It also says whether this curl, handed the whole .netrc, would have sent
# the password to the storage host: the case the orb's private file exists
# for. That line is information, not a check, since a patched curl doesn't.
#
# Needs curl, python3, openssl, tar and sha512sum; nothing leaves this
# machine.
#
# Run from a checkout:
#   bash tests/mirror_login_test.sh

set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
INSTALL_SH="${ROOT}/src/install/gosec/install.sh"
for tool in curl python3 openssl tar sha512sum; do
    if ! command -v "${tool}" > /dev/null 2>&1; then
        echo "FAIL: this test needs ${tool}."
        exit 1
    fi
done

WORK=$(mktemp -d)
SERVER=""
cleanup() {
    if [[ -n "${SERVER}" ]]; then
        kill "${SERVER}" 2> /dev/null
        wait "${SERVER}" 2> /dev/null
    fi
    rm -rf "${WORK}"
}
trap cleanup EXIT

FAILURES=0
OUTPUT=""
RC=0
check() {
    local name=$1
    shift
    if "$@"; then
        echo "  ok: ${name}"
    else
        echo "  FAIL: ${name}"
        while IFS= read -r line; do
            printf '    | %s\n' "${line}"
        done <<< "${OUTPUT}"$'\n'"requests: $(cat "${WORK}/requests.log" 2> /dev/null)"
        FAILURES=$((FAILURES + 1))
    fi
}
succeeded() { [[ "${RC}" -eq 0 ]]; }
failed() { [[ "${RC}" -ne 0 ]]; }
said() { grep -qF -- "$1" <<< "${OUTPUT}"; }
not_said() { ! said "$1"; }
requested() { grep -qxF -- "$1" "${WORK}/requests.log"; }
not_requested() { ! grep -qF -- "$1" "${WORK}/requests.log"; }

# A stand-in gosec release, and a copy of install.sh whose table lists it.
VERSION="0.0.0-mirrortest"
case "$(uname -m)" in
    x86_64 | amd64) ARCH=amd64 ;;
    aarch64 | arm64) ARCH=arm64 ;;
    *)
        echo "FAIL: unsupported CPU $(uname -m)"
        exit 1
        ;;
esac
ASSET="gosec_${VERSION}_linux_${ARCH}.tar.gz"
ASSET_PATH="/securego/gosec/releases/download/v${VERSION}/${ASSET}"
mkdir -p "${WORK}/release" "${WORK}/www${ASSET_PATH%/*}"
printf '#!/bin/sh\necho "Version: %s"\n' "${VERSION}" > "${WORK}/release/gosec"
chmod 0755 "${WORK}/release/gosec"
tar -czf "${WORK}/www${ASSET_PATH}" -C "${WORK}/release" gosec
SHA512=$(sha512sum "${WORK}/release/gosec" | awk '{ print $1 }')
sed "/^declare -A sha512sums=($/a\\    [\"${VERSION}/${ARCH}\"]=\"${SHA512}\"" "${INSTALL_SH}" > "${WORK}/install.sh"

# The server: localhost wants the login and redirects to 127.0.0.1, which
# serves the file to anyone. Each request is logged as HOST PATH and what
# its Authorization header held: none, the mirror's login, or something
# else.
PASSWORD="s3cret-mirror-token"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "${WORK}/key.pem" -out "${WORK}/cert.pem" -days 1 \
    -subj /CN=localhost -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" 2> /dev/null
cat > "${WORK}/serve.py" << 'EOF'
import base64, http.server, ssl, sys

root, cert, key, log, port_file, password = sys.argv[1:7]
expected = "Basic " + base64.b64encode(("ci:" + password).encode()).decode()


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        host = self.headers.get("Host", "").rsplit(":", 1)[0]
        auth = self.headers.get("Authorization")
        login = "none" if auth is None else ("mirror-login" if auth == expected else "other-login")
        with open(log, "a") as f:
            f.write(f"{host} {self.path} {login}\n")
        if host == "localhost":
            if auth != expected:
                self.send_response(401)
                self.send_header("WWW-Authenticate", 'Basic realm="mirror"')
                self.end_headers()
                return
            self.send_response(302)
            self.send_header("Location", f"https://127.0.0.1:{self.server.server_port}/storage{self.path}")
            self.end_headers()
            return
        if host == "127.0.0.1" and self.path.startswith("/storage/"):
            try:
                with open(root + self.path[len("/storage"):], "rb") as f:
                    data = f.read()
            except OSError:
                self.send_response(404)
                self.end_headers()
                return
            self.send_response(200)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        self.send_response(404)
        self.end_headers()

    def log_message(self, *args):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(cert, key)
server.socket = context.wrap_socket(server.socket, server_side=True)
with open(port_file, "w") as f:
    f.write(str(server.server_port))
server.serve_forever()
EOF
python3 -I "${WORK}/serve.py" "${WORK}/www" "${WORK}/cert.pem" "${WORK}/key.pem" "${WORK}/requests.log" \
    "${WORK}/port" "${PASSWORD}" 2> "${WORK}/server.log" &
SERVER=$!
for _ in $(seq 50); do
    [[ -s "${WORK}/port" ]] && break
    sleep 0.1
done
if [[ ! -s "${WORK}/port" ]]; then
    echo "FAIL: the test server didn't start: $(cat "${WORK}/server.log")"
    exit 1
fi
PORT=$(cat "${WORK}/port")
MIRROR="https://localhost:${PORT}"

# The .netrc every case with a login starts from: the mirror's entry, with
# an entry for the storage host that has no password and a default entry
# without a login, which together make curl 7.76.0 to 8.11.1 send the
# mirror's password on to the storage host, and another host's token.
NETRC_CONTENT="machine github.com login gh password gh-token
machine 127.0.0.1 login ci
machine localhost login ci password ${PASSWORD}
default
"

CASE=""
new_case() {
    CASE=$(mktemp -d "${WORK}/case.XXXXXX")
    mkdir -p "${CASE}/home" "${CASE}/bin" "${CASE}/tmp"
    : > "${WORK}/requests.log"
}
# run_install [VAR=value ...]: installs from the mirror in CASE.
run_install() {
    OUTPUT=$(cd "${CASE}" && env -u NETRC -u CURL_HOME -u XDG_CONFIG_HOME \
        "HOME=${CASE}/home" "TMPDIR=${CASE}/tmp" "BASH_ENV=${CASE}/bash_env" "CURL_CA_BUNDLE=${WORK}/cert.pem" \
        "NO_PROXY=localhost,127.0.0.1" "no_proxy=localhost,127.0.0.1" \
        "PARAM_VERSION=${VERSION}" PARAM_VERIFY_CHECKSUMS=strict "PARAM_INSTALL_PATH=${CASE}/bin" PARAM_CACHING=false \
        "PARAM_DOWNLOAD_BASE_URL=${MIRROR}" "$@" bash "${WORK}/install.sh" 2>&1)
    RC=$?
}
installed() { [[ "$("${CASE}/bin/gosec" 2>&1)" == "Version: ${VERSION}" ]]; }

echo "=== gosec from a mirror that needs a login ($(curl --version | head -n 1 | cut -d' ' -f1-2))"

echo "--- without a login"
new_case
run_install
check "the install fails" failed
check "saying how to give the mirror a login" said "If localhost needs a login, put an entry for it in ${CASE}/home/.netrc"
check "the mirror was asked without one" requested "localhost ${ASSET_PATH} none"
check "and nothing came from storage" not_requested "/storage/"

echo "--- with the mirror's entry in ~/.netrc"
new_case
printf '%s' "${NETRC_CONTENT}" > "${CASE}/home/.netrc"
chmod 600 "${CASE}/home/.netrc"
run_install
check "the install succeeds" succeeded
check "and installs the release" installed
check "says which entry it uses" said "mirror login:     the entry for localhost in ${CASE}/home/.netrc"
check "the mirror gets the login" requested "localhost ${ASSET_PATH} mirror-login"
check "the storage host it redirects to gets none" requested "127.0.0.1 /storage${ASSET_PATH} none"
check "the log never shows the password" not_said "${PASSWORD}"
check "nor the other host's token" not_said "gh-token"
check "and no private copy is left behind" test -z "$(ls -A "${CASE}/tmp")"

# The control: this curl, handed the whole .netrc as curl's own --netrc
# would read it.
: > "${WORK}/requests.log"
CASE_HOME="${CASE}/home"
(cd "${CASE}" && env HOME="${CASE_HOME}" CURL_CA_BUNDLE="${WORK}/cert.pem" NO_PROXY=localhost,127.0.0.1 no_proxy=localhost,127.0.0.1 \
    curl -q -fsSL --netrc-file "${CASE_HOME}/.netrc" -o /dev/null "${MIRROR}${ASSET_PATH}") > /dev/null 2>&1
if grep -qF "127.0.0.1 /storage${ASSET_PATH} mirror-login" "${WORK}/requests.log"; then
    echo "  info: handed the whole .netrc, this curl sends the mirror's password to the storage host (CVE-2024-11053, CVE-2025-0167)"
else
    echo "  info: handed the whole .netrc, this curl keeps the mirror's password from the storage host"
fi

echo "--- with a ~/.curlrc that says location-trusted"
new_case
printf '%s' "${NETRC_CONTENT}" > "${CASE}/home/.netrc"
chmod 600 "${CASE}/home/.netrc"
printf 'location-trusted\n' > "${CASE}/home/.curlrc"
run_install
check "the install succeeds" succeeded
check "the storage host still gets no login" requested "127.0.0.1 /storage${ASSET_PATH} none"

echo "--- with NETRC naming the file"
new_case
printf '%s' "${NETRC_CONTENT}" > "${CASE}/netrc"
chmod 600 "${CASE}/netrc"
run_install "NETRC=${CASE}/netrc"
check "the install succeeds" succeeded
check "using the entry in that file" said "mirror login:     the entry for localhost in ${CASE}/netrc"
check "the mirror gets the login" requested "localhost ${ASSET_PATH} mirror-login"

echo "--- with a wrong password"
new_case
printf 'machine localhost login ci password wrong-token\n' > "${CASE}/home/.netrc"
chmod 600 "${CASE}/home/.netrc"
run_install
check "the install fails" failed
check "the mirror refused the login" requested "localhost ${ASSET_PATH} other-login"
check "the log never shows it" not_said "wrong-token"

echo
if [[ "${FAILURES}" -gt 0 ]]; then
    echo "${FAILURES} check(s) failed."
    exit 1
fi
echo "All mirror login checks passed."
