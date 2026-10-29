# Build and run runner images locally with UTM

The templates in this repository build images on Azure (Ubuntu, Windows) and with Anka (macOS). This guide shows how to build the arm64 macOS images on your own Apple silicon Mac and run them in [UTM](https://mac.getutm.app/).

| Image                                  | How             | Scripts         |
| -------------------------------------- | --------------- | --------------- |
| macOS 14, 15, 26 arm64, Xcode 27 arm64 | macOS VM in UTM | `scripts/macos` |
| Other images                           | Not supported, see [Unsupported images](#unsupported-images) | |

The install scripts, tests and software reports come from the same templates the hosted images use. The scripts only replace the parts that are tied to Anka: creating the VM and connecting to it.

## Requirements

- A Mac with Apple silicon. UTM runs arm64 guests with hardware virtualization; x64 guests would be emulated, which is far too slow for an image build
- [UTM](https://mac.getutm.app/) 5.0.8 or later in `/Applications`. Set `UTMCTL` if `utmctl` lives elsewhere
- [Packer](https://developer.hashicorp.com/packer/install), from the HashiCorp tap: `brew install hashicorp/tap/packer`
- Disk space: VM disks are sparse and only take the space that is used, but a full image still needs a few hundred GB, depending on the number of Xcode versions

```bash
brew install --cask utm
brew install hashicorp/tap/packer
```

> [!IMPORTANT]
> Run the scripts in Terminal in a logged-in GUI session on the host. `utmctl` talks to the UTM app through Apple events and does not work over SSH or before login. The first run asks you to allow Terminal to control UTM.

The scripts are written for the bash 3.2 that ships with macOS. Shared functions live in `helpers/utm/utm-helpers.sh`.

## Choose the release to build

The default branch of `actions/runner-images` can be in a state that does not build, so the scripts build from a release tag by default, not from the files next to them. A release tag has the form `<image>/<YYYYMMDD>.<build>`, for example `macos-26-arm64/20261021.0445`.

`build-image.sh` takes these options:

| Option | Effect |
| ------ | ------ |
| none | Build the newest release tag of the image from the fork, `sbugalski/local-runner-images` |
| `--repo upstream` | Take the tags from `actions/runner-images` instead. `--repo` also accepts any git URL |
| `--tag TAG` | Build this release, as a full tag or as the version only, for example `--tag 20261021.0445` |
| `--from-checkout` | Build from this checkout, for example to test changes to the templates |

The script clones the sources at the tag once (a shallow clone of a few MB) into `~/Library/Caches/local-runner-images/sources` and uses the release version as the image version and in the default VM name, for example `macos-26-arm64-20261021.0445`. The UTM scripts themselves always come from this checkout.

### Keep the fork's release tags up to date

GitHub does not copy new upstream tags into a fork. The **Sync upstream release tags** workflow (`.github/workflows/sync-upstream-tags.yml`) does it every day: it fetches the release tags of the macOS images from `actions/runner-images` and pushes the ones the fork does not have yet. To run it right away, start it from the **Actions** tab (**Run workflow**).

> [!IMPORTANT]
> The default `GITHUB_TOKEN` cannot push commits that change files in `.github/workflows`, and new upstream commits often do.
> When the workflow fails with "refusing to allow a GitHub App to create or update workflow", create a fine-grained personal access token for the fork with **Contents: Read and write** and **Workflows: Read and write**, and store it as the repository secret `TAGS_SYNC_TOKEN`. The workflow uses it when it is set.

GitHub turns off scheduled workflows in a fork until you enable Actions for it, and in public repositories after 60 days without activity. When the fork has no release tag for an image, the build script stops and prints the command that copies the tags of that image by hand, for example:

```bash
git fetch https://github.com/actions/runner-images.git 'refs/tags/macos-26-arm64/*:refs/tags/macos-26-arm64/*'
git push origin 'refs/tags/macos-26-arm64/*'
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

## Unsupported images

- **x64 images** (macOS x64). UTM can only emulate x64 on Apple silicon. An image build installs tens of GB of software and would take days under emulation
- **macOS on an Intel Mac.** UTM supports macOS guests only on Apple silicon
- **Ubuntu and Windows images.** These scripts cover the macOS templates only

## Run the images

Each build leaves the VM stopped in UTM. Pass `--export PATH.utm` to `build-image.sh` to also export it as a `.utm` bundle you can copy to another Mac. Start it in the UTM window or from Terminal:

```bash
UTMCTL=/Applications/UTM.app/Contents/MacOS/utmctl
"$UTMCTL" start macos-26-arm64-20261021.0445
"$UTMCTL" ip-address macos-26-arm64-20261021.0445
ssh runner@<ip>
```

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
