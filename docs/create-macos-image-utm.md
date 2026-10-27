# Build and run macOS images locally with UTM

The macOS templates in `images/macos/templates` are built with Anka in GitHub's infrastructure. This guide shows how to build the same arm64 images on your own Apple silicon Mac and run them in [UTM](https://mac.getutm.app/).

The scripts in `images/macos/utm` replace the Anka parts of the build:

- `create-base-vm.sh` creates a macOS VM in UTM from an IPSW restore image and prepares it the way the Anka source VM is prepared (user account, Remote Login, SIP disabled, passwordless sudo). You do this once per macOS version
- `build-image.sh` clones the base VM, starts the clone and runs the regular image template against it with the Packer `null` builder. The result is a VM in UTM with the full runner image software

Every install script, test and software report comes from the same template the hosted image uses, so the result matches the hosted image as closely as possible without Anka.

## Requirements

- A Mac with Apple silicon. macOS guests in UTM use Apple's Virtualization framework, which supports them only on Apple silicon, so the x64 images (`macOS-*.anka.pkr.hcl` without `arm64`) cannot be built this way
- [UTM](https://mac.getutm.app/) 5.0.8 or later in `/Applications`. Set `UTMCTL` if `utmctl` lives elsewhere
- [Packer](https://developer.hashicorp.com/packer/install), for example `brew install packer`
- `python3` on the host when you use `--xcode-dir`
- Disk space: a full image with several Xcode versions needs a few hundred GB. VM disks are sparse, so they only take the space that is used
- The Xcode `.xip` archives listed in the toolset of the image, see [Provide Xcode](#step-2-provide-xcode)

> [!IMPORTANT]
> Run the scripts in Terminal in a logged-in GUI session on the host. `utmctl` talks to the UTM app through Apple events and does not work over SSH or before login. The first run asks you to allow Terminal to control UTM.

Supported images:

| `--image`        | Template                      | Guest macOS |
| ---------------- | ----------------------------- | ----------- |
| `macos-14-arm64` | `macOS-14.arm64.anka.pkr.hcl` | 14          |
| `macos-15-arm64` | `macOS-15.arm64.anka.pkr.hcl` | 15          |
| `macos-26-arm64` | `macOS-26.arm64.anka.pkr.hcl` | 26          |
| `xcode-27-arm64` | `xcode-27.arm64.anka.pkr.hcl` | 27          |

The guest cannot be newer than the host. To build `xcode-27-arm64`, the host must run macOS 27 or later.

## Step 1: Create the base VM

Download an IPSW restore image for the macOS version of the image. Apple publishes the URLs of its restore images for Mac computers; UTM also offers to download the latest one when you create a macOS VM in its window.

```bash
export UTM_VM_PASSWORD='choose-a-password'

./images/macos/utm/create-base-vm.sh \
    --name macos-26-base \
    --ipsw ~/Downloads/UniversalMac_26.x_Restore.ipsw \
    --username runner
```

Use `--cpu`, `--memory` (MiB) and `--disk` (GiB) to change the defaults of 6 cores, 8192 MiB and 300 GiB. `--ipsw` also accepts an `https://` URL; the file is cached in `~/Library/Caches/local-runner-images`.

The script installs macOS and then needs you twice in the UTM window:

1. **Setup Assistant.** Create an administrator account with the short name and password you passed, turn on **System Settings > General > Sharing > Remote Login**, and shut down the VM. With `--auto-setup` the script creates the account and turns on Remote Login itself, but this requires macOS 27 or later on both the host and the guest
2. **recoveryOS.** The script boots the VM into recoveryOS. Open **Utilities > Terminal**, run `csrutil disable`, confirm, and shut down the VM. The image scripts write to the system TCC database and unload system daemons, which System Integrity Protection blocks

The script waits until the VM shuts down after each step. Finally it connects over SSH, allows passwordless `sudo` for the account and turns off sleep (`images/macos/utm/configure-base-vm.sh`), then shuts the VM down. Keep the base VM; each build starts from a clone of it.

## Step 2: Provide Xcode

`Install-Xcode.ps1` downloads `<storage URL>Xcode-<version>.xip?<SAS>` for every Xcode version in the toolset and checks the SHA-256 sum from the toolset. `<version>` is the `version` field under `xcode.arm64.versions` in `images/macos/toolsets/toolset-*.json`, for example `Xcode-26.6+17F113.xip`.

Download the archives from [Apple Developer](https://developer.apple.com/download/all/?q=xcode) and rename them to that pattern. Then choose one option:

- `--xcode-dir DIR`: the script serves `DIR` over HTTP on the host side of the UTM shared network while the build runs
- `--xcode-url URL`: use your own server or storage. Put a query string such as a SAS token in `XCODE_INSTALL_SAS`

> [!TIP]
> To build faster or with less disk space, remove Xcode versions from the toolset before the build, but keep the one set as `xcode.default`. The tests in `images/macos/scripts/tests/Xcode.Tests.ps1` read the same toolset, so they stay consistent.

## Step 3: Build the image

```bash
export UTM_VM_PASSWORD='choose-a-password'
export GITHUB_API_PAT='<optional token, avoids GitHub API rate limits>'

./images/macos/utm/build-image.sh \
    --image macos-26-arm64 \
    --base-vm macos-26-base \
    --username runner \
    --xcode-dir ~/Downloads/xcode
```

The script:

1. Clones the base VM to `--name` (default `<image>-<timestamp>`)
2. Starts the clone and waits for its IP address and SSH
3. Runs `packer init` and `packer build` on the image template with `builder_type=null`
4. Shuts the VM down

The software report is written to `images/image-output/`. When the build fails, the clone is deleted; pass `--keep-on-failure` to keep it running for debugging. Pass `--export PATH.utm` to also export the finished VM as a `.utm` bundle, which you can copy to another Mac and open in UTM.

## Run the image

The finished VM appears in the UTM window. Start it there or from Terminal:

```bash
UTMCTL=/Applications/UTM.app/Contents/MacOS/utmctl
"$UTMCTL" start macos-26-arm64-202610271200
"$UTMCTL" ip-address macos-26-arm64-202610271200
ssh runner@<ip>
```

For a clean environment on every run, clone the image before each job and delete the clone afterwards, the same way `build-image.sh` treats the base VM:

```bash
"$UTMCTL" clone macos-26-arm64-202610271200 --name job-1
"$UTMCTL" start job-1
# ... run the job over SSH ...
"$UTMCTL" stop job-1 --request
"$UTMCTL" delete job-1
```

On a macOS 27 host, `utmctl start --disposable` runs the VM without saving changes to its disk, which avoids the clone.

To use the VM as a GitHub Actions runner, install the runner application in the guest as described in [Adding self-hosted runners](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/adding-self-hosted-runners).

> [!NOTE]
> Apple's macOS license allows at most two additional macOS VMs per Mac, for development and testing and similar purposes. Check the license terms before you run macOS VMs as shared CI infrastructure.

## Troubleshooting

- **`utmctl failed`**: start the script from Terminal in the GUI session and allow Terminal to control UTM in **System Settings > Privacy & Security > Automation**
- **No IP address**: the script reads it from `utmctl ip-address` and from `/var/db/dhcpd_leases`. Check that the VM network mode is **Shared Network** and that the guest finished booting
- **The guest cannot download Xcode from `--xcode-dir`**: the macOS firewall on the host may block `python3`. Allow incoming connections for it or use `--xcode-url`
- **`Xcode ... checksum mismatch`**: the archive is not the one from the toolset. Download the exact build named in the `version` field
- **`System Integrity Protection is enabled`**: repeat the recoveryOS step. Start the base VM with `utmctl start <name> --recovery`
