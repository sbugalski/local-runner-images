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

`Install-Xcode.ps1` downloads `<storage URL>Xcode-<version>.xip?<SAS>` for every Xcode version in the toolset and checks the SHA-256 sum from the toolset. `<version>` is the `version` field under `xcode.arm64.versions` in `images/macos/toolsets/toolset-*.json`, for example `Xcode-26.6+17F113.xip`.

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

The script clones the base VM to `--name` (default `<image>-<timestamp>`), starts the clone, waits for SSH, runs `packer build` with `builder_type=null` and shuts the VM down.

## Ubuntu images

The Ubuntu templates only define an `azure-arm` source, so `scripts/ubuntu/generate-template.sh` writes a copy of the build file to `images/ubuntu/.utm-template` (ignored by git) with three changes:

- the build uses a `null` source that connects to the UTM VM over SSH
- the final `waagent -force -deprovision+user` is dropped. It needs the Azure agent and would delete the build user
- the software report is downloaded to `images/image-output` instead of over the committed readme

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

The script builds `ubuntu-slim:test` for `linux/amd64` and runs `images/ubuntu-slim/test.sh` against it. Pass another image name as the first argument to tag the image differently.

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

For a clean environment on every run, clone the image before each job and delete the clone afterwards:

```bash
"$UTMCTL" clone ubuntu-24.04-arm64-202610271200 --name job-1
"$UTMCTL" start job-1
# ... run the job over SSH ...
"$UTMCTL" stop job-1 --request
"$UTMCTL" delete job-1
```

On a macOS 27 host, `utmctl start --disposable` runs a macOS VM without saving changes to its disk, which avoids the clone.

To use a VM as a GitHub Actions runner, install the runner application in the guest as described in [Adding self-hosted runners](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/adding-self-hosted-runners).

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
