#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kas_bin="${KAS_BIN:-${project_dir}/.venv/bin/kas}"

if [[ ! -x "${kas_bin}" ]] && command -v kas >/dev/null 2>&1; then
  kas_bin="$(command -v kas)"
fi

if [[ ! -x "${kas_bin}" ]] && [[ -x "${HOME}/.venvs/keystone-p550-kas/bin/kas" ]]; then
  kas_bin="${HOME}/.venvs/keystone-p550-kas/bin/kas"
fi

if [[ ! -x "${kas_bin}" ]]; then
  echo "kas was not found at ${kas_bin} or in PATH. Set KAS_BIN to the kas executable." >&2
  exit 2
fi

export PATH="$(dirname "${kas_bin}"):${PATH}"
export KAS_WORK_DIR="${project_dir}/sources"
export KAS_BUILD_DIR="${KAS_BUILD_DIR:-${project_dir}/build}"
cache_root="$(dirname "${KAS_BUILD_DIR}")"

mkdir -p "${KAS_BUILD_DIR}" "${cache_root}/downloads" "${cache_root}/sstate-cache"

command_name="${1:-build}"
if [[ $# -gt 0 ]]; then
  shift
fi

prepare_download_cache() {
  # Local-source recipes below meta-keystone-p550 rely on these exact locked
  # revisions, so refuse to fetch or build from an unverified working tree.
  "${project_dir}/scripts/verify-sources.sh"
  "${project_dir}/scripts/seed-bitbake-git-cache.sh"
}

fetch_all_sources() {
  local max_attempts="${P550_FETCH_ATTEMPTS:-3}"
  local attempt
  local status

  if [[ ! "${max_attempts}" =~ ^[1-9][0-9]*$ ]]; then
    echo "P550_FETCH_ATTEMPTS must be a positive integer, got: ${max_attempts}" >&2
    return 2
  fi

  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    echo "Source preflight: attempt ${attempt}/${max_attempts}"
    if "${kas_bin}" shell "${project_dir}/kas/p550-keystone.yml" \
      -c "bitbake --runall=fetch bootchain"; then
      echo "Source preflight completed: the bootchain task graph is cached."
      return 0
    else
      status=$?
    fi

    # Preserve the conventional interrupted-command status instead of
    # unexpectedly restarting a fetch that the user deliberately stopped.
    if [[ "${status}" -eq 130 ]]; then
      return "${status}"
    fi

    if [[ "${attempt}" -lt "${max_attempts}" ]]; then
      echo "Source preflight failed; retrying remaining downloads in 5 seconds." >&2
      sleep 5
    fi
  done

  echo "Source preflight failed after ${max_attempts} attempts; compilation was not started." >&2
  return "${status}"
}

case "${command_name}" in
  fetch)
    prepare_download_cache
    fetch_all_sources
    exit $?
    ;;
  build)
    prepare_download_cache
    fetch_all_sources
    ;;
esac

exec "${kas_bin}" "${command_name}" "${project_dir}/kas/p550-keystone.yml" "$@"
