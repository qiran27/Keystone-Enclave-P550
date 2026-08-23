# P550 Keystone porting plan

## Why this is a system port

Keystone is not a normal Linux package. Its Security Monitor (SM) executes in
machine mode inside OpenSBI; Linux uses a kernel module to call its SBI
extension; the SDK/runtime/examples must use the same ABI. A root filesystem
containing only the driver and examples is therefore not a Keystone system.

The official P550 release also requires a matching bootchain. For that reason
the base is SiFive Freedom-U-SDK 2025.11.00-HFP550, OpenSBI 1.6 plus SiFive's
seven EIC7700 patches, U-Boot EIC7X-2025.01, and Linux 6.12.33.

## What can be reused from VisionFive 2

The `vf2-support` commit is valuable as an integration map:

1. add a board identity to Keystone;
2. compile the SM into the board's OpenSBI;
3. call `sm_init()` during OpenSBI final initialization;
4. define SM memory, PMP count, hart count and platform hooks;
5. build/install the kernel driver, SDK, runtime and examples;
6. create a bootable image and test an enclave on hardware.

Its constants and patches cannot be copied verbatim. VisionFive 2 uses a
different SoC, five harts in that port and a different OpenSBI integration.

## Milestone 0: official Ubuntu baseline

- Download the checksum-pinned official Ubuntu image and recovery bootloader.
- Prepare them with `./prepare-flash-assets.sh --baseline`.
- Boot and capture OpenSBI, U-Boot and Linux UART logs.
- Confirm the image uses Linux 6.12.33 and the 2025.11.00 bootchain.

This milestone separates board/build failures from Keystone failures.

## Milestone 1: Security Monitor in OpenSBI (implemented)

Extend `opensbi-sifive-hf-prem_1.6.bbappend` with the pinned Keystone source
and small, reviewable P550 patches:

- extend `platform/eswin/eic770x/objects.mk` with Keystone SM objects and its
  shared ABI include path;
- call `sm_init(cold_boot)` from `eic770x_final_init()` without removing the
  vendor's FDT fixups, reset handling or CSR setup;
- adapt the VF2 ecall and enclave-trap paths to OpenSBI 1.6's return object and
  full `sbi_trap_context`, and use the current `stval` supervisor CSR name;
- replace the removed VF2 TLB-callback workaround with a dedicated OpenSBI 1.6
  IPI event that synchronizes PMP updates across all interruptible P550 harts;
- queue PMP broadcasts independently per hart and reassert the EIC7700
  machine-software interrupt only when a destination still has queued PMP work
  after 10 ms without acknowledgement.

The integration now builds SM sources from VF2 commit
`c5f7ac3977f50309ac816b54f470c4021573bf5e`, calls `sm_init(cold_boot)` and
defines a four-hart/eight-entry-PMP platform. Keystone recreates both protected
address holes from the vendor OpenSBI patch after its PMP reset. Verify on
hardware:

- implemented and unlocked architectural PMP entries on every hart;
- the firmware-reserved interval (the official payload offset suggests
  `0x80000000..0x80200000`, but it must be checked against the shipped memory
  map and boot logs);
- four application harts and whether hart IDs are contiguous;
- a real entropy/attestation-key source.

The generic/VF2 pseudo-random fallback and published test root key are
test-only and must not be presented as production attestation. The P550 test
attestation hashes OpenSBI's immutable RX range; writable data/BSS cannot be
compared to `fw_payload.bin` after OpenSBI has started executing.

Special care is required around SiFive patch
`0005-lib-sbi-eic770x-Add-PMP-for-TOR-region.patch`: it changes OpenSBI's root
domain PMP programming. Keystone must reserve its own entries without the
OpenSBI domain setup later overwriting them. The test gate is an OpenSBI boot,
successful probe of SBI extension `0x08424b45`, and a PMP dump on all harts.

## Milestone 2: Linux 6.12 driver (implemented)

- Build the VF2 `linux-keystone-driver` as an out-of-tree module against the
  exact kernel reported by the official image's `uname -r`.
- Port any kernel API changes after the last upstream-tested kernel version.
- Enable required RISC-V, memory-management and module options via a kernel
  config fragment.
- Install the module and a modules-load entry only after it builds cleanly.

The gate is creation of `/dev/keystone_enclave` and a successful minimal SBI
ioctl path, with kernel lockdep/KASAN warnings absent where those diagnostics
are practical.

## Milestone 3: SDK, runtime and examples payload (implemented)

- Build the SDK natively on P550 using private compiler-name wrappers required
  by the VF2 CMake files, without modifying their source.
- Build the Eyrie runtime and all official hello, hello-native, attestation and
  tests packages from the same pinned VF2 source.
- Preserve the official `test-fib-bench` `rdcycle` behavior by enabling
  `scounteren.CY` only in the saved enclave context; restore the host value on
  exit because the vendor Ubuntu kernel intentionally disables user access.
- Package the driver, host launcher, runtime and `.ke` artifacts as one
  versioned payload for installation onto the official Ubuntu image.
- Run both hello examples on every hart, validate a test-key report, execute
  all nine tests, with repeated create/run/destroy testing available as a
  separate diagnostic rather than a release gate.

## Milestone 4: security and deployment

- Replace test keys and pseudo-randomness with a documented device root of
  trust and entropy source.
- Define the firmware measurement and image-signing procedure.
- Test cold boot, warm reboot, multi-hart concurrency, memory pressure and
  negative PMP access cases.
- Retain the 1000-cycle sequential cross-hart regression test and capture any
  `[KS-P550-PMP-IPI-RETRY]` UART marker for each release candidate.
- Produce the final official-Ubuntu/custom-bootchain bundle together with the
  matching payload, checksums, source lock and UART validation log.
