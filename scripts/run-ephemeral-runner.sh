#!/bin/bash -e -o pipefail
################################################################################
##  File:  run-ephemeral-runner.sh
##  Desc:  Runs GitHub Actions jobs of a repository on a runner image in UTM.
##         For every job it clones the image VM, starts the clone, registers a
##         just-in-time runner that takes one job and then unregisters itself,
##         and deletes the clone afterwards, so every job starts from a clean
##         system. The image VM itself is never started.
##         The runner runs detached in the guest, so a dropped SSH connection
##         does not end the job; the script polls the runner and the GitHub API.
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
  --idle-timeout MIN   Stop when a runner gets no job for MIN minutes (default: 0, wait forever)
  --job-timeout MIN    Stop a job that runs longer than MIN minutes and fail it
                       (default: 0, only the timeout of the job on GitHub applies)
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
idle_timeout=0
job_timeout=0

POLL_SECONDS=30
# A guest that does not answer SSH for this long is considered dead
UNREACHABLE_SECONDS=600

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vm) vm=$2; shift 2 ;;
        --repo) repo=$2; shift 2 ;;
        --username) username=$2; shift 2 ;;
        --ssh-key) ssh_key=$2; shift 2 ;;
        --labels) extra_labels=$2; shift 2 ;;
        --jobs) jobs=$2; shift 2 ;;
        --idle-timeout) idle_timeout=$2; shift 2 ;;
        --job-timeout) job_timeout=$2; shift 2 ;;
        --runner-group) runner_group=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; fail "Unknown argument '$1'" ;;
    esac
done

[[ -n "$vm" && -n "$repo" && -n "$username" ]] || { usage >&2; fail "--vm, --repo and --username are required"; }
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "--repo must look like OWNER/REPO"
[[ -z "$extra_labels" || "$extra_labels" =~ ^[A-Za-z0-9_.-]+(,[A-Za-z0-9_.-]+)*$ ]] || fail "--labels must be a comma-separated list of names"
for number in "$jobs" "$runner_group" "$idle_timeout" "$job_timeout"; do
    [[ "$number" =~ ^[0-9]+$ ]] || fail "--jobs, --runner-group, --idle-timeout and --job-timeout must be whole numbers"
done
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

# Clones left behind by a run that could not clean up, e.g. after kill -9 or a
# host restart. Another instance of this script may still use them, so only warn
leftovers=$("$UTMCTL" list | awk -v prefix="$vm-runner-" 'NR > 1 && index($3, prefix) == 1 { print $3 }')
if [[ -n "$leftovers" ]]; then
    log "Found runner clones of '$vm' from earlier runs. Unless another instance of this script uses them, delete them with:"
    for leftover in $leftovers; do
        echo "    $UTMCTL stop $leftover --force; $UTMCTL delete $leftover" >&2
    done
fi

work_dir=$(mktemp -d)
cache_dir="$HOME/Library/Caches/local-runner-images/actions-runner"
mkdir -p "$cache_dir"

# Keep the token out of the process list
printf 'Authorization: Bearer %s\n' "$GITHUB_TOKEN" > "$work_dir/auth-header"
chmod 600 "$work_dir/auth-header"

# All clones share the host keys of the image but can get different addresses,
# so known_hosts entries would only cause mismatches
ssh_options=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=15 -o ServerAliveInterval=30)
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
    # Stop the VM first: GitHub does not delete a runner that still runs a job
    if [[ -n "$clone" ]] && vm_exists "$clone"; then
        log "Removing VM '$clone'"
        "$UTMCTL" stop "$clone" --force >/dev/null 2>&1 || true
        # subshell, because fail() would exit before the VM is deleted
        (wait_vm_status "$clone" "stopped" 60) || true
        "$UTMCTL" delete "$clone" || true
    fi
    clone=""
    if [[ -n "$runner_id" ]]; then
        # Fails harmlessly when GitHub has already removed the runner
        github_api DELETE "/repos/$repo/actions/runners/$runner_id" >/dev/null 2>&1 || true
        runner_id=""
    fi
}

# Prints true or false for the busy state of the current runner, or nothing
# when the API does not answer or the runner is gone
runner_busy() {
    local response
    response=$(github_api GET "/repos/$repo/actions/runners/$runner_id" 2>/dev/null) || return 0
    echo "$response" > "$work_dir/runner.json"
    plutil -extract busy raw -o - "$work_dir/runner.json" 2>/dev/null || true
}

# Waits for the detached runner in the guest and prints how it ended:
# finished:<exit code>, idle, job-timeout, unreachable or vm-stopped
watch_runner() {
    local started now busy exit_code busy_since="" unreachable_since=""
    started=$(date +%s)
    while sleep "$POLL_SECONDS"; do
        now=$(date +%s)
        if [[ "$(vm_status "$clone" 2>/dev/null)" != "started" ]]; then
            echo vm-stopped
            return
        fi

        # '|| true' in the guest, so the exit status of ssh only reflects the connection
        if exit_code=$(guest_ssh 'cat ~/actions-runner/exit-code 2>/dev/null || true' 2>/dev/null); then
            unreachable_since=""
            if [[ -n "$exit_code" ]]; then
                echo "finished:$exit_code"
                return
            fi
        else
            unreachable_since=${unreachable_since:-$now}
            if (( now - unreachable_since >= UNREACHABLE_SECONDS )); then
                echo unreachable
                return
            fi
        fi

        busy=$(runner_busy)
        if [[ "$busy" == "true" ]]; then
            busy_since=${busy_since:-$now}
            if (( job_timeout > 0 && now - busy_since >= job_timeout * 60 )); then
                echo job-timeout
                return
            fi
        elif [[ -z "$busy_since" ]] && (( idle_timeout > 0 && now - started >= idle_timeout * 60 )); then
            # GitHub refuses to delete a runner with a job, so a job that was
            # assigned in the meantime keeps running
            if github_api DELETE "/repos/$repo/actions/runners/$runner_id" >/dev/null 2>&1; then
                echo idle
                return
            fi
        fi
    done
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

    # Detached with nohup, so the runner outlives the SSH session that starts
    # it; a login shell loads the environment the image sets up for the account
    guest_ssh "cd ~/actions-runner && nohup bash -lc './run.sh --jitconfig $jit_config; echo \$? > exit-code' > runner.log 2>&1 < /dev/null &"
    log "Runner '$clone' is waiting for a job in $repo (labels: $labels)"

    outcome=$(watch_runner)
    case "$outcome" in
        finished:0) log "Runner '$clone' finished its job" ;;
        finished:*) log "Runner '$clone' exited with code ${outcome#finished:}" ;;
        idle) log "Runner '$clone' got no job within $idle_timeout minutes" ;;
        job-timeout) log "The job on '$clone' ran longer than $job_timeout minutes and is stopped" ;;
        unreachable) log "Runner '$clone' did not answer over SSH for $((UNREACHABLE_SECONDS / 60)) minutes" ;;
        vm-stopped) log "VM '$clone' stopped before its runner finished" ;;
    esac
    if [[ "$outcome" != "finished:0" && "$outcome" != "idle" ]]; then
        log "Last lines of the runner log:"
        guest_ssh 'tail -n 20 ~/actions-runner/runner.log' >&2 2>/dev/null || true
    fi
    remove_job
}

completed=0
while (( jobs == 0 || completed < jobs )); do
    run_job
    if [[ "$outcome" == "idle" ]]; then
        log "Stopping, no job arrived for $idle_timeout minutes"
        break
    fi
    completed=$((completed + 1))
done
