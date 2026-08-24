# Keystone on HiFive Premier P550

This project ports Keystone Enclave to the SiFive HiFive Premier P550 while
reusing SiFive's prebuilt Ubuntu 24.04 root filesystem. It does not rebuild a
large Yocto demo image.

The complete Chinese porting report, including the main failures encountered
and their fixes, is available in [`PORTING-REPORT.md`](PORTING-REPORT.md).

## Architecture

The hybrid system has three independently versioned parts:

1. **Official prebuilt Ubuntu image** — normal userspace, packages, services
   and the base P550 operating system.
2. **P550 bootchain** — DDR/second-stage firmware, U-Boot and OpenSBI. A real
   Keystone build must embed the P550 Security Monitor in OpenSBI.
3. **Matching Keystone payload** — Linux driver, SDK, Eyrie runtime and enclave
   test programs built from the pinned Keystone revision.

Only parts 2 and 3 require source compilation. The official Ubuntu image and
recovery bootloader are pinned in `release-assets.lock.yml`; source revisions
are pinned in `sources.lock.yml`.

## Workflow at a glance

| Role | Machine | Required work | Result |
| --- | --- | --- | --- |
| Bootchain maintainer | x86_64 Ubuntu build VM | Build the small kas `bootchain` target | custom signed bootloader and `fw_payload.bin` |
| Payload maintainer | one P550 running the pinned Ubuntu/kernel | Build driver, SDK, runtime and examples once | matching payload archive |
| End user | P550 plus any download machine | Download the published pair, flash and install | ready-to-run Keystone Ubuntu system |

The end user does **not** compile the payload on their P550. Native payload
building is a release-maintainer step needed only when the kernel or pinned
Keystone sources change.

## Current status and security boundary

The repository currently provides:

- verified 2025.11.00 Ubuntu and recovery-bootloader downloads;
- a bootchain-only kas/Yocto target, replacing the former full image build;
- safe baseline and future Keystone bundle preparation;
- the pinned P550, OpenSBI, Linux and Keystone sources;
- the staged porting and hardware-validation plan in `docs/PORTING.md`.

The P550 bootchain target compiles the SM from the pinned VF2 branch into the
vendor EIC770x OpenSBI. Hardware validation uses the four official packages
`hello.ke`, `hello-native.ke`, `attestor.ke` and `tests.ke` on all four harts.
The validated candidate also completed 1000 sequential cross-hart
create/run/destroy cycles without a matched firmware or kernel failure. See
`docs/VALIDATION.md` for the exact gates and capacity limits.

This is an enclave-capable development release, not a production
attestation/security certification. The attestation path is deliberately
enabled with Keystone's published test device key and a test random source so
the report/signature/measurement flow can be exercised. It provides no unique
P550 device identity and must not be used as a production root of trust.

The functional gate passes with the upstream SDK interrupt/resume behavior and
without a userspace scheduling delay. The P550 OpenSBI adaptation queues PMP
updates per hart and reasserts an EIC7700 machine-software interrupt when a
queued PMP update has not been acknowledged for 10 ms. This is a platform IPI
delivery recovery path, not a delay in the enclave SDK. The 2026-08-23 hardware
candidate passed 1000 sequential cross-CPU runs after this change. Production
security certification and workloads that exceed the fixed PMP-region capacity
remain outside the claim of this development release.

## Recover space from the old full-image build

If an earlier checkout filled the disk while compiling `demo-coreip-cli`, stop
the build and preview the cleanup:

```bash
cd ~/keystone-p550-system
./scripts/clean-yocto-state.sh
```

Delete only the obsolete generated state after reviewing the output:

```bash
./scripts/clean-yocto-state.sh --apply
df -h .
```

This removes `build/`, `sstate-cache/`, `downloads/`, `build.log` and
`fetch.log`. It preserves `sources/`, `.venv/`, project files and
`release-cache/`. See `docs/STORAGE.md`.

## Host setup

Use Ubuntu 22.04 or 24.04 on an ext4 filesystem:

```bash
./scripts/install-ubuntu-deps.sh
```

Fetch the official prebuilt Ubuntu image and recovery bootloader:

```bash
./fetch-release-assets.sh all
```

They are stored under:

```text
release-cache/2025.11.00-HFP550/
```

Fetch and verify pinned source repositories only when building or developing
the bootchain/Keystone port:

```bash
./fetch-sources.sh
./scripts/verify-sources.sh
```

## Build the Keystone bootchain

The kas configuration now targets only `bootchain`:

```bash
set -o pipefail
./scripts/build-keystone-bootchain.sh 2>&1 | tee build.log
```

It no longer builds `demo-coreip-cli`, XFCE, TensorFlow, OpenCV, Rust, Boost or
a root filesystem. The result is:

```text
artifacts/keystone/bootloader_ddr5_secboot.bin
artifacts/keystone/fw_payload.bin
artifacts/keystone/bootchain-manifest.txt
```

The SM, SDK ABI headers and all later payload components are pinned to VF2
commit `c5f7ac3977f50309ac816b54f470c4021573bf5e`.

## Build the matching payload on the P550

First boot the board with the official Ubuntu image and baseline bootloader.
Clone this project on that board, fetch the locked sources, then build against
the exact running vendor kernel:

```bash
./scripts/fetch-keystone-vf2.sh
./scripts/build-keystone-payload-on-board.sh --install-deps
```

This produces `artifacts/keystone/keystone-p550-payload.tar.zst`. Its driver,
SDK, Eyrie runtime and all four official example packages come from the same
pinned `keystone-vf2` commit. If the official image does not provide headers
matching `uname -r`, the script stops instead of building an unsafe module.
The adjacent `.sha256` file records only the payload filename, so it remains
valid after both files are copied from the P550 to another build machine.
The disposable SDK build copy receives the reviewable
`scripts/patches/keystone-vf2-sdk-stdint.patch`, which makes the VF2 shared ABI
header self-contained for the Ubuntu 24.04 GCC 13 C++ compiler; the locked
component checkout itself remains unchanged.
It also receives
`scripts/patches/keystone-vf2-sdk-eyrie-cmake-flags.patch`, which passes the
freestanding compiler flags to Eyrie's nested CMake build as one CMake cache
value without embedding literal quote characters.
`scripts/patches/keystone-vf2-sdk-eyrie-nopie.patch` makes Eyrie's loader and
runtime non-PIE and disables the GNU build-ID note. The payload builder rejects
a GOT-based loader, a runtime containing `.note.gnu.build-id`, or a runtime
whose ELF entry does not equal its first load address; each condition caused a
real P550 entry fault during porting.
The examples build copy also receives
`scripts/patches/keystone-vf2-examples-native-gcc.patch`; Ubuntu's default
stack protector and PIE are disabled for freestanding enclave/Eyrie binaries,
and `hello-native` gets an explicit `main` ELF entry point.
`scripts/patches/keystone-vf2-examples-p550.patch` gives attestation the same
explicit entry, passes a P550-specific 1 MiB free-EPM argument from the package
launch scripts without changing the official runners' 48 MiB defaults, and
makes the test attestor measure the immutable OpenSBI RX range used by the
P550 SM.
The host SDK retains the official Keystone behavior after an enclave timer
interrupt: it immediately issues `RESUME` without an artificial sleep. Timer
delivery correctness is handled in the OpenSBI/SM context-switch path; a
userspace delay would add latency and could conceal a firmware bug.
P550 Ubuntu disables `rdcycle` for normal userspace. The SM therefore enables
only `scounteren.CY` in the separately saved enclave context so the unmodified
official `test-fib-bench` can run, then restores Linux's original counter
policy on every exit.

Building the payload on a P550 is a release-maintainer step, not a requirement
for every end user. Once the resulting payload is published, another P550
running the exact kernel named in `PAYLOAD-MANIFEST.txt` can install that
archive directly. Rebuild on-board only after changing the Keystone sources or
when the target board's `uname -r` differs.

### P550 without Internet access

The board does not need a permanent network connection. Generate an exact
offline dependency request **on the P550** using its installed-package state
and cached Ubuntu indexes:

```bash
cd ~/keystone-p550-system
./scripts/create-p550-offline-deps-request.sh
```

Copy `artifacts/offline-deps/p550-offline-deps-request.tar.gz` to the
**networked Ubuntu build VM**, then run there:

```bash
cd ~/keystone-p550-system
./scripts/download-p550-offline-deps.sh \
  /path/to/p550-offline-deps-request.tar.gz
```

For Ubuntu ports packages, the downloader uses the official Ubuntu archive
snapshot `20251115T000000Z`, matching the 2025.11 P550 image package state;
this avoids 404 responses for binaries later superseded in the live archive.
It retries the live archive only if the snapshot lookup fails. Override the
date only when deliberately targeting another board-image package state, for
example `P550_UBUNTU_SNAPSHOT=YYYYMMDDTHHMMSSZ`.

Copy the resulting
`artifacts/offline-deps/p550-offline-deps-bundle.tar.gz` back to the **P550**
and install it without contacting any package mirror:

```bash
cd ~/keystone-p550-system
./scripts/install-p550-offline-deps.sh \
  /path/to/p550-offline-deps-bundle.tar.gz
./scripts/build-keystone-payload-on-board.sh
```

Do not use `--install-deps` in the last command: that option invokes online
`apt-get update`. The request must be created on the P550, not on the x86_64
VM, so apt selects the correct `riscv64` packages and only dependencies missing
from that exact board image.

If a payload build fails after SDK or driver compilation, fix or update the
project files and continue the existing build tree instead of recompiling
everything:

```bash
set -o pipefail
./scripts/build-keystone-payload-on-board.sh --resume 2>&1 | \
  tee -a build-payload.log
```

`--resume` accepts an existing build tree only. It reuses a complete SDK only
when its recorded source/compatibility-patch fingerprint still matches; an
older or differently patched SDK is rebuilt automatically. It reuses the
kernel module and regenerates only the examples top-level CMake cache before
continuing. Omit `--resume` whenever a clean build is required.

## Baseline and Keystone bundles

Prepare a stock recovery/baseline USB bundle:

```bash
./prepare-flash-assets.sh --baseline
```

After the SM port and payload pass their validation gates, prepare the actual
Keystone bundle with explicit matching artifacts:

```bash
./prepare-flash-assets.sh \
  --keystone-bootloader artifacts/keystone/bootloader_ddr5_secboot.bin \
  --payload artifacts/keystone/keystone-p550-payload.tar.zst
```

`fw_payload.bin` and `bootchain-manifest.txt` must be beside the supplied
bootloader. The bundle script includes them automatically so the attestation
reference cannot be separated from the bootchain that produced it.

The USB flashing commands are in `docs/FLASHING.md`.

After booting the custom firmware, unpack and install the payload:

```bash
mkdir -p ~/keystone-payload
tar --zstd -xf keystone-p550-payload.tar.zst -C ~/keystone-payload
~/keystone-payload/install-keystone-payload.sh
./scripts/validate-keystone-on-board.sh
```

The installed official packages are directly runnable from:

```bash
cd /usr/share/keystone/examples
sudo ./hello.ke
sudo ./hello-native.ke
sudo ./attestor.ke
sudo ./tests.ke
```

The required UART and Linux checks are listed in `docs/VALIDATION.md`.

Record the release hashes only after `validate-keystone-on-board.sh` completes
on the exact bootchain/payload pair. They are also generated as `SHA256SUMS`
by the GitHub Release script:

```text
sha256sum artifacts/keystone/bootloader_ddr5_secboot.bin
sha256sum artifacts/keystone/fw_payload.bin
sha256sum artifacts/keystone/keystone-p550-payload.tar.zst
```

Generated binaries remain Git-ignored. Publish these three files, their
manifests/checksums, and the official Ubuntu image URL as GitHub Release assets;
do not commit multi-gigabyte images or build directories into the source tree.

## Why the official bootloader is not the final Keystone bootloader

`bootloader_ddr5_secboot.bin` contains OpenSBI. Keystone's Security Monitor
runs in machine mode as part of OpenSBI, so copying only a kernel module and
userspace binaries onto stock Ubuntu cannot create a Keystone TEE. The official
bootloader is retained strictly as a known-good recovery/baseline asset.

## Repository contents and GitHub publishing

Commit the integration files, not source clones or generated data:

```text
.gitattributes
.gitignore
README.md
PORTING-REPORT.md
sources.lock.yml
release-assets.lock.yml
docs/
kas/
meta-keystone-p550/
scripts/
fetch-sources.sh
fetch-release-assets.sh
prepare-flash-assets.sh
publish-github.sh
publish-release-assets.sh
sources/.gitkeep
```

The following stay local and ignored:

```text
.venv/
sources/*
build/
downloads/
sstate-cache/
release-cache/
artifacts/
flash/
*.log
```

Prepare and review the allowlist before publishing:

```bash
./scripts/check-project.sh
./publish-github.sh prepare
git diff --cached
```

Publish to an empty GitHub repository without force-pushing:

```bash
./publish-github.sh publish \
  https://github.com/USER/keystone-p550-system.git main
```

After the source commit is published and the validated files exist under
`artifacts/keystone/`, upload the small hardware deliverables to a new GitHub
Release (requires an authenticated GitHub CLI):

```bash
./publish-release-assets.sh p550-keystone-2026.08.22
```

The release script requires the successful board-generated
`hardware-validation.txt`, verifies that its hashes still match, regenerates
`artifacts/keystone/SHA256SUMS`, refuses to replace an existing release, and
uploads only the bootchain, payload and manifests. It does not upload the
official Ubuntu image; end users obtain that pinned image from SiFive through
`./fetch-release-assets.sh all`. The complete maintainer checklist is in
`docs/RELEASING.md`.

## Author

- Name: wuju
- Email: 2813480370@qq.com
