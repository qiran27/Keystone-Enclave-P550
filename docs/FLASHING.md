# USB flashing on HiFive Premier P550

## Two deliberately separate bundles

The root filesystem is the official SiFive 2025.11.00 Ubuntu 24.04 image. The
release-pinned URL, size and SHA-256 are stored in
`release-assets.lock.yml`.

Prepare an unmodified recovery/baseline bundle with:

```bash
./prepare-flash-assets.sh --baseline
```

This combines the validated official Ubuntu image and official bootloader. It
does **not** run Keystone.

A real Keystone bundle must use a newly built bootloader containing the
Keystone Security Monitor inside OpenSBI, plus the matching Linux driver and
userspace payload:

```bash
./prepare-flash-assets.sh \
  --keystone-bootloader artifacts/keystone/bootloader_ddr5_secboot.bin \
  --payload artifacts/keystone/keystone-p550-payload.tar.zst
```

The script refuses to substitute the official bootloader in Keystone mode.
The official binary is suitable only for baseline boot and recovery because
OpenSBI is part of that binary and does not contain the P550 Keystone SM.

## U-Boot commands

Copy all generated bundle files to the root of an ext4-formatted USB drive.
At the P550 U-Boot prompt, inspect the device and filenames first:

```text
usb stop
usb reset
ext4ls usb 0:1 /
```

Load and write the selected bootchain:

```text
ext4load usb 0:1 0x90000000 bootloader_ddr5_secboot.bin
echo $filesize
es_burn write 0x90000000 flash
```

Write the uncompressed official Ubuntu image to eMMC:

```text
es_fs write usb 0 ubuntu-24.04-preinstalled-server-riscv64.img mmc 0
```

Both `es_burn` and `es_fs` overwrite persistent storage. Confirm the USB
device, checksums, filenames and target board before running them. After a
Keystone-mode flash, boot Ubuntu and install the matching payload according
to the payload manifest; do not mix driver/SDK artifacts from another firmware
revision.

## Install the matching payload after first boot

Copy `keystone-p550-payload.tar.zst` from the USB drive to Ubuntu, then run:

```bash
mkdir -p ~/keystone-payload
tar --zstd -xf keystone-p550-payload.tar.zst -C ~/keystone-payload
~/keystone-payload/install-keystone-payload.sh
```

The installer places the module only under the running kernel's versioned
module directory, installs the userspace files without replacing Ubuntu's
merged-`/usr` `/lib` symlink, runs `depmod`, loads `keystone-driver`, and
requires `/dev/keystone_enclave` to appear. Continue with
`docs/VALIDATION.md`.
