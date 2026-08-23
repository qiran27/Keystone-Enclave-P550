#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -m)" != "riscv64" ]]; then
  echo "Run this check on the P550 board." >&2
  exit 2
fi

echo "Architecture: $(uname -m)"
echo "Kernel:       $(uname -r)"
sudo modprobe keystone-driver
test -c /dev/keystone_enclave
echo "PASS: /dev/keystone_enclave is a character device"

example_dir=/usr/share/keystone/examples
hello="${example_dir}/hello.ke"
hello_native="${example_dir}/hello-native.ke"
attestor="${example_dir}/attestor.ke"
tests_package="${example_dir}/tests.ke"
validation_runs="${P550_VALIDATE_RUNS:-0}"
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
artifact_dir="${project_dir}/artifacts/keystone"
validation_record="${artifact_dir}/hardware-validation.txt"
failure_pattern='bus error of cause event|watchdog detected|hard LOCKUP|soft lockup|rcu_preempt detected stalls|invalid enclave id|sbi_trap_error|Unable to handle kernel|kernel BUG|Oops:|maximum number of PMP regions|SBI call failed with error code 100003|cannot destroy enclave: SBI failed with error code 100005'
log_dir="$(mktemp -d)"
trap 'rm -rf -- "${log_dir}"' EXIT

for example in "${hello}" "${hello_native}" "${attestor}" "${tests_package}"; do
  if [[ ! -x "${example}" ]]; then
    echo "Missing executable example: ${example}" >&2
    exit 3
  fi
done
if [[ ! "${validation_runs}" =~ ^[0-9]+$ ]]; then
  echo "P550_VALIDATE_RUNS must be a non-negative integer." >&2
  exit 4
fi

initial_failures="$(sudo dmesg | grep -Eic "${failure_pattern}" || true)"
if (( initial_failures != 0 )); then
  echo "Kernel log already contains ${initial_failures} Keystone/P550 failure events." >&2
  sudo dmesg | grep -Ei "${failure_pattern}" | tail -n 40 >&2
  exit 5
fi

cpu_count="$(nproc)"
for ((cpu = 0; cpu < cpu_count; cpu++)); do
  for example in "${hello}" "${hello_native}"; do
    name="$(basename "${example}")"
    echo "Running ${name} on CPU ${cpu}"
    sudo timeout 20s taskset -c "${cpu}" "${example}" > \
      "${log_dir}/${name}.${cpu}.log" 2>&1 || {
        cat "${log_dir}/${name}.${cpu}.log" >&2
        exit 6
      }
  done
done
echo "PASS: hello and hello-native succeeded on all ${cpu_count} CPUs"

echo "Running official attestation example (test key only)"
sudo timeout 60s "${attestor}" > "${log_dir}/attestor.log" 2>&1 || {
  cat "${log_dir}/attestor.log" >&2
  exit 7
}
for expected in \
  'Attestation report SIGNATURE is valid' \
  'Enclave and SM hashes match with expected.' \
  'Returned data in the report match with the nonce sent.'; do
  if ! grep -Fq "${expected}" "${log_dir}/attestor.log"; then
    echo "Attestation output is missing: ${expected}" >&2
    cat "${log_dir}/attestor.log" >&2
    exit 7
  fi
done
if grep -Eiq 'invalid|do NOT|does not match|\[FAIL\]' \
     "${log_dir}/attestor.log"; then
  echo "Attestation example reported a verification failure." >&2
  cat "${log_dir}/attestor.log" >&2
  exit 7
fi
echo "PASS: attestation signature, SM/enclave measurements and nonce"

echo "Running the complete official tests package"
sudo timeout 180s "${tests_package}" > "${log_dir}/tests.log" 2>&1 || {
  cat "${log_dir}/tests.log" >&2
  exit 7
}
for test_name in \
  test-stack test-loop test-malloc test-long-nop test-fibonacci \
  test-fib-bench test-attestation test-untrusted test-data-sealing; do
  if ! grep -Fq "testing ${test_name}" "${log_dir}/tests.log"; then
    echo "Official tests package did not run ${test_name}." >&2
    cat "${log_dir}/tests.log" >&2
    exit 7
  fi
done
if grep -Eiq '\[FAIL\]|Attestation report is invalid|error' \
     "${log_dir}/tests.log"; then
  echo "Official tests package reported a failure." >&2
  cat "${log_dir}/tests.log" >&2
  exit 7
fi
echo "PASS: all nine tests in tests.ke completed without a reported failure"

if (( validation_runs > 0 )); then
  for ((iteration = 1; iteration <= validation_runs; iteration++)); do
    cpu=$((iteration % cpu_count))
    if (( iteration == 1 || iteration % 10 == 0 )); then
      echo "Optional repeat progress: ${iteration}/${validation_runs} (CPU ${cpu})"
    fi
    sudo timeout 20s taskset -c "${cpu}" "${hello}" > \
      "${log_dir}/repeat.log" 2>&1 || {
        echo "hello.ke failed at iteration ${iteration} on CPU ${cpu}." >&2
        cat "${log_dir}/repeat.log" >&2
        exit 8
      }
  done
  echo "PASS: hello.ke completed ${validation_runs} optional cross-CPU repeated runs"
else
  echo "INFO: optional repeated-run diagnostic is disabled"
fi

final_failures="$(sudo dmesg | grep -Eic "${failure_pattern}" || true)"
if (( final_failures != 0 )); then
  echo "Kernel log contains ${final_failures} Keystone/P550 failure events." >&2
  sudo dmesg | grep -Ei "${failure_pattern}" | tail -n 40 >&2
  exit 9
fi
echo "PASS: no bus error, watchdog, RCU-stall, invalid-EID or SBI-trap event"

paired_artifacts=(
  bootloader_ddr5_secboot.bin
  fw_payload.bin
  keystone-p550-payload.tar.zst
)
for artifact in "${paired_artifacts[@]}"; do
  if [[ ! -s "${artifact_dir}/${artifact}" ]]; then
    echo "Validated runtime, but cannot record the release pair: missing ${artifact_dir}/${artifact}" >&2
    exit 10
  fi
done

mkdir -p "${artifact_dir}"
cat > "${validation_record}" <<EOF
status=pass
board=hifive-premier-p550
architecture=$(uname -m)
kernel=$(uname -r)
cpus=${cpu_count}
repeated_runs=${validation_runs}
validated_at=$(date --iso-8601=seconds)
bootloader_sha256=$(sha256sum "${artifact_dir}/bootloader_ddr5_secboot.bin" | awk '{print $1}')
fw_payload_sha256=$(sha256sum "${artifact_dir}/fw_payload.bin" | awk '{print $1}')
payload_sha256=$(sha256sum "${artifact_dir}/keystone-p550-payload.tar.zst" | awk '{print $1}')
attestation=signature-measurements-and-nonce-pass-test-key-only
kernel_log=no-matched-failure-events
EOF
echo "Hardware validation record: ${validation_record}"

echo "Check the UART boot log separately for:"
echo "  [SM] Keystone security monitor has been initialized!"
