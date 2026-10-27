#!/bin/bash -e -o pipefail
################################################################################
##  File:  utm-helpers.sh
##  Desc:  Helper functions to drive UTM virtual machines from the macOS host.
##         Sourced by create-base-vm.sh and build-image.sh.
##         Written for the bash 3.2 that ships with macOS.
################################################################################

UTMCTL="${UTMCTL:-/Applications/UTM.app/Contents/MacOS/utmctl}"

# Oldest UTM release whose scripting API (macOS install, recovery boot,
# ip-address for Apple VMs) these scripts were written against
UTM_MIN_VERSION="5.0.8"

log() {
    echo "==> $*"
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

assert_host() {
    [[ "$(uname -s)" == "Darwin" ]] || fail "UTM builds run on a macOS host only"
    [[ "$(uname -m)" == "arm64" ]] || fail "macOS guests in UTM require an Apple silicon host"
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

# Runs an AppleScript against UTM. Arguments after the script are passed to `on run argv`
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
            return address of item 1 of (network interfaces of (configuration of vm))' "$1"
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

# Starts a VM and prints its IP address once SSH accepts connections
start_vm_and_wait_ssh() {
    local name=$1 ip
    "$UTMCTL" start "$name" >&2
    wait_vm_status "$name" "started" 300
    ip=$(wait_vm_ip "$name")
    wait_ssh "$ip"
    echo "$ip"
}
