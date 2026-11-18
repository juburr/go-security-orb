# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is an unofficial CircleCI orb, and set of GitHub Actions, that checks Go code and the binaries it ships for security. It installs Go, govulncheck, gosec and go-licenses, each checksum-verified, and wraps the checks around them: `vulncheck`, `vulncheck_bin`, `fetch_vuln_db`, `gosec`, `licenses`, `mod_verify`, `fips_bin` and `fips_test`. `configure_modules` sets up private module proxies and credentials. Code quality checks (vet, golangci-lint, tests) are go-quality-orb's; SBOMs are syft-orb's.

## Development Commands

```bash
# Pack the orb from source into a single file, and validate it
circleci orb pack src/ > orb.yml
circleci orb validate orb.yml

# Lint
yamllint .
shellcheck src/scripts/*.sh src/scripts/lib/*.sh src/install/*/*.sh actions/*.sh tests/*.sh tests/install_fixtures/*.sh

# Tests (offline; commands_test.sh needs Go 1.24+ and jq)
for t in tests/*_test.sh; do bash "$t" || break; done

# Run one command's script with its YAML defaults (what test-deploy.yml uses for steps that must fail)
bash tests/run_command.sh gosec working_dir=tests/fixtures/weakcrypto

# Generate SHA-512 checksum table entries for a new release of one tool
./src/install/<tool>/install_hash.sh -v <version>
```

## Architecture

### Orb Structure (`src/`)

- `@orb.yml` - Orb metadata (version 2.1)
- `commands/`
  - `install.yml` - Installs the tools named in `tools`, through one `install_<tool>` step per tool, each picked by a `when: condition: matches:` on the `tools` string (`^(.*[ ,])?<tool>([ ,].*)?$`). Its first step, `scripts/install_tools.sh`, rejects unknown names. `go` goes first, so the source builds find it.
  - `install_<tool>.yml` - One per tool, in the family's standard install command shape: cache key from `scripts/cache_key.sh`, `restore_cache`, the tool's `install/<tool>/install.sh`, `save_cache`. `ORB_NAME` is `go-security-orb-<tool>`.
  - `vulncheck`, `vulncheck_bin`, `fetch_vuln_db`, `gosec`, `licenses`, `mod_verify`, `fips_bin`, `fips_test` - One script each in `scripts/`.
  - `configure_modules` - `scripts/configure_modules.sh` (see below).
- `install/<tool>/install.sh` and `install_hash.sh` - Kept outside `scripts/`, because `tests/shell_conventions_test.sh` exempts only `src/scripts/install.sh`, `install_hash.sh` and `cache_key.sh` by exact path. orb pack ignores the directory; commands include its files with `<< include(install/<tool>/install.sh) >>`.
- `scripts/lib/go_security.sh` - Helpers shared by the command scripts, passed to each step as `SCRIPT_GO_SECURITY_LIB: << include(scripts/lib/go_security.sh) >>` and `eval`ed after a check that it is set. Only defines functions and variables; no `set` line.
- `examples/` - Usage examples, pinned to the orb's current version
- `../actions/<command>/action.yml` - The GitHub Action for each command (see below).
- `../schemas/run-record.v1.json` - The run record's JSON Schema. Its URL is in every run record, so fields are only ever added within v1.

### Install scripts (`src/install/<tool>/install.sh`)

Each follows the layout every juburr orb's install.sh shares: a tool definition, the shared install logic (byte-identical across the orbs; never edit it here alone), and the `sha512sums` table keyed `"<version>/<arch>"`. The tool definition holds a helper block, `# >>> go-security-orb install helpers >>>` to `# <<< ... <<<`, identical in all four scripts (`tests/install_test.sh` checks): `gs_download_base_url`, `gs_install_record` (writes `.<binary>.install.json` beside the binary, which `gs_tool_verified` and the run records read), `gs_install_prebuilt`, and the source build helpers `gs_fetch_go`, `gs_build`, `gs_build_verified` and `gs_install_source_built`.

**Mirror logins.** `gs_download_base_url` hands the mirror it validated to the shared logic's `orb_use_mirror`, which reads the `.netrc` file (`NETRC`, or `~/.netrc`, as go and `configure_modules` do; curl itself reads `NETRC` only from 8.16.0) with an awk reader that tokenizes as curl does (a line whose first non-blank character is `#` is a comment, even between a keyword and its value; `macdef` runs to a blank line; an entry can span lines). The first `machine` entry named after the mirror's host, or `host:port`, wins; a `default` entry is never used. Only a complete entry without quoted values counts: it is written straight from awk, never through a shell variable, to `ORB_WORK_DIR/mirror.netrc` under `umask 077`. `orb_download` passes that file with `--netrc-file`, `--no-location-trusted` and `--location` (the second turns off following redirects, the third turns it back on) only to URLs under the mirror, so curl never reads the user's whole file: a password-less entry or a `default` entry there would let curl 7.76.0 to 8.11.1 send the mirror's password to a redirect target (CVE-2024-11053, CVE-2025-0167), and a `github.com` token would go to GitHub. wget can't be given one entry, so a mirror login with only wget fails. The shared install contract checks the rules, and `tests/mirror_login_test.sh` (below) checks them against the real curl.

The default `install_path` of govulncheck, gosec and go-licenses is `~/.go-security-orb/bin`, not `~/bin` as in the other juburr orbs: cimg/go puts `~/go/bin`, which holds a govulncheck 1.1.4 that panics on Go 1.27 code, before `~/bin` on the `PATH`, and the shared logic only adds a directory that isn't on the `PATH` yet, so the image's copy won. A directory of the orb's own is added first.

- **go**: the release archive is hashed; `tool_install` unpacks it beside `install_path` and swaps it in, and refuses an `install_path` that holds anything but an earlier Go installation. The table covers 1.26.0 to 1.27.3.
- **gosec**: a `.tar.gz` member. `install_hash.sh` verifies the release's `checksums.txt` against its Sigstore bundle with gosec's own cosign key (pinned PEM, `GOSEC_COSIGN_KEY`), then the archive against it. Bundles start at 2.24.6; 2.24.1 to 2.24.5 and 2.26.0 have no release assets.
- **govulncheck**, **go-licenses**: no binaries, so the table pins the binary `GS_BUILD_GO_VERSION` (1.27.3) builds, the benchstat model from go-quality-orb: `gs_build` runs `go install <package>@v<version>` with `CGO_ENABLED=0`, `GOFLAGS=-trimpath -modcacherw`, `GOTOOLCHAIN=local`, `GOAMD64=v1`, `GOARM64=v8.0`, `GOFIPS140=off`, `GOENV=off`, `GOWORK=off` and a private GOPATH, leaving the job's `GOPROXY`/`GOSUMDB` alone. The job's go builds when it is that release; otherwise the release is downloaded, checked against `gs_go_sha512sums`, and builds. Their `install_hash.sh` share an identical `# >>> source build install_hash logic >>>` block (`-v` builds, `-g` prints Go entries). Changing `GS_BUILD_GO_VERSION` means generating every entry again and bumping the cache key version.

The build Go matters at run time: govulncheck and gosec type-check with the go/types they were built with, which can't read a newer Go's standard library or export data. `vulncheck` compares `build_go_version` from the install record (or `go version` of the binary) with the go on the PATH before a symbol scan.

When a tool's default version changes, change it in `install_<tool>.yml` and in `install.yml`'s `<tool>_version`, then regenerate the actions; `tests/wiring_test.sh` fails when the YAML defaults differ, `tests/actions_test.sh` when an action's do.

### Command scripts (`src/scripts/`)

Every check runs in each module `gs_modules` resolves from `modules` (`.` by default, a list, or `all`), or on each file `gs_binaries` expands from `binaries`. Every check takes `output_dir`, `report_name`, `junit`, `run_record`, `report_only` and `store_artifacts`. The rule every gate follows: findings fail the step unless `report_only` is true; a tool that didn't complete, or that would pass while checking nothing, always fails it. Each script tells them apart from the tool's output, not only its exit code:

- **vulncheck** / **vulncheck_bin**: govulncheck `-format json` exits 0 with findings, so non-zero is an error. Its stream is pretty-printed JSON objects, read with `jq -s`. `GS_VULN_JQ` (in the lib) turns it into the orb's summary: a finding's level is called when `trace[0].function` is set, imported when `trace[0].package` is, else required; findings group by OSV ID; `ignore` entries match the ID or an alias. SARIF and OpenVEX come from govulncheck's hidden `-mode convert` on the same stream, so each module is scanned once; `gs_vuln_sarif` and `gs_vuln_vex` merge them (collect every run's rules before taking the first run's `tool`, or jq evaluates them against the tool object), with per-scan prefixes and products in `WORK/meta/<id>.prefix|product`. Fail-open guards: govulncheck runs inside each module directory (with `-C` it takes the standard library version from the wrong go); `GOFLAGS=-mod=mod` is refused, read with `go env GOFLAGS` so a flag `go env -w` saved counts too; a `file://` database needs `index/modules.json` and `index/db.json` (without them govulncheck reads loose entries and an empty directory passes); `gs_db_fresh` fails a database older than `max_db_age_days` or with no date; the SBOM must name a standard library version (a bad `GOVERSION` silently checks none); a binary's SBOM must name a Go release. `go_version` sets `GOVERSION`, which govulncheck reads as the standard library version.
- **fetch_vuln_db**: accepts an https zip URL (vuln.go.dev's `vulndb.zip` by default), a local zip or a directory. Every name must match `ENTRY` (`index/{db,modules,vulns}.json`, `ID/<ID>.json`, the two directories), checked before unpacking (with no duplicate names and, with unzip, no symbolic link entries; Python's zipfile writes links as plain files) and again on the unpacked tree, NUL-safe. Then the index must parse, every ID `index/vulns.json` lists must exist, and the database must be fresh. It writes `.go-security-orb.json` (source, zip SHA-256, time, modified, entries), which `gs_db_json` puts in run records, stages beside `path` and swaps it in with renames, and refuses a `path` that holds anything but a database copy. Exports `db_env_var` (default `GO_SECURITY_VULN_DB`) as a `file://` URL.
- **gosec**: exits 1 for issues and for "Golang errors" alike, so the JSON decides: any `Golang errors` entry is an error. The packages come from `go list -find -e -f '{{if or .GoFiles .CgoFiles}}{{.Dir}}{{end}}'` (with tests, the test files too), passed as relative directories, since gosec's own `./...` walks testdata and nested modules. With `-e`, go list reports a pattern it can't resolve as a package with an `Error` and exits 0, so the template marks errors (`E`) apart from directories (`D`): any error but "build constraints exclude all Go files" (a package for another platform), and any pattern but `./...` that "matched no packages", fails before gosec runs. One run writes SARIF (`-fmt=sarif -out`) and JSON (`-stdout -verbose=json`), with `-track-suppressions`. With `tests`, findings are deduplicated by file, line, column and rule. `require_suppression_reasons` counts an `inSource` suppression whose justification is empty or spaces.
- **licenses**: go-licenses `report` with the orb's template (TSV), and the policy applied here, since `check` exits 1 for violations and errors alike and its default policy passes GPL. It always runs with `GOROOT=$(go env GOROOT)`: a `-trimpath` build doesn't know its GOROOT and then takes every package for the standard library. A report without the module's own packages (its module path and the paths below it) is an error. Every failure exits 1. URL lookups need the network, and come back `Unknown` without it.
- **mod_verify**: `go list -mod=readonly -deps -test` runs first (imports go.mod or go.sum lack; `download` and `verify` look such modules up in the checksum database instead, and fail for ones it doesn't know), then `go mod download` (go.sum against what it fetches or finds in the cache: `SECURITY ERROR`/`checksum mismatch` is a finding), `go mod verify` (the cache's files against its own hashes: `has been modified`, `missing ziphash`) and, with `vendor/modules.txt`, `GOWORK=off go mod vendor -o` compared with `diff -r`. With `pin_toolchain`, `GOTOOLCHAIN=local` is exported and `go list -m` finds a go.mod that needs a newer Go. Settings come from `go env -json` run in an empty directory; `public_match` applies Go's `module.MatchPrefixPatterns` to `GOPRIVATE`/`GONOSUMDB`/`GONOPROXY` against a list of public module paths (go env reports `GONOSUMDB` and `GONOPROXY` as `GOPRIVATE` when they are unset, so equal values are attributed to `GOPRIVATE`).
- **fips_bin**: parses `go version -m` text into BuildInfo's shape (`BUILDINFO_JQ`; `go version -m -json` is too new to rely on) and checks it (`CHECK_JQ`): Go release against `min_go_version`; `GOFIPS140` present and in `gofips140` (`latest` and a missing line fail; Go 1.24 records v1.0.0 as `v1.0.0`, 1.25+ as `v1.0.0-c2097c7c`, both CMVP #5247; `v1.26.0` is in process); `DefaultGODEBUG`'s `fips140` on or only (a go.mod `godebug fips140=off` sets it off); `CGO_ENABLED=0` when required; `dep` and `=>` paths matching `CRYPTO_MODULES` exactly or with a `/vN` suffix (so `golang.org/x/crypto/x509roots/fallback` doesn't match), unless `allowed_crypto_modules` accepts them with a reason. `GOEXPERIMENT=boringcrypto` and `microsoft_systemcrypto` are noted; Go refuses `GOFIPS140` with boringcrypto or the `purego` tag. The run record is on by default.
- **fips_test**: `GOFIPS140=<gofips140> GODEBUG=<job's>,fips140=<fips140> go test -json`. Go before 1.24 ignores both settings, so it fails. `build-fail` events and `FailedBuild` are errors; failing top-level tests are findings, and the algorithms come from `<pkg>: use of X is not allowed in FIPS 140-only mode` in their output. A test that panics ends the package's test binary, so each package with a panicking test runs again with `-skip=^(T1|T2)$`, up to `MAX_RERUNS`, unless `extra_args` has `-skip`; the analysis keeps each test's last result, a failure over a pass. `report_only` defaults to true.

### `configure_modules` (`scripts/configure_modules.sh`)

Exports `GOPROXY`, `GONOSUMDB`, `GOPRIVATE` and `GOSUMDB` to later steps and writes one host's credentials to `${NETRC:-~/.netrc}`, checking every parameter before it changes anything: patterns go through the same `public_match` list as mod_verify's, `goproxy` takes `direct`, `off`, `https://` and `file:///` URLs and `http://` only to loopback, never userinfo, a query or a fragment, and `gosumdb` refuses `off`. The netrc entry, `machine HOST login USER password TOKEN`, goes first after a `# configure_modules HOST` marker that lets a later run replace it (and the `# go-security-orb mod_verify HOST` entries mod_verify wrote before 0.2.0), since go and git use the first entry for a host; it is written to a `mktemp` file under `umask 077` and moved into place, so a symlinked `.netrc` is replaced, not written through. Go's netrc parser cuts at `#`, and curl's, which git uses, strips the quotes from a value that starts with one, so credentials with spaces or `#`, or that start with `"`, are refused. go looks a host up with its port and curl without, so a `host` with a port gets a second entry, for the host alone, after its own marker. It warns when `GOAUTH` leaves `netrc` out, or `NETRC` names a file git won't read. The script and `tests/configure_modules_test.sh` are identical in go-security-orb and go-quality-orb, so the script uses neither orb's lib; never edit either in one orb alone.

### Shared helpers (`scripts/lib/go_security.sh`)

- `gs_subst` expands environment variables by piping the value to `circleci env subst` on stdin, and uses the value as is without the CLI (local runs and GitHub Actions). `gs_list` substitutes and splits on commas and spaces; `gs_words` splits `extra_args` with `split_shell_words` (the parser container-ops-orb, oras-orb, crane-orb, skopeo-orb, rust-security-orb and go-quality-orb use), refusing `$(...)`, backticks and shell operators outside quotes.
- `gs_bool`, `gs_match` (`[[ =~ ]]` in the C locale), `gs_uint`, `gs_output`, `gs_tool`/`gs_tool_verified` (warns when a binary isn't the one its install record names), `gs_go`, `gs_require_jq`, `gs_modules`, `gs_label`/`gs_labels`, `gs_join`, `gs_packages`, `gs_go_version`, `gs_binaries`, `gs_env_var_name`, `gs_export` (`printf 'export %s=%q\n'` to `$BASH_ENV`), `gs_json_is` (never `jq -e` on a tool's output: jq 1.6 exits 0 on an empty file), `gs_sha256`, `gs_url_public`.
- `gs_junit FILE SUITE CASES_JSON`, `gs_gate FINDINGS REPORT_ONLY SUMMARY`, `gs_plural`, `gs_tail`.
- `gs_run_record FILE COMMAND OUTCOME EXIT_CODE STARTED` writes the run record from `GS_TOOL`, `GS_TOOL_VERSION`, `GS_ARGS`, `GS_INPUTS` (`role:path`), `GS_REPORTS`, `GS_DB_JSON`, `GS_COUNTS` and `GS_RESULTS`, with `gs_ci_json` (CircleCI or GitHub Actions), `gs_tool_json` (SHA-512 and install record) and `gs_toolchain_json` (`go env -json` of the module settings, URLs without credentials). Keep `schemas/run-record.v1.json` in step with it; `tests/commands_test.sh` checks every record it writes against it.
- Vulnerability helpers: `gs_vuln_setup`, `gs_vuln_db`, `gs_db_json`, `gs_db_fresh`, `gs_ignore`, `gs_vuln_level`, `GS_VULN_JQ`, `gs_vuln_print`, `gs_vuln_sarif`, `gs_vuln_vex`, `gs_has_format`, `gs_vuln_report` (writes every report and the run record, then gates).
- Variables a script sets for the lib to read carry `# shellcheck disable=SC2034 # read by ...`, since shellcheck can't see into the eval'd lib.

### GitHub Actions (`actions/`)

Every command has a composite action of the same name in `actions/<command>/action.yml`, with inputs identical to the command's parameters (names and defaults). Each step passes inputs to the orb's script as `PARAM_*` environment variables, as the command does, and runs it with `bash "${GITHUB_ACTION_PATH}/../run_script.sh" SCRIPT SCRIPT_GO_SECURITY_LIB=<lib>`, with `working-directory: ${{ inputs.working_dir }}`. Inputs never appear inside a `run:` script. A command that stores artifacts has a step that names the artifact `go-security-reports-<report_name>-<random>` (names must be unique in a run) and an `actions/upload-artifact` step with `if: always() && (inputs.store_artifacts == 'true' || inputs.store_artifacts == '1')`. Install actions restore and save `actions/cache` around the install, with the command's key ingredients. Every `uses:` is pinned to a commit SHA with its version in a comment.

`actions/run_script.sh` turns xtrace off first, since the step's environment can hold secrets. It gives a script a fresh `BASH_ENV`, runs it, and passes on what sourcing that file changes, and every variable an `export NAME=` line in it names, changed or not: new `PATH` entries through `GITHUB_PATH` (last first, to keep their order) and other variables through `GITHUB_ENV` with a random delimiter. `NAME=FILE` arguments set `SCRIPT_*` variables to a file's contents, as `<< include() >>` does. It and `tests/actions_test.sh` are meant to be identical in every juburr orb that ships actions (melange-orb has the older copy).

The actions were generated from the command YAML; keep them in sync by hand or with an equivalent generator, and quote any default a YAML 1.1 reader would take for a boolean or number (`"on"`, `"true"`, `"14"`): every input is a string. `tests/actions_test.sh` checks all of this.

### CI Pipeline

- `.circleci/config.yml` - Setup workflow: `test-install` (`tests/install_test.sh`, the shared install contract for go and gosec against `tests/install_fixtures/`, then `tests/install_build_test.sh`, the build install of govulncheck and go-licenses against a stand-in Go), `test-env-subst` (env subst and shell conventions), `test-commands` (`tests/commands_test.sh` on `cimg/go:1.27`, then `tests/configure_modules_test.sh` and `tests/wiring_test.sh`), `test-actions` (`tests/actions_test.sh`), orb-tools lint, pack and review (`orb_name: go-security`), shellcheck.
- `.circleci/test-deploy.yml` - Runs against `tests/fixtures`: `clean` (every check passes), `vulnerable` (golang.org/x/text v0.3.5, GO-2021-0113 called from main) and `weakcrypto` (MD5, SHA-1 with a `#nosec` without a justification; no dependencies). Jobs: `install-test` (every tool, the pinned binaries, a second install from the cache), `checksum-test` (unlisted versions fail closed, `known_versions`, a local HTTPS mirror serving the real gosec release and then a tampered one, then `tests/mirror_login_test.sh`), `arm64-test`, `checks-test` (configure_modules with proxy.golang.org and stand-in credentials, then everything passes on clean, and the checkout is left unchanged), `findings-test` (report_only reports every finding; each check fails by default; tools that can't complete fail with report_only; a tampered module cache fails mod_verify), `machine-test` (fetch_vuln_db, then vulncheck with vuln.go.dev blocked in `/etc/hosts`). Steps that must fail run through `tests/run_command.sh`. Publishing runs on `v*` tags.
- `.github/workflows/actions.yml` - The actions on GitHub's runners: `offline-tests` (the actions, configure_modules and mirror login tests), `install` (amd64 and arm64, pinned binaries, a second install from the cache, an unlisted version failing), `install-from-cache` (every download host blocked), `checks` (both architectures), `findings` (each check fails by default, with `continue-on-error` and outcome checks), `offline-db`.

`tests/mirror_login_test.sh` runs gosec's install.sh with the real curl against a local HTTPS server (Python, standard library) that wants a login on `localhost` and redirects to `127.0.0.1`, which curl treats as another host. With a `.netrc` that also holds a password-less entry for `127.0.0.1`, a `default` entry and a `github.com` token, the redirect target must get no login, also with `location-trusted` in `~/.curlrc`; it covers no entry, `NETRC`, and a wrong password, and prints, as information, whether this curl handed the whole file would have leaked. The install contract checks the same rules against its curl and wget stand-ins.

`tests/commands_test.sh` runs the real go against copies of the fixtures and modules it writes, offline: a file:// module proxy (zips made with a small Go program, since CI images need not have `zip`) for mod_verify's cache and go.sum cases, and stand-ins for gosec, govulncheck (answering with the real streams, SARIF and OpenVEX in `tests/fixtures/govulncheck`, dated today), go-licenses and the CircleCI CLI. A `go` wrapper prints `FILE.buildinfo` for `go version -m FILE`, so fips_bin can be tested on builds this machine can't make. It must pass with bash 4.0, 4.3 and 5 first on the `PATH`.

## Linting

YAML linting uses `.yamllint` config (extends "relaxed", 200-char line limit). Shell scripts are linted with shellcheck via the CI pipeline; the fixture fragments in `tests/install_fixtures/` carry a `# shellcheck shell=bash` directive. `actionlint` checks `.github/workflows/actions.yml`, including the local actions' inputs.

Scripts pass parameter values to `circleci env subst` on stdin, as `gs_subst` does. Passed as an argument, a value starting with `-` is parsed as a CLI flag. `tests/env_subst_test.sh` enforces this.

## Shell conventions

Every script in `src/scripts/` except the shared install code follows the conventions all juburr orbs share. `tests/shell_conventions_test.sh` checks the mechanical ones; it is identical in every orb, so never edit it.

- Line 1 is `#!/bin/bash` and the first command is `set -euo pipefail` (the library in `lib/` has no `set` line). No `set +o history`, never xtrace; `configure_modules.sh` runs `set +o xtrace` before reading the credentials, with a one-line comment.
- Under `-u`, use `${VAR:-}` for variables that may be unset. `PARAM_*` values the command YAML always sets are read directly, so tests that run a script directly must set every one of them (`tests/run_command.sh` sets them from the YAML).
- Expand an array that can be empty as `${arr[@]+"${arr[@]}"}`, not `"${arr[@]}"`: under `-u`, bash before 4.4 treats an empty array as unset and aborts with "unbound variable", and the orb supports bash 4.0+. Bash 4.0 also treats an empty `"$@"` as unbound, even inside `${@+"$@"}`, so copy `"$@"` into an array only when `$#` is non-zero.
- `ERROR: ` and `WARN: ` messages go to stderr (`>&2` on every line of the message); everything else goes to stdout. Every non-zero exit prints an `ERROR:` line first, unless the failing tool already explained itself.
- `$BASH_ENV` exports use `printf 'export %s=%q\n'`; `eval` only runs orb code (`"${SCRIPT_GO_SECURITY_LIB}"`). Secrets never go on a command line, and curl that sends credentials or fetches trusted content uses `--fail` and `--proto '=https'`.
- Temporary files and directories come from `mktemp` and are removed by one EXIT trap per script (a second `trap ... EXIT` replaces the first).
- With `pipefail`, `head -n 5` ending a pipeline can kill the writer with SIGPIPE (exit 141); use `awk 'NR <= 5'`, which reads everything.
- The scripts must work with jq 1.6: never `jq -e` on a tool's output, never name a jq variable `$module` (a keyword in jq 1.6; the scripts use `$mod`), and in jq a pipe binds looser than `as`: write `([...] | unique) as $x`, not `[...] | unique as $x`.

## Naming

Command names say what they check: the tool (`gosec`, `vulncheck` for govulncheck, `vulncheck_bin` for its binary mode), the subject (`licenses`, `mod_verify` for `go mod verify` and more), or the standard (`fips_bin`, `fips_test`). Parameters that map onto one flag or setting take its name in snake_case (`scan`, `test`, `tags`, `gofips140` for `GOFIPS140`, `fips140` for `GODEBUG=fips140`, `include_tests`). Plumbing matches the other juburr orbs: `working_dir`, `modules`, `packages`, `extra_args`, `output_dir`, `report_name`, `junit`, `run_record`, `report_only`, `store_artifacts`; credentials are `env_var_name` parameters named `username` and `password`; variables a command writes are `<thing>_env_var`; lists take commas or spaces.

## Verification

Before committing changes, verify work locally if tools are available on the system:
- Run `shellcheck src/scripts/*.sh src/scripts/lib/*.sh src/install/*/*.sh actions/*.sh tests/*.sh tests/install_fixtures/*.sh`
- Run every `tests/*_test.sh`, also with bash 4.0 and 4.3 first on the `PATH`, with jq 1.6, and under `LC_ALL=en_US.UTF-8` when the system has that locale
- Run `circleci orb pack src/ > orb.yml && circleci orb validate orb.yml`, and validate `.circleci/test-deploy.yml` with the packed orb spliced in under `orbs.go-security-orb`
- Run `actionlint .github/workflows/actions.yml`
- For changes to a command, also run it with the real tools against the fixtures through `tests/run_command.sh`, as `test-deploy.yml` does
