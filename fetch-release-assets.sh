#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python_bin="${project_dir}/.venv/bin/python"
asset_lock="${project_dir}/release-assets.lock.yml"
asset_cache="${P550_RELEASE_CACHE:-${project_dir}/release-cache}"
selection="${1:-all}"

case "${selection}" in
  all|ubuntu|bootloader) ;;
  *)
    echo "Usage: ./fetch-release-assets.sh [all|ubuntu|bootloader]" >&2
    exit 2
    ;;
esac

if [[ ! -x "${python_bin}" ]]; then
  echo "Project Python environment not found. Run ./scripts/install-ubuntu-deps.sh first." >&2
  exit 2
fi

mapfile -t release_info < <(
  "${python_bin}" - "${asset_lock}" "${selection}" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as stream:
    lock = yaml.safe_load(stream)

selection = sys.argv[2]
print(lock["release"])
for name, asset in lock["assets"].items():
    if selection not in ("all", name):
        continue
    print("\t".join((
        name,
        asset["filename"],
        asset["url"],
        asset["sha256"],
        str(asset["size"]),
    )))
PY
)

if (( ${#release_info[@]} < 2 )); then
  echo "No assets selected from ${asset_lock}." >&2
  exit 2
fi

release="${release_info[0]}"
destination_dir="${asset_cache}/${release}"
mkdir -p "${destination_dir}"

for row in "${release_info[@]:1}"; do
  IFS=$'\t' read -r name filename url expected_sha256 expected_size <<<"${row}"
  destination="${destination_dir}/${filename}"

  if [[ -f "${destination}" ]] && \
     printf '%s  %s\n' "${expected_sha256}" "${destination}" | sha256sum --check --status && \
     [[ "$(stat --format=%s "${destination}")" == "${expected_size}" ]]; then
    printf 'CACHED   %-12s %s\n' "${name}" "${destination}"
    continue
  fi

  temporary="${destination}.download.$$"
  rm -f -- "${temporary}"
  echo "FETCH    ${name} <- ${url}"
  if ! wget --timeout=120 --tries=5 --retry-connrefused \
      -O "${temporary}" "${url}"; then
    rm -f -- "${temporary}"
    exit 2
  fi

  if ! printf '%s  %s\n' "${expected_sha256}" "${temporary}" | \
       sha256sum --check --status; then
    rm -f -- "${temporary}"
    echo "Checksum verification failed for ${filename}." >&2
    exit 2
  fi
  if [[ "$(stat --format=%s "${temporary}")" != "${expected_size}" ]]; then
    rm -f -- "${temporary}"
    echo "Size verification failed for ${filename}." >&2
    exit 2
  fi

  mv -- "${temporary}" "${destination}"
  printf 'VERIFIED %-12s %s\n' "${name}" "${destination}"
done
