#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 PATH-TO-p550-offline-deps-bundle.tar.gz" >&2
}

if [[ "$(uname -m)" != "riscv64" ]]; then
  echo "Run this script on the HiFive Premier P550 (riscv64)." >&2
  exit 2
fi
if (( $# != 1 )); then
  usage
  exit 3
fi
bundle_archive="$(readlink -f "$1")"
if [[ ! -f "${bundle_archive}" ]]; then
  echo "Bundle archive not found: ${bundle_archive}" >&2
  exit 4
fi

temp_dir="$(mktemp -d)"
trap 'rm -rf "${temp_dir}"' EXIT
tar -xzf "${bundle_archive}" -C "${temp_dir}"
bundle_dir="$(find "${temp_dir}" -type f -name SHA256SUMS -printf '%h\n' -quit)"
if [[ -z "${bundle_dir}" ]]; then
  echo "SHA256SUMS is missing from the dependency bundle." >&2
  exit 5
fi

(
  cd "${bundle_dir}"
  sha256sum -c SHA256SUMS
)
mapfile -d '' debs < <(find "${bundle_dir}/packages" -maxdepth 1 \
  -type f -name '*.deb' -print0 | sort -z)
if (( ${#debs[@]} == 0 )); then
  echo "No .deb packages found in the dependency bundle." >&2
  exit 6
fi

# The request generator already resolved the exact dependency closure from the
# target's own dpkg state. Install that locked closure directly: apt may prefer
# newer candidates from its stale repository indexes even when every requested
# .deb is local, which makes --no-download fail without naming an archive.
if ! sudo dpkg --install "${debs[@]}"; then
  echo "Offline package installation failed; dpkg audit follows:" >&2
  sudo dpkg --audit >&2 || true
  echo "Do not run apt-get -f install while the board is offline." >&2
  exit 8
fi

for command_name in ar as cmake gcc g++ ld make makeself ninja objcopy objdump tar zstd; do
  command -v "${command_name}" >/dev/null 2>&1 || {
    echo "Dependency installation completed but ${command_name} is still missing." >&2
    exit 7
  }
done
test -e "/lib/modules/$(uname -r)/build/Makefile"
echo "P550 offline build dependencies are installed."
