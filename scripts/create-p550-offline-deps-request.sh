#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_dir="${project_dir}/artifacts/offline-deps"
request_dir="${output_dir}/p550-offline-deps-request"
request_archive="${output_dir}/p550-offline-deps-request.tar.gz"
apt_plan="${request_dir}/apt-plan.txt"
url_list="${request_dir}/urls.txt"

if [[ "$(uname -m)" != "riscv64" ]]; then
  echo "Run this script on the HiFive Premier P550 (riscv64)." >&2
  exit 2
fi

if [[ ! -d "/lib/modules/$(uname -r)/build" ]]; then
  echo "Missing exact kernel headers: /lib/modules/$(uname -r)/build" >&2
  echo "The vendor header package must be obtained before building the driver." >&2
  exit 3
fi

rm -rf "${request_dir}"
mkdir -p "${request_dir}"

packages=(
  build-essential
  cmake
  git
  makeself
  ninja-build
  zstd
  "linux-headers-$(uname -r)"
)

cat > "${request_dir}/REQUEST-MANIFEST.txt" <<EOF
board=hifive-premier-p550
architecture=$(uname -m)
kernel=$(uname -r)
packages=${packages[*]}
EOF

# Do not update package indexes here: the board is intentionally offline.
# --print-uris lets the target's own dpkg/apt state choose the exact missing
# riscv64 dependency closure without downloading or installing anything.
sudo apt-get --print-uris --yes --no-install-recommends install \
  "${packages[@]}" | tee "${apt_plan}"

sed -n "s/^'\(https\{0,1\}:\/\/[^']*\)'.*/\1/p" \
  "${apt_plan}" | sort -u > "${url_list}"

if [[ ! -s "${url_list}" ]]; then
  missing=0
  for command_name in ar as cmake gcc g++ ld make makeself ninja objcopy objdump tar zstd; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
      echo "Missing ${command_name}, but apt produced no download URL." >&2
      missing=1
    fi
  done
  if (( missing )); then
    echo "The board's cached Ubuntu package indexes are missing or too old." >&2
    echo "Temporarily provide package indexes/network, then create the request again." >&2
    exit 4
  fi
  echo "All required build tools are already installed; no offline bundle is needed."
  exit 0
fi

tar -C "${output_dir}" -czf "${request_archive}" \
  "$(basename "${request_dir}")"

echo "Offline dependency request: ${request_archive}"
echo "Copy it to the networked Ubuntu build VM."
