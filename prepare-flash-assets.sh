#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python_bin="${project_dir}/.venv/bin/python"
asset_lock="${project_dir}/release-assets.lock.yml"
mode=""
custom_bootloader=""
sm_reference=""
bootchain_manifest=""
payload=""

usage() {
  cat <<'EOF'
Usage:
  ./prepare-flash-assets.sh --baseline
  ./prepare-flash-assets.sh --keystone-bootloader FILE --payload FILE

--baseline prepares the unmodified, matched SiFive Ubuntu/bootloader pair for
board recovery and baseline testing. It is not Keystone-capable.

The Keystone form deliberately requires a custom bootloader containing the
P550 Security Monitor and a payload archive containing the matching driver,
SDK/runtime and tests. It never silently substitutes the stock bootloader.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --baseline)
      mode="baseline"
      shift
      ;;
    --keystone-bootloader)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      mode="keystone"
      custom_bootloader="$2"
      shift 2
      ;;
    --payload)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      payload="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "${mode}" ]]; then
  usage >&2
  exit 2
fi
if [[ "${mode}" == "keystone" && -z "${payload}" ]]; then
  echo "A matching Keystone payload is required with --payload." >&2
  exit 2
fi
if [[ -n "${custom_bootloader}" && ! -f "${custom_bootloader}" ]]; then
  echo "Custom bootloader not found: ${custom_bootloader}" >&2
  exit 2
fi
if [[ -n "${payload}" && ! -f "${payload}" ]]; then
  echo "Keystone payload not found: ${payload}" >&2
  exit 2
fi
if [[ ! -x "${python_bin}" ]]; then
  echo "Project Python environment not found. Run ./scripts/install-ubuntu-deps.sh first." >&2
  exit 2
fi

mapfile -t asset_info < <(
  "${python_bin}" - "${asset_lock}" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as stream:
    lock = yaml.safe_load(stream)
print(lock["release"])
for key in ("ubuntu", "bootloader"):
    print(lock["assets"][key]["filename"])
PY
)

release="${asset_info[0]}"
ubuntu_filename="${asset_info[1]}"
stock_bootloader_filename="${asset_info[2]}"
release_dir="${project_dir}/release-cache/${release}"
bundle_dir="${project_dir}/flash/hifive-premier-p550-${release}-${mode}"

"${project_dir}/fetch-release-assets.sh" all

ubuntu_xz="${release_dir}/${ubuntu_filename}"
stock_bootloader="${release_dir}/${stock_bootloader_filename}"
image_name="${ubuntu_filename%.xz}"

rm -rf -- "${bundle_dir}"
mkdir -p "${bundle_dir}"

if [[ "${mode}" == "baseline" ]]; then
  install -m 0644 "${stock_bootloader}" \
    "${bundle_dir}/${stock_bootloader_filename}"
  cat > "${bundle_dir}/BASELINE-NOT-KEYSTONE.txt" <<'EOF'
This bundle contains the unmodified SiFive bootloader and Ubuntu image.
It is intended for recovery and board-baseline tests only. It does not contain
the Keystone Security Monitor, driver, runtime or enclave applications.
EOF
else
  custom_dir="$(cd "$(dirname "${custom_bootloader}")" && pwd)"
  sm_reference="${custom_dir}/fw_payload.bin"
  bootchain_manifest="${custom_dir}/bootchain-manifest.txt"
  if [[ ! -f "${sm_reference}" || ! -f "${bootchain_manifest}" ]]; then
    echo "The custom bootloader directory must also contain:" >&2
    echo "  fw_payload.bin" >&2
    echo "  bootchain-manifest.txt" >&2
    echo "These files bind the attestation example to the exact SM build." >&2
    exit 2
  fi
  install -m 0644 "${custom_bootloader}" \
    "${bundle_dir}/${stock_bootloader_filename}"
  install -m 0644 "${sm_reference}" "${bundle_dir}/fw_payload.bin"
  install -m 0644 "${bootchain_manifest}" \
    "${bundle_dir}/bootchain-manifest.txt"
  install -m 0644 "${payload}" "${bundle_dir}/$(basename "${payload}")"
  if [[ -f "${payload}.sha256" ]]; then
    install -m 0644 "${payload}.sha256" \
      "${bundle_dir}/$(basename "${payload}.sha256")"
  fi
fi

echo "Decompressing the official Ubuntu image (this needs several GiB of free space)..."
xz --decompress --stdout "${ubuntu_xz}" > "${bundle_dir}/${image_name}"

(
  cd "${bundle_dir}"
  sha256sum ./* > SHA256SUMS
)

cat <<EOF
Flash bundle ready: ${bundle_dir}

Copy its files to an ext4-formatted USB drive. See docs/FLASHING.md before
executing any destructive U-Boot write command.
EOF
