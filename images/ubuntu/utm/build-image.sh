#!/bin/bash -e
################################################################################
##  File:  build-image.sh
##  Desc:  Builds an arm64 Ubuntu runner image in UTM on an Apple silicon Mac.
##         Creates a VM from the Ubuntu cloud image, configures access with
##         cloud-init and provisions it with the regular image template
##         through the Packer 'null' builder (see generate-template.sh).
##  Usage: see docs/create-image-utm.md or run with --help
################################################################################

set -o pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../../../helpers/utm/utm-helpers.sh"

usage() {
    cat <<EOF
Usage: $(basename "$0") --image IMAGE [options]

Required:
  --image IMAGE        One of: ubuntu-22.04-arm64, ubuntu-24.04-arm64, ubuntu-26.04-arm64

Options:
  --name NAME          Name of the new VM (default: <image>-<timestamp>)
  --username USER      Account created by cloud-init (default: runner)
  --ssh-key PATH       Private SSH key for the account; PATH.pub must exist
                       (default: ~/.ssh/utm-runner-images, generated if missing)
  --cpu COUNT          CPU cores (default: 4)
  --memory MIB         Memory in MiB (default: 16384)
  --disk GIB           Disk size in GiB, allocated sparsely (default: 100)
  --export PATH        Export the finished VM as a .utm bundle to PATH
  --keep-on-failure    Leave the VM running when the build fails, for debugging
  -h, --help           Show this help
EOF
}

username=runner
ssh_key="$HOME/.ssh/utm-runner-images"
cpu=4
memory=16384
disk=100
keep_on_failure=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --image) image=$2; shift 2 ;;
        --name) name=$2; shift 2 ;;
        --username) username=$2; shift 2 ;;
        --ssh-key) ssh_key=$2; shift 2 ;;
        --cpu) cpu=$2; shift 2 ;;
        --memory) memory=$2; shift 2 ;;
        --disk) disk=$2; shift 2 ;;
        --export) export_path=$2; shift 2 ;;
        --keep-on-failure) keep_on_failure=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; fail "Unknown argument '$1'" ;;
    esac
done

case "$image" in
    ubuntu-22.04-arm64) release="22.04"; build_name="ubuntu-22_04-arm64"; image_os="ubuntu22-arm64" ;;
    ubuntu-24.04-arm64) release="24.04"; build_name="ubuntu-24_04-arm64"; image_os="ubuntu24-arm64" ;;
    ubuntu-26.04-arm64) release="26.04"; build_name="ubuntu-26_04-arm64"; image_os="ubuntu26-arm64" ;;
    *) usage >&2; fail "Unsupported --image '$image'. x64 images would run emulated, only arm64 is supported" ;;
esac

[[ "$username" =~ ^[a-z_][a-z0-9_-]*$ ]] || fail "--username must be a short POSIX account name, e.g. 'runner'"
name=${name:-$image-$(date +%Y%m%d%H%M)}

assert_host
for tool in packer qemu-img hdiutil curl shasum ssh-keygen nc; do
    assert_command "$tool"
done
vm_exists "$name" && fail "A VM named '$name' already exists in UTM"

if [[ ! -f "$ssh_key" ]]; then
    log "Generating SSH key $ssh_key"
    mkdir -p "$(dirname "$ssh_key")"
    ssh-keygen -q -t ed25519 -N "" -C "utm-runner-images" -f "$ssh_key"
fi
[[ -f "$ssh_key.pub" ]] || fail "Public key '$ssh_key.pub' not found"

cache_dir="$HOME/Library/Caches/local-runner-images/ubuntu-$release"
cloud_image="ubuntu-$release-server-cloudimg-arm64.img"
base_url="https://cloud-images.ubuntu.com/releases/$release/release"
mkdir -p "$cache_dir"

log "Downloading the Ubuntu $release cloud image"
curl -fsSL --retry 3 -o "$cache_dir/SHA256SUMS" "$base_url/SHA256SUMS"
expected_sum=$(awk -v file="*$cloud_image" '$2 == file { print $1 }' "$cache_dir/SHA256SUMS")
[[ -n "$expected_sum" ]] || fail "$cloud_image is not listed in $base_url/SHA256SUMS"
if [[ ! -f "$cache_dir/$cloud_image" ]] || [[ "$(shasum -a 256 "$cache_dir/$cloud_image" | cut -d' ' -f1)" != "$expected_sum" ]]; then
    curl -fL --retry 3 -o "$cache_dir/$cloud_image" "$base_url/$cloud_image"
    [[ "$(shasum -a 256 "$cache_dir/$cloud_image" | cut -d' ' -f1)" == "$expected_sum" ]] || fail "Checksum mismatch for $cloud_image"
fi

work_dir=$(mktemp -d)
build_succeeded=false

cleanup() {
    stop_vm_watchdog
    rm -rf "$work_dir"
    if [[ "$build_succeeded" != true ]] && vm_exists "$name"; then
        if [[ "$keep_on_failure" == true ]]; then
            log "Build failed, VM '$name' is left running for debugging"
        else
            log "Build failed, removing VM '$name'"
            "$UTMCTL" stop "$name" --force >/dev/null 2>&1 || true
            # subshell, because fail() would exit the trap before the VM is deleted
            (wait_vm_status "$name" "stopped" 60) || true
            "$UTMCTL" delete "$name" || true
        fi
    fi
}
trap cleanup EXIT

# The Apple Virtualization backend needs a raw disk image
log "Preparing a ${disk} GiB disk"
qemu-img convert -f qcow2 -O raw "$cache_dir/$cloud_image" "$work_dir/disk.img"
qemu-img resize -f raw "$work_dir/disk.img" "${disk}G" >/dev/null

# cloud-init NoCloud seed: any volume labeled 'cidata' is picked up on first boot
mkdir -p "$work_dir/seed"
cat > "$work_dir/seed/meta-data" <<EOF
instance-id: $name
local-hostname: ${image//./-}
EOF
cat > "$work_dir/seed/user-data" <<EOF
#cloud-config
users:
  - name: $username
    groups: [adm, sudo]
    shell: /bin/bash
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    lock_passwd: true
    ssh_authorized_keys:
      - $(cat "$ssh_key.pub")
write_files:
  # configure-environment.sh edits the Azure agent configuration, which only
  # exists on Azure images
  - path: /etc/waagent.conf
    content: |
      ResourceDisk.Format=n
      ResourceDisk.EnableSwap=n
      ResourceDisk.SwapSizeMB=0
EOF
hdiutil makehybrid -quiet -iso -joliet -default-volume-name cidata -o "$work_dir/seed.iso" "$work_dir/seed"

log "Creating VM '$name' ($cpu CPU, $memory MiB RAM, $disk GiB disk)"
utm_osascript '
            set vmConfig to {name:(item 1 of argv), os:linux, cpu cores:((item 4 of argv) as integer), memory:((item 5 of argv) as integer), drives:{{source:(POSIX file (item 2 of argv))}, {source:(POSIX file (item 3 of argv))}}}
            make new virtual machine with properties {backend:apple, configuration:vmConfig}' \
    "$name" "$work_dir/disk.img" "$work_dir/seed.iso" "$cpu" "$memory" >/dev/null
# UTM copied the drives into the VM bundle
rm -rf "$work_dir"

log "Starting VM '$name'"
ip=$(start_vm_and_wait_ssh "$name")
log "VM is reachable at $ip"

template_dir=$("$SCRIPT_DIR/generate-template.sh" "$build_name")
mkdir -p "$SCRIPT_DIR/../../image-output"
cd "$template_dir"
start_vm_watchdog "$name"
packer build \
    -var "utm_vm_host=$ip" \
    -var "utm_vm_username=$username" \
    -var "utm_ssh_private_key_file=$ssh_key" \
    -var "image_os=$image_os" \
    -var "image_version=$name" \
    .

stop_vm_watchdog
stop_vm "$name"
build_succeeded=true

if [[ -n "$export_path" ]]; then
    log "Exporting '$name' to $export_path"
    mkdir -p "$(dirname "$export_path")"
    utm_osascript 'export (virtual machine named (item 1 of argv)) to (POSIX file (item 2 of argv))' \
        "$name" "$(cd "$(dirname "$export_path")" && pwd)/$(basename "$export_path")"
fi

log "Image '$name' is ready in UTM. Connect with: ssh -i $ssh_key $username@<ip>"
log "Software report: $(cd "$SCRIPT_DIR/../../image-output" && pwd)/"
