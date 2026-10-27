#!/bin/bash -e -o pipefail
################################################################################
##  File:  run-ephemeral-runner.sh
##  Desc:  Runs GitHub Actions jobs of a repository on a runner image in UTM.
##         For every job it clones the image VM, starts the clone, registers a
##         just-in-time runner that takes one job and then unregisters itself,
##         and deletes the clone afterwards, so every job starts from a clean
##         system. The image VM itself is never started.
##  Usage: see docs/create-image-utm.md or run with --help
################################################################################

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../helpers/utm/utm-helpers.sh"

usage() {
    cat <<EOF
Usage: $(basename "$0") --vm NAME --repo OWNER/REPO --username USER [options]

Required:
  --vm NAME            Image VM in UTM built by build-image.sh. It stays stopped and unchanged
  --repo OWNER/REPO    Repository to register the runners to
  --username USER      Account in the guest

Options:
  --ssh-key PATH       Private SSH key of the account (Ubuntu images). Without it,
                       the password in UTM_VM_PASSWORD is used (macOS images)
  --labels LIST        Additional comma-separated runner labels. Every runner gets
                       self-hosted, macOS or Linux, and ARM64
  --jobs COUNT         Stop after COUNT jobs (default: 0, run until interrupted)
  --runner-group ID    Runner group ID (default: 1, the Default group)
  -h, --help           Show this help

Environment:
  GITHUB_TOKEN         Token allowed to manage the self-hosted runners of the repository:
                       a fine-grained token with "Administration: Read and write" on it,
                       or a classic token with the repo scope (required)
  UTM_VM_PASSWORD      Password of the guest account, when --ssh-key is not used
EOF
}

jobs=0
runner_group=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vm) vm=$2; shift 2 ;;
        --repo) repo=$2; shift 2 ;;
        --username) username=$2; shift 2 ;;
        --ssh-key) ssh_key=$2; shift 2 ;;
        --labels) extra_labels=$2; shift 2 ;;
        --jobs) jobs=$2; shift 2 ;;
        --runner-group) runner_group=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; fail "Unknown argument '$1'" ;;
    esac
done

[[ -n "$vm" && -n "$repo" && -n "$username" ]] || { usage >&2; fail "--vm, --repo and --username are required"; }
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "--repo must look like OWNER/REPO"
[[ -z "$extra_labels" || "$extra_labels" =~ ^[A-Za-z0-9_.-]+(,[A-Za-z0-9_.-]+)*$ ]] || fail "--labels must be a comma-separated list of names"
[[ "$jobs" =~ ^[0-9]+$ && "$runner_group" =~ ^[0-9]+$ ]] || fail "--jobs and --runner-group must be numbers"
[[ -n "$GITHUB_TOKEN" ]] || fail "Set GITHUB_TOKEN to a token that can manage the runners of $repo"
if [[ -n "$ssh_key" ]]; then
    [[ -f "$ssh_key" ]] || fail "SSH key '$ssh_key' not found"
else
    [[ -n "$UTM_VM_PASSWORD" ]] || fail "Pass --ssh-key or set the guest password in UTM_VM_PASSWORD"
fi

assert_host
for tool in curl git ssh scp plutil nc; do
    assert_command "$tool"
done
vm_exists "$vm" || fail "VM '$vm' not found in UTM"
[[ "$(vm_status "$vm")" == "stopped" ]] || fail "VM '$vm' must be stopped, clones are made from its disk"

work_dir=$(mktemp -d)
cache_dir="$HOME/Library/Caches/local-runner-images/actions-runner"
mkdir -p "$cache_dir"

# Keep the token out of the process list
printf 'Authorization: Bearer %s\n' "$GITHUB_TOKEN" > "$work_dir/auth-header"
chmod 600 "$work_dir/auth-header"

# All clones share the host keys of the image but can get different addresses,
# so known_hosts entries would only cause mismatches
ssh_options=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ServerAliveInterval=30)
if [[ -n "$ssh_key" ]]; then
    ssh_options+=(-i "$ssh_key" -o IdentitiesOnly=yes -o BatchMode=yes)
else
    # ssh reads a password only from a terminal or from SSH_ASKPASS
    cat > "$work_dir/askpass" <<'EOF'
#!/bin/sh
printf '%s\n' "$UTM_VM_PASSWORD"
EOF
    chmod 700 "$work_dir/askpass"
    export UTM_VM_PASSWORD SSH_ASKPASS="$work_dir/askpass" SSH_ASKPASS_REQUIRE=force
    ssh_options+=(-o "PreferredAuthentications=password,keyboard-interactive" -o PubkeyAuthentication=no)
fi

# Commands are built on the host on purpose, e.g. with the runner configuration
# shellcheck disable=SC2029
guest_ssh() {
    ssh "${ssh_options[@]}" "$username@$ip" "$@"
}

github_api() {
    local method=$1 path=$2 data=$3
    local args=()
    if [[ -n "$data" ]]; then
        args=(--data "$data")
    fi
    curl -sS --fail-with-body -X "$method" \
        -H "@$work_dir/auth-header" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "${args[@]}" "https://api.github.com$path"
}

# Prints the path of the cached runner archive for $1 (osx or linux), downloaded on first use
runner_archive() {
    local file="actions-runner-$1-arm64-$runner_version.tar.gz"
    if [[ ! -f "$cache_dir/$file" ]]; then
        log "Downloading $file"
        curl -fL --retry 3 -o "$cache_dir/$file.part" \
            "https://github.com/actions/runner/releases/download/v$runner_version/$file"
        mv "$cache_dir/$file.part" "$cache_dir/$file"
    fi
    echo "$cache_dir/$file"
}

tags=$(git ls-remote --tags --refs https://github.com/actions/runner.git) || fail "Could not list the releases of actions/runner"
runner_version=$(echo "$tags" | awk '{ sub("refs/tags/", "", $2); print $2 }' | select_latest_runner_version)
[[ -n "$runner_version" ]] || fail "Could not find the newest release of actions/runner"
log "Using actions/runner $runner_version"

clone=""
runner_id=""

# Deletes the runner registration and the clone of the current job. GitHub
# assigns a just-in-time runner a single job, so its registration is no longer
# needed afterwards, even if GitHub has not removed it yet
remove_job() {
    if [[ -n "$runner_id" ]]; then
        # Fails harmlessly when GitHub has already removed the runner
        github_api DELETE "/repos/$repo/actions/runners/$runner_id" >/dev/null 2>&1 || true
        runner_id=""
    fi
    if [[ -n "$clone" ]] && vm_exists "$clone"; then
        log "Removing VM '$clone'"
        "$UTMCTL" stop "$clone" --force >/dev/null 2>&1 || true
        # subshell, because fail() would exit before the VM is deleted
        (wait_vm_status "$clone" "stopped" 60) || true
        "$UTMCTL" delete "$clone" || true
    fi
    clone=""
}

cleanup() {
    remove_job
    rm -rf "$work_dir"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

run_job() {
    clone="$vm-runner-$(date +%Y%m%d%H%M%S)"
    log "Cloning '$vm' to '$clone'"
    "$UTMCTL" clone "$vm" --name "$clone"
    vm_exists "$clone" || fail "Cloning '$vm' failed"
    ip=$(start_vm_and_wait_ssh "$clone")

    local runner_os os_label
    case "$(guest_ssh uname -s)" in
        Darwin) runner_os=osx; os_label=macOS ;;
        Linux) runner_os=linux; os_label=Linux ;;
        *) fail "Unsupported guest operating system in '$clone'" ;;
    esac

    local labels="self-hosted,$os_label,ARM64${extra_labels:+,$extra_labels}"
    local body response jit_config
    body=$(printf '{"name":"%s","runner_group_id":%s,"labels":["%s"],"work_folder":"_work"}' \
        "$clone" "$runner_group" "${labels//,/\",\"}")
    response=$(github_api POST "/repos/$repo/actions/runners/generate-jitconfig" "$body") \
        || fail "Could not register a runner in $repo: $response"
    echo "$response" > "$work_dir/jit.json"
    runner_id=$(plutil -extract runner.id raw -o - "$work_dir/jit.json")
    jit_config=$(plutil -extract encoded_jit_config raw -o - "$work_dir/jit.json")
    rm -f "$work_dir/jit.json"
    [[ "$jit_config" =~ ^[A-Za-z0-9+/=]+$ ]] || fail "Unexpected runner configuration from the GitHub API"

    scp -q "${ssh_options[@]}" "$(runner_archive "$runner_os")" "$username@$ip:actions-runner.tar.gz"
    guest_ssh 'mkdir -p ~/actions-runner && tar -xzf ~/actions-runner.tar.gz -C ~/actions-runner && rm ~/actions-runner.tar.gz'

    # A login shell loads the environment the image sets up for the runner user
    log "Runner '$clone' is waiting for a job in $repo (labels: $labels)"
    if guest_ssh "bash -lc 'cd ~/actions-runner && ./run.sh --jitconfig $jit_config'"; then
        log "Runner '$clone' finished its job"
    else
        log "Runner '$clone' exited with an error"
    fi
    remove_job
}

completed=0
while (( jobs == 0 || completed < jobs )); do
    run_job
    completed=$((completed + 1))
done
