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

Authenticate the GitHub CLI on the build machine, then run:

```bash
gh auth login
./publish-release-assets.sh p550-keystone-YYYY.MM.DD
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

## 4. What another user needs

An end user does not rebuild the payload on a P550. They clone the source
repository, download the matching GitHub Release assets, obtain the official
Ubuntu image, copy the flash bundle to ext4 USB, flash the custom bootloader
and Ubuntu image, then install the published payload. A payload is valid only
for the kernel recorded in its `PAYLOAD-MANIFEST.txt`.
