#!/bin/bash -e
################################################################################
##  File:  build-image.sh
##  Desc:  Builds an arm64 Ubuntu runner image in UTM on an Apple silicon Mac.
##         Creates a VM from the Ubuntu cloud image, configures access with
##         cloud-init and provisions it with the regular image template
##         through the Packer 'null' builder (see generate-template.sh).
##         The template comes from the newest release tag of the image in the
##         fork (or the original repository with --repo upstream), unless --tag
##         or --from-checkout says otherwise. --test-template runs an empty
##         build (build.utm-test.pkr.hcl) instead, to test the flow quickly.
##  Usage: see docs/create-image-utm.md or run with --help
################################################################################

set -o pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../../helpers/utm/utm-helpers.sh"

usage() {
    cat <<EOF
Usage: $(basename "$0") --image IMAGE [options]

Required:
  --image IMAGE        One of: ubuntu-22.04-arm64, ubuntu-24.04-arm64, ubuntu-26.04-arm64

Options:
  --repo REPO          Where to take release tags from: fork (default), upstream
                       (actions/runner-images) or a git URL
  --tag TAG            Release to build, e.g. ubuntu24-arm64/20261026.166 or
                       20261026.166 (default: the newest release of the image)
  --from-checkout      Build from this checkout instead of a release tag
  --name NAME          Name of the new VM (default: <image>-<release version>)
  --username USER      Account created by cloud-init (default: runner)
  --ssh-key PATH       Private SSH key for the account; PATH.pub must exist
                       (default: ~/.ssh/utm-runner-images, generated if missing)
  --cpu COUNT          CPU cores (default: 4)
  --memory MIB         Memory in MiB (default: 16384)
  --disk GIB           Disk size in GiB, allocated sparsely (default: 100)
  --export PATH        Export the finished VM as a .utm bundle to PATH
  --keep-on-failure    Leave the VM running when the build fails, for debugging
  --test-template      Run the empty build.utm-test.pkr.hcl instead of the image
                       template: tests VM creation, SSH and the power off and
                       cold start of the reboot step in a few minutes
                       (default name: <image>-utm-test-<date>)
  -h, --help           Show this help
EOF
}

username=runner
ssh_key="$HOME/.ssh/utm-runner-images"
cpu=4
memory=16384
disk=100
keep_on_failure=false
from_checkout=false
test_template=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --image) image=$2; shift 2 ;;
        --repo) set_source_repo "$2"; shift 2 ;;
        --tag) tag=$2; shift 2 ;;
        --from-checkout) from_checkout=true; shift ;;
        --name) name=$2; shift 2 ;;
        --username) username=$2; shift 2 ;;
        --ssh-key) ssh_key=$2; shift 2 ;;
        --cpu) cpu=$2; shift 2 ;;
        --memory) memory=$2; shift 2 ;;
        --disk) disk=$2; shift 2 ;;
        --export) export_path=$2; shift 2 ;;
        --keep-on-failure) keep_on_failure=true; shift ;;
        --test-template) test_template=true; shift ;;
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

assert_host
resolve_image_source "$image_os" "$tag" "$from_checkout"
if [[ "$test_template" == true ]]; then
    name=${name:-$image-utm-test-$(date +%Y%m%d%H%M)}
else
    name=${name:-$image-${SOURCE_VERSION:-$(date +%Y%m%d%H%M)}}
fi
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

# Azure images point apt at azure.archive.ubuntu.com, which configure-apt-sources.sh
# turns into a mirror list that fails over to the Ubuntu archives, and the image
# tests check for that list. 22.04 and 24.04 arm64 stay on ports.ubuntu.com as on
# Azure, from 26.04 arm64 is in the main archive. cloud-init uses the primary
# mirror for the security pocket too
apt_config=""
if [[ "$release" != "22.04" && "$release" != "24.04" ]]; then
    apt_config="apt:
  primary:
    - arches: [default]
      uri: http://azure.archive.ubuntu.com/ubuntu/"
fi

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
$apt_config
EOF
hdiutil makehybrid -quiet -iso -joliet -default-volume-name cidata -o "$work_dir/seed.iso" "$work_dir/seed"

log "Creating VM '$name' ($cpu CPU, $memory MiB RAM, $disk GiB disk)"
utm_osascript '
            set vmConfig to {name:(item 1 of argv), os:linux, cpu cores:((item 4 of argv) as integer), memory:((item 5 of argv) as integer), drives:{{source:((item 2 of argv) as POSIX file)}, {source:((item 3 of argv) as POSIX file)}}}
            make new virtual machine with properties {backend:apple, configuration:vmConfig}' \
    "$name" "$work_dir/disk.img" "$work_dir/seed.iso" "$cpu" "$memory" >/dev/null
# UTM copied the drives into the VM bundle
rm -rf "$work_dir"

log "Starting VM '$name'"
ip=$(start_vm_and_wait_ssh "$name")
log "VM is reachable at $ip"

template_dir=$("$SCRIPT_DIR/generate-template.sh" "$build_name" "$SOURCE_DIR")
if [[ "$test_template" == true ]]; then
    # Keep the null source and the variables, replace only the build
    rm "$template_dir/build.$build_name.pkr.hcl"
    cp "$SCRIPT_DIR/build.utm-test.pkr.hcl" "$template_dir/"
fi
mkdir -p "$SOURCE_DIR/images/image-output"
cd "$template_dir"
start_vm_watchdog "$name"
packer build \
    -var "utm_vm_host=$ip" \
    -var "utm_vm_username=$username" \
    -var "utm_ssh_private_key_file=$ssh_key" \
    -var "image_os=$image_os" \
    -var "image_version=${SOURCE_VERSION:-$name}" \
    .

stop_vm_watchdog
stop_vm "$name"
build_succeeded=true

if [[ -n "$export_path" ]]; then
    log "Exporting '$name' to $export_path"
    mkdir -p "$(dirname "$export_path")"
    utm_osascript 'export (virtual machine named (item 1 of argv)) to ((item 2 of argv) as POSIX file)' \
        "$name" "$(cd "$(dirname "$export_path")" && pwd)/$(basename "$export_path")"
fi

log "Image '$name' is ready in UTM. Connect with: ssh -i $ssh_key $username@<ip>"
[[ "$test_template" == true ]] || log "Software report: $SOURCE_DIR/images/image-output/"
