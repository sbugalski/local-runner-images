#!/bin/bash -e
################################################################################
##  File:  build-image.sh
##  Desc:  Builds and tests the ubuntu-slim container image on a macOS host.
##         The image only supports linux/amd64 (several tools are downloaded as
##         amd64 binaries), so on Apple silicon it is built under emulation.
##         The sources come from the newest release tag of ubuntu-slim in the
##         fork (or the original repository with --repo upstream), unless
##         --tag or --from-checkout says otherwise.
##  Usage: see docs/create-image-utm.md or run with --help
################################################################################

set -o pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../../helpers/utm/utm-helpers.sh"

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --repo REPO          Where to take release tags from: fork (default), upstream
                       (actions/runner-images) or a git URL
  --tag TAG            Release to build, e.g. ubuntu-slim/20261026.36 or 20261026.36
                       (default: the newest release of ubuntu-slim)
  --from-checkout      Build from this checkout instead of a release tag
  --name NAME          Docker image name (default: ubuntu-slim:<release version>)
  -h, --help           Show this help

Environment:
  GITHUB_TOKEN         GitHub token to avoid API rate limits during the build (optional)
EOF
}

from_checkout=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo) set_source_repo "$2"; shift 2 ;;
        --tag) tag=$2; shift 2 ;;
        --from-checkout) from_checkout=true; shift ;;
        --name) image_name=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; fail "Unknown argument '$1'" ;;
    esac
done

assert_command docker
docker info >/dev/null 2>&1 || fail "The Docker engine is not running. Start Docker Desktop, OrbStack or Colima"

# test.sh formats the image size with GNU numfmt, which macOS does not ship
if ! command -v numfmt >/dev/null 2>&1; then
    command -v gnumfmt >/dev/null 2>&1 || fail "numfmt not found. Install it with: brew install coreutils"
    shim_dir=$(mktemp -d)
    trap 'rm -rf "$shim_dir"' EXIT
    ln -s "$(command -v gnumfmt)" "$shim_dir/numfmt"
    export PATH="$shim_dir:$PATH"
fi

resolve_image_source "ubuntu-slim" "$tag" "$from_checkout"
# Not ubuntu-slim:test, which test.sh would build again on its own
image_name=${image_name:-ubuntu-slim:${SOURCE_VERSION:-local}}

export DOCKER_DEFAULT_PLATFORM=linux/amd64
cd "$SOURCE_DIR/images/ubuntu-slim"

build_args=()
if [[ -n "$SOURCE_VERSION" ]]; then
    build_args+=(--build-arg "IMAGE_VERSION=$SOURCE_VERSION")
fi
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    build_args+=(--secret "id=api_pat,env=GITHUB_TOKEN")
fi
log "Building $image_name"
docker build --progress plain "${build_args[@]}" -t "$image_name" .

./test.sh "$image_name"
