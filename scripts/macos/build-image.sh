#!/bin/bash -e -o pipefail
################################################################################
##  File:  build-image.sh
##  Desc:  Builds a macOS runner image in UTM. Clones the base VM created by
##         create-base-vm.sh and provisions the clone with the regular image
##         template through the Packer 'null' builder.
##  Usage: see docs/create-image-utm.md or run with --help
################################################################################

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TEMPLATES_DIR=$(cd "$SCRIPT_DIR/../../images/macos/templates" && pwd)
source "$SCRIPT_DIR/../../helpers/utm/utm-helpers.sh"

usage() {
    cat <<EOF
Usage: $(basename "$0") --image IMAGE --base-vm NAME --username USER (--xcode-dir DIR | --xcode-url URL) [options]

Required:
  --image IMAGE        One of: macos-14-arm64, macos-15-arm64, macos-26-arm64, xcode-27-arm64
  --base-vm NAME       Base VM created by create-base-vm.sh
  --username USER      Guest account (password: UTM_VM_PASSWORD)
  --xcode-dir DIR      Directory with Xcode-<version>.xip files, served to the guest over HTTP
  --xcode-url URL      Base URL that serves Xcode-<version>.xip files (SAS token: XCODE_INSTALL_SAS)

Options:
  --name NAME          Name of the new VM (default: <image>-<timestamp>)
  --export PATH        Export the finished VM as a .utm bundle to PATH
  --keep-on-failure    Leave the VM running when the build fails, for debugging
  -h, --help           Show this help

Environment:
  UTM_VM_PASSWORD      Password of the guest account (required)
  GITHUB_API_PAT       GitHub token to avoid API rate limits during the build (optional)
  XCODE_INSTALL_SAS    Query string appended to --xcode-url (optional)
EOF
}

keep_on_failure=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --image) image=$2; shift 2 ;;
        --base-vm) base_vm=$2; shift 2 ;;
        --username) username=$2; shift 2 ;;
        --xcode-dir) xcode_dir=$2; shift 2 ;;
        --xcode-url) xcode_url=$2; shift 2 ;;
        --name) name=$2; shift 2 ;;
        --export) export_path=$2; shift 2 ;;
        --keep-on-failure) keep_on_failure=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; fail "Unknown argument '$1'" ;;
    esac
done

case "$image" in
    macos-14-arm64) template="macOS-14.arm64.anka.pkr.hcl" ;;
    macos-15-arm64) template="macOS-15.arm64.anka.pkr.hcl" ;;
    macos-26-arm64) template="macOS-26.arm64.anka.pkr.hcl" ;;
    xcode-27-arm64) template="xcode-27.arm64.anka.pkr.hcl" ;;
    *) usage >&2; fail "Unsupported --image '$image'. Only arm64 images can run in UTM" ;;
esac

[[ -n "$base_vm" && -n "$username" ]] || { usage >&2; fail "--base-vm and --username are required"; }
[[ -n "$xcode_dir" || -n "$xcode_url" ]] || fail "Either --xcode-dir or --xcode-url is required"
[[ -n "$xcode_dir" && -n "$xcode_url" ]] && fail "Use either --xcode-dir or --xcode-url, not both"
[[ -n "$UTM_VM_PASSWORD" ]] || fail "Set the guest account password in UTM_VM_PASSWORD"
name=${name:-$image-$(date +%Y%m%d%H%M)}

assert_host
assert_command packer
assert_command nc
vm_exists "$base_vm" || fail "Base VM '$base_vm' not found in UTM"
[[ "$(vm_status "$base_vm")" == "stopped" ]] || fail "Base VM '$base_vm' must be stopped"
vm_exists "$name" && fail "A VM named '$name' already exists in UTM"
if [[ -n "$xcode_dir" ]]; then
    assert_command python3
    xcode_dir=$(cd "$xcode_dir" && pwd)
    ls "$xcode_dir"/Xcode-*.xip >/dev/null 2>&1 || fail "No Xcode-<version>.xip files in '$xcode_dir'"
fi

server_pid=""
build_succeeded=false

cleanup() {
    stop_vm_watchdog
    if [[ -n "$server_pid" ]]; then
        kill "$server_pid" 2>/dev/null || true
    fi
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

log "Cloning '$base_vm' to '$name'"
"$UTMCTL" clone "$base_vm" --name "$name"
vm_exists "$name" || fail "Cloning '$base_vm' failed"

log "Starting VM '$name'"
ip=$(start_vm_and_wait_ssh "$name")
log "VM is reachable at $ip"

if [[ -n "$xcode_dir" ]]; then
    # The host side of the vmnet shared network is the .1 address of the guest's subnet
    host_ip="${ip%.*}.1"
    port=8642
    log "Serving $xcode_dir at http://$host_ip:$port/"
    python3 -m http.server "$port" --bind "$host_ip" --directory "$xcode_dir" >/dev/null 2>&1 &
    server_pid=$!
    xcode_url="http://$host_ip:$port/"
fi

mkdir -p "$TEMPLATES_DIR/../../image-output"
cd "$TEMPLATES_DIR"
packer init "$template"
start_vm_watchdog "$name"
PKR_VAR_vm_password="$UTM_VM_PASSWORD" \
PKR_VAR_github_api_pat="$GITHUB_API_PAT" \
PKR_VAR_xcode_install_sas="$XCODE_INSTALL_SAS" \
packer build \
    -var "builder_type=null" \
    -var "source_vm_name=$ip" \
    -var "build_id=$name" \
    -var "vm_username=$username" \
    -var "xcode_install_storage_url=$xcode_url" \
    "$template"

stop_vm_watchdog
stop_vm "$name"
build_succeeded=true

if [[ -n "$export_path" ]]; then
    log "Exporting '$name' to $export_path"
    mkdir -p "$(dirname "$export_path")"
    utm_osascript 'export (virtual machine named (item 1 of argv)) to (POSIX file (item 2 of argv))' \
        "$name" "$(cd "$(dirname "$export_path")" && pwd)/$(basename "$export_path")"
fi

log "Image '$name' is ready in UTM. Software report: $(cd "$TEMPLATES_DIR/../.." && pwd)/image-output/"
