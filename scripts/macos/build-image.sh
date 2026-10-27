#!/bin/bash -e -o pipefail
################################################################################
##  File:  build-image.sh
##  Desc:  Builds a macOS runner image in UTM. Clones the base VM created by
##         create-base-vm.sh and provisions the clone with the regular image
##         template through the Packer 'null' builder. The template comes from
##         the newest release tag of the image in the fork (or the original
##         repository with --repo upstream), unless --tag or --from-checkout
##         says otherwise.
##  Usage: see docs/create-image-utm.md or run with --help
################################################################################

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
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
  --repo REPO          Where to take release tags from: fork (default), upstream
                       (actions/runner-images) or a git URL
  --tag TAG            Release to build, e.g. macos-26-arm64/20261021.0445 or
                       20261021.0445 (default: the newest release of the image)
  --from-checkout      Build from this checkout instead of a release tag
  --name NAME          Name of the new VM (default: <image>-<release version>)
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
from_checkout=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --image) image=$2; shift 2 ;;
        --repo) set_source_repo "$2"; shift 2 ;;
        --tag) tag=$2; shift 2 ;;
        --from-checkout) from_checkout=true; shift ;;
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
    macos-14-arm64) template="macOS-14.arm64.anka.pkr.hcl"; toolset="toolset-14.json" ;;
    macos-15-arm64) template="macOS-15.arm64.anka.pkr.hcl"; toolset="toolset-15.json" ;;
    macos-26-arm64) template="macOS-26.arm64.anka.pkr.hcl"; toolset="toolset-26.json" ;;
    xcode-27-arm64) template="xcode-27.arm64.anka.pkr.hcl"; toolset="toolset-xcode-27.json" ;;
    *) usage >&2; fail "Unsupported --image '$image'. Only arm64 images can run in UTM" ;;
esac

[[ -n "$base_vm" && -n "$username" ]] || { usage >&2; fail "--base-vm and --username are required"; }
[[ -n "$xcode_dir" || -n "$xcode_url" ]] || fail "Either --xcode-dir or --xcode-url is required"
[[ -n "$xcode_dir" && -n "$xcode_url" ]] && fail "Use either --xcode-dir or --xcode-url, not both"
[[ -n "$UTM_VM_PASSWORD" ]] || fail "Set the guest account password in UTM_VM_PASSWORD"

assert_host
assert_command packer
assert_command nc
assert_command python3
resolve_image_source "$image" "$tag" "$from_checkout"
TEMPLATES_DIR="$SOURCE_DIR/images/macos/templates"
name=${name:-$image-${SOURCE_VERSION:-$(date +%Y%m%d%H%M)}}
vm_exists "$base_vm" || fail "Base VM '$base_vm' not found in UTM"
[[ "$(vm_status "$base_vm")" == "stopped" ]] || fail "Base VM '$base_vm' must be stopped"
vm_exists "$name" && fail "A VM named '$name' already exists in UTM"

# The Xcode versions depend on the release, so check them before the long build starts
xcode_files=$(python3 -I -c '
import json, sys
for xcode in json.load(open(sys.argv[1]))["xcode"]["arm64"]["versions"]:
    print("Xcode-{}.xip".format(xcode["version"]))
' "$SOURCE_DIR/images/macos/toolsets/$toolset") || fail "Could not read the Xcode versions from $toolset"
log "The build installs: ${xcode_files//$'\n'/ }"
if [[ -n "$xcode_dir" ]]; then
    xcode_dir=$(cd "$xcode_dir" && pwd)
    missing=""
    for file in $xcode_files; do
        [[ -f "$xcode_dir/$file" ]] || missing="$missing $file"
    done
    [[ -z "$missing" ]] || fail "Missing in '$xcode_dir':$missing"
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
    -var "build_id=${SOURCE_VERSION:-$name}" \
    -var "vm_username=$username" \
    -var "xcode_install_storage_url=$xcode_url" \
    "$template"

stop_vm_watchdog
stop_vm "$name"
build_succeeded=true

if [[ -n "$export_path" ]]; then
    log "Exporting '$name' to $export_path"
    mkdir -p "$(dirname "$export_path")"
    utm_osascript 'export (virtual machine named (item 1 of argv)) to ((item 2 of argv) as POSIX file)' \
        "$name" "$(cd "$(dirname "$export_path")" && pwd)/$(basename "$export_path")"
fi

log "Image '$name' is ready in UTM. Software report: $(cd "$TEMPLATES_DIR/../.." && pwd)/image-output/"
