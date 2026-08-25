#!/usr/bin/env bash
set -euo pipefail

expected_kernel="6.12.33-1-premier"

if [[ "$(uname -m)" != "riscv64" ]]; then
  echo "This validation script must run on the P550 board." >&2
  exit 2
fi
if [[ "$(uname -r)" != "${expected_kernel}" ]]; then
  echo "Wrong running kernel: $(uname -r), expected ${expected_kernel}" >&2
  exit 2
fi

for module_name in eswin-mailbox es_cipher keystone-driver; do
  if ! lsmod | awk '{print $1}' | grep -qx "${module_name//-/_}"; then
    echo "Module is not loaded: ${module_name}" >&2
    exit 3
  fi
done

[[ -c /dev/eswin_ipc_misc_dev0 ]] || {
  echo "ESWIN cipher character device is missing." >&2
  exit 3
}
[[ -c /dev/keystone_enclave ]] || {
  echo "Keystone character device is missing." >&2
  exit 3
}
[[ -r /usr/lib/libes_cipher.so.1.0 ]] || {
  echo "ESWIN cipher userspace library is missing." >&2
  exit 3
}

echo "PASS: kernel ${expected_kernel}"
echo "PASS: ESWIN mailbox/cipher modules and /dev/eswin_ipc_misc_dev0"
echo "PASS: Keystone driver and /dev/keystone_enclave"
echo "Hardware cryptographic operations can now be tested through libes_cipher."
