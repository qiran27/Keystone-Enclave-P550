#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
artifact_dir="${project_dir}/artifacts/keystone"
tag="${1:-}"

if [[ -z "${tag}" || "${tag}" == "-h" || "${tag}" == "--help" ]]; then
  cat <<'EOF'
Usage: ./publish-release-assets.sh RELEASE_TAG

Uploads the locally hardware-validated P550 bootchain, matching payload and
manifests to a new GitHub Release in the repository configured as origin.
The script never uploads the official multi-gigabyte Ubuntu image.
EOF
  [[ -n "${tag}" ]] && exit 0
  exit 2
fi

command -v gh >/dev/null 2>&1 || {
  echo "GitHub CLI (gh) is required." >&2
  exit 2
}
command -v sha256sum >/dev/null 2>&1 || {
  echo "sha256sum is required." >&2
  exit 2
}

release_files=(
  "${artifact_dir}/bootloader_ddr5_secboot.bin"
  "${artifact_dir}/fw_payload.bin"
  "${artifact_dir}/bootchain-manifest.txt"
  "${artifact_dir}/keystone-p550-payload.tar.zst"
  "${artifact_dir}/keystone-p550-payload.tar.zst.sha256"
  "${artifact_dir}/hardware-validation.txt"
)
for release_file in "${release_files[@]}"; do
  if [[ ! -f "${release_file}" ]]; then
    echo "Missing release artifact: ${release_file}" >&2
    exit 2
  fi
done

record_value() {
  local key="$1"
  sed -n "s/^${key}=//p" \
    "${artifact_dir}/hardware-validation.txt" | tail -n 1
}

if [[ "$(record_value status)" != "pass" ]]; then
  echo "Hardware validation record does not contain status=pass." >&2
  exit 2
fi
declare -A recorded_hashes=(
  [bootloader_ddr5_secboot.bin]="$(record_value bootloader_sha256)"
  [fw_payload.bin]="$(record_value fw_payload_sha256)"
  [keystone-p550-payload.tar.zst]="$(record_value payload_sha256)"
)
for artifact in "${!recorded_hashes[@]}"; do
  actual_hash="$(sha256sum "${artifact_dir}/${artifact}" | awk '{print $1}')"
  if [[ -z "${recorded_hashes[${artifact}]}" || \
        "${actual_hash}" != "${recorded_hashes[${artifact}]}" ]]; then
    echo "${artifact} does not match hardware-validation.txt." >&2
    exit 2
  fi
done

(
  cd "${artifact_dir}"
  sha256sum \
    bootloader_ddr5_secboot.bin \
    fw_payload.bin \
    bootchain-manifest.txt \
    keystone-p550-payload.tar.zst \
    keystone-p550-payload.tar.zst.sha256 \
    hardware-validation.txt > SHA256SUMS
  sha256sum -c SHA256SUMS
)
release_files+=("${artifact_dir}/SHA256SUMS")
gh auth status >/dev/null

if gh release view "${tag}" >/dev/null 2>&1; then
  echo "GitHub Release ${tag} already exists; refusing to overwrite it." >&2
  exit 2
fi

cat <<EOF
About to create GitHub Release ${tag} with:
  bootloader_ddr5_secboot.bin
  fw_payload.bin
  bootchain-manifest.txt
  keystone-p550-payload.tar.zst
  keystone-p550-payload.tar.zst.sha256
  hardware-validation.txt
  SHA256SUMS
EOF

if [[ "${PUBLISH_ASSUME_YES:-0}" != "1" ]]; then
  read -r -p "Type 'yes' to create the release: " answer
  if [[ "${answer}" != "yes" ]]; then
    echo "Release publication cancelled."
    exit 1
  fi
fi

gh release create "${tag}" "${release_files[@]}" \
  --title "Keystone on HiFive Premier P550 ${tag}" \
  --notes "Hardware-validated Keystone P550 bootchain, matching SM reference and payload for SiFive Ubuntu 2025.11.00, kernel 6.12.33-1-premier. The official Ubuntu image remains available from SiFive and is not duplicated in this release. Attestation uses a public test key and is not a production identity claim."

echo "Published hardware artifacts to GitHub Release ${tag}."
