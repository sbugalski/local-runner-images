#!/bin/bash -e -o pipefail
################################################################################
##  File:  utm-helpers.sh
##  Desc:  Helper functions for local image builds on the macOS host: picking
##         the upstream release to build and driving UTM virtual machines.
##         Sourced by the scripts in scripts/.
##         Written for the bash 3.2 that ships with macOS.
################################################################################

UTMCTL="${UTMCTL:-/Applications/UTM.app/Contents/MacOS/utmctl}"

# Images are built from the sources of a release tag, because the default
# branch can be in a state that does not build. Tags come from the fork by
# default, or from the original repository (--repo upstream)
FORK_REPO="https://github.com/sbugalski/local-runner-images.git"
UPSTREAM_REPO="https://github.com/actions/runner-images.git"
SOURCE_REPO="${SOURCE_REPO:-$FORK_REPO}"
SOURCE_CACHE_DIR="${SOURCE_CACHE_DIR:-$HOME/Library/Caches/local-runner-images/sources}"

# Oldest UTM release whose scripting API (macOS install, recovery boot,
# ip-address for Apple VMs) these scripts were written against
UTM_MIN_VERSION="5.0.8"

# Progress goes to stderr, so functions can print their result on stdout
log() {
    echo "==> $*" >&2
}

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

# Returns 0 when version $1 is greater than or equal to version $2
version_ge() {
    local -a left right
    local i
    IFS=. read -r -a left <<< "$1"
    IFS=. read -r -a right <<< "$2"
    for i in 0 1 2; do
        local l=${left[$i]:-0} r=${right[$i]:-0}
        if (( l > r )); then return 0; fi
        if (( l < r )); then return 1; fi
    done
    return 0
}

# Reads tags from stdin and prints the newest release tag of image $1.
# Release tags look like <image>/<YYYYMMDD>.<build>, e.g. ubuntu24-arm64/20261026.166
select_latest_tag() {
    grep -E "^$1/[0-9]{8}\.[0-9]+$" | sort -t. -k1,1 -k2,2n | tail -n 1 || true
}

# Sets SOURCE_REPO from the --repo option: fork, upstream or a git URL
set_source_repo() {
    case "$1" in
        ""|fork) SOURCE_REPO=$FORK_REPO ;;
        upstream) SOURCE_REPO=$UPSTREAM_REPO ;;
        *) SOURCE_REPO=$1 ;;
    esac
}

# Reads tags of actions/runner from stdin and prints the newest runner version, e.g. 2.338.2
select_latest_runner_version() {
    sed -n -E 's/^v([0-9]+\.[0-9]+\.[0-9]+)$/\1/p' | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1 || true
}

# Prints the release tag to build for image $1: $2 when given, with or without
# the image prefix, otherwise the newest release tag in SOURCE_REPO
resolve_image_tag() {
    local image=$1 tag=$2 tags
    if [[ -z "$tag" ]]; then
        tags=$(git ls-remote --tags --refs "$SOURCE_REPO" "refs/tags/$image/*") || fail "Could not list the tags of $SOURCE_REPO"
        tag=$(echo "$tags" | awk '{ sub("refs/tags/", "", $2); print $2 }' | select_latest_tag "$image")
        if [[ -z "$tag" ]]; then
            fail "No release tags for '$image' in $SOURCE_REPO. Use --repo upstream, run the 'Sync upstream release tags' workflow of the fork, or copy the tags yourself:
    git fetch $UPSTREAM_REPO 'refs/tags/$image/*:refs/tags/$image/*' && git push origin 'refs/tags/$image/*'"
        fi
    elif [[ "$tag" != */* ]]; then
        tag="$image/$tag"
    fi
    [[ "$tag" == "$image/"* ]] || fail "Tag '$tag' is not a release of '$image'"
    echo "$tag"
}

# Prints a directory with the sources of SOURCE_REPO at release tag $1, cloned on first use
image_source_at_tag() {
    local tag=$1 repo_key
    # e.g. github.com_actions_runner-images, so tags of different repositories do not mix
    repo_key=$(echo "${SOURCE_REPO#*://}" | sed -e 's|\.git$||' -e 's|[/:@]|_|g')
    local dir="$SOURCE_CACHE_DIR/$repo_key/${tag//\//_}"
    if [[ ! -d "$dir/.git" ]]; then
        log "Fetching $SOURCE_REPO at $tag"
        mkdir -p "$(dirname "$dir")"
        git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$tag" "$SOURCE_REPO" "$dir" >&2 \
            || fail "Could not fetch tag '$tag' from $SOURCE_REPO"
    fi
    echo "$dir"
}

# Sets SOURCE_DIR, and SOURCE_VERSION to the release version (e.g. 20261026.166),
# for image $1: this repository with --from-checkout ($3 = true), otherwise release tag $2 or the newest one
# shellcheck disable=SC2034 # SOURCE_DIR and SOURCE_VERSION are read by the calling script
resolve_image_source() {
    local image=$1 tag=$2 from_checkout=$3
    if [[ "$from_checkout" == true ]]; then
        [[ -z "$tag" ]] || fail "Use either --tag or --from-checkout, not both"
        SOURCE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
        SOURCE_VERSION=""
        log "Building from this repository at $SOURCE_DIR"
    else
        tag=$(resolve_image_tag "$image" "$tag")
        SOURCE_DIR=$(image_source_at_tag "$tag")
        SOURCE_VERSION=${tag#*/}
        log "Building from release $tag of $SOURCE_REPO"
    fi
}

assert_host() {
    [[ "$(uname -s)" == "Darwin" ]] || fail "UTM builds run on a macOS host only"
    [[ "$(uname -m)" == "arm64" ]] || fail "UTM builds of the runner images require an Apple silicon host"
    [[ -x "$UTMCTL" ]] || fail "utmctl not found at '$UTMCTL'. Install UTM or set UTMCTL"

    local version
    version=$("$UTMCTL" version) || fail "utmctl failed. It must run in a logged in GUI session, not over SSH"
    version_ge "$version" "$UTM_MIN_VERSION" || fail "UTM $UTM_MIN_VERSION or later is required, found $version"
}

assert_command() {
    command -v "$1" >/dev/null 2>&1 || fail "'$1' is required but was not found in PATH"
}

host_macos_major() {
    sw_vers -productVersion | cut -d. -f1
}

# Runs an AppleScript against UTM. Arguments after the script are passed to `on run argv`.
# Turn path arguments into files with `(item N of argv) as POSIX file`: inside the
# tell block `POSIX file (item N of argv)` is sent to UTM, which fails with -1728
utm_osascript() {
    local script=$1
    shift
    osascript - "$@" <<EOF
on run argv
    with timeout of 600 seconds
        tell application "UTM"
$script
        end tell
    end timeout
end run
EOF
}

vm_exists() {
    "$UTMCTL" status "$1" >/dev/null 2>&1
}

vm_status() {
    "$UTMCTL" status "$1"
}

wait_vm_status() {
    local name=$1 expected=$2 timeout=${3:-0}
    local waited=0
    while [[ "$(vm_status "$name")" != "$expected" ]]; do
        if (( timeout > 0 && waited >= timeout )); then
            fail "VM '$name' did not reach status '$expected' within ${timeout}s"
        fi
        sleep 5
        waited=$((waited + 5))
    done
}

# Asks the guest to shut down and waits until it is stopped
stop_vm() {
    local name=$1
    [[ "$(vm_status "$name")" == "stopped" ]] && return 0
    log "Shutting down VM '$name'"
    "$UTMCTL" stop "$name" --request || true
    if ! (wait_vm_status "$name" "stopped" 300); then
        log "Guest did not shut down in time, forcing stop"
        "$UTMCTL" stop "$name" --force
        wait_vm_status "$name" "stopped" 60
    fi
}

vm_mac_address() {
    utm_osascript '
            set vm to virtual machine named (item 1 of argv)
            set config to configuration of vm
            return address of item 1 of network interfaces of config' "$1"
}

# Looks up the IPv4 address of a VM in the vmnet DHCP leases. The leases file
# stores MAC octets without leading zeros, e.g. 2:a:3f:...
ip_from_dhcp_leases() {
    local mac=$1 leases=${2:-/var/db/dhcpd_leases}
    [[ -r "$leases" ]] || return 0
    mac=$(echo "$mac" | tr 'A-F' 'a-f' | sed -E 's/(^|:)0([0-9a-f])/\1\2/g')
    awk -v mac="1,$mac" '
        /^\{/ { ip = ""; hw = "" }
        /ip_address=/ { sub(/.*ip_address=/, ""); ip = $0 }
        /hw_address=/ { sub(/.*hw_address=/, ""); hw = $0 }
        /^\}/ { if (hw == mac) found = ip }
        END { if (found != "") print found }
    ' "$leases"
}

# Prints the IPv4 address of a running VM once it is known
wait_vm_ip() {
    local name=$1 timeout=${2:-600}
    local waited=0 ip mac
    mac=$(vm_mac_address "$name")
    while true; do
        ip=$("$UTMCTL" ip-address "$name" 2>/dev/null | grep -E '^[0-9]+(\.[0-9]+){3}$' | head -n 1 || true)
        if [[ -z "$ip" && -n "$mac" ]]; then
            ip=$(ip_from_dhcp_leases "$mac")
        fi
        if [[ -n "$ip" ]]; then
            echo "$ip"
            return 0
        fi
        (( waited >= timeout )) && fail "Could not get the IP address of VM '$name' within ${timeout}s"
        sleep 10
        waited=$((waited + 10))
    done
}

wait_ssh() {
    local ip=$1 timeout=${2:-600}
    local waited=0
    until nc -z -G 5 "$ip" 22 >/dev/null 2>&1; do
        (( waited >= timeout )) && fail "SSH on $ip did not come up within ${timeout}s"
        sleep 10
        waited=$((waited + 10))
    done
}

# Starts the VM again whenever it is found stopped, until stop_vm_watchdog.
# Covers guest reboots during the build that end with the VM stopped, and the
# power off that replaces the reboot step of the Ubuntu templates
start_vm_watchdog() {
    local name=$1
    (
        while sleep 15; do
            if [[ "$(vm_status "$name" 2>/dev/null)" == "stopped" ]]; then
                echo "==> VM '$name' stopped during the build, starting it again" >&2
                "$UTMCTL" start "$name" >&2 || true
            fi
        done
    ) &
    VM_WATCHDOG_PID=$!
}

stop_vm_watchdog() {
    if [[ -n "$VM_WATCHDOG_PID" ]]; then
        kill "$VM_WATCHDOG_PID" 2>/dev/null || true
        # Reaping the job here keeps bash from printing 'Terminated' for it
        wait "$VM_WATCHDOG_PID" 2>/dev/null || true
        VM_WATCHDOG_PID=""
    fi
}

# Starts VM $1, with further arguments passed to utmctl start (e.g. --disposable),
# and prints its IP address once SSH accepts connections
start_vm_and_wait_ssh() {
    local name=$1 ip
    shift
    "$UTMCTL" start "$name" "$@" >&2
    wait_vm_status "$name" "started" 300
    ip=$(wait_vm_ip "$name")
    wait_ssh "$ip"
    echo "$ip"
}
