#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
release="2025.11.00-HFP550"
kernel_release="6.12.33-1-premier"
machine="hifive-premier-p550"
image_name="ubuntu-24.04-preinstalled-server-riscv64.img"
default_bundle="${project_dir}/flash/hifive-premier-p550-${release}-keystone"
base_image="${default_bundle}/${image_name}"
payload="${project_dir}/artifacts/keystone/keystone-p550-payload.tar.zst"
bootloader="${project_dir}/artifacts/keystone/bootloader_ddr5_secboot.bin"
output_dir="${project_dir}/artifacts/eswin-cipher"
force=0

usage() {
  cat <<EOF
Usage: ./scripts/build-eswin-cipher-image.sh [OPTIONS]

Build the ESWIN mailbox/cipher-enabled P550 kernel and inject it, the matching
Keystone payload and ESWIN userspace library into a copy of the official
${release} Ubuntu image.

Options:
  --base-image FILE  Input Ubuntu .img (default: ${base_image})
  --payload FILE     Matching Keystone payload archive (default: ${payload})
  --bootloader FILE  Matching Keystone bootloader (default: ${bootloader})
  --output-dir DIR   Artifact directory (default: ${output_dir})
  --force            Replace an existing generated image
  -h, --help         Show this help
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --base-image)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      base_image="$2"
      shift 2
      ;;
    --payload)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      payload="$2"
      shift 2
      ;;
    --bootloader)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      bootloader="$2"
      shift 2
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      output_dir="$2"
      shift 2
      ;;
    --force)
      force=1
      shift
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

for command_name in losetup mount umount mountpoint sha256sum tar wget xz \
  depmod modinfo file readelf dpkg-deb make; do
  command -v "${command_name}" >/dev/null 2>&1 || {
    echo "Required command not found: ${command_name}" >&2
    exit 2
  }
done

for input in "${base_image}" "${payload}" "${bootloader}"; do
  [[ -s "${input}" ]] || {
    echo "Required input is missing or empty: ${input}" >&2
    exit 2
  }
done

mkdir -p "${output_dir}"
output_dir="$(cd "${output_dir}" && pwd)"
case "${output_dir}" in
  "${project_dir}"/artifacts/*) ;;
  *)
    echo "Output directory must remain below ${project_dir}/artifacts" >&2
    exit 2
    ;;
esac

output_image="${output_dir}/${image_name%.img}-keystone-eswin-cipher.img"
output_bootloader="${output_dir}/bootloader_ddr5_secboot.bin"
if [[ -e "${output_image}" ]]; then
  if (( force == 0 )); then
    echo "Generated image already exists: ${output_image}" >&2
    echo "Use --force to replace only this generated copy." >&2
    exit 2
  fi
  rm -f -- "${output_image}"
fi

cd "${project_dir}"
./scripts/verify-sources.sh

echo "Building the P550 kernel, ESWIN mailbox and cipher modules..."
./scripts/kas-build.sh shell -c "bitbake linux-sifive-hf-premier-p550"

kernel_work="$(find build/tmp/work -path '*linux-sifive-hf-premier-p550*' \
  -type d -name 'linux-hifive_premier_p550-standard-build' -print -quit)"
deploy_dir="${project_dir}/build/tmp/deploy/images/${machine}"
[[ -n "${kernel_work}" && -d "${kernel_work}" ]] || {
  echo "Kernel build directory was not produced." >&2
  exit 3
}

actual_release="$(make -s -C build/tmp/work-shared/${machine}/kernel-source \
  O="${project_dir}/${kernel_work}" ARCH=riscv \
  LOCALVERSION=-1-premier kernelrelease)"
if [[ "${actual_release}" != "${kernel_release}" ]]; then
  echo "Kernel ABI mismatch: expected ${kernel_release}, got ${actual_release}" >&2
  exit 3
fi

kernel_image="${kernel_work}/arch/riscv/boot/Image"
kernel_config="${kernel_work}/.config"
kernel_map="${kernel_work}/System.map"
kernel_dtb="${kernel_work}/arch/riscv/boot/dts/eswin/eic7700-hifive-premier-p550.dtb"
modules_archive="$(find -L "${deploy_dir}" -maxdepth 1 -type f \
  -name 'modules-*.tgz' -printf '%T@ %p\n' | sort -nr | head -n 1 | cut -d' ' -f2-)"

for artifact in "${kernel_image}" "${kernel_config}" "${kernel_map}" \
  "${kernel_dtb}" "${modules_archive}"; do
  [[ -s "${artifact}" ]] || {
    echo "Kernel artifact is missing or empty: ${artifact:-not found}" >&2
    exit 3
  }
done

if ! file "${kernel_image}" | grep -q 'PE32+'; then
  echo "The generated RISC-V Image is not an EFI-stub PE executable." >&2
  exit 3
fi

module_stage="$(mktemp -d)"
payload_stage="$(mktemp -d)"
root_mount="$(mktemp -d)"
esp_mount="$(mktemp -d)"
loop_device=""

cleanup() {
  if mountpoint -q "${esp_mount}"; then
    sudo umount "${esp_mount}" || true
  fi
  if mountpoint -q "${root_mount}"; then
    sudo umount "${root_mount}" || true
  fi
  if [[ -n "${loop_device}" ]]; then
    sudo losetup -d "${loop_device}" || true
  fi
  rm -rf -- "${module_stage}" "${payload_stage}"
  rmdir "${root_mount}" "${esp_mount}" 2>/dev/null || true
}
trap cleanup EXIT

tar -xzf "${modules_archive}" -C "${module_stage}"
tar --zstd -xf "${payload}" -C "${payload_stage}"

for module_name in eswin-mailbox es_cipher keystone-driver; do
  if ! find "${module_stage}" -type f -name "${module_name}.ko*" \
      -print -quit | grep -q .; then
    echo "The kernel module archive is missing ${module_name}." >&2
    exit 3
  fi
done

payload_kernel="$(awk -F= '$1 == "kernel" {print $2; exit}' \
  "${payload_stage}/PAYLOAD-MANIFEST.txt")"
if [[ "${payload_kernel}" != "${kernel_release}" ]]; then
  echo "Keystone payload kernel mismatch: ${payload_kernel:-missing}" >&2
  exit 3
fi

eswin_cache="${project_dir}/release-cache/eswin-cipher"
mkdir -p "${eswin_cache}"
eswin_base_url="https://ppa.launchpadcontent.net/eswincomputing/noble-platform/ubuntu/pool/main/e/essdk"
declare -A eswin_sha256=(
  [es-sdk-common_1.10.1ubuntu4_riscv64.deb]="9bd824cd320e025cea9e795183ec0ae6723f2142cd8c45c4b60d5dfbb6ac5983"
  [es-sdk-cipher_1.10.1ubuntu4_riscv64.deb]="f2e04b7a0003b2affda5725bdda177ed049732fa7b7e94ef7059957b292953eb"
)
for package_name in "${!eswin_sha256[@]}"; do
  package_path="${eswin_cache}/${package_name}"
  if [[ ! -f "${package_path}" ]] || ! echo "${eswin_sha256[${package_name}]}  ${package_path}" | sha256sum -c - >/dev/null 2>&1; then
    temp_package="${package_path}.part.$$"
    rm -f -- "${temp_package}"
    wget -O "${temp_package}" "${eswin_base_url}/${package_name}"
    echo "${eswin_sha256[${package_name}]}  ${temp_package}" | sha256sum -c -
    mv -f -- "${temp_package}" "${package_path}"
  fi
  dpkg-deb -x "${package_path}" "${payload_stage}/eswin-rootfs"
done

echo "Copying the official Ubuntu image before modification..."
cp --reflink=auto --sparse=always "${base_image}" "${output_image}"
sync

sudo -v
loop_device="$(sudo losetup --find --show --partscan "${output_image}")"
[[ -b "${loop_device}p1" && -b "${loop_device}p3" ]] || {
  echo "Expected GPT partitions were not exposed for ${output_image}" >&2
  exit 4
}
sudo mount "${loop_device}p1" "${esp_mount}"
sudo mount "${loop_device}p3" "${root_mount}"

installed_release="$(basename "$(readlink -f "${root_mount}/boot/vmlinuz")")"
if [[ "${installed_release}" != "vmlinuz-${kernel_release}" ]]; then
  echo "Unexpected base-image kernel: ${installed_release}" >&2
  exit 4
fi

sudo rm -rf -- "${root_mount}/usr/lib/modules/${kernel_release}"
sudo tar --keep-directory-symlink -xzf "${modules_archive}" -C "${root_mount}"

sudo install -m 0644 "${kernel_image}" \
  "${root_mount}/boot/vmlinuz-${kernel_release}"
sudo install -m 0644 "${kernel_config}" \
  "${root_mount}/boot/config-${kernel_release}"
sudo install -m 0644 "${kernel_map}" \
  "${root_mount}/boot/System.map-${kernel_release}"
sudo install -D -m 0644 "${kernel_dtb}" \
  "${root_mount}/boot/dtbs/${kernel_release}/eswin/eic7700-hifive-premier-p550.dtb"
sudo install -D -m 0644 "${kernel_dtb}" \
  "${esp_mount}/dtb/eswin/eic7700-hifive-premier-p550.dtb"

sudo install -D -m 0644 \
  "${payload_stage}/rootfs/etc/modules-load.d/keystone.conf" \
  "${root_mount}/etc/modules-load.d/keystone.conf"
sudo mkdir -p "${root_mount}/usr/share/keystone"
sudo cp -a "${payload_stage}/rootfs/usr/share/keystone/." \
  "${root_mount}/usr/share/keystone/"

sudo cp -a "${payload_stage}/eswin-rootfs/usr/." "${root_mount}/usr/"
sudo install -D -m 0644 \
  "${project_dir}/meta-keystone-p550/recipes-kernel/linux/files/eswin-cipher/eswin-ipc-scpu.h" \
  "${root_mount}/usr/include/linux/eswin-ipc-scpu.h"
printf '%s\n' eswin-mailbox es_cipher | \
  sudo tee "${root_mount}/etc/modules-load.d/eswin-cipher.conf" >/dev/null

sudo depmod -b "${root_mount}" "${kernel_release}"
sudo sync

for module_name in eswin-mailbox es_cipher keystone-driver; do
  module_file="$(find "${root_mount}/usr/lib/modules/${kernel_release}" \
    -type f -name "${module_name}.ko*" -print -quit)"
  [[ -n "${module_file}" ]] || {
    echo "Installed module not found: ${module_name}" >&2
    exit 4
  }
  vermagic="$(modinfo -F vermagic "${module_file}")"
  [[ "${vermagic}" == "${kernel_release} "* ]] || {
    echo "Wrong vermagic for ${module_file}: ${vermagic}" >&2
    exit 4
  }
done

sudo umount "${esp_mount}"
sudo umount "${root_mount}"
sudo losetup -d "${loop_device}"
loop_device=""

install -m 0644 "${bootloader}" "${output_bootloader}"
cat > "${output_dir}/eswin-cipher-manifest.txt" <<EOF
board=${machine}
release_base=${release}
kernel=${kernel_release}
kernel_source_revision=$(git -C sources/riscv-linux rev-parse HEAD)
kernel_config=SiFive P550 config plus ESWIN mailbox/cipher and Keystone modules
eswin_driver_source=eswincomputing/linux-stable linux-6.6.18-EIC7X
eswin_driver_revision=fc6038c00e006226e3bd504d2679c534eabf5503
eswin_userspace=essdk 1.10.1ubuntu4
keystone_payload=$(basename "${payload}")
bootloader=$(basename "${output_bootloader}")
image=$(basename "${output_image}")
EOF

(
  cd "${output_dir}"
  sha256sum "$(basename "${output_image}")" \
    "$(basename "${output_bootloader}")" \
    eswin-cipher-manifest.txt > SHA256SUMS
)

cat <<EOF
ESWIN cipher-enabled Keystone image is ready:
  ${output_image}
  ${output_bootloader}
  ${output_dir}/SHA256SUMS
EOF
