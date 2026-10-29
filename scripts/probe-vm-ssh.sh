#!/bin/bash -e
################################################################################
##  File:  probe-vm-ssh.sh
##  Desc:  Tries SSH on every address in the macOS vmnet DHCP leases, newest
##         lease first, to find a UTM VM whose address is unknown, e.g. after
##         a build lost it across a reboot. Apple Virtualization VMs have no
##         guest agent, so 'utmctl ip-address' prints nothing for them.
##         For each lease it prints the host name, address, MAC, lease expiry,
##         whether port 22 is open and what logging in returned.
##  Usage: probe-vm-ssh.sh [--name HOSTNAME] [--username USER] [--ssh-key PATH]
################################################################################

set -o pipefail

LEASES=${DHCP_LEASES:-/var/db/dhcpd_leases}
username=runner
ssh_key="$HOME/.ssh/utm-runner-images"
name_filter=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name) name_filter=$2; shift 2 ;;
        --username) username=$2; shift 2 ;;
        --ssh-key) ssh_key=$2; shift 2 ;;
        -h|--help) sed -n 's/^##  Usage: //p' "$0"; exit 0 ;;
        *) echo "ERROR: Unknown argument '$1'" >&2; exit 1 ;;
    esac
done

[[ -r "$LEASES" ]] || { echo "ERROR: $LEASES not found, no VM has had a DHCP lease yet" >&2; exit 1; }
[[ -f "$ssh_key" ]] || { echo "ERROR: SSH key '$ssh_key' not found, pass --ssh-key" >&2; exit 1; }

# One line per lease: expiry (epoch) name ip mac, newest first
leases=$(awk '
    /^\{/ { name = "-"; ip = ""; hw = ""; lease = "0x0" }
    /^[ \t]*name=/ { sub(/.*name=/, ""); name = $0 }
    /ip_address=/ { sub(/.*ip_address=/, ""); ip = $0 }
    /hw_address=/ { sub(/.*hw_address=1,/, ""); hw = $0 }
    /lease=/ { sub(/.*lease=/, ""); lease = $0 }
    /^\}/ { if (ip != "") print lease, name, ip, hw }
' "$LEASES" | while read -r lease name ip hw; do
    echo "$((lease)) $name $ip $hw"
done | sort -rn)

[[ -n "$name_filter" ]] && leases=$(echo "$leases" | awk -v name="$name_filter" '$2 == name')
[[ -n "$leases" ]] || { echo "No leases found${name_filter:+ for '$name_filter'}"; exit 0; }

# VMs are rebuilt with new host keys on the same addresses, so known_hosts is not used
ssh_options=(-i "$ssh_key" -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=2
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

echo "$leases" | while read -r expiry name ip hw; do
    echo "=== $name  $ip  $hw  lease until $(date -r "$expiry" '+%Y-%m-%d %H:%M:%S')"
    if ! nc -z -G 3 "$ip" 22 >/dev/null 2>&1; then
        echo "    port 22: closed or no answer"
        continue
    fi
    echo "    port 22: open"
    if output=$(ssh "${ssh_options[@]}" "$username@$ip" \
        'echo "hostname: $(hostname)"; echo "up since: $(uptime -s)"; echo "systemd: $(systemctl is-system-running)"; systemctl list-jobs --no-legend | head -5' \
        </dev/null 2>&1); then
        echo "$output" | sed 's/^/    /'
    else
        echo "    ssh as $username failed:"
        echo "$output" | tail -n 5 | sed 's/^/    /'
    fi
done
