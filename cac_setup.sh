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
DWNLD_DIR="/tmp"                    # Location to place artifacts
FF_PROFILE_NAME="old_ff_profile"    # Location to save old Firefox profile

ERR_COLOR='\033[0;31m'              # Red for error messages
INFO_COLOR='\033[0;33m'             # Yellow for notes
NO_COLOR='\033[0m'                  # Revert terminal back to no color

DB_FILENAME="cert9.db"
CERT_EXTENSION="cer"
CERT_FILENAME="AllCerts"
BUNDLE_FILENAME="AllCerts.zip"

# Browser registry — each entry is "DisplayName:binary:db_pattern:type"
#   db_pattern: grep pattern to match cert9.db paths for this browser
#   type: "firefox" (Firefox-family) or "chromium" (Chromium-family)
# To add a new browser, add an entry here. Chromium-based browsers all share
# the ~/.pki/nssdb/ database, so only one needs to run to initialize it.
BROWSERS=(
    "Firefox:firefox:firefox:firefox"
    "LibreWolf:librewolf:librewolf:firefox"
    "Waterfox:waterfox:waterfox:firefox"
    "Google Chrome:google-chrome:pki:chromium"
    "Chromium:chromium-browser:pki:chromium"
    "Chromium:chromium:pki:chromium"
    "Brave:brave-browser:pki:chromium"
    "Microsoft Edge:microsoft-edge-stable:pki:chromium"
    "Vivaldi:vivaldi-stable:pki:chromium"
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

    # Arrays populated by browser_check
    found_db_patterns=()                # Database grep patterns for detected browsers
    found_browsers=()                   # Display names of detected compatible browsers

    detect_os
    root_check
    user_check
    check_running_browsers
    browser_check

    # Build deduplicated grep pattern from detected browsers
    local db_pattern=""
    local -A seen_patterns
    for p in "${found_db_patterns[@]}"
    do
        if [ -z "${seen_patterns[$p]:-}" ]
        then
            seen_patterns[$p]=1
            if [ -n "$db_pattern" ]
            then
                db_pattern="$db_pattern\|$p"
            else
                db_pattern="$p"
            fi
        fi
    done

    # Exclude snap paths only on Debian-family systems
    local db_exclude=""
    if [ "$OS_FAMILY" == "debian" ]
    then
        db_exclude="snap"
    fi

    # Browser profile/database creation can lag behind the headless launch, so
    # retry the search a few times before giving up. This is the most common
    # cause of the "No valid databases located" failure.
    local db_tries=3
    mapfile -t databases < <(find_db "$db_pattern" "$db_exclude")
    while [ "${#databases[@]}" -eq 0 ] && [ "$db_tries" -gt 1 ]
    do
        print_info "No certificate databases found yet; waiting for browser profiles to initialize..."
        sleep 3
        mapfile -t databases < <(find_db "$db_pattern" "$db_exclude")
        db_tries=$((db_tries - 1))
    done

    # Check if databases were found properly
    if [ "${#databases[@]}" -eq 0 ]
    then
        # Database was not found
        if [ "$snap_ff" == true ]
        then
            revert_firefox
        else
            # Firefox was not replaced, exit with E_DATABASE error
            print_err "No valid databases located. Try running, then closing your browser(s), then start this script again."
            echo -e "\tExiting..."

            exit "$E_DATABASE"
        fi
    else
        # Database was found. (Good)
        # If Firefox was replaced from snap to apt, the snap_ff flag is no longer
        # relevant since we now have a valid database from the apt version.
        snap_ff=false
    fi

    # Install middleware and necessary utilities
    print_info "Installing middleware and essential utilities..."
    if ! install_packages
    then
        print_err "Failed to install required packages. Check your network and package manager, then re-run."
        exit 1
    fi
    print_info "Done"

    # Pull all necessary files
    print_info "Downloading DoD certificates..."
    if ! wget -qP "$DWNLD_DIR" "$CERT_URL"
    then
        print_err "Failed to download DoD certificates from $CERT_URL"
        exit 1
    fi
    print_info "Done."

    # Unzip cert bundle
    if [ ! -e "$DWNLD_DIR/$BUNDLE_FILENAME" ]
    then
        print_err "Certificate bundle not found at $DWNLD_DIR/$BUNDLE_FILENAME"
        exit "$E_DATABASE"
    fi
    mkdir -p "$DWNLD_DIR/$CERT_FILENAME"
    if ! unzip -qo "$DWNLD_DIR/$BUNDLE_FILENAME" -d "$DWNLD_DIR/$CERT_FILENAME"
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

    # Import certificates into cert9.db databases for browsers
    for db in "${databases[@]}"
    do
        if [ -n "$db" ]
        then
            import_certs "$db"
        fi
    done

    register_pkcs11

    print_info "Enabling pcscd service to start on boot..."
    systemctl enable pcscd.socket
    if [ "$OS_FAMILY" != "debian" ]
    then
        systemctl start pcscd.socket
    fi
    print_info "Done"

    # Remove artifacts
    print_info "Removing artifacts..."
    if ! rm -rf "${DWNLD_DIR:?}"/{"$BUNDLE_FILENAME","$CERT_FILENAME","$FF_PROFILE_NAME"} 2>/dev/null
    then
        print_err "Failed to remove artifacts. Artifacts were stored in ${DWNLD_DIR}."
    else
        print_info "Done."
    fi

    # Summary of what was accomplished
    echo
    print_info "===================== Setup complete ====================="
    if [ "${#found_browsers[@]}" -gt 0 ]
    then
        print_info "Configured browser(s): ${found_browsers[*]}"
    fi
    print_info "Certificate databases updated: ${#databases[@]}"
    print_info "Total certificates imported: $total_imported"
    echo
    print_info "Next steps:"
    print_info "  1. Insert your CAC and restart your browser(s)."
    print_info "  2. If a site does not prompt for your certificate, reboot."
    print_info "  3. If issues persist, run 'pkcs11-register' and try again."

    exit "$EXIT_SUCCESS"
} # main


# Find cert9.db databases, excluding Trash directories
# Usage: find_db [include_filter] [exclude_filter]
find_db ()
{
    local include="${1:-}"
    local exclude="${2:-}"
    local results
    results=$(find "$ORIG_HOME" -name "$DB_FILENAME" 2>/dev/null | grep -v "Trash")

    if [ -n "$include" ]
    then
        results=$(echo "$results" | grep "$include")
    fi
    if [ -n "$exclude" ]
    then
        results=$(echo "$results" | grep -v "$exclude")
    fi
    echo "$results"
} # find_db


# Run a browser headlessly to initialize its profile/database directory
# Usage: run_browser <binary> <headless_args>
run_browser ()
{
    local binary="$1"
    local args="$2"
    print_info "Starting $binary silently to complete post-install actions..."
    # shellcheck disable=SC2086
    sudo -H -u "$SUDO_USER" "$binary" $args >/dev/null 2>&1 &
    sleep 3
    graceful_kill "$binary"
} # run_browser


# Gracefully terminate a process, falling back to SIGKILL.
# Matches against the full command line (-f) to stay consistent with how
# browsers are detected. This matters for binaries whose names exceed the
# 15-char kernel "comm" limit (e.g. chromium-browser, microsoft-edge-stable),
# which plain pkill would silently fail to match.
graceful_kill ()
{
    local process_name="$1"
    pkill -f "$process_name" 2>/dev/null
    sleep 2
    if pgrep -f "$process_name" >/dev/null 2>&1
    then
        pkill -9 -f "$process_name" 2>/dev/null
    fi
    sleep 1
} # graceful_kill


# Prints message with red [ERROR] tag before the message
print_err ()
{
    echo -e "${ERR_COLOR}[ERROR]${NO_COLOR} $1"
} # print_err


# Prints message with yellow [INFO] tag before the message
print_info ()
{
    echo -e "${INFO_COLOR}[INFO]${NO_COLOR} $1"
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


# Replace the current snap version of Firefox with the compatible apt version of Firefox
reconfigure_firefox ()
{
    # Replace snap Firefox with version from PPA maintained via Mozilla
    check_for_ff_pin
    #Profile migration
    backup_ff_profile
    print_info "Removing Snap version of Firefox"
    snap remove --purge firefox
    print_info "Adding PPA for Mozilla maintained Firefox"
    add-apt-repository -y ppa:mozillateam/ppa
    print_info "Setting priority to prefer Mozilla PPA over snap package"
    echo -e "Package: *\nPin: release o=LP-PPA-mozillateam\nPin-Priority: 1001" > /etc/apt/preferences.d/mozilla-firefox
    print_info "Enabling updates for future Firefox releases"
    # shellcheck disable=SC2016
    echo -e 'Unattended-Upgrade::Allowed-Origins:: "LP-PPA-mozillateam:${distro_codename}";' > /etc/apt/apt.conf.d/51unattended-upgrades-firefox
    print_info "Installing Firefox via apt"
    DEBIAN_FRONTEND=noninteractive apt install -y --allow-downgrades firefox
    print_info "Completed re-installation of Firefox"

    # Forget the previous location of firefox executable
    if hash firefox
    then
        hash -d firefox
    fi

    run_browser "firefox" "--headless --first-startup"
    print_info "Finished, closing Firefox."

    if [ "$backup_exists" == true ]
    then
        print_info "Migrating user profile into newly installed Firefox"
        migrate_ff_profile "migrate"
    fi

    repin_firefox
} # reconfigure_firefox


# Check if any supported browsers are currently running and warn the user.
# Offers to kill them since the script runs as root.
check_running_browsers ()
{
    local running=""
    local -a running_binaries=()
    local -A checked

    for entry in "${BROWSERS[@]}"
    do
        IFS=':' read -r name binary _ _ <<< "$entry"

        # Skip if we already checked this binary (e.g. chromium listed twice)
        if [ -n "${checked[$binary]:-}" ]
        then
            continue
        fi
        checked[$binary]=1

        if pgrep -f "$binary" >/dev/null 2>&1
        then
            running_binaries+=("$binary")
            if [ -n "$running" ]
            then
                running="$running, $name"
            else
                running="$name"
            fi
        fi
    done

    if [ -n "$running" ]
    then
        print_err "Running browser(s) detected: $running"

        local choice=''
        while [ "$choice" != "y" ] && [ "$choice" != "n" ]
        do
            echo -e "\nWould you like this script to close them for you? ${INFO_COLOR}(y/n)${NO_COLOR}"
            read -rp '> ' choice
        done

        if [ "$choice" == "y" ]
        then
            for binary in "${running_binaries[@]}"
            do
                graceful_kill "$binary"
            done
            print_info "Browsers closed."
        else
            print_info "Please close all browsers and restart this script."
            exit "$E_BROWSER"
        fi
    fi
} # check_running_browsers


# Discovery of browsers installed on the user's system
# Iterates the BROWSERS registry, detects installed browsers, initializes
# their profile directories, and handles Firefox snap on Debian.
browser_check ()
{
    print_info "Checking for supported browsers..."
    local pki_initialized=false

    for entry in "${BROWSERS[@]}"
    do
        IFS=':' read -r name binary db_pattern type <<< "$entry"

        if ! command -v "$binary" >/dev/null 2>&1
        then
            continue
        fi

        print_info "Found $name."

        # Firefox-specific: check for snap installation (Debian only)
        if [ "$binary" == "firefox" ] && [ "$OS_FAMILY" == "debian" ]
        then
            local ff_path
            ff_path="$(command -v firefox)"
            if [[ "$ff_path" =~ snap ]]
            then
                snap_ff=true
                print_err "This version of Firefox was installed as a snap package"
                continue
            elif grep -Fq "exec /snap/bin/firefox" "$ff_path" 2>/dev/null
            then
                snap_ff=true
                print_err "This version of Firefox was installed as a snap package with a launch script"
                continue
            fi
        fi

        # Track this browser as compatible
        found_browsers+=("$name")
        found_db_patterns+=("$db_pattern")

        # Initialize profile directory via headless launch
        if [ "$type" == "chromium" ]
        then
            # All Chromium-based browsers share ~/.pki/nssdb — only init once
            if [ "$pki_initialized" == false ]
            then
                print_info "Running $name to generate certificate database..."
                run_browser "$binary" "--headless --disable-gpu"
                pki_initialized=true
                print_info "Done."
            fi
        else
            print_info "Running $name to generate profile directory..."
            run_browser "$binary" "--headless --first-startup"
            print_info "Done."
        fi
    done

    # No browsers found at all
    if [ "${#found_browsers[@]}" -eq 0 ] && [ "$snap_ff" == false ]
    then
        print_err "No supported browsers detected."
        print_info "Please install a supported browser (Firefox, Chrome, Chromium, Brave, Edge, LibreWolf, Waterfox, or Vivaldi)."
        exit "$E_BROWSER"
    fi

    # Handle snap Firefox on Debian
    if [ "$snap_ff" == true ]
    then
        echo -e "
        ********************${ERR_COLOR}[ WARNING ]${NO_COLOR}********************
        * The version of Firefox you have installed       *
        * currently was installed via snap.               *
        * This version of Firefox is not currently        *
        * compatible with the method used to enable CAC   *
        * support in browsers.                            *
        *                                                 *
        * As a work-around, this script can automatically *
        * remove the snap version and reinstall via apt.  *
        *                                                 *
        * The option to attempt to migrate all of your    *
        * personalizations will be given if you choose to *
        * replace Firefox via this script. Your Firefox   *
        * profile will be saved to a temp location, then  *
        * will overwrite the default profile once the apt *
        * version of Firefox has been installed.          *
        *                                                 *
        ********************${ERR_COLOR}[ WARNING ]${NO_COLOR}********************\n"

        # Prompt user to elect to replace snap firefox with apt firefox
        choice=''
        while [ "$choice" != "y" ] && [ "$choice" != "n" ]
        do
            echo -e "\nWould you like to switch to the apt version of Firefox? ${INFO_COLOR}(y/n)${NO_COLOR}"
            read -rp '> ' choice
        done

        if [ "$choice" == "y" ]
        then
            reconfigure_firefox
        else
            if [ "${#found_browsers[@]}" -eq 0 ]
            then
                print_info "You have elected to keep the snap version of Firefox.\n"
                print_err "You have no compatible browsers. Exiting..."
                exit "$E_BROWSER"
            fi
        fi
    fi
} # browser_check


# Locate and backup the profile for the user's snap version of Firefox
# Backup is placed in /tmp/ff_old_profile/ and can be restored after the
# apt version of Firefox has been installed
backup_ff_profile ()
{
    local location
    location="$(find_db "firefox" | grep "snap")"
    if [ -z "$location" ]
    then
        print_info "No user profile was found in snap-installed version of Firefox."
    else
        # A user profile exists in the snap version of FF
        choice=''
        while [ "$choice" != "y" ] && [ "$choice" != "n" ]
        do
            echo -e "\nWould you like to transfer your bookmarks and personalizations to the new version of Firefox? ${INFO_COLOR}(y/n)${NO_COLOR}"
            read -rp '> ' choice
        done

        if [ "$choice" == "y" ]
        then
            print_info "Backing up Firefox profile"
            ff_profile="$(dirname "$location")"
            sudo -H -u "$SUDO_USER" cp -rf "$ff_profile" "$DWNLD_DIR/$FF_PROFILE_NAME"
            backup_exists=true
        fi

    fi
} # backup_ff_profile


# Moves the user's backed up Firefox profile from the temp location to the newly
# installed apt version of Firefox in the ~/.mozilla directory
migrate_ff_profile ()
{
    local direction=$1

    if [ "$direction" == "migrate" ]
    then
        # Find the apt Firefox profile directory. We search for the profile
        # folder (*.default*) rather than cert9.db because the database may
        # not exist yet after a fresh install and headless launch.
        local apt_ff_profile_dir
        apt_ff_profile_dir="$(find "$ORIG_HOME/.mozilla/firefox" -maxdepth 1 -type d -name "*.default*" 2>/dev/null | grep -v "snap" | head -n 1)"
        if [ -z "$apt_ff_profile_dir" ]
        then
            print_err "Something went wrong while trying to find apt Firefox's user profile directory."
            exit "$E_DATABASE"
        else
            if sudo -H -u "$SUDO_USER" cp -rf "$DWNLD_DIR/$FF_PROFILE_NAME"/* "$apt_ff_profile_dir"
            then
                print_info "Successfully migrated user profile for Firefox versions"
            else
                print_err "Unable to migrate Firefox profile"
            fi
        fi
    elif [ "$direction" == "restore" ]
    then
        local location
        location="$(find_db "firefox" | grep "snap")"
        if [ -z "$location" ]
        then
            print_info "No user profile was found in snap-installed version of Firefox."
        else
            local ff_profile_dir
            ff_profile_dir="$(dirname "$location")"
            if sudo -H -u "$SUDO_USER" cp -rf "$DWNLD_DIR/$FF_PROFILE_NAME"/* "$ff_profile_dir"
            then
                print_info "Successfully restored user profile for Firefox"
            else
                print_err "Unable to migrate Firefox profile"
            fi
        fi
    fi

} # migrate_ff_profile


# Reinstall the user's previous version of Firefox if the snap version was
# removed in the process of this script.
revert_firefox ()
{
    # Firefox was replaced, let's put it back where it was.
    print_err "No valid databases located. Reinstalling previous version of Firefox..."
    DEBIAN_FRONTEND=noninteractive apt purge firefox -y
    snap install firefox
    run_browser "firefox" "--headless --first-startup"
    print_info "Completed. Exiting..."
    # "Restore" the old profile back to the snap version of Firefox
    migrate_ff_profile "restore"

    exit "$E_DATABASE"
} # revert_firefox


# Integrate all certificates into the databases for existing browsers
import_certs ()
{
    local db="$1"
    local db_root cert imported=0 failed=0
    db_root="$(dirname "$db")"
    if [ -n "$db_root" ]
    then
        case "$db_root" in
            *"pki"*)
                print_info "Importing certificates for Chromium-based browser..."
                ;;
            *"firefox"*)
                print_info "Importing certificates for Firefox..."
                ;;
            *"librewolf"*)
                print_info "Importing certificates for LibreWolf..."
                ;;
            *"waterfox"*)
                print_info "Importing certificates for Waterfox..."
                ;;
            *)
                print_info "Importing certificates..."
                ;;
        esac

        print_info "Loading certificates into $db_root"

        for cert in "$DWNLD_DIR/$CERT_FILENAME/"*."$CERT_EXTENSION"
        do
            if certutil -d sql:"$db_root" -A -t TC -n "$cert" -i "$cert" 2>/dev/null
            then
                imported=$((imported + 1))
            else
                failed=$((failed + 1))
            fi
        done

        if [ "$failed" -gt 0 ]
        then
            print_err "Imported $imported certificate(s), $failed failed for $db_root"
        else
            print_info "Imported $imported certificate(s)."
        fi
        total_imported=$((total_imported + imported))
    fi
    echo
} # import_certs


# Check to see if the user has Firefox pinned to their favorites bar in GNOME
check_for_ff_pin ()
{
    if [ -z "$XDG_CURRENT_DESKTOP" ]; then
        print_info "Desktop environment information not available."
        return
    fi

    if [[ "$XDG_CURRENT_DESKTOP" =~ [Gg][Nn][Oo][Mm][Ee] ]]
    then
        print_info "Detected GNOME-based desktop environment"
        curr_favorites=$(gsettings get org.gnome.shell favorite-apps)
        if [[ "$curr_favorites" =~ firefox\.desktop ]]
        then
            ff_was_pinned=true
        fi
    else
        print_err "Unsupported desktop environment."
        print_err "Unable to repin Firefox to favorites bar"
        print_info "Firefox can still be pinned manually"
    fi
} # check_for_ff_pin


repin_firefox ()
{
    print_info "Attempting to repin Firefox to favorites bar..."
    if [ "$ff_was_pinned" == true ]
    then
        print_info "Pinning Firefox to favorites bar"
        gsettings set org.gnome.shell favorite-apps "$(gsettings get org.gnome.shell favorite-apps | sed s/.$//), 'firefox.desktop']"
        print_info "Done."
    fi
} # repin_firefox


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
            pacman -Sy --noconfirm pcsclite ccid opensc nss unzip wget pcsc-tools || return 1
            ;;
    esac
} # install_packages


# Register the CAC PKCS11 module using the appropriate method for the OS family
register_pkcs11 ()
{
    case "$OS_FAMILY" in
        debian)
            print_info "Registering CAC module with PKCS11..."
            pkcs11-register
            print_info "Done"
            ;;
        fedora|arch)
            print_info "Verifying PKCS11 module registration..."
            # OpenSC module is automatically registered via p11-kit on Fedora and Arch
            if p11-kit list-modules | grep -q opensc
            then
                print_info "OpenSC PKCS11 module is properly registered"
            else
                print_err "OpenSC PKCS11 module not found. You may need to reinstall opensc package."
            fi
            print_info "Done"
            ;;
    esac
} # register_pkcs11


main
