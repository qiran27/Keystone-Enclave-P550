#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kernel_release="6.12.33-1-premier"
image="${1:-${project_dir}/artifacts/eswin-cipher/ubuntu-24.04-preinstalled-server-riscv64-keystone-eswin-cipher.img}"

if (( EUID != 0 )); then
  echo "Run this validator as root so it can attach and mount the image." >&2
  exit 2
fi

for command_name in cmp file find grep losetup modinfo mount mountpoint \
  sha256sum strings umount; do
  command -v "${command_name}" >/dev/null 2>&1 || {
    echo "Required command not found: ${command_name}" >&2
    exit 2
  }
done

[[ -s "${image}" ]] || {
  echo "Image not found or empty: ${image}" >&2
  exit 2
}
image="$(readlink -f "${image}")"

root_mount="$(mktemp -d)"
esp_mount="$(mktemp -d)"
loop_device=""

cleanup() {
  if mountpoint -q "${esp_mount}"; then
    umount "${esp_mount}" || true
  fi
  if mountpoint -q "${root_mount}"; then
    umount "${root_mount}" || true
  fi
  if [[ -n "${loop_device}" ]]; then
    losetup -d "${loop_device}" || true
  fi
  rmdir "${root_mount}" "${esp_mount}" 2>/dev/null || true
}
trap cleanup EXIT

checksum_file="$(dirname "${image}")/SHA256SUMS"
if [[ -s "${checksum_file}" ]]; then
  (
    cd "$(dirname "${image}")"
    sha256sum -c "$(basename "${checksum_file}")"
  )
fi

loop_device="$(losetup --find --show --read-only --partscan "${image}")"
[[ -b "${loop_device}p1" && -b "${loop_device}p3" ]] || {
  echo "Expected GPT partitions were not exposed for ${image}" >&2
  exit 3
}
mount -o ro "${loop_device}p1" "${esp_mount}"
mount -o ro "${loop_device}p3" "${root_mount}"

grep -qx 'CONFIG_ESWIN_MBOX=m' \
  "${root_mount}/boot/config-${kernel_release}"
grep -qx 'CONFIG_CRYPTO_DEV_ESWIN_EIC770x=m' \
  "${root_mount}/boot/config-${kernel_release}"
grep -qx 'CONFIG_KEYSTONE_DRIVER=m' \
  "${root_mount}/boot/config-${kernel_release}"

kernel_image="${root_mount}/boot/vmlinuz-${kernel_release}"
file "${kernel_image}" | grep -q 'PE32+.*RISC-V'

root_dtb="${root_mount}/boot/dtbs/${kernel_release}/eswin/eic7700-hifive-premier-p550.dtb"
esp_dtb="${esp_mount}/dtb/eswin/eic7700-hifive-premier-p550.dtb"
cmp "${root_dtb}" "${esp_dtb}"
strings "${root_dtb}" | grep -Fxq 'eswin,win2030-mailbox'
strings "${root_dtb}" | grep -Fxq 'eswin,win2030-ipc'

for module_name in eswin-mailbox es_cipher keystone-driver; do
  module_file="$(find "${root_mount}/usr/lib/modules/${kernel_release}" \
    -type f -name "${module_name}.ko*" -print -quit)"
  [[ -n "${module_file}" ]] || {
    echo "Installed module not found: ${module_name}" >&2
    exit 3
  }
  vermagic="$(modinfo -F vermagic "${module_file}")"
  [[ "${vermagic}" == "${kernel_release} "* ]] || {
    echo "Wrong vermagic for ${module_file}: ${vermagic}" >&2
    exit 3
  }
  printf '%-20s %s\n' "${module_name}" "${vermagic}"
done

[[ -s "${root_mount}/usr/lib/libes_cipher.so.1.0" ]]
[[ -d "${root_mount}/usr/share/keystone/examples" ]]
[[ -s "${root_mount}/etc/modules-load.d/eswin-cipher.conf" ]]
[[ -s "${root_mount}/etc/modules-load.d/keystone.conf" ]]

echo "Image validation passed: ${image}"
