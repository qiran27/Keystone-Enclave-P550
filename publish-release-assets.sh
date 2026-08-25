#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage:
  ./publish-release-assets.sh keystone RELEASE_TAG
  ./publish-release-assets.sh eswin RELEASE_TAG
  ./publish-release-assets.sh RELEASE_TAG

The one-argument form is retained for compatibility and publishes the
hardware-validated Keystone bootchain and payload.

The eswin form publishes the integrated Keystone + ESWIN cipher image. The
raw image is compressed first. If the compressed file is not below GitHub's
2 GiB per-asset limit, it is split into independently checksummed parts.
EOF
}

mode="${1:-}"
tag="${2:-}"
if [[ "${mode}" != "keystone" && "${mode}" != "eswin" ]]; then
  tag="${mode}"
  mode="keystone"
fi

if [[ -z "${tag}" || "${tag}" == "-h" || "${tag}" == "--help" ]]; then
  usage
  [[ -n "${tag}" ]] && exit 0
  exit 2
fi

for command_name in gh sha256sum; do
  command -v "${command_name}" >/dev/null 2>&1 || {
    echo "${command_name} is required." >&2
    exit 2
  }
done

confirm_release() {
  local release_tag="$1"
  shift
  printf 'About to create GitHub Release %s with:\n' "${release_tag}"
  printf '  %s\n' "$@"
  if [[ "${PUBLISH_ASSUME_YES:-0}" != "1" ]]; then
    read -r -p "Type 'yes' to create the release: " answer
    if [[ "${answer}" != "yes" ]]; then
      echo "Release publication cancelled."
      exit 1
    fi
  fi
}

check_new_release() {
  gh auth status >/dev/null
  if gh release view "${tag}" >/dev/null 2>&1; then
    echo "GitHub Release ${tag} already exists; refusing to overwrite it." >&2
    exit 2
  fi
}

publish_keystone() {
  local artifact_dir="${project_dir}/artifacts/keystone"
  local release_files=()
  local release_names=()
  local release_file artifact actual_hash

  release_names=(
    bootloader_ddr5_secboot.bin
    fw_payload.bin
    bootchain-manifest.txt
    keystone-p550-payload.tar.zst
    keystone-p550-payload.tar.zst.sha256
    hardware-validation.txt
  )
  for artifact in "${release_names[@]}"; do
    release_file="${artifact_dir}/${artifact}"
    if [[ ! -f "${release_file}" ]]; then
      echo "Missing release artifact: ${release_file}" >&2
      exit 2
    fi
    release_files+=("${release_file}")
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
    sha256sum "${release_names[@]}" > SHA256SUMS
    sha256sum -c SHA256SUMS
  )
  release_files+=("${artifact_dir}/SHA256SUMS")
  release_names+=(SHA256SUMS)

  check_new_release
  confirm_release "${tag}" "${release_names[@]}"
  gh release create "${tag}" "${release_files[@]}" \
    --title "Keystone on HiFive Premier P550 ${tag}" \
    --notes "Hardware-validated Keystone P550 bootchain, matching SM reference and payload for SiFive Ubuntu 2025.11.00, kernel 6.12.33-1-premier. Attestation uses a public test key and is not a production identity claim."
}

publish_eswin() {
  local artifact_dir="${project_dir}/artifacts/eswin-cipher"
  local image_name="ubuntu-24.04-preinstalled-server-riscv64-keystone-eswin-cipher.img"
  local compressed_name="${image_name}.xz"
  local image_path="${artifact_dir}/${image_name}"
  local compressed_path="${artifact_dir}/${compressed_name}"
  local stage_dir
  local max_asset_bytes=$((2 * 1024 * 1024 * 1024))
  local part_bytes=$((1900 * 1024 * 1024))
  local compressed_size release_file
  local release_files=()
  local release_names=()

  for release_file in \
    "${image_path}" \
    "${artifact_dir}/bootloader_ddr5_secboot.bin" \
    "${artifact_dir}/eswin-cipher-manifest.txt" \
    "${artifact_dir}/SHA256SUMS"; do
    if [[ ! -f "${release_file}" ]]; then
      echo "Missing ESWIN release artifact: ${release_file}" >&2
      exit 2
    fi
  done

  stage_dir="$(mktemp -d "${artifact_dir}/release-${tag}.XXXXXX")"

  (cd "${artifact_dir}" && sha256sum -c SHA256SUMS)
  command -v xz >/dev/null 2>&1 || {
    echo "xz is required to package the integrated image." >&2
    exit 2
  }

  if [[ -f "${compressed_path}" ]]; then
    echo "Verifying cached ${compressed_name}..."
    xz -t "${compressed_path}"
    if [[ "$(xz -dc "${compressed_path}" | sha256sum | awk '{print $1}')" != \
          "$(sha256sum "${image_path}" | awk '{print $1}')" ]]; then
      echo "Cached ${compressed_name} does not expand to the validated image." >&2
      exit 2
    fi
  else
    echo "Compressing ${image_name}; this can take several minutes..."
    xz -T0 -6 -k "${image_path}"
  fi

  mkdir -p "${stage_dir}"
  cp -f \
    "${artifact_dir}/bootloader_ddr5_secboot.bin" \
    "${artifact_dir}/eswin-cipher-manifest.txt" \
    "${artifact_dir}/SHA256SUMS" \
    "${stage_dir}/"

  compressed_size="$(stat -c '%s' "${compressed_path}")"
  if (( compressed_size < max_asset_bytes )); then
    cp -f "${compressed_path}" "${stage_dir}/"
  else
    command -v split >/dev/null 2>&1 || {
      echo "split is required because the compressed image exceeds 2 GiB." >&2
      exit 2
    }
    rm -f -- "${stage_dir}/${compressed_name}.part-"[0-9][0-9][0-9]
    split --bytes="${part_bytes}" --numeric-suffixes=0 --suffix-length=3 \
      "${compressed_path}" "${stage_dir}/${compressed_name}.part-"
  fi

  if [[ -f "${artifact_dir}/eswin-cipher-speed-results.csv" ]]; then
    cp -f "${artifact_dir}/eswin-cipher-speed-results.csv" "${stage_dir}/"
  fi

  (
    cd "${stage_dir}"
    sha256sum -- * > DOWNLOAD-SHA256SUMS
    sha256sum -c DOWNLOAD-SHA256SUMS
  )

  while IFS= read -r -d '' release_file; do
    release_files+=("${release_file}")
    release_names+=("$(basename "${release_file}")")
  done < <(find "${stage_dir}" -maxdepth 1 -type f -print0 | sort -z)

  check_new_release
  confirm_release "${tag}" "${release_names[@]}"
  gh release create "${tag}" "${release_files[@]}" \
    --title "Keystone + ESWIN cipher on HiFive Premier P550 ${tag}" \
    --notes "Integrated SiFive Ubuntu 2025.11.00 image for HiFive Premier P550 with the hardware-validated Keystone bootchain/payload and ESWIN SCPU cipher support. Verify DOWNLOAD-SHA256SUMS first. If the image is split, concatenate the .part-* files in lexical order, then run xz -d and verify SHA256SUMS before flashing."
}

case "${mode}" in
  keystone) publish_keystone ;;
  eswin) publish_eswin ;;
esac

echo "Published ${mode} hardware artifacts to GitHub Release ${tag}."
