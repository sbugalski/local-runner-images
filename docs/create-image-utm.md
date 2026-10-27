# Build and run runner images locally with UTM

The templates in this repository build images on Azure (Ubuntu, Windows) and with Anka (macOS). This guide shows how to build the arm64 macOS and Ubuntu images on your own Apple silicon Mac and run them in [UTM](https://mac.getutm.app/), and how to build the `ubuntu-slim` container image on a Mac.

| Image                                                   | How                         | Scripts                  |
| ------------------------------------------------------- | --------------------------- | ------------------------ |
| macOS 14, 15, 26 arm64, Xcode 27 arm64                  | macOS VM in UTM             | `scripts/macos`          |
| Ubuntu 22.04, 24.04, 26.04 arm64                        | Linux VM in UTM             | `scripts/ubuntu`         |
| `ubuntu-slim`                                           | Docker container            | `scripts/ubuntu-slim`    |
| macOS and Ubuntu x64, Windows                           | Not supported, see [Unsupported images](#unsupported-images) | |

In every case the install scripts, tests and software reports come from the same templates the hosted images use. The scripts only replace the parts that are tied to Azure or Anka: creating the VM and connecting to it.

## Requirements

- A Mac with Apple silicon. UTM runs arm64 guests with hardware virtualization; x64 guests would be emulated, which is far too slow for an image build
- [UTM](https://mac.getutm.app/) 5.0.8 or later in `/Applications`. Set `UTMCTL` if `utmctl` lives elsewhere
- [Packer](https://developer.hashicorp.com/packer/install), for example `brew install packer`
- Disk space: VM disks are sparse and only take the space that is used, but a full image still needs from about 50 GB (Ubuntu) to a few hundred GB (macOS with several Xcode versions)

> [!IMPORTANT]
> Run the scripts in Terminal in a logged-in GUI session on the host. `utmctl` talks to the UTM app through Apple events and does not work over SSH or before login. The first run asks you to allow Terminal to control UTM.

The scripts are written for the bash 3.2 that ships with macOS. Shared functions live in `helpers/utm/utm-helpers.sh`.

## Choose the release to build

The default branch of `actions/runner-images` can be in a state that does not build, so the scripts build from a release tag by default, not from the files next to them. A release tag has the form `<image>/<YYYYMMDD>.<build>`, for example `macos-26-arm64/20261021.0445` or `ubuntu24-arm64/20261026.166`.

All three build scripts take the same options:

| Option | Effect |
| ------ | ------ |
| none | Build the newest release tag of the image from the fork, `sbugalski/local-runner-images` |
| `--repo upstream` | Take the tags from `actions/runner-images` instead. `--repo` also accepts any git URL |
| `--tag TAG` | Build this release, as a full tag or as the version only, for example `--tag 20261021.0445` |
| `--from-checkout` | Build from this checkout, for example to test changes to the templates |

The script clones the sources at the tag once (a shallow clone of a few MB) into `~/Library/Caches/local-runner-images/sources` and uses the release version as the image version and in the default VM name, for example `macos-26-arm64-20261021.0445`. The UTM scripts themselves always come from this checkout.

### Keep the fork's release tags up to date

GitHub does not copy new upstream tags into a fork. The **Sync upstream release tags** workflow (`.github/workflows/sync-upstream-tags.yml`) does it every day: it fetches the release tags of the images in the table above from `actions/runner-images` and pushes the ones the fork does not have yet. To run it right away, start it from the **Actions** tab (**Run workflow**).

> [!IMPORTANT]
> The default `GITHUB_TOKEN` cannot push commits that change files in `.github/workflows`, and new upstream commits often do.
> When the workflow fails with "refusing to allow a GitHub App to create or update workflow", create a fine-grained personal access token for the fork with **Contents: Read and write** and **Workflows: Read and write**, and store it as the repository secret `TAGS_SYNC_TOKEN`. The workflow uses it when it is set.

GitHub turns off scheduled workflows in a fork until you enable Actions for it, and in public repositories after 60 days without activity. When the fork has no release tag for an image, the build script stops and prints the command that copies the tags of that image by hand, for example:

```bash
git fetch https://github.com/actions/runner-images.git 'refs/tags/ubuntu24-arm64/*:refs/tags/ubuntu24-arm64/*'
git push origin 'refs/tags/ubuntu24-arm64/*'
```

## macOS images

The macOS templates support a Packer `null` builder next to Anka. `build-image.sh` uses it against a clone of a base VM that you create once per macOS version:

- `create-base-vm.sh` creates a macOS VM in UTM from an IPSW restore image and prepares it the way the Anka source VM is prepared (user account, Remote Login, SIP disabled, passwordless sudo)
- `build-image.sh` clones the base VM, starts the clone and runs the image template against it. The result is a VM in UTM with the full runner image software

| `--image`        | Template                      | Guest macOS |
| ---------------- | ----------------------------- | ----------- |
| `macos-14-arm64` | `macOS-14.arm64.anka.pkr.hcl` | 14          |
| `macos-15-arm64` | `macOS-15.arm64.anka.pkr.hcl` | 15          |
| `macos-26-arm64` | `macOS-26.arm64.anka.pkr.hcl` | 26          |
| `xcode-27-arm64` | `xcode-27.arm64.anka.pkr.hcl` | 27          |

The guest cannot be newer than the host. To build `xcode-27-arm64`, the host must run macOS 27 or later.

### Step 1: Create the base VM

Download an IPSW restore image for the macOS version of the image. Apple publishes the URLs of its restore images for Mac computers; UTM also offers to download the latest one when you create a macOS VM in its window.

```bash
export UTM_VM_PASSWORD='choose-a-password'

./scripts/macos/create-base-vm.sh \
    --name macos-26-base \
    --ipsw ~/Downloads/UniversalMac_26.x_Restore.ipsw \
    --username runner
```

Use `--cpu`, `--memory` (MiB) and `--disk` (GiB) to change the defaults of 6 cores, 8192 MiB and 300 GiB. `--ipsw` also accepts an `https://` URL; the file is cached in `~/Library/Caches/local-runner-images`.

The script installs macOS and then needs you twice in the UTM window:

1. **Setup Assistant.** Create an administrator account with the short name and password you passed, turn on **System Settings > General > Sharing > Remote Login**, and shut down the VM. With `--auto-setup` the script creates the account and turns on Remote Login itself, but this requires macOS 27 or later on both the host and the guest
2. **recoveryOS.** The script boots the VM into recoveryOS. Open **Utilities > Terminal**, run `csrutil disable`, confirm, and shut down the VM. The image scripts write to the system TCC database and unload system daemons, which System Integrity Protection blocks

The script waits until the VM shuts down after each step. Finally it connects over SSH, allows passwordless `sudo` for the account and turns off sleep (`scripts/macos/configure-base-vm.sh`), then shuts the VM down. Keep the base VM; each build starts from a clone of it.

### Step 2: Provide Xcode

`Install-Xcode.ps1` downloads `<storage URL>Xcode-<version>.xip?<SAS>` for every Xcode version in the toolset and checks the SHA-256 sum from the toolset. `<version>` is the `version` field under `xcode.arm64.versions` in `images/macos/toolsets/toolset-*.json` of the release you build, for example `Xcode-26.6+17F113.xip`.
The Xcode versions change between releases; `build-image.sh` prints the files the release needs and, with `--xcode-dir`, stops before the build when one is missing.

Download the archives from [Apple Developer](https://developer.apple.com/download/all/?q=xcode) and rename them to that pattern. Then choose one option:

- `--xcode-dir DIR`: the script serves `DIR` over HTTP with `python3` on the host side of the UTM shared network while the build runs
- `--xcode-url URL`: use your own server or storage. Put a query string such as a SAS token in `XCODE_INSTALL_SAS`

> [!TIP]
> To build faster or with less disk space, remove Xcode versions from the toolset before the build, but keep the one set as `xcode.default`. The tests in `images/macos/scripts/tests/Xcode.Tests.ps1` read the same toolset, so they stay consistent.

### Step 3: Build the macOS image

```bash
export UTM_VM_PASSWORD='choose-a-password'
export GITHUB_API_PAT='<optional token, avoids GitHub API rate limits>'

./scripts/macos/build-image.sh \
    --image macos-26-arm64 \
    --base-vm macos-26-base \
    --username runner \
    --xcode-dir ~/Downloads/xcode
```

The script clones the base VM to `--name` (default `<image>-<release version>`), starts the clone, waits for SSH, runs `packer build` with `builder_type=null` and shuts the VM down.

## Ubuntu images

The Ubuntu templates only define an `azure-arm` source, so `scripts/ubuntu/generate-template.sh` writes a copy of the build file to `images/ubuntu/.utm-template` (ignored by git) with three changes:

- the build uses a `null` source that connects to the UTM VM over SSH
- the final `waagent -force -deprovision+user` is dropped. It needs the Azure agent and would delete the build user
- the software report is downloaded to `images/image-output` of the sources instead of over the committed readme

The script fails when an upstream change to the template makes this rewrite incomplete, rather than build something different from the template.

Additional requirement: `qemu-img` from `brew install qemu`. UTM's Apple Virtualization backend needs a raw disk, and the script converts the Ubuntu cloud image with it.

```bash
./scripts/ubuntu/build-image.sh --image ubuntu-24.04-arm64
```

| `--image`            | Template                             |
| -------------------- | ------------------------------------ |
| `ubuntu-22.04-arm64` | `build.ubuntu-22_04-arm64.pkr.hcl`   |
| `ubuntu-24.04-arm64` | `build.ubuntu-24_04-arm64.pkr.hcl`   |
| `ubuntu-26.04-arm64` | `build.ubuntu-26_04-arm64.pkr.hcl`   |

The script:

1. Downloads the arm64 cloud image from `cloud-images.ubuntu.com`, checks it against `SHA256SUMS` and caches it in `~/Library/Caches/local-runner-images`
2. Converts it to a raw disk of `--disk` GiB (default 100) and creates a cloud-init seed that adds the account `--username` (default `runner`) with passwordless `sudo` and your SSH key
3. Creates a Linux VM in UTM with `--cpu` (default 4) and `--memory` MiB (default 16384), starts it and waits for SSH
4. Runs `packer build` on the generated template and shuts the VM down

The account has no password; you log in with the SSH key. Pass `--ssh-key PATH` to use your own key (`PATH.pub` must exist), otherwise the script creates `~/.ssh/utm-runner-images`.

> [!NOTE]
> The Azure image has the Azure agent and Azure apt mirrors; the cloud image does not. The script writes a stub `/etc/waagent.conf` so `configure-environment.sh` can run, and the apt sources keep pointing at `ports.ubuntu.com`.

## ubuntu-slim

`ubuntu-slim` is a container image, not a VM, so it does not run in UTM. Its Dockerfile downloads amd64 binaries, so it only builds for `linux/amd64`, which Docker runs emulated on Apple silicon.

Requirements: a Docker engine with the `docker` CLI (Docker Desktop, OrbStack or Colima) and `numfmt` from `brew install coreutils`, used by `test.sh`.

```bash
export GITHUB_TOKEN='<optional token, avoids GitHub API rate limits>'
./scripts/ubuntu-slim/build-macos.sh
```

The script builds `ubuntu-slim:<release version>` for `linux/amd64` and runs `images/ubuntu-slim/test.sh` of the release against it. Pass `--name` to tag the image differently.

## Unsupported images

- **x64 images** (macOS x64, Ubuntu x64, Windows Server 2022 and 2025). UTM can only emulate x64 on Apple silicon. An image build installs tens of GB of software and would take days under emulation
- **macOS on an Intel Mac.** UTM supports macOS guests only on Apple silicon
- **Windows 11 arm64.** UTM can run it with the QEMU backend, but the templates depend on Azure for more than the VM: they rely on the Azure image (drivers, WinRM over HTTPS), and they end with Sysprep `/generalize /oobe`, which leaves a local VM at the first-run setup screen.
  Building it locally needs an unattended install, VirtIO drivers and changes to the build steps, which these scripts do not cover

## Run the images

Each build leaves the VM stopped in UTM. Pass `--export PATH.utm` to `build-image.sh` to also export it as a `.utm` bundle you can copy to another Mac. Start it in the UTM window or from Terminal:

```bash
UTMCTL=/Applications/UTM.app/Contents/MacOS/utmctl
"$UTMCTL" start ubuntu-24.04-arm64-202610271200
"$UTMCTL" ip-address ubuntu-24.04-arm64-202610271200
ssh -i ~/.ssh/utm-runner-images runner@<ip>
```

### Run the images as ephemeral GitHub Actions runners

`scripts/run-ephemeral-runner.sh` serves the jobs of one repository from an image VM, with a clean system for every job:

1. It clones the image VM (an APFS copy-on-write clone, so it takes seconds and almost no disk space) and starts the clone
2. It asks the GitHub API for a [just-in-time runner configuration](https://docs.github.com/en/rest/actions/self-hosted-runners). A just-in-time runner is ephemeral: GitHub assigns it a single job. After the job the script also deletes the runner registration
3. It copies the newest [actions/runner](https://github.com/actions/runner) release into the guest and starts the runner over SSH. The images do not contain the runner application, so the script downloads it once into `~/Library/Caches/local-runner-images/actions-runner`
4. When the job is done, it deletes the clone and starts again with a new one

```bash
export GITHUB_TOKEN='<token that can manage the runners of the repository>'

# macOS image, password login
UTM_VM_PASSWORD='choose-a-password' ./scripts/run-ephemeral-runner.sh \
    --vm macos-26-arm64-20261021.0445 --repo OWNER/REPO --username runner --labels macos-26-arm64

# Ubuntu image, SSH key login
./scripts/run-ephemeral-runner.sh \
    --vm ubuntu-24.04-arm64-20261026.166 --repo OWNER/REPO --username runner \
    --ssh-key ~/.ssh/utm-runner-images --labels ubuntu-24.04-arm64
```

Every runner gets the labels `self-hosted`, `macOS` or `Linux`, and `ARM64`, plus the ones in `--labels`. Target them in a workflow with, for example, `runs-on: [self-hosted, macos-26-arm64]`. `--jobs COUNT` stops after `COUNT` jobs; without it the script runs until you stop it with Ctrl+C, which also removes the clone and the unused runner registration.

`GITHUB_TOKEN` must be allowed to manage the self-hosted runners of the repository: a fine-grained personal access token for that repository with **Administration: Read and write**, or a classic token with the `repo` scope.

Notes:

- One script runs one runner at a time. Start the script several times for parallel runners, as far as the Mac has CPU and memory for the VMs
- The runner runs in the SSH session of the guest account, not in its GUI session. Jobs that need the GUI session, such as some UI tests on macOS, may not work
- Clones of an image share its host name and SSH host keys. The script does not check the host keys of the clones, which only run on the local UTM network
- On a macOS 27 host, `utmctl start --disposable` runs a macOS VM without saving changes to its disk, an alternative to cloning when you run a VM by hand

> [!NOTE]
> Apple's macOS license allows at most two additional macOS VMs per Mac, for development and testing and similar purposes. Check the license terms before you run macOS VMs as shared CI infrastructure.

## Troubleshooting

- **`utmctl failed`**: start the script from Terminal in the GUI session and allow Terminal to control UTM in **System Settings > Privacy & Security > Automation**
- **No IP address**: the scripts read it from `utmctl ip-address` and from `/var/db/dhcpd_leases`. Check that the VM network mode is **Shared Network** and that the guest finished booting
- **The VM stops during the build**: some guest reboots end with the VM stopped. The build scripts start it again while Packer runs, so Packer reconnects after the reboot
- **A build fails**: the VM is deleted. Pass `--keep-on-failure` to keep it running and connect over SSH to investigate
- **The guest cannot download Xcode from `--xcode-dir`**: the macOS firewall on the host may block `python3`. Allow incoming connections for it or use `--xcode-url`
- **`Xcode ... checksum mismatch`**: the archive is not the one from the toolset. Download the exact build named in the `version` field
- **`System Integrity Protection is enabled`**: repeat the recoveryOS step. Start the base VM with `utmctl start <name> --recovery`
- **`generate-template.sh` reports that a build file changed**: the upstream Ubuntu template changed in a way the rewrite does not cover. Compare the build file with the generated one and update `generate-template.sh`
