# P550 Keystone hardware validation

The generated firmware is not considered enclave-capable merely because it
compiles. Keep the official recovery bootloader available and record the full
UART log while applying these gates.

## 1. Firmware gate

During the build, `build-keystone-bootchain.sh` verifies the SM marker in the
deployed `fw_payload`/`fw_dynamic` OpenSBI image.  The final
`bootloader_ddr5_secboot.bin` has already passed through the P550 `nsign`
wrapper, so a direct `strings` search of that file is not a reliable build
gate.

The UART log must contain the line below and must continue into U-Boot and
Linux without an SM hang or PMP exception:

```text
[SM] Keystone security monitor has been initialized!
```

The P550 port has eight PMP entries. Its expected allocation is SM at the
highest priority, Linux as the lowest-priority catch-all, the vendor low/high
protected holes in between, and the remaining entries available to an enclave.
Any PMP access fault during normal boot is a port failure, not a Linux issue.

## 2. Driver gate

Install the payload produced on this exact board/kernel, then run:

```bash
uname -a
modinfo keystone-driver
sudo modprobe keystone-driver
ls -l /dev/keystone_enclave
dmesg | tail -n 100
```

The device must be a character device and the kernel log must not show an SBI,
page-table, PMP or module-version failure.

## 3. Enclave gate

From a checkout of this project on the board:

```bash
./scripts/validate-keystone-on-board.sh
```

This verifies `/dev/keystone_enclave`, runs `hello.ke` and `hello-native.ke` on
all four CPUs, verifies the test attestation signature, enclave/SM
measurements and nonce, and runs all nine programs in `tests.ke`. Every command
is available directly under `/usr/share/keystone/examples/`.

The default release gate runs the official packages without adding timing
changes. A maintainer may request additional sequential cross-CPU `hello.ke`
runs as a separate robustness diagnostic:

```bash
P550_VALIDATE_RUNS=1000 ./scripts/validate-keystone-on-board.sh
```

The 2026-08-23 candidate completed 1000 such create/run/destroy cycles on the
four-hart P550. The OpenSBI port uses per-hart PMP queues and, after 10 ms
without acknowledgement, reasserts the EIC7700 machine-software interrupt for
only the destination harts whose PMP queues remain non-empty. A rate-limited
UART marker identifies use of this recovery path:

```text
[KS-P550-PMP-IPI-RETRY]
```

The default repeat count remains zero, and the SDK resume loop contains no
artificial sleep or yield. Thus the normal validation path keeps the official
example behavior; the 10 ms threshold belongs only to the P550 firmware's lost
IPI recovery path.

The validator rejects pre-existing or newly generated EIC7700 bus errors,
watchdog lockups, RCU stalls, invalid enclave IDs, PMP exhaustion and SBI trap
failures. Run it only after a clean reboot; an earlier failed experimental
boot can leave stale failures in `dmesg` and must not be counted as a new
release result. Do not use four simultaneous enclave creators as a stability
test: the P550 has only eight PMP entries and that workload exhausts the
platform's fixed PMP-region budget before it tests normal enclave execution.

After every automated gate passes, the validator writes
`artifacts/keystone/hardware-validation.txt`. That record includes the exact
kernel, CPU/optional-run count and hashes of the paired bootloader, SM reference
and payload. The GitHub Release script refuses artifacts that do not match it.

## 4. Security boundary

This integration packages and exercises the official attestation example, but
uses Keystone's published test device key and a cycle-counter-derived test
random function. A valid report proves only that the test-key path and the
packaged immutable OpenSBI measurement agree. It is not a production identity
or security claim. A P550 root of trust, entropy source, provisioning process
and measurement policy still require implementation and review.

## 5. Release record

For each published release, record the board, Ubuntu/kernel version, UART SM
initialization line, validator output and SHA-256 values for all three paired
artifacts:

```text
bootloader_ddr5_secboot.bin
fw_payload.bin
keystone-p550-payload.tar.zst
```

Do not carry hashes forward from an earlier diagnostic bootchain. The release
scripts regenerate `SHA256SUMS` from the exact locally validated files.
