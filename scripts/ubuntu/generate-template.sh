#!/bin/bash -e
################################################################################
##  File:  generate-template.sh
##  Desc:  Generates a Packer template for a local UTM build from an Ubuntu
##         image template. The upstream build blocks target the azure-arm
##         source, so the build file is copied with these changes:
##         - the source becomes a 'null' source that connects to the UTM VM
##         - the final 'waagent -deprovision+user' is dropped, it would delete
##           the build user and needs the Azure agent
##         - downloaded software reports go to images/image-output
##  Usage: generate-template.sh <build name> [source dir]
##         <build name> is e.g. ubuntu-24_04-arm64, [source dir] the root of
##         the runner-images sources (default: this repository).
##         Prints the directory of the generated template.
################################################################################

set -o pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SOURCE_DIR=$(cd "${2:-$SCRIPT_DIR/../..}" && pwd)
TEMPLATES_DIR="$SOURCE_DIR/images/ubuntu/templates"
# A sibling of templates/, so ${path.root}/../scripts still resolves
OUTPUT_DIR="$TEMPLATES_DIR/../.utm-template"

build_name=$1
build_file="$TEMPLATES_DIR/build.$build_name.pkr.hcl"
if [[ -z "$build_name" || ! -f "$build_file" ]]; then
    echo "ERROR: build file '$build_file' not found" >&2
    exit 1
fi

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR=$(cd "$OUTPUT_DIR" && pwd)

cp "$TEMPLATES_DIR/variable.ubuntu.pkr.hcl" "$OUTPUT_DIR/"

# shellcheck disable=SC2016 # ${path.root} is HCL and must stay unexpanded
sed -e 's|source\.azure-arm\.image|source.null.image|' \
    -e 's|/usr/sbin/waagent -force -deprovision+user && ||' \
    -e 's|destination = "${path.root}/\.\./|destination = "${path.root}/../../image-output/|' \
    "$build_file" > "$OUTPUT_DIR/build.$build_name.pkr.hcl"

# Fail loudly when an upstream change makes the rewrite incomplete
generated="$OUTPUT_DIR/build.$build_name.pkr.hcl"
if ! grep -q 'source\.null\.image' "$generated" || grep -Eq 'azure-arm|waagent' "$generated"; then
    echo "ERROR: $build_file changed in a way generate-template.sh does not handle" >&2
    exit 1
fi

cat > "$OUTPUT_DIR/source.utm.pkr.hcl" <<'EOF'
variable "utm_vm_host" {
  type = string
}

variable "utm_vm_username" {
  type = string
}

variable "utm_ssh_private_key_file" {
  type = string
}

source "null" "image" {
  ssh_host             = var.utm_vm_host
  ssh_username         = var.utm_vm_username
  ssh_private_key_file = var.utm_ssh_private_key_file
  ssh_timeout          = "10m"
}
EOF

echo "$OUTPUT_DIR"
