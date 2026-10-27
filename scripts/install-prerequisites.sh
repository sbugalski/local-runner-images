#!/bin/bash -e -o pipefail
################################################################################
##  File:  install-prerequisites.sh
##  Desc:  Installs the software the scripts in scripts/ need on the macOS host.
##         Checks every tool first and installs only what is missing, so it can
##         be run again at any time.
##  Usage: install-prerequisites.sh [--for LIST] [--dry-run]
################################################################################

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../helpers/utm/utm-helpers.sh"

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --for LIST           Comma-separated components to prepare (default: all):
                         macos        macOS images: UTM, Packer
                         ubuntu       Ubuntu images: UTM, Packer, QEMU (qemu-img)
                         ubuntu-slim  ubuntu-slim: Docker CLI with buildx, Colima, coreutils
                         runner       run-ephemeral-runner.sh: UTM
  --dry-run            Only show what is missing
  -h, --help           Show this help

Always checked: Xcode Command Line Tools (git, python3) and Homebrew.
EOF
}

components="macos,ubuntu,ubuntu-slim,runner"
dry_run=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --for) components=$2; shift 2 ;;
        --dry-run) dry_run=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; fail "Unknown argument '$1'" ;;
    esac
done

[[ "$(uname -s)" == "Darwin" ]] || fail "The scripts run on a macOS host only"
[[ "$components" =~ ^(macos|ubuntu|ubuntu-slim|runner)(,(macos|ubuntu|ubuntu-slim|runner))*$ ]] \
    || fail "--for takes a comma-separated list of: macos, ubuntu, ubuntu-slim, runner"

wants() {
    [[ ",$components," == *",$1,"* ]]
}

need_utm=false
need_packer=false
need_qemu=false
need_docker=false
wants macos && { need_utm=true; need_packer=true; }
wants ubuntu && { need_utm=true; need_packer=true; need_qemu=true; }
wants ubuntu-slim && need_docker=true
wants runner && need_utm=true

if [[ "$(uname -m)" != "arm64" ]]; then
    log "This Mac has an Intel processor. UTM runs the macOS and Ubuntu images only on Apple silicon, so only ubuntu-slim can be built here"
    need_utm=false
    need_packer=false
    need_qemu=false
fi

missing=0

# Runs a command, or with --dry-run only counts it
step() {
    local description=$1
    shift
    if [[ "$dry_run" == true ]]; then
        echo "    would: $description" >&2
        missing=$((missing + 1))
    else
        log "$description"
        "$@"
    fi
}

load_homebrew() {
    local brew_path
    for brew_path in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        if ! command -v brew >/dev/null 2>&1 && [[ -x "$brew_path" ]]; then
            eval "$("$brew_path" shellenv)"
        fi
    done
}

install_homebrew() {
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
}

# Xcode Command Line Tools provide git, python3 and the compilers Homebrew needs
if xcode-select -p >/dev/null 2>&1; then
    log "Xcode Command Line Tools: installed"
else
    log "Xcode Command Line Tools: missing"
    if [[ "$dry_run" == true ]]; then
        missing=$((missing + 1))
    else
        xcode-select --install || true
        fail "Finish the Command Line Tools installation in the dialog that opened, then run this script again"
    fi
fi

# Homebrew lives in /opt/homebrew on Apple silicon and in /usr/local on Intel Macs
load_homebrew
if command -v brew >/dev/null 2>&1; then
    log "Homebrew: installed"
else
    log "Homebrew: missing"
    step "install Homebrew with the official installer (asks for your password)" install_homebrew
    if [[ "$dry_run" != true ]]; then
        load_homebrew
        command -v brew >/dev/null 2>&1 || fail "Homebrew is not in PATH after the installation"
        log "Add Homebrew to your shell as the installer explains in its 'Next steps'"
    fi
fi

# Installs Homebrew package $2, a formula or a cask ($1), unless $3 exists:
# an absolute path, or the name of a command
brew_install() {
    local kind=$1 package=$2 check=$3 present=false
    if [[ "$check" == /* ]]; then
        [[ -e "$check" ]] && present=true
    else
        command -v "$check" >/dev/null 2>&1 && present=true
    fi
    if [[ "$present" == true ]]; then
        log "$package: installed"
        return
    fi
    log "$package: missing"
    if [[ "$kind" == cask ]]; then
        step "brew install --cask $package" brew install --cask "$package"
    else
        step "brew install $package" brew install "$package"
    fi
}

if [[ "$need_utm" == true ]]; then
    brew_install cask utm /Applications/UTM.app
    if [[ -d /Applications/UTM.app ]]; then
        # Read from the bundle: utmctl would launch UTM and needs a GUI session
        utm_version=$(defaults read /Applications/UTM.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null || echo 0)
        if ! version_ge "$utm_version" "$UTM_MIN_VERSION"; then
            log "UTM $utm_version is older than $UTM_MIN_VERSION"
            if brew list --cask utm >/dev/null 2>&1; then
                step "brew upgrade --cask utm" brew upgrade --cask utm
            else
                fail "Update UTM to $UTM_MIN_VERSION or later from https://mac.getutm.app/ (it was not installed with Homebrew)"
            fi
        fi
    fi
fi

if [[ "$need_packer" == true ]]; then
    # Packer is only in the HashiCorp tap since its license change
    brew_install formula hashicorp/tap/packer packer
fi

if [[ "$need_qemu" == true ]]; then
    brew_install formula qemu qemu-img
fi

if [[ "$need_docker" == true ]]; then
    brew_install formula coreutils gnumfmt
    if command -v docker >/dev/null 2>&1; then
        # Docker Desktop, OrbStack or an earlier run of this script
        log "Docker CLI: installed"
    else
        # Colima runs the Docker engine in a lightweight VM, without Docker Desktop
        brew_install formula colima colima
        brew_install formula docker docker
        brew_install formula docker-buildx docker-buildx
        # The ubuntu-slim build needs BuildKit (--secret), which the buildx plugin provides
        if [[ "$dry_run" != true ]]; then
            plugins_dir="$(brew --prefix)/lib/docker/cli-plugins"
            mkdir -p "$HOME/.docker"
            python3 -I - "$HOME/.docker/config.json" "$plugins_dir" <<'EOF'
import json, os, sys
path, plugins_dir = sys.argv[1], sys.argv[2]
config = json.load(open(path)) if os.path.exists(path) else {}
dirs = config.setdefault("cliPluginsExtraDirs", [])
if plugins_dir not in dirs:
    dirs.append(plugins_dir)
    json.dump(config, open(path, "w"), indent=2)
EOF
        fi
        log "Start the Docker engine with amd64 support through Rosetta before building ubuntu-slim:"
        echo "    colima start --vm-type=vz --vz-rosetta" >&2
    fi
fi

if [[ "$dry_run" == true ]]; then
    log "$missing step(s) to run. Run without --dry-run to install them"
else
    log "All prerequisites for: $components are installed"
fi
