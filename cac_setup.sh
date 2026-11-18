#!/usr/bin/env bash

# cac_setup.sh
# Description: Setup a Linux environment for Common Access Card use.

# Ensure globs that match nothing expand to nothing (not the literal pattern),
# so an empty certificate directory can't produce a bogus "*.cer" import.
shopt -s nullglob

# Constants
EXIT_SUCCESS=0                      # Success exit code
E_NOTROOT=86                        # Non-root exit error
E_BROWSER=87                        # Compatible browser not found
E_DATABASE=88                       # No database located
E_DISTRO=89                         # Unsupported Linux distribution
FF_PROFILE_NAME="old_ff_profile"    # Location to save old Firefox profile

ERR_COLOR='\033[0;31m'              # Red for error messages
INFO_COLOR='\033[0;33m'             # Yellow for notes
NO_COLOR='\033[0m'                  # Revert terminal back to no color

DB_FILENAME="cert9.db"
CERT_EXTENSION="cer"
CERT_FILENAME="AllCerts"
BUNDLE_FILENAME="AllCerts.zip"
MODULE_NAME="CAC Module (OpenSC)" # NSS security-module display name for the OpenSC PKCS#11 library

# Display name, executable and browser family.
BROWSERS=(
    "Firefox:firefox:firefox"
    "Firefox ESR:firefox-esr:firefox"
    "LibreWolf:librewolf:firefox"
    "Waterfox:waterfox:firefox"
    "Google Chrome:google-chrome:chromium"
    "Chromium:chromium-browser:chromium"
    "Chromium:chromium:chromium"
    "Brave:brave-browser:chromium"
    "Microsoft Edge:microsoft-edge-stable:chromium"
    "Vivaldi:vivaldi-stable:chromium"
)

main ()
{
    snap_ff=false                       # Flag to prompt for how to handle snap Firefox
    backup_exists=false                 # Whether a Firefox profile backup was made
    ff_was_pinned=false                 # Whether Firefox was pinned in GNOME favorites
    OS_FAMILY=""                        # Detected OS family (debian/fedora/arch)

    ORIG_HOME=""                        # Home dir of the invoking user (set by user_check)
    CERT_URL="https://militarycac.com/maccerts/$BUNDLE_FILENAME"
    total_imported=0                    # Running count of certificates imported

    local -a selected_browsers=()
    found_browsers=()
    databases=()

    detect_os
    root_check
    user_check
    check_running_browsers
    browser_check

    print_info "Installing middleware and essential utilities..."
    if ! install_packages
    then
        print_err "Failed to install required packages. Check your network and package manager, then re-run."
        exit 1
    fi

    # Keep downloads and any migration backup private to this run and user.
    DWNLD_DIR="$(as_user mktemp -d /tmp/linux-cac.XXXXXXXX)" || exit 1
    trap 'cleanup "$?"' EXIT
    init_browser_dbs

    if [ "${#databases[@]}" -eq 0 ]
    then
        print_err "No browser certificate databases found. Start and close the browser, then rerun setup."
        exit "$E_DATABASE"
    fi

    local opensc_module
    if ! opensc_module="$(find_opensc_module)"
    then
        print_err "Could not locate opensc-pkcs11.so. Check the OpenSC package installation."
        exit "$E_DATABASE"
    fi

    # Pull all necessary files
    print_info "Downloading DoD certificates..."
    if ! as_user wget -qO "$DWNLD_DIR/$BUNDLE_FILENAME" "$CERT_URL"
    then
        print_err "Failed to download DoD certificates from $CERT_URL"
        exit 1
    fi
    print_info "Done."

    if ! as_user unzip -qo "$DWNLD_DIR/$BUNDLE_FILENAME" -d "$DWNLD_DIR/$CERT_FILENAME"
    then
        print_err "Failed to extract certificate bundle. The download may be corrupt."
        exit "$E_DATABASE"
    fi

    # Ensure at least one certificate was actually extracted before importing
    local -a cert_files
    cert_files=("$DWNLD_DIR/$CERT_FILENAME"/*."$CERT_EXTENSION")
    if [ "${#cert_files[@]}" -eq 0 ]
    then
        print_err "No certificates (*.$CERT_EXTENSION) found in the downloaded bundle. Aborting."
        exit "$E_DATABASE"
    fi

    local db failed=0
    for db in "${databases[@]}"
    do
        import_certs "$db" || failed=1
        load_pkcs11_module "$db" "$opensc_module" || failed=1
    done

    if [ "$failed" -ne 0 ]
    then
        print_err "Browser configuration was incomplete. See the database errors above and rerun setup."
        exit "$E_DATABASE"
    fi

    verify_pkcs11
    if ! systemctl enable --now pcscd.socket
    then
        print_err "Could not enable and start pcscd.socket."
        exit 1
    fi

    # Summary of what was accomplished
    echo
    print_info "===================== Setup complete ====================="
    print_info "Configured browser(s): ${found_browsers[*]}"
    print_info "Certificate databases updated: ${#databases[@]}"
    print_info "Total certificates imported: $total_imported"
    echo
    print_info "Next steps:"
    print_info "  1. Insert your CAC and fully restart your browser(s)."
    print_info "  2. Visit a site that requires your certificate and enter your PIN when prompted."
    print_info "  3. If no prompt appears, ensure the browser is fully closed (no background"
    print_info "     processes), reboot, then try again."

    exit "$EXIT_SUCCESS"
} # main


as_user ()
{
    sudo -H -u "$SUDO_USER" -- "$@"
}

cleanup ()
{
    if [ "$1" -ne 0 ] && [ "$backup_exists" == true ]
    then
        print_err "Firefox profile backup retained in $DWNLD_DIR/$FF_PROFILE_NAME"
    else
        as_user rm -rf -- "${DWNLD_DIR:?}" || print_err "Could not clean up $DWNLD_DIR"
    fi
}

# Keep one entry per NSS directory, including when browser commands are aliases.
init_nss_db ()
{
    local dir="$1" db
    for db in "${databases[@]}"
    do
        [[ "$db" -ef "$dir" ]] && return 0
    done
    if [ ! -f "$dir/$DB_FILENAME" ]
    then
        if ! as_user mkdir -p -- "$dir" || ! as_user certutil -N -d "sql:$dir" --empty-password
        then
            print_err "Could not initialize the NSS database in $dir"
            return 1
        fi
    fi
    databases+=("$dir")
}

# Read profile paths ([ProfileN] Path) or install defaults ([Install...] Default)
# from Firefox's registry, including profiles stored outside the browser root.
firefox_profiles ()
{
    local -n result="$1"
    local key="$2" root profile paths
    shift 2
    result=()
    for root in "$@"
    do
        if [ -f "$root/profiles.ini" ]
        then
            # shellcheck disable=SC2016
            paths="$(as_user awk -v key="$key" '
                { sub(/\r$/, "") }
                /^\[/ { selected = (key == "Path" ? /^\[Profile[0-9]+\]$/ : /^\[Install[^]]+\]$/) }
                selected && index($0, key "=") == 1 { print substr($0, length(key) + 2) }
            ' "$root/profiles.ini")" || return 1
            while IFS= read -r profile
            do
                [ -n "$profile" ] || continue
                [[ "$profile" = /* ]] || profile="$root/$profile"
                [ -d "$profile" ] && result+=("$profile")
            done <<< "$paths"
        elif [ "$key" == Path ]
        then
            for profile in "$root"/*/"$DB_FILENAME"
            do
                result+=("${profile%/*}")
            done
        fi
    done
    return 0
}

init_browser_profile_dbs ()
{
    local binary="$1" profile
    local -a roots profiles
    case "$binary" in
        firefox|firefox-esr) roots=("$ORIG_HOME/.mozilla/firefox" "$ORIG_HOME/.config/mozilla/firefox") ;;
        librewolf) roots=("$ORIG_HOME/.librewolf" "$ORIG_HOME/.config/librewolf") ;;
        waterfox)  roots=("$ORIG_HOME/.waterfox" "$ORIG_HOME/.config/waterfox") ;;
    esac

    firefox_profiles profiles Path "${roots[@]}" || return 1
    if [ "${#profiles[@]}" -eq 0 ]
    then
        # Let the browser select its default profile and exit on its own.
        # -CreateProfile alone can leave a named profile unused on first launch.
        print_info "Initializing the default $binary profile..."
        if ! as_user timeout -k 5 60 "$binary" --headless --no-remote --screenshot /dev/null about:blank >/dev/null
        then
            print_err "Could not initialize $binary. Start and close it, then rerun setup."
            return 1
        fi
        firefox_profiles profiles Path "${roots[@]}" || return 1
    fi
    if [ "${#profiles[@]}" -eq 0 ]
    then
        print_err "Could not locate a $binary profile. Start and close the browser, then rerun setup."
        return 1
    fi
    for profile in "${profiles[@]}"
    do
        init_nss_db "$profile" || return 1
    done
}

init_chromium_dbs ()
{
    local legacy="$ORIG_HOME/.pki/nssdb" modern="$ORIG_HOME/.local/share/pki/nssdb"
    # Older releases require the legacy path. Newer releases also honor it,
    # but creating it alongside an existing modern database can mask that DB.
    if [ -d "$legacy" ] || [ ! -d "$modern" ]
    then
        init_nss_db "$legacy" || return 1
    fi
    if [ -d "$modern" ]
    then
        init_nss_db "$modern" || return 1
    fi
}

# Prints message with red [ERROR] tag before the message
print_err ()
{
    printf '%b[ERROR]%b %s\n' "$ERR_COLOR" "$NO_COLOR" "$1" >&2
} # print_err


# Prints message with yellow [INFO] tag before the message
print_info ()
{
    printf '%b[INFO]%b %s\n' "$INFO_COLOR" "$NO_COLOR" "$1"
} # print_info


# Check to ensure the script is executed as root
root_check ()
{
    # Only users with $UID 0 have root privileges
    local ROOT_UID=0

    # Ensure the script is ran as root
    if [ "${EUID:-$(id -u)}" -ne "$ROOT_UID" ]
    then
        print_err "Please run this script as root."
        exit "$E_NOTROOT"
    fi
} # root_check


# Ensure the script was launched via sudo by a regular user, and resolve that
# user's home directory. The script drops to $SUDO_USER to launch browsers and
# searches that user's home for certificate databases, so a missing SUDO_USER
# (e.g. running from a raw root shell) would otherwise fail in confusing ways.
user_check ()
{
    if [ -z "${SUDO_USER:-}" ] || [ "$SUDO_USER" == "root" ]
    then
        print_err "This script must be run with sudo as your regular user, not from a root shell."
        print_info "Example: sudo bash cac_setup.sh"
        exit "$E_NOTROOT"
    fi

    ORIG_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
    if [ -z "$ORIG_HOME" ] || [ ! -d "$ORIG_HOME" ]
    then
        print_err "Could not determine a valid home directory for user '$SUDO_USER'."
        exit "$E_NOTROOT"
    fi
} # user_check


is_snap_firefox ()
{
    local launcher
    launcher="$(command -v firefox)" || return 1
    [[ "$launcher" == */snap/bin/firefox ]] || grep -Fq 'exec /snap/bin/firefox' "$launcher"
}

ask_yes_no ()
{
    local choice
    while true
    do
        if ! read -rp "$1 (y/n) " choice
        then
            print_err "Setup requires an answer. Rerun it in an interactive terminal."
            exit "$E_BROWSER"
        fi
        case "$choice" in
            y|Y) return 0 ;;
            n|N) return 1 ;;
        esac
    done
}

install_native_firefox ()
{
    print_info "Installing native Firefox from the Mozilla Team PPA..."
    add-apt-repository -y ppa:mozillateam/ppa || return 1
    printf '%s\n' 'Package: firefox*' 'Pin: release o=LP-PPA-mozillateam' 'Pin-Priority: 1001' \
        > /etc/apt/preferences.d/mozilla-firefox || return 1
    # shellcheck disable=SC2016
    echo 'Unattended-Upgrade::Allowed-Origins:: "LP-PPA-mozillateam:${distro_codename}";' \
        > /etc/apt/apt.conf.d/51unattended-upgrades-firefox || return 1
    DEBIAN_FRONTEND=noninteractive apt install -y --allow-downgrades firefox || return 1
    hash -r
    if ! command -v firefox >/dev/null || is_snap_firefox
    then
        print_err "Could not find a native Firefox installation. Keeping the snap."
        return 1
    fi
}


# Finish configuring the native browser before removing the user's snap.
reconfigure_firefox ()
{
    local -a profiles
    local snap_home="$ORIG_HOME/snap/firefox/common"
    local -a native_roots=("$ORIG_HOME/.mozilla/firefox" "$ORIG_HOME/.config/mozilla/firefox")
    check_for_ff_pin
    firefox_profiles profiles Path "$snap_home/.mozilla/firefox" "$snap_home/.config/mozilla/firefox" || return 1
    if [ "${#profiles[@]}" -gt 0 ] && ask_yes_no "Copy your snap profile over the native default Firefox profile, including bookmarks and saved logins?"
    then
        if [ "${#profiles[@]}" -ne 1 ]
        then
            print_err "Several snap profiles exist. Migrate them manually before replacing Firefox."
            return 1
        fi
        as_user mkdir -- "$DWNLD_DIR/$FF_PROFILE_NAME" || return 1
        as_user cp -a -- "${profiles[0]}/." "$DWNLD_DIR/$FF_PROFILE_NAME/" || return 1
        backup_exists=true
    fi

    install_native_firefox || return 1
    init_browser_profile_dbs firefox || return 1

    if [ "$backup_exists" == true ]
    then
        firefox_profiles profiles Path "${native_roots[@]}" || return 1
        if [ "${#profiles[@]}" -gt 1 ]
        then
            firefox_profiles profiles Default "${native_roots[@]}" || return 1
        fi
        if [ "${#profiles[@]}" -ne 1 ]
        then
            print_err "Cannot select a single native Firefox profile for migration. Keeping the snap."
            return 1
        fi
        as_user cp -a -- "$DWNLD_DIR/$FF_PROFILE_NAME/." "${profiles[0]}/" || return 1
    fi
    snap remove firefox || return 1
    repin_firefox
}

# Match the invoking user's browser executable, including its packaged name.
# A browser name in a document path or another process's arguments is unrelated.
browser_process_pattern ()
{
    local names="$1"
    case "$1" in
        google-chrome) names='google-chrome(-stable)?|chrome' ;;
        chromium-browser|chromium) names='chromium(-browser)?' ;;
        microsoft-edge-stable) names='microsoft-edge(-stable)?|msedge' ;;
        brave-browser) names='brave(-browser)?' ;;
        vivaldi-stable) names='vivaldi(-stable|-bin)?' ;;
        firefox|firefox-esr) names='firefox(-esr|-bin)?' ;;
    esac
    printf '^([^[:space:]]*/)?(%s)([[:space:]]|$)' "$names"
}

check_running_browsers ()
{
    local entry name binary pattern
    local -a running=() patterns=()
    local -A checked=()
    for entry in "${BROWSERS[@]}"
    do
        IFS=: read -r name binary _ <<< "$entry"
        pattern="$(browser_process_pattern "$binary")"
        if [[ ! ${checked[$pattern]:-} ]] && pgrep -u "$SUDO_USER" -f -- "$pattern" >/dev/null
        then
            running+=("$name")
            patterns+=("$pattern")
        fi
        checked[$pattern]=1
    done
    if [ "${#running[@]}" -eq 0 ]
    then
        return 0
    fi
    print_info "Running browser(s) detected: ${running[*]}"
    if ! ask_yes_no "Close these browsers?"
    then
        print_info "Close your browsers and restart setup."
        exit "$E_BROWSER"
    fi
    for pattern in "${patterns[@]}"
    do
        pkill -TERM -u "$SUDO_USER" -f -- "$pattern"
    done
    sleep 2
    for pattern in "${patterns[@]}"
    do
        pkill -KILL -u "$SUDO_USER" -f -- "$pattern"
    done
    sleep 1
    for pattern in "${patterns[@]}"
    do
        if pgrep -u "$SUDO_USER" -f -- "$pattern" >/dev/null
        then
            print_err "A browser is still running. Close it and restart setup."
            exit "$E_BROWSER"
        fi
    done
}

browser_check ()
{
    local entry name binary
    local -A detected=()
    for entry in "${BROWSERS[@]}"
    do
        IFS=: read -r name binary _ <<< "$entry"
        command -v "$binary" >/dev/null || continue
        [[ ${detected[$name]:-} ]] && continue
        if [[ "$binary" == firefox && "$OS_FAMILY" == debian ]] && is_snap_firefox
        then
            snap_ff=true
            continue
        fi
        print_info "Found $name."
        selected_browsers+=("$entry")
        found_browsers+=("$name")
        detected[$name]=1
    done

    if [ "$snap_ff" == true ]
    then
        print_info "This fork configures native Firefox. You can replace the Firefox snap with the apt version."
        if ask_yes_no "Switch to native Firefox and remove the snap?"
        then
            found_browsers+=("Firefox")
        else
            snap_ff=false
        fi
    fi
    if [ "${#found_browsers[@]}" -eq 0 ]
    then
        print_err "No compatible browser selected. Install a supported native browser and rerun setup."
        exit "$E_BROWSER"
    fi
}

init_browser_dbs ()
{
    local entry binary type
    local pki_initialized=false
    for entry in "${selected_browsers[@]}"
    do
        IFS=: read -r _ binary type <<< "$entry"
        if [ "$type" == chromium ]
        then
            if [ "$pki_initialized" == false ]
            then
                init_chromium_dbs || exit "$E_DATABASE"
                pki_initialized=true
            fi
        else
            init_browser_profile_dbs "$binary" || exit "$E_DATABASE"
        fi
    done
    if [ "$snap_ff" == true ]
    then
        reconfigure_firefox || exit "$E_BROWSER"
    fi
}

import_certs ()
{
    local db="$1" cert imported=0 failed=0
    print_info "Loading certificates into $db"
    for cert in "${cert_files[@]}"
    do
        if as_user certutil -d "sql:$db" -A -t TC -n "${cert##*/}" -i "$cert"
        then
            imported=$((imported + 1))
        else
            print_err "Could not import ${cert##*/} into $db"
            failed=$((failed + 1))
        fi
    done
    total_imported=$((total_imported + imported))
    print_info "Imported $imported certificate(s) into $db."
    [ "$failed" -eq 0 ]
}

# Keep the existing position of a pinned Firefox launcher during migration.
check_for_ff_pin ()
{
    local favorites
    if [[ "${XDG_CURRENT_DESKTOP:-}" =~ [Gg][Nn][Oo][Mm][Ee] ]] &&
        favorites="$(as_user gsettings get org.gnome.shell favorite-apps)"
    then
        if [[ "$favorites" == *"'firefox.desktop'"* || "$favorites" == *"'firefox_firefox.desktop'"* ]]
        then
            ff_was_pinned=true
        fi
    fi
}

repin_firefox ()
{
    local favorites snap_id="'firefox_firefox.desktop'" native_id="'firefox.desktop'"
    [ "$ff_was_pinned" == true ] || return 0
    favorites="$(as_user gsettings get org.gnome.shell favorite-apps)" || return 0
    case "$favorites" in
        *"$native_id"*) return 0 ;;
        *"$snap_id"*) favorites="${favorites/"$snap_id"/"$native_id"}" ;;
        '[]'|'@as []') favorites="[$native_id]" ;;
        *) favorites="${favorites%]}, $native_id]" ;;
    esac
    as_user gsettings set org.gnome.shell favorite-apps "$favorites" || print_info "Pin Firefox manually in GNOME Favorites."
}


# Detect the Linux distribution family and set OS_FAMILY accordingly
detect_os ()
{
    if [ ! -f /etc/os-release ]
    then
        print_err "Cannot detect Linux distribution. /etc/os-release not found."
        exit "$E_DISTRO"
    fi

    # shellcheck source=/dev/null
    . /etc/os-release

    local distro_id="${ID:-}"
    local distro_like="${ID_LIKE:-}"
    local distro_info="$distro_id $distro_like"

    if [[ "$distro_info" =~ [Dd]ebian|[Uu]buntu ]]
    then
        OS_FAMILY="debian"
    elif [[ "$distro_info" =~ [Ff]edora|[Rr]hel|[Cc]ent[Oo][Ss] ]]
    then
        OS_FAMILY="fedora"
    elif [[ "$distro_info" =~ [Aa]rch ]]
    then
        OS_FAMILY="arch"
    else
        print_err "Unsupported Linux distribution: ${PRETTY_NAME:-$distro_id}"
        print_info "Supported distributions: Debian/Ubuntu, Fedora, Arch Linux"
        exit "$E_DISTRO"
    fi

    print_info "Detected OS: ${PRETTY_NAME:-$distro_id} (family: $OS_FAMILY)"
} # detect_os


# Install middleware packages using the appropriate package manager
install_packages ()
{
    case "$OS_FAMILY" in
        debian)
            apt update || print_err "apt update reported errors; attempting to continue..."
            DEBIAN_FRONTEND=noninteractive apt install -y libpcsclite1 pcscd libccid libpcsc-perl pcsc-tools libnss3-tools unzip wget opensc || return 1
            ;;
        fedora)
            dnf install -y pcsc-lite pcsc-lite-ccid opensc nss-tools unzip wget pcsc-tools || return 1
            ;;
        arch)
            pacman -S --needed --noconfirm pcsclite ccid opensc nss unzip wget pcsc-tools || return 1
            ;;
    esac
} # install_packages


# Locate the OpenSC PKCS#11 shared object. Its path varies by distribution and
# CPU architecture (Debian multiarch, Fedora lib64, Arch), so check the common
# locations and fall back to a search. Prints the path on success.
find_opensc_module ()
{
    local arch_dir
    arch_dir="$(uname -m)-linux-gnu"
    local candidates=(
        "/usr/lib/$arch_dir/opensc-pkcs11.so"
        "/usr/lib/$arch_dir/pkcs11/opensc-pkcs11.so"
        "/usr/lib64/opensc-pkcs11.so"
        "/usr/lib64/pkcs11/opensc-pkcs11.so"
        "/usr/lib/opensc-pkcs11.so"
        "/usr/lib/pkcs11/opensc-pkcs11.so"
    )

    local candidate
    for candidate in "${candidates[@]}"
    do
        if [ -e "$candidate" ]
        then
            echo "$candidate"
            return 0
        fi
    done

    # Fall back to searching the common library roots
    local found
    found="$(find /usr/lib /usr/lib64 -name opensc-pkcs11.so -print -quit 2>/dev/null)"
    if [ -n "$found" ]
    then
        echo "$found"
        return 0
    fi

    return 1
} # find_opensc_module


# Load the OpenSC PKCS#11 module into a single NSS database so the owning
# browser will prompt for the CAC PIN. Idempotent: skips databases that already
# have the module. Runs as the invoking user so NSS files stay user-owned.
load_pkcs11_module ()
{
    local db_root="$1"
    local module="$2"

    # Older installations may have registered the same library under another
    # display name. modutil reports the library path independently of its name.
    local listing
    if ! listing="$(as_user env LC_ALL=C modutil -dbdir "sql:$db_root" -list)"
    then
        print_err "Could not list security modules in $db_root"
        return 1
    fi
    if awk '
        /^[[:space:]]*[0-9]+\./ { opensc = 0 }
        /^[[:space:]]*library name: (.*\/)?opensc-pkcs11\.so$/ { opensc = 1 }
        opensc && /^[[:space:]]*status: loaded$/ { loaded = 1 }
        END { exit !loaded }
    ' <<< "$listing"
    then
        print_info "Module already present in $db_root"
        return 0
    fi

    # -force suppresses modutil's interactive confirmation prompt
    if as_user modutil -dbdir "sql:$db_root" -add "$MODULE_NAME" -libfile "$module" -force >/dev/null
    then
        print_info "Loaded module into $db_root"
    else
        print_err "Failed to load module into $db_root"
        return 1
    fi
} # load_pkcs11_module


# Sanity-check that the OpenSC PKCS#11 module is visible to p11-kit. The module
# is loaded directly into each browser database by load_pkcs11_module; this is
# an informational check and also covers system-wide NSS consumers on
# Fedora/Arch, where p11-kit auto-loads the module.
verify_pkcs11 ()
{
    if ! command -v p11-kit >/dev/null 2>&1
    then
        return 0
    fi

    print_info "Verifying OpenSC PKCS#11 module registration..."
    if as_user p11-kit list-modules 2>/dev/null | grep -qi opensc
    then
        print_info "OpenSC PKCS#11 module is registered with p11-kit."
    else
        print_info "p11-kit did not report OpenSC. Browser databases use the directly registered module."
    fi
    print_info "Done"
} # verify_pkcs11

if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]}" == "$0" ]]
then
    main
fi
