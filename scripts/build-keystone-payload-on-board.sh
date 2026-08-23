#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_dir="${project_dir}/sources/keystone-vf2"
work_dir="${project_dir}/artifacts/build-p550"
artifact_dir="${project_dir}/artifacts/keystone"
sdk_patch="${project_dir}/scripts/patches/keystone-vf2-sdk-stdint.patch"
sdk_cmake_patch="${project_dir}/scripts/patches/keystone-vf2-sdk-eyrie-cmake-flags.patch"
sdk_nopie_patch="${project_dir}/scripts/patches/keystone-vf2-sdk-eyrie-nopie.patch"
driver_cleanup_patch="${project_dir}/scripts/patches/keystone-vf2-driver-finalize-cleanup.patch"
examples_patch="${project_dir}/scripts/patches/keystone-vf2-examples-native-gcc.patch"
examples_p550_patch="${project_dir}/scripts/patches/keystone-vf2-examples-p550.patch"
sdk_source_dir="${work_dir}/sdk-src"
examples_source_dir="${work_dir}/examples-src"
sdk_dir="${work_dir}/sdk-install"
sdk_marker="${sdk_dir}/.p550-sdk-inputs.sha256"
tool_dir="${work_dir}/native-toolchain"
payload_dir="${work_dir}/payload"
vf2_revision="c5f7ac3977f50309ac816b54f470c4021573bf5e"
install_deps=0
resume=0
sm_bin="${artifact_dir}/fw_payload.bin"

usage() {
  cat <<'EOF'
Usage: ./scripts/build-keystone-payload-on-board.sh [--install-deps] [--resume]
       [--sm-bin FILE]

Run this script on the HiFive Premier P550 while it is booted with the
official Ubuntu image. It builds the VF2-pinned Keystone driver against the
exact running kernel, then builds the VF2 SDK, Eyrie runtime and all official
examples: hello, hello-native, attestation and the complete tests package.

FILE must be fw_payload.bin from the exact Keystone bootchain currently booted
on the board. The default is artifacts/keystone/fw_payload.bin.

Use --resume after a failed invocation to preserve the existing build tree and
continue incrementally. Omit it for a clean, reproducible build.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --install-deps) install_deps=1 ;;
    --resume) resume=1 ;;
    --sm-bin)
      shift
      (( $# > 0 )) || { usage >&2; exit 2; }
      sm_bin="$1"
      ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

if [[ "$(uname -m)" != "riscv64" ]]; then
  echo "This script must run natively on the riscv64 P550 board." >&2
  exit 3
fi

if (( install_deps )); then
  sudo apt-get update
  sudo apt-get install -y \
    build-essential cmake git makeself ninja-build zstd \
    "linux-headers-$(uname -r)"
fi

for command_name in ar as cmake gcc g++ ld make makeself objcopy objdump readelf tar zstd; do
  command -v "${command_name}" >/dev/null 2>&1 || {
    echo "Missing ${command_name}." >&2
    echo "Use --install-deps only when the board has Internet access." >&2
    echo "For an offline board, follow 'P550 without Internet access' in README.md." >&2
    exit 4
  }
done

kernel_build="/lib/modules/$(uname -r)/build"
if [[ ! -e "${kernel_build}/Makefile" ]]; then
  echo "Kernel build tree is missing: ${kernel_build}" >&2
  echo "Install the exact headers for $(uname -r); headers from another kernel are unsafe." >&2
  exit 5
fi
if [[ ! -d "${source_dir}/.git" ]]; then
  echo "Missing ${source_dir}; run ./scripts/fetch-keystone-vf2.sh first." >&2
  exit 6
fi
if [[ ! -f "${sdk_patch}" ]]; then
  echo "Missing SDK compatibility patch: ${sdk_patch}" >&2
  exit 7
fi
if [[ ! -f "${sdk_cmake_patch}" ]]; then
  echo "Missing SDK Eyrie CMake compatibility patch: ${sdk_cmake_patch}" >&2
  exit 8
fi
if [[ ! -f "${examples_patch}" ]]; then
  echo "Missing examples compatibility patch: ${examples_patch}" >&2
  exit 9
fi
if [[ ! -f "${examples_p550_patch}" ]]; then
  echo "Missing P550 examples compatibility patch: ${examples_p550_patch}" >&2
  exit 9
fi
if [[ ! -f "${sdk_nopie_patch}" ]]; then
  echo "Missing SDK Eyrie non-PIE patch: ${sdk_nopie_patch}" >&2
  exit 9
fi
if [[ ! -f "${driver_cleanup_patch}" ]]; then
  echo "Missing driver cleanup patch: ${driver_cleanup_patch}" >&2
  exit 9
fi
actual_revision="$(git -C "${source_dir}" rev-parse HEAD)"
if [[ "${actual_revision}" != "${vf2_revision}" ]]; then
  echo "Wrong Keystone VF2 revision: ${actual_revision}" >&2
  exit 10
fi
sdk_fingerprint="$({
  printf '%s\n' "${vf2_revision}"
  sha256sum "${sdk_patch}" "${sdk_cmake_patch}" \
    "${sdk_nopie_patch}"
} | sha256sum | awk '{print $1}')"
driver_fingerprint="$({
  printf '%s\n' "${vf2_revision}"
  sha256sum "${driver_cleanup_patch}"
} | sha256sum | awk '{print $1}')"
driver_marker="${work_dir}/driver-src/.p550-driver-inputs.sha256"
sm_bin="$(readlink -f "${sm_bin}")"
if [[ ! -s "${sm_bin}" ]]; then
  echo "Missing Keystone SM reference image: ${sm_bin}" >&2
  echo "Copy artifacts/keystone/fw_payload.bin from the bootchain build host." >&2
  exit 10
fi
if (( $(stat -c '%s' "${sm_bin}") < 0x40000 )); then
  echo "SM reference image is shorter than the P550 0x40000-byte RX measurement." >&2
  exit 10
fi

# Offline boards may boot with a stale clock. CMake and make cannot reliably
# build when checked-out inputs appear to come from the future.
latest_source_epoch="$(find "${source_dir}" -type f -printf '%T@\n' | \
  sort -nr | sed -n '1{s/\..*//;p;}')"
current_epoch="$(date +%s)"
if [[ -n "${latest_source_epoch}" ]] && \
   (( latest_source_epoch > current_epoch + 300 )); then
  echo "System clock is older than the Keystone source timestamps." >&2
  echo "Current time: $(date --iso-8601=seconds)" >&2
  echo "Set the P550 clock before building to avoid clock-skew failures." >&2
  exit 11
fi

if (( resume )); then
  for resume_dir in \
    "${work_dir}/driver-src" "${sdk_source_dir}" "${examples_source_dir}"; do
    if [[ ! -d "${resume_dir}" ]]; then
      echo "Cannot resume: missing ${resume_dir}" >&2
      echo "Run again without --resume to start a clean build." >&2
      exit 12
    fi
  done
  mkdir -p "${tool_dir}" "${sdk_dir}" "${payload_dir}/rootfs"
else
  rm -rf "${work_dir}"
  mkdir -p "${tool_dir}" "${sdk_dir}" "${payload_dir}/rootfs"
  cp -a "${source_dir}/linux-keystone-driver" "${work_dir}/driver-src"
  cp -a "${source_dir}/sdk" "${sdk_source_dir}"
  cp -a "${source_dir}/examples" "${examples_source_dir}"
fi
# Keep the pinned VF2 repository pristine. Apply the GCC 13 self-contained
# header fix only to the disposable SDK build copy; installed SDK headers and
# all example builds then consume the same corrected ABI declarations. EOL
# normalization supports source trees transported via NTFS. The ceiling keeps
# git-apply in standalone mode instead of letting it discover the parent
# keystone-p550-system repository and silently filter the SDK-relative paths.
sdk_compat_headers=(
  "${sdk_source_dir}/include/shared/sm_call.h"
  "${sdk_source_dir}/include/host/Params.hpp"
  "${sdk_source_dir}/macros.cmake"
)
for compat_header in "${sdk_compat_headers[@]}"; do
  sed -i 's/\r$//' "${compat_header}"
done
apply_patch_once() {
  local source_copy="$1"
  local patch_file="$2"

  if GIT_CEILING_DIRECTORIES="${work_dir}" \
       git -C "${source_copy}" apply --check "${patch_file}" \
       2>/dev/null; then
    GIT_CEILING_DIRECTORIES="${work_dir}" \
      git -C "${source_copy}" apply "${patch_file}"
  elif GIT_CEILING_DIRECTORIES="${work_dir}" \
         git -C "${source_copy}" apply --reverse --check "${patch_file}" \
         2>/dev/null; then
    echo "Compatibility patch already applied: $(basename "${patch_file}")"
  else
    echo "Compatibility patch does not match the disposable source copy:" >&2
    echo "  ${patch_file}" >&2
    echo "Run again without --resume to recreate a clean build tree." >&2
    exit 13
  fi
}

apply_patch_once "${sdk_source_dir}" "${sdk_patch}"
if grep -Fqx '      "-DCMAKE_C_FLAGS:STRING=${CMAKE_C_FLAGS}"' \
     "${sdk_source_dir}/macros.cmake"; then
  echo "Compatibility patch already applied: $(basename "${sdk_cmake_patch}")"
else
  apply_patch_once "${sdk_source_dir}" "${sdk_cmake_patch}"
fi
if grep -Fqx '      "-DCMAKE_ASM_FLAGS:STRING=${CMAKE_ASM_FLAGS}"' \
     "${sdk_source_dir}/macros.cmake" && \
   grep -Fqx '      "-DCMAKE_EXE_LINKER_FLAGS:STRING=${CMAKE_EXE_LINKER_FLAGS}"' \
     "${sdk_source_dir}/macros.cmake"; then
  echo "Compatibility patch already applied: $(basename "${sdk_nopie_patch}")"
else
  apply_patch_once "${sdk_source_dir}" "${sdk_nopie_patch}"
fi
grep -qx '#include <stddef.h>' \
  "${sdk_source_dir}/include/shared/sm_call.h"
grep -qx '#include <stdint.h>' \
  "${sdk_source_dir}/include/shared/sm_call.h"
grep -qx '#include <linux/types.h>' \
  "${sdk_source_dir}/include/shared/sm_call.h"
grep -qx '#include <stdint.h>' \
  "${sdk_source_dir}/include/host/Params.hpp"
grep -Fqx '      "-DCMAKE_C_FLAGS:STRING=${CMAKE_C_FLAGS}"' \
  "${sdk_source_dir}/macros.cmake"
grep -Fqx '      "-DCMAKE_ASM_FLAGS:STRING=${CMAKE_ASM_FLAGS}"' \
  "${sdk_source_dir}/macros.cmake"
grep -Fqx '      "-DCMAKE_EXE_LINKER_FLAGS:STRING=${CMAKE_EXE_LINKER_FLAGS}"' \
  "${sdk_source_dir}/macros.cmake"

sed -i 's/\r$//' "${work_dir}/driver-src/keystone-ioctl.c"
apply_patch_once "${work_dir}/driver-src" "${driver_cleanup_patch}"
grep -Fq 'Keep the partially initialized object alive' \
  "${work_dir}/driver-src/keystone-ioctl.c"

for examples_compat_file in \
  "${examples_source_dir}/hello-native/CMakeLists.txt" \
  "${examples_source_dir}/attestation/CMakeLists.txt" \
  "${examples_source_dir}/attestation/host/attestor-runner.cpp" \
  "${examples_source_dir}/attestation/host/verifier.cpp" \
  "${examples_source_dir}/tests/CMakeLists.txt" \
  "${examples_source_dir}/tests/test-runner.cpp"; do
  sed -i 's/\r$//' "${examples_compat_file}"
done
apply_patch_once "${examples_source_dir}" "${examples_patch}"
apply_patch_once "${examples_source_dir}" "${examples_p550_patch}"
grep -Fqx 'target_link_options(${eapp_bin} PRIVATE "-Wl,-e,main")' \
  "${examples_source_dir}/hello-native/CMakeLists.txt"
grep -Fqx 'target_link_options(${eapp_bin} PRIVATE "-Wl,-e,main")' \
  "${examples_source_dir}/attestation/CMakeLists.txt"
grep -Fqx '  size_t freemem_size   = 48 * 1024 * 1024;' \
  "${examples_source_dir}/attestation/host/attestor-runner.cpp"
grep -Fqx '  size_t freemem_size   = 48 * 1024 * 1024;' \
  "${examples_source_dir}/tests/test-runner.cpp"
grep -Fq -- '--freemem-size 1024' \
  "${examples_source_dir}/attestation/CMakeLists.txt"
grep -Fq -- '--freemem-size 1024' \
  "${examples_source_dir}/tests/CMakeLists.txt"
grep -Fqx '  const size_t sanctum_sm_size = 0x40000;' \
  "${examples_source_dir}/attestation/host/verifier.cpp"

# The VF2 CMake files require Buildroot-style executable names. On the P550
# the native compiler has the same ABI, so these private wrappers select it
# without modifying the pinned component source.
for pair in \
  gcc:gcc g++:g++ as:as ld:ld ar:ar objcopy:objcopy objdump:objdump; do
  wrapper="${pair%%:*}"
  native="${pair##*:}"
  ln -sfn "$(command -v "${native}")" \
    "${tool_dir}/riscv64-buildroot-linux-gnu-${wrapper}"
done
export PATH="${tool_dir}:${PATH}"

build_sdk() {
  # Always configure the legacy VF2 SDK in a fresh cache. Its toolchain macro
  # force-writes compiler cache entries and cannot safely reconfigure an old
  # cache. The freestanding eapp/edge libraries must not contain host stack
  # protector or PIE references because Eyrie links them with -nostdlib.
  rm -rf "${work_dir}/sdk-build" "${sdk_dir}"
  mkdir -p "${sdk_dir}"
  cmake -S "${sdk_source_dir}" -B "${work_dir}/sdk-build" \
    -G Ninja \
    -DKEYSTONE_SDK_DIR="${sdk_dir}" \
    -DKEYSTONE_BITS=64 \
    -DCMAKE_C_FLAGS="-fno-stack-protector -fno-pie" \
    -DCMAKE_CXX_FLAGS="-fno-stack-protector -fno-pie" \
    -DCMAKE_BUILD_TYPE=Release
  cmake --build "${work_dir}/sdk-build" --parallel
  cmake --install "${work_dir}/sdk-build"
  printf '%s\n' "${sdk_fingerprint}" > "${sdk_marker}"
}

sdk_resume_files=(
  "${sdk_dir}/lib/libkeystone-eapp.a"
  "${sdk_dir}/lib/libkeystone-edge.a"
  "${sdk_dir}/lib/libkeystone-host.a"
  "${sdk_dir}/include/host/Enclave.hpp"
  "${sdk_dir}/cmake/macros.cmake"
  "${sdk_marker}"
)
sdk_can_resume=1
for sdk_resume_file in "${sdk_resume_files[@]}"; do
  if [[ ! -f "${sdk_resume_file}" ]]; then
    sdk_can_resume=0
    break
  fi
done
if (( sdk_can_resume )) && \
   [[ "$(cat "${sdk_marker}")" != "${sdk_fingerprint}" ]]; then
  sdk_can_resume=0
fi

if (( resume && sdk_can_resume )); then
  # Refresh the installed helper in case a compatibility patch changed it.
  install -m 0644 "${sdk_source_dir}/macros.cmake" \
    "${sdk_dir}/cmake/macros.cmake"
  echo "Reusing freestanding-safe Keystone SDK and refreshing macros.cmake."
else
  if (( resume )); then
    echo "Existing SDK predates the freestanding flags; rebuilding it once."
  fi
  build_sdk
fi

if (( resume )) && \
   [[ -f "${work_dir}/driver-src/keystone-driver.ko" ]] && \
   [[ -f "${driver_marker}" ]] && \
   [[ "$(cat "${driver_marker}")" == "${driver_fingerprint}" ]]; then
  echo "Reusing completed Keystone kernel module."
else
  if (( resume )); then
    echo "Driver inputs changed; rebuilding the Keystone kernel module."
  fi
  make -C "${kernel_build}" \
    M="${work_dir}/driver-src" \
    ARCH=riscv \
    KEYSTONE_SDK_DIR="${sdk_dir}" \
    modules
  printf '%s\n' "${driver_fingerprint}" > "${driver_marker}"
fi

if (( resume )); then
  # VF2's toolchain macro force-writes CMake compiler cache entries. A second
  # configure of the same top-level examples cache makes CMake purge that
  # cache, including KEYSTONE_SDK_DIR. Regenerate only CMake's top-level
  # metadata; compiled objects and ExternalProject downloads remain in place.
  rm -f "${work_dir}/examples-build/CMakeCache.txt"
  rm -rf "${work_dir}/examples-build/CMakeFiles"
  echo "Refreshing the examples CMake cache for resume."
fi

cmake -S "${examples_source_dir}" -B "${work_dir}/examples-build" \
  -G Ninja \
  -DKEYSTONE_SDK_DIR="${sdk_dir}" \
  -DKEYSTONE_BITS=64 \
  -DKEYSTONE_EYRIE_RUNTIME="${source_dir}/runtime" \
  -Dfw_bin="${sm_bin}" \
  -DPATH="${PATH}" \
  -DCMAKE_C_FLAGS="-fno-stack-protector -fno-pie -no-pie" \
  -DCMAKE_ASM_FLAGS="-fno-pie -fno-pic" \
  -DCMAKE_EXE_LINKER_FLAGS="-no-pie -Wl,--build-id=none" \
  -DCMAKE_BUILD_TYPE=Release
cmake --build "${work_dir}/examples-build" --parallel \
  --target hello-package hello-native-package attestor-package test-package

# Ubuntu's GCC defaults to PIE. Without an explicit ASM override, loader.S
# expands `la sp, _estack` through a GOT entry outside the .text-only flat
# binary. The resulting loader reads a zero stack pointer and never reaches
# Eyrie. Reject such payloads before packaging them.
loader_bins=()
while IFS= read -r -d '' loader_bin; do
  loader_bins+=("${loader_bin}")
done < <(find "${work_dir}/examples-build" -type f -name loader.bin -print0)
if (( ${#loader_bins[@]} == 0 )); then
  echo "No Eyrie loader.bin was produced." >&2
  exit 14
fi
for loader_bin in "${loader_bins[@]}"; do
  loader_entry="$(${tool_dir}/riscv64-buildroot-linux-gnu-objdump \
    -D -b binary -m riscv:rv64 "${loader_bin}" | \
    sed -n '/<\.data>:/,+40p')"
  if grep -Eq '[[:space:]]ld[[:space:]]+(sp|a0),' <<<"${loader_entry}"; then
    echo "PIE/GOT-based Eyrie loader rejected: ${loader_bin}" >&2
    printf '%s\n' "${loader_entry}" >&2
    exit 15
  fi
done

# Eyrie's transition deliberately sets stvec to RUNTIME_VA_START before
# enabling the runtime address space. The VF2 linker script therefore expects
# the first runtime instruction at the first LOAD virtual address. Ubuntu's
# GCC enables GNU build IDs by default; the resulting NOTE occupies that
# address and moves _start forward, so the first supervisor trap tries to
# execute the note's namesz word (0x00000004). Reject that layout.
runtime_bins=()
while IFS= read -r -d '' runtime_bin; do
  runtime_bins+=("${runtime_bin}")
done < <(find "${work_dir}/examples-build" -type f \
  -path '*/pkg/eyrie-rt' -print0)
if (( ${#runtime_bins[@]} == 0 )); then
  echo "No packaged Eyrie runtime was produced." >&2
  exit 16
fi
for runtime_bin in "${runtime_bins[@]}"; do
  if readelf -SW "${runtime_bin}" | grep -Fq '.note.gnu.build-id'; then
    echo "GNU build-id shifted the Eyrie runtime entry: ${runtime_bin}" >&2
    exit 17
  fi
  runtime_entry="$(readelf -h "${runtime_bin}" | \
    awk '/Entry point address:/ { print tolower($4); exit }')"
  runtime_load="$(readelf -lW "${runtime_bin}" | \
    awk '$1 == "LOAD" { print tolower($3); exit }')"
  if [[ -z "${runtime_entry}" || -z "${runtime_load}" || \
        "${runtime_entry}" != "${runtime_load}" ]]; then
    echo "Eyrie entry does not equal its first LOAD address: ${runtime_bin}" >&2
    echo "entry=${runtime_entry:-missing} load=${runtime_load:-missing}" >&2
    exit 18
  fi
done

# The build trees are reusable with --resume, but payload staging must always
# be regenerated so files removed or renamed by a newer script cannot leak
# into the release archive.
rm -rf -- "${payload_dir}/rootfs"
rm -f -- "${payload_dir}/install-keystone-payload.sh" \
  "${payload_dir}/PAYLOAD-MANIFEST.txt"

module_dir="${payload_dir}/rootfs/lib/modules/$(uname -r)/extra"
example_dir="${payload_dir}/rootfs/usr/share/keystone/examples"
mkdir -p "${module_dir}" "${example_dir}" \
  "${payload_dir}/rootfs/usr/share/keystone" \
  "${payload_dir}/rootfs/etc/modules-load.d"
install -m 0644 "${work_dir}/driver-src/keystone-driver.ko" \
  "${module_dir}/keystone-driver.ko"
rm -rf "${payload_dir}/rootfs/usr/share/keystone/sdk"
cp -a "${sdk_dir}" "${payload_dir}/rootfs/usr/share/keystone/sdk"
find "${work_dir}/examples-build" -type f -name '*.ke' -exec \
  install -m 0755 '{}' "${example_dir}/" \;
test -x "${example_dir}/hello.ke"
test -x "${example_dir}/hello-native.ke"
test -x "${example_dir}/attestor.ke"
test -x "${example_dir}/tests.ke"
printf '%s\n' keystone-driver > \
  "${payload_dir}/rootfs/etc/modules-load.d/keystone.conf"

cat > "${payload_dir}/install-keystone-payload.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
payload_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
running_kernel="$(uname -r)"
module_source="${payload_dir}/rootfs/lib/modules/${running_kernel}/extra/keystone-driver.ko"

if [[ ! -f "${module_source}" ]]; then
  echo "Payload does not contain a driver for running kernel ${running_kernel}." >&2
  exit 1
fi

# Ubuntu uses merged-/usr, where /lib is a symlink to /usr/lib. Copying the
# synthetic rootfs wholesale would try to replace that symlink with a
# directory. Install each payload subtree into its real destination instead.
sudo install -D -m 0644 "${module_source}" \
  "/lib/modules/${running_kernel}/extra/keystone-driver.ko"
sudo install -D -m 0644 \
  "${payload_dir}/rootfs/etc/modules-load.d/keystone.conf" \
  /etc/modules-load.d/keystone.conf
sudo mkdir -p /usr/share/keystone
# Remove the incorrectly named directory/symlink produced by older payloads,
# then install the canonical plural examples directory as a real directory.
if [[ -L /usr/share/keystone/example || \
      -d /usr/share/keystone/example ]]; then
  sudo rm -rf -- /usr/share/keystone/example
fi
if [[ -L /usr/share/keystone/examples || \
      -d /usr/share/keystone/examples ]]; then
  sudo rm -rf -- /usr/share/keystone/examples
fi
sudo cp -a "${payload_dir}/rootfs/usr/share/keystone/." \
  /usr/share/keystone/
sudo depmod -a
sudo modprobe keystone-driver
test -e /dev/keystone_enclave
echo "Driver loaded and /dev/keystone_enclave exists."
echo "Run /usr/share/keystone/examples/hello.ke for the first enclave test."
EOF
chmod 0755 "${payload_dir}/install-keystone-payload.sh"

cat > "${payload_dir}/PAYLOAD-MANIFEST.txt" <<EOF
board=hifive-premier-p550
kernel=$(uname -r)
keystone_source=its-valentinvp/keystone
keystone_revision=${vf2_revision}
sdk_compat_patch=keystone-vf2-sdk-stdint.patch
sdk_eyrie_cmake_patch=keystone-vf2-sdk-eyrie-cmake-flags.patch
sdk_eyrie_nopie_patch=keystone-vf2-sdk-eyrie-nopie.patch
examples_compat_patch=keystone-vf2-examples-native-gcc.patch
examples_p550_patch=keystone-vf2-examples-p550.patch
driver_cleanup_patch=keystone-vf2-driver-finalize-cleanup.patch
components=linux-keystone-driver,sdk,runtime,examples/hello,examples/hello-native,examples/attestation,examples/tests
official_example_packages=hello.ke,hello-native.ke,attestor.ke,tests.ke
attestation=test-only-known-key-no-device-root-key
attestation_sm_reference=$(basename "${sm_bin}")
attestation_sm_reference_size=0x40000
attestation_sm_reference_sha256=$(sha256sum "${sm_bin}" | awk '{print $1}')
EOF

mkdir -p "${artifact_dir}"
tar --zstd -C "${payload_dir}" -cf \
  "${artifact_dir}/keystone-p550-payload.tar.zst" .
(
  cd "${artifact_dir}"
  sha256sum keystone-p550-payload.tar.zst > \
    keystone-p550-payload.tar.zst.sha256
)

echo "Payload: ${artifact_dir}/keystone-p550-payload.tar.zst"
echo "It is tied to kernel $(uname -r) and Keystone ${vf2_revision}."
