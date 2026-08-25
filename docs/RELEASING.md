# Publishing the P550 Keystone project

The source repository and the hardware artifacts are deliberately published
separately. A normal Git clone must stay small and reproducible; generated
firmware and the matching board-built payload belong in a GitHub Release.

## 1. Source repository

Run on the Ubuntu build machine after reviewing local changes:

```bash
cd ~/keystone-p550-system
./scripts/check-project.sh
./publish-github.sh prepare
git diff --cached --stat
git diff --cached
```

The preparation command uses an allowlist. It includes the metadata layer,
lock files, documentation and scripts. It excludes source clones, build state,
downloads, virtual environments, logs, flash bundles and `artifacts/`.

Create an empty GitHub repository, then publish without force-pushing:

```bash
./publish-github.sh publish \
  https://github.com/USER/keystone-p550-system.git main
```

The script asks for the literal confirmation `yes`, creates a commit only when
there are staged changes, and refuses to replace an existing different
`origin` URL.

## 2. Hardware validation record

Flash the exact candidate bootloader, install its matching payload, reboot to
a clean kernel log and run on the P550:

```bash
cd ~/keystone-p550-system
./scripts/validate-keystone-on-board.sh
```

The release gate covers all four CPUs, attestation and all nine official test
programs. `P550_VALIDATE_RUNS=N` enables an optional repeated-run diagnostic;
it is disabled by default so the normal gate retains the official examples'
behavior and duration. The validated 2026-08-23 candidate used 1000 sequential
cross-CPU runs in addition to the default gate.

A complete pass writes:

```text
artifacts/keystone/hardware-validation.txt
```

The record binds the board/kernel test result to SHA-256 values for the
bootloader, `fw_payload.bin` and payload archive. Copy it back to the build
machine together with any artifact rebuilt on the P550.

## 3. GitHub Release

Authenticate the GitHub CLI on the build machine. To publish the validated
Keystone bootchain and payload, run:

```bash
gh auth login
./publish-release-assets.sh keystone p550-keystone-YYYY.MM.DD
```

The release script refuses to publish if the three artifact hashes differ
from `hardware-validation.txt`, or if the tag already exists. It uploads:

```text
bootloader_ddr5_secboot.bin
fw_payload.bin
bootchain-manifest.txt
keystone-p550-payload.tar.zst
keystone-p550-payload.tar.zst.sha256
hardware-validation.txt
SHA256SUMS
```

Do not upload the official multi-gigabyte Ubuntu image. End users obtain the
pinned image directly from SiFive with `./fetch-release-assets.sh all`.

### Integrated Keystone + ESWIN cipher image

After `scripts/build-eswin-cipher-image.sh` and both offline/on-board
validators pass, publish the integrated image under a separate tag:

```bash
./publish-release-assets.sh eswin p550-keystone-eswin-cipher-YYYY.MM.DD
```

This mode verifies `artifacts/eswin-cipher/SHA256SUMS`, xz-compresses the raw
image and enforces GitHub's per-asset size limit. A compressed image that is
not below 2 GiB is split into 1900 MiB `.part-*` files. The Release contains
`DOWNLOAD-SHA256SUMS` for the downloaded/compressed assets and the original
`SHA256SUMS` for the reconstructed raw image. An optional
`eswin-cipher-speed-results.csv` in the artifact directory is published with
the same Release. The script creates a draft first and can resume it after a
network failure by skipping already uploaded assets with matching sizes.

When the Windows host already provides a local proxy on `127.0.0.1:7890`, a
build VM using VMware NAT will not inherit it. Forward it explicitly from a
Windows terminal:

```bash
ssh -N -R 17890:127.0.0.1:7890 BUILD_USER@BUILD_VM
```

Keep the tunnel open and set `HTTPS_PROXY=http://127.0.0.1:17890` in the VM
only for the Release command. This avoids exposing the proxy to the LAN.

## 4. What another user needs

An end user does not rebuild the payload on a P550. For the original Keystone
Release, they clone the source repository, download the matching Release
assets, obtain the official Ubuntu image, flash the custom bootloader and
image, then install the published payload. For an integrated ESWIN Release,
they verify the download checksums, concatenate any `.part-*` files, decompress
the image, verify the raw-image checksums and flash it directly. The integrated
image already contains its matching Keystone payload and cipher modules.
