#!/usr/bin/env bash
# Exercise real NSS databases and OpenSC without a reader or host changes.
set -eu
cd "$(dirname "$0")/.."
source ./cac_setup.sh

scratch="$(mktemp -d)"
trap 'rm -rf -- "$scratch"' EXIT
test_home="$scratch/home"
SUDO_USER="$(id -un)"
mkdir -p "$test_home" "$scratch/bin"
export PATH="$scratch/bin:$PATH"

# Only the OS, browser launch and external download boundaries are replaced.
root_check () { :; }
user_check () { ORIG_HOME="$test_home"; }
install_packages () { touch "$scratch/packages-ready"; }
as_user () {
    [[ -f "$scratch/packages-ready" ]] || return 1
    "$@"
}
pgrep () { return 1; }
systemctl () { [[ "$*" == 'enable --now pcscd.socket' ]]; }
wget () {
    [[ "$1" == -qO ]] || return 1
    cp -- "$scratch/bundle.zip" "$2"
    dirname "$2" > "$scratch/download-dir"
}

openssl req -x509 -newkey rsa:2048 -nodes -subj /CN=Linux-CAC-test \
    -keyout "$scratch/test.key" -outform DER -out "$scratch/Test CA.cer" 2>/dev/null
zip -qj "$scratch/bundle.zip" "$scratch/Test CA.cer"
root="$test_home/.config/mozilla/firefox"
modern="$test_home/.local/share/pki/nssdb"
custom="$test_home/External Profile"
mkdir -p "$root/relative.default" "$root/unrelated.dir" "$modern" "$custom"
printf '[Profile0]\r\nPath=relative.default\r\n[Profile1]\nPath=%s\n[InstallABC]\nDefault=relative.default\n' \
    "$custom" > "$root/profiles.ini"
for binary in firefox-esr chromium google-chrome
do
    printf '#!/bin/sh\nexit 1\n' > "$scratch/bin/$binary"
    chmod +x "$scratch/bin/$binary"
done
BROWSERS=('Firefox ESR:firefox-esr:firefox' 'Chromium:chromium:chromium' 'Chrome:google-chrome:chromium')

# An earlier installer may have used a different display name for OpenSC.
module="$(find_opensc_module)"
certutil -N -d "sql:$custom" --empty-password
modutil -dbdir "sql:$custom" -add 'Previous OpenSC name' -libfile "$module" -force >/dev/null
for pass in first second
do
    (main) > "$scratch/$pass.log"
    grep -q 'Certificate databases updated: 3' "$scratch/$pass.log"
    grep -q 'Total certificates imported: 3' "$scratch/$pass.log"
    [[ ! -e "$(cat "$scratch/download-dir")" ]]
    for db in "$root/relative.default" "$custom" "$modern"
    do
        certutil -L -d "sql:$db" -n 'Test CA.cer' >/dev/null
        listing="$(modutil -dbdir "sql:$db" -list)"
        [[ "$(grep -c 'library name: .*opensc-pkcs11.so' <<< "$listing")" == 1 ]]
    done
done
[[ ! -e "$test_home/.pki" && ! -e "$root/unrelated.dir/cert9.db" ]]
grep -q 'Module already present' "$scratch/second.log"

# Fresh Chromium, both DB locations, and a newly created Firefox default.
ORIG_HOME="$scratch/fresh"
databases=()
init_chromium_dbs
[[ -f "$ORIG_HOME/.pki/nssdb/cert9.db" ]]
mkdir -p "$ORIG_HOME/.local/share/pki/nssdb"
init_chromium_dbs
[[ "${#databases[@]}" == 2 ]]
export fixture_root="$ORIG_HOME/.mozilla/firefox"
cat > "$scratch/bin/firefox-esr" <<'BROWSER'
#!/bin/sh
mkdir -p "$fixture_root/initial.default"
printf '[Profile0]\nPath=initial.default\n' > "$fixture_root/profiles.ini"
BROWSER
init_browser_profile_dbs firefox-esr
[[ -f "$fixture_root/initial.default/cert9.db" ]]

expect_status () {
    local expected="$1" actual=0
    shift
    ("$@") > "$scratch/failure.log" 2>&1 || actual=$?
    if [[ "$actual" != "$expected" ]] || grep -q 'Setup complete' "$scratch/failure.log"
    then
        cat "$scratch/failure.log" >&2
        echo "Expected exit $expected from $*, got $actual" >&2
        exit 1
    fi
}

expect_status "$E_BROWSER" ask_yes_no 'Close browsers?' </dev/null
[[ ! '/usr/bin/editor firefox.txt' =~ $(browser_process_pattern firefox) ]]
[[ '/opt/google/chrome/chrome --browser' =~ $(browser_process_pattern google-chrome) ]]

with_missing_module () {
    find_opensc_module () { return 1; }
    main
}
with_service_failure () {
    systemctl () { return 1; }
    main
}
with_unloadable_module () {
    user_check () { ORIG_HOME="$scratch/no-library"; }
    BROWSERS=('Chromium:chromium:chromium')
    find_opensc_module () { echo "$scratch/missing.so"; }
    main
}
expect_status "$E_DATABASE" with_missing_module
expect_status "$E_DATABASE" with_unloadable_module
expect_status 1 with_service_failure

printf 'invalid certificate\n' > "$scratch/broken.cer"
zip -qj "$scratch/bundle.zip" "$scratch/broken.cer"
expect_status "$E_DATABASE" main
grep -q 'Could not import broken.cer' "$scratch/failure.log"
[[ ! -e "$(cat "$scratch/download-dir")" ]]

# Keep the snap installed until a single source profile, including dotfiles,
# has actually been copied to the native installation's default.
ORIG_HOME="$scratch/migration"
snap_profile="$ORIG_HOME/snap/firefox/common/.mozilla/firefox"
native="$ORIG_HOME/.config/mozilla/firefox"
DWNLD_DIR="$scratch/backup"
mkdir -p "$snap_profile/source" "$native/active" "$native/other" "$DWNLD_DIR"
printf '[Profile0]\nPath=source\n' > "$snap_profile/profiles.ini"
printf '[Profile0]\nPath=other\n[Profile1]\nPath=active\n[InstallABC]\nDefault=active\n' > "$native/profiles.ini"
touch "$snap_profile/source/.bookmark-fixture"

install_native_firefox () { :; }
check_for_ff_pin () { :; }
repin_firefox () { :; }
snap () {
    [[ "$*" == 'remove firefox' && -f "$native/active/.bookmark-fixture" ]] || return 1
    touch "$scratch/snap-removed"
}
backup_exists=false
databases=()
reconfigure_firefox <<< y
[[ -e "$scratch/snap-removed" && ! -e "$native/other/.bookmark-fixture" ]]

# Multiple source profiles must leave the snap in place.
mkdir "$snap_profile/second"
printf '[Profile1]\nPath=second\n' >> "$snap_profile/profiles.ini"
rm "$scratch/snap-removed"
expect_status 1 reconfigure_firefox <<< y
[[ ! -e "$scratch/snap-removed" ]]
