#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
artifact_dir="${project_dir}/artifacts/keystone"
deploy_dir="${project_dir}/build/tmp/deploy/images/hifive-premier-p550"
vf2_revision="c5f7ac3977f50309ac816b54f470c4021573bf5e"

cd "${project_dir}"
./scripts/verify-sources.sh

actual_revision="$(git -C sources/keystone-vf2 rev-parse HEAD)"
if [[ "${actual_revision}" != "${vf2_revision}" ]]; then
  echo "Wrong Keystone VF2 revision: ${actual_revision}" >&2
  exit 3
fi

./scripts/kas-build.sh build

bootloader="${deploy_dir}/bootloader_ddr5_secboot.bin"
sm_reference="${deploy_dir}/fw_payload.bin"
sm_elf="${deploy_dir}/fw_payload.elf"
sm_measurement_size=0x40000
if [[ ! -s "${bootloader}" ]]; then
  echo "Keystone bootloader was not deployed at ${bootloader}" >&2
  exit 4
fi
if [[ ! -s "${sm_reference}" ]]; then
  echo "Keystone SM reference image was not deployed at ${sm_reference}" >&2
  exit 4
fi
if (( $(stat -c '%s' "${sm_reference}") < sm_measurement_size )); then
  echo "Keystone SM reference image is shorter than ${sm_measurement_size} bytes." >&2
  exit 4
fi
if [[ ! -s "${sm_elf}" ]]; then
  echo "Keystone SM ELF was not deployed at ${sm_elf}" >&2
  exit 4
fi
fw_start="$(nm -n "${sm_elf}" | awk '$3 == "_fw_start" { value = "0x" $1 } END { print value }')"
fw_rw_start="$(nm -n "${sm_elf}" | awk '$3 == "_fw_rw_start" { value = "0x" $1 } END { print value }')"
if [[ -z "${fw_start}" || -z "${fw_rw_start}" ]] || \
   (( fw_rw_start - fw_start != sm_measurement_size )); then
  echo "Unexpected OpenSBI RX measurement range: ${fw_start:-missing}..${fw_rw_start:-missing}" >&2
  echo "Update the P550 verifier before publishing this bootchain." >&2
  exit 4
fi

sm_marker="Keystone security monitor has been initialized"
sm_evidence=""
if command -v strings >/dev/null 2>&1; then
  for candidate in \
    "${deploy_dir}/fw_payload.elf" \
    "${deploy_dir}/fw_payload.bin" \
    "${deploy_dir}/fw_dynamic.elf" \
    "${deploy_dir}/fw_dynamic.bin"; do
    if [[ -s "${candidate}" ]] && \
       grep -Fq "${sm_marker}" < <(strings "${candidate}"); then
      sm_evidence="${candidate}"
      break
    fi
  done

  if [[ -z "${sm_evidence}" ]]; then
    echo "The deployed OpenSBI images do not contain the expected Keystone SM marker." >&2
    echo "Checked fw_payload and fw_dynamic before the signed secboot wrapper was generated." >&2
    exit 5
  fi
else
  echo "The strings command is required to verify the unwrapped OpenSBI image." >&2
  exit 5
fi

mkdir -p "${artifact_dir}"
install -m 0644 "${bootloader}" \
  "${artifact_dir}/bootloader_ddr5_secboot.bin"
install -m 0644 "${sm_reference}" \
  "${artifact_dir}/fw_payload.bin"

cat > "${artifact_dir}/bootchain-manifest.txt" <<EOF
artifact=bootloader_ddr5_secboot.bin
board=hifive-premier-p550
release_base=2025.11.00-HFP550
keystone_source=its-valentinvp/keystone
keystone_revision=${vf2_revision}
security_monitor=enabled
attestation=test-only-no-device-root-key
attestation_sm_reference=fw_payload.bin
attestation_sm_reference_size=${sm_measurement_size}
attestation_sm_reference_sha256=$(sha256sum "${artifact_dir}/fw_payload.bin" | awk '{print $1}')
validation=hardware-required
sm_build_evidence=$(basename "${sm_evidence}")
sm_build_evidence_sha256=$(sha256sum "${sm_evidence}" | awk '{print $1}')
sha256=$(sha256sum "${artifact_dir}/bootloader_ddr5_secboot.bin" | awk '{print $1}')
EOF

echo "Keystone test bootchain: ${artifact_dir}/bootloader_ddr5_secboot.bin"
echo "Manifest: ${artifact_dir}/bootchain-manifest.txt"
echo "This artifact still requires the hardware gates in docs/VALIDATION.md."
