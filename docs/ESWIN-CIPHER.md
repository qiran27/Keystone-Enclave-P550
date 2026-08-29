# ESWIN cipher acceleration on HiFive Premier P550

## Source and scope

The P550 Ubuntu 2025.11 image and its SiFive 6.12.33 kernel do not ship the
ESWIN SCPU mailbox/cipher driver. This project backports the relevant files
from ESWIN's official `linux-stable` branch `linux-6.6.18-EIC7X`, revision
`fc6038c00e006226e3bd504d2679c534eabf5503`, into the kernel revision already
locked by `sources.lock.yml`.

The integration adds:

- the ESWIN mailbox controller and its DT binding;
- the SCPU cipher character driver and official UAPI header;
- the P550 `mailbox@50a00000` and `ipc-scpu` device-tree nodes;
- SID/TBU setup through the helpers already present in the SiFive 6.12 tree;
- official ESWIN `es-sdk-common` and `es-sdk-cipher` 1.10.1ubuntu4 userspace
  files, pinned by SHA-256;
- the locked Keystone official VisionFive2 host driver, built in the same
  kernel tree so its `CONFIG_MODVERSIONS` CRCs match the replaced kernel.

The resulting device is `/dev/eswin_ipc_misc_dev0`. The kernel modules are
`eswin-mailbox.ko` and `es_cipher.ko`.

## Kernel compatibility changes

The original ESWIN driver depends on several helpers from ESWIN's complete
6.6 kernel. The P550 backport uses the equivalent interfaces in SiFive's
6.12.33 tree:

- `eic7700_aon_sid_cfg()` for stream-ID programming;
- `eic7700_tbu_power()` for the SCPU translation buffer;
- the fixed node ID `0` for this single-die P550 board, avoiding the vendor
  driver's dependency on the non-exported `cpuid_to_hartid_map()` symbol;
- regmap software spinlocks for local mailbox serialization.  ESWIN's source
  requests Linux `hwspinlock` ID 0, but the SiFive P550 kernel registers no
  hardware-spinlock provider, so the unadapted mailbox fails probe with
  `-ENXIO`.  The mailbox `WR_LOCK` register continues to arbitrate access with
  the SCPU; `fast_io` only replaces the unavailable local Linux lock and keeps
  interrupt-context accesses atomic;
- current 6.12 `dma_buf_attach()` and attachment mapping APIs;
- the 6.12 `void` platform-driver remove callback.

User-pointer IOVA mapping and externally supplied DMA-BUF mapping retain the
official ioctl ABI. The two vendor-private ioctls that allocate/free buffers
from ESWIN's separate reserved-memory heap return `-EOPNOTSUPP`, because that
heap is not part of the SiFive Ubuntu memory layout. Normal `libes_cipher`
operations use the supported user-pointer path and do not require replacing
the complete Ubuntu memory subsystem.

## Build and validation

Prepare the ordinary Keystone bundle first, then run:

```bash
./scripts/build-eswin-cipher-image.sh --force
```

The script refuses a kernel release other than `6.12.33-1-premier`, modifies a
copy rather than the downloaded base image, preserves Ubuntu's merged `/usr`
layout, installs the matching Keystone module, runs `depmod`, and writes
`artifacts/eswin-cipher/SHA256SUMS`.

Validate the completed image offline before flashing:

```bash
sudo ./scripts/validate-eswin-cipher-image.sh
```

After flashing and booting the P550:

```bash
./scripts/validate-eswin-cipher-on-board.sh
```

An OpenSSL 3 provider linked to the official ESWIN Cipher SDK can then exercise
the actual SCPU path.  For the `enc_24` test tree used during this port:

```bash
cd ~/enc_24
export OPENSSL_MODULES="$PWD/build-riscv-native"
sudo --preserve-env=OPENSSL_MODULES \
  ./build-riscv-native/enc_hw_speed aes
```

The hardware program must report `provider: eswinprov`, `backend: hardware`
and exit successfully.  Merely loading the provider is not treated as proof of
hardware acceleration.

Successful compilation and image inspection prove build-time integration.
Actual cipher operations still require this final hardware boot validation.
