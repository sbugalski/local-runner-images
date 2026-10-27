#!/bin/bash -e -o pipefail
################################################################################
##  File:  create-base-vm.sh
##  Desc:  Creates a macOS base VM in UTM from an IPSW restore image.
##         The base VM plays the role of the Anka source VM: it is cloned by
##         build-image.sh for every image build.
##  Usage: see docs/create-image-utm.md or run with --help
################################################################################

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../../../helpers/utm/utm-helpers.sh"

usage() {
    cat <<EOF
Usage: $(basename "$0") --name NAME --ipsw PATH_OR_URL --username USER [options]

Required:
  --name NAME          Name of the base VM in UTM
  --ipsw PATH_OR_URL   macOS IPSW restore image (local path or https URL)
  --username USER      Account to create in the guest (password: UTM_VM_PASSWORD)

Options:
  --cpu COUNT          CPU cores (default: 6)
  --memory MIB         Memory in MiB (default: 8192)
  --disk GIB           Disk size in GiB, allocated sparsely (default: 300)
  --auto-setup         Create the account without Setup Assistant.
                       Requires macOS 27 or later on the host and in the guest
  -h, --help           Show this help

Environment:
  UTM_VM_PASSWORD      Password of the guest account (required)
  UTMCTL               Path to utmctl (default: $UTMCTL)
EOF
}

cpu=6
memory=8192
disk=300
auto_setup=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name) name=$2; shift 2 ;;
        --ipsw) ipsw=$2; shift 2 ;;
        --username) username=$2; shift 2 ;;
        --cpu) cpu=$2; shift 2 ;;
        --memory) memory=$2; shift 2 ;;
        --disk) disk=$2; shift 2 ;;
        --auto-setup) auto_setup=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; fail "Unknown argument '$1'" ;;
    esac
done

[[ -n "$name" && -n "$ipsw" && -n "$username" ]] || { usage >&2; fail "--name, --ipsw and --username are required"; }
[[ -n "$UTM_VM_PASSWORD" ]] || fail "Set the guest account password in UTM_VM_PASSWORD"
[[ "$username" =~ ^[a-z_][a-z0-9_-]*$ ]] || fail "--username must be a short POSIX account name, e.g. 'runner'"

assert_host
assert_command packer
assert_command nc
vm_exists "$name" && fail "A VM named '$name' already exists in UTM"
if [[ "$auto_setup" == true ]] && (( $(host_macos_major) < 27 )); then
    fail "--auto-setup requires macOS 27 or later on the host"
fi

if [[ "$ipsw" =~ ^https?:// ]]; then
    cache_dir="$HOME/Library/Caches/local-runner-images"
    mkdir -p "$cache_dir"
    ipsw_path="$cache_dir/$(basename "${ipsw%%\?*}")"
    log "Downloading $ipsw to $ipsw_path"
    curl -fL --retry 3 -C - -o "$ipsw_path" "$ipsw"
else
    ipsw_path=$(cd "$(dirname "$ipsw")" && pwd)/$(basename "$ipsw")
fi
[[ -f "$ipsw_path" ]] || fail "IPSW '$ipsw_path' not found"

log "Creating VM '$name' ($cpu CPU, $memory MiB RAM, $disk GiB disk)"
utm_osascript '
            set vmConfig to {name:(item 1 of argv), os:macOS, macRecoveryIpsw:(POSIX file (item 2 of argv)), cpu cores:((item 3 of argv) as integer), memory:((item 4 of argv) as integer), drives:{{guest size:((item 5 of argv) as integer)}}}
            make new virtual machine with properties {backend:apple, configuration:vmConfig}' \
    "$name" "$ipsw_path" "$cpu" "$memory" "$((disk * 1024))" >/dev/null

log "Installing macOS from $(basename "$ipsw_path")"
utm_osascript 'install (virtual machine named (item 1 of argv))' "$name"
while true; do
    # progress is returned as an integer percentage so the output does not depend on the locale
    progress=$(utm_osascript '
            set p to query install (virtual machine named (item 1 of argv))
            if installing of p then
                return (round ((progress of p) * 100)) as text
            end if
            return "done"' "$name")
    [[ "$progress" == "done" ]] && break
    echo "    ${progress}%"
    sleep 30
done
log "macOS installed"

if [[ "$auto_setup" == true ]]; then
    log "Setting up account '$username' on first boot"
    printf '%s' "$UTM_VM_PASSWORD" | "$UTMCTL" start "$name" --provision-username "$username" \
        --provision-password-stdin --provision-auto-login --provision-ssh
    wait_vm_status "$name" "started" 300
    wait_ssh "$(wait_vm_ip "$name" 1800)" 1800
    stop_vm "$name"
else
    "$UTMCTL" start "$name"
    cat <<EOF

Complete Setup Assistant in the UTM window of '$name':
  1. Create an administrator account with the short name '$username'
     and the password from UTM_VM_PASSWORD
  2. Skip Apple Account sign-in, Location Services and analytics
  3. Turn on System Settings > General > Sharing > Remote Login
  4. Shut down the VM (Apple menu > Shut Down)

Waiting for the VM to stop...
EOF
    wait_vm_status "$name" "stopped"
fi

log "Booting into recoveryOS to disable System Integrity Protection"
"$UTMCTL" start "$name" --recovery
cat <<EOF

In the UTM window of '$name':
  1. If recoveryOS asks for a user, sign in as '$username'
  2. Open Utilities > Terminal and run: csrutil disable
  3. Confirm with 'y' and the credentials of '$username'
  4. Shut down the VM (Apple menu > Shut Down)

The image scripts write to the system TCC database and unload system
daemons, which is not possible while SIP is enabled.

Waiting for the VM to stop...
EOF
wait_vm_status "$name" "stopped"

log "Configuring the guest over SSH"
ip=$(start_vm_and_wait_ssh "$name")
PKR_VAR_vm_password="$UTM_VM_PASSWORD" packer build \
    -var "vm_host=$ip" \
    -var "vm_username=$username" \
    "$SCRIPT_DIR/base-vm.pkr.hcl"
stop_vm "$name"

log "Base VM '$name' is ready. Build an image with:"
echo "    $SCRIPT_DIR/build-image.sh --image <image> --base-vm '$name' --username '$username' --xcode-dir <dir>"
