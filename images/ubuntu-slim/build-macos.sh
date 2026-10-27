#!/bin/bash -e
################################################################################
##  File:  build-macos.sh
##  Desc:  Builds and tests the ubuntu-slim container image on a macOS host.
##         The image only supports linux/amd64 (several tools are downloaded as
##         amd64 binaries), so on Apple silicon it is built under emulation.
##  Usage: build-macos.sh [IMAGE_NAME]   (default: ubuntu-slim:test)
##         Set GITHUB_TOKEN to avoid GitHub API rate limits during the build.
################################################################################

set -o pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
image_name=${1:-ubuntu-slim:test}

command -v docker >/dev/null 2>&1 || { echo "ERROR: docker CLI not found. Install Docker Desktop, OrbStack or Colima" >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "ERROR: the Docker engine is not running" >&2; exit 1; }

# test.sh formats the image size with GNU numfmt, which macOS does not ship
if ! command -v numfmt >/dev/null 2>&1; then
    command -v gnumfmt >/dev/null 2>&1 || { echo "ERROR: numfmt not found. Install it with: brew install coreutils" >&2; exit 1; }
    shim_dir=$(mktemp -d)
    trap 'rm -rf "$shim_dir"' EXIT
    ln -s "$(command -v gnumfmt)" "$shim_dir/numfmt"
    export PATH="$shim_dir:$PATH"
fi

export DOCKER_DEFAULT_PLATFORM=linux/amd64
cd "$SCRIPT_DIR"

if [[ "$image_name" != "ubuntu-slim:test" ]]; then
    # test.sh builds only its default image name, so build other names here
    api_pat_args=()
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        api_pat_args=(--secret "id=api_pat,env=GITHUB_TOKEN")
    fi
    docker build --progress plain "${api_pat_args[@]}" -t "$image_name" .
fi

./test.sh "$image_name"
