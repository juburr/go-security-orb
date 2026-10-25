# shellcheck shell=bash disable=SC2034 # a fragment: the install contract it is spliced into reads these
# Go's release archive holds a whole installation, go/, rather than one
# binary: the checksum table covers the archive, and install_path is the
# installation's root, whose bin directory goes on the PATH. On top of the
# shared contract (and the download_base_url checks of release.sh, for
# https://dl.google.com/go): install_path is only ever replaced when it is
# empty or an earlier Go installation, an archive without one is refused, and
# a GOROOT naming another installation is pointed at the new one.
FIXTURE_ORIGIN="https://dl.google.com/go"
FIXTURE_GO_TREE=1

# fixture_make_asset VERSION ARCH DEST CONTENT: a release archive holding
# go/VERSION and CONTENT as go/bin/go, or (FIXTURE_GO_TREE=0) only the binary.
fixture_make_asset() {
    local dir
    dir=$(mktemp -d "${WORK}/asset.XXXXXX")
    mkdir -p "${dir}/go/bin" "${dir}/go/src"
    cp "$4" "${dir}/go/bin/go"
    chmod 0755 "${dir}/go/bin/go"
    printf 'stand-in standard library\n' > "${dir}/go/src/fixture.txt"
    if [[ "${FIXTURE_GO_TREE}" == 1 ]]; then
        printf 'go%s\ntime 2099-01-01T00:00:00Z\n' "$1" > "${dir}/go/VERSION"
        tar -czf "$3" -C "${dir}" go
    else
        tar -czf "$3" -C "${dir}/go" bin
    fi
    rm -rf "${dir}"
    printf '%s\n' "$3"
}

fixture_installed_file() {
    printf '%s/bin/go\n' "$2"
}

fixture_installed_content() {
    printf '%s/bin/go\n' "$1"
}

fixture_path_dir() {
    printf '%s/bin/bin\n' "$1"
}

fixture_tool_checks() {
    begin "Go: install_path is a whole installation"
    new_case
    run_install
    check "installs the standard library beside the binary" test -f "${CASE}/bin/src/fixture.txt"
    check "and the VERSION file" grep -qx "go${LISTED}" "${CASE}/bin/VERSION"
    printf 'left over\n' > "${CASE}/bin/src/stale.txt"
    run_install PARAM_VERSION="${FAILING}" PARAM_VERIFY_CHECKSUMS=strict
    check "a new release that can't run leaves the earlier installation whole" test -f "${CASE}/bin/src/stale.txt"
    run_install
    check "an earlier installation is replaced" succeeded
    check "as a whole, leaving none of its files" test ! -e "${CASE}/bin/src/stale.txt"
    check "leaves no temporary files beside it" no_stray_temp
    new_case
    mkdir -p "${CASE}/bin/bin" "${CASE}/bin/pkg/empty"
    run_install
    check "an install_path holding only empty directories is installed into" installed
    check "replacing them" test ! -e "${CASE}/bin/pkg/empty"
    new_case
    mkdir -p "${CASE}/bin/docs"
    printf 'precious\n' > "${CASE}/bin/docs/notes.txt"
    run_install
    check "refuses an install_path that holds files, but not Go" failed
    check "saying so" said "holds something other than a Go installation"
    check "leaves it alone" grep -qx precious "${CASE}/bin/docs/notes.txt"
    check "before downloading anything" no_downloads
    new_case
    printf 'a file\n' > "${CASE}/bin"
    run_install
    check "refuses an install_path that is a file" failed
    check "saying it is not a directory" said "is not a directory"
    new_case
    mkdir -p "${CASE}/real"
    ln -s "${CASE}/real" "${CASE}/bin"
    run_install
    check "refuses an install_path that is a symbolic link" failed
    check "saying so" said "is a symbolic link"
    FIXTURE_GO_TREE=0
    fixture_make_asset "${UNLISTED}" "${DEFAULT_ARCH}" "$(served_file "${UNLISTED}" "${DEFAULT_ARCH}")" "${WORK}/good-${DEFAULT_ARCH}" > /dev/null
    FIXTURE_GO_TREE=1
    new_case
    run_install "PARAM_VERSION=${UNLISTED}" PARAM_VERIFY_CHECKSUMS=known_versions
    check "refuses an archive without go/VERSION and go/bin/go" failed
    check "saying it holds no Go installation" said "does not hold a Go installation"
    check "and installs nothing" not_installed

    begin "Go: GOROOT"
    new_case
    run_install GOROOT=/opt/other-go
    check "a GOROOT naming another installation is set to the new one for later steps" \
        grep -qxF "$(printf 'export GOROOT=%q' "${CASE}/bin")" "${CASE}/bash_env"
    check "saying so" said "GOROOT was /opt/other-go"
    new_case
    run_install "GOROOT=${CASE}/bin/"
    check "a GOROOT naming install_path is left alone" not_said "GOROOT was"
    new_case
    run_install -u GOROOT
    check "without GOROOT, none is set" test -z "$(grep GOROOT "${CASE}/bash_env")"
}
