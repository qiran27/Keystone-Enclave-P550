#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_dir="${project_dir}/artifacts/offline-deps"
bundle_dir="${output_dir}/p550-offline-deps-bundle"
bundle_archive="${output_dir}/p550-offline-deps-bundle.tar.gz"
# The official 2025.11.00 P550 image was composed from the Ubuntu archive in
# November 2025. Normal -updates pockets remove superseded binaries; Ubuntu's
# official snapshot service preserves that historical dependency set.
ubuntu_snapshot="${P550_UBUNTU_SNAPSHOT:-20251115T000000Z}"

usage() {
  echo "Usage: $0 PATH-TO-p550-offline-deps-request.tar.gz" >&2
}

if (( $# != 1 )); then
  usage
  exit 2
fi
request_archive="$(readlink -f "$1")"
if [[ ! -f "${request_archive}" ]]; then
  echo "Request archive not found: ${request_archive}" >&2
  exit 3
fi
for command_name in dpkg-deb sha256sum tar wget; do
  command -v "${command_name}" >/dev/null 2>&1 || {
    echo "Missing host command: ${command_name}" >&2
    exit 4
  }
done

temp_dir="$(mktemp -d)"
trap 'rm -rf "${temp_dir}"' EXIT
tar -xzf "${request_archive}" -C "${temp_dir}"
url_list="$(find "${temp_dir}" -type f -name urls.txt -print -quit)"
manifest="$(find "${temp_dir}" -type f -name REQUEST-MANIFEST.txt -print -quit)"
if [[ -z "${url_list}" || ! -s "${url_list}" ]]; then
  echo "The request contains no package URLs." >&2
  exit 5
fi

rm -rf "${bundle_dir}"
mkdir -p "${bundle_dir}/packages"
[[ -n "${manifest}" ]] && cp "${manifest}" "${bundle_dir}/"

while IFS= read -r package_url; do
  [[ -n "${package_url}" ]] || continue
  package_name="$(basename "${package_url%%\?*}")"
  package_path="${bundle_dir}/packages/${package_name}"
  case "${package_url}" in
    http://ports.ubuntu.com/ubuntu-ports/*|https://ports.ubuntu.com/ubuntu-ports/*)
      archive_path="${package_url#*://ports.ubuntu.com/ubuntu-ports/}"
      snapshot_url="https://snapshot.ubuntu.com/ubuntu/${ubuntu_snapshot}/${archive_path}"
      echo "Fetching ${package_name} from Ubuntu snapshot ${ubuntu_snapshot}."
      if ! wget --continue --directory-prefix="${bundle_dir}/packages" \
          "${snapshot_url}"; then
        rm -f "${package_path}"
        echo "Snapshot lookup failed; trying the live Ubuntu ports archive."
        wget --continue --directory-prefix="${bundle_dir}/packages" \
          "${package_url}"
      fi
      ;;
    *)
      wget --continue --directory-prefix="${bundle_dir}/packages" \
        "${package_url}"
      ;;
  esac
done < "${url_list}"

shopt -s nullglob
debs=("${bundle_dir}/packages/"*.deb)
if (( ${#debs[@]} == 0 )); then
  echo "No .deb packages were downloaded." >&2
  exit 6
fi

for deb in "${debs[@]}"; do
  arch="$(dpkg-deb -f "${deb}" Architecture)"
  if [[ "${arch}" != "riscv64" && "${arch}" != "all" ]]; then
    echo "Unexpected package architecture ${arch}: ${deb}" >&2
    exit 7
  fi
done

(
  cd "${bundle_dir}"
  sha256sum packages/*.deb > SHA256SUMS
)
tar -C "${output_dir}" -czf "${bundle_archive}" \
  "$(basename "${bundle_dir}")"

echo "Offline dependency bundle: ${bundle_archive}"
echo "Copy it back to the P550 board."
