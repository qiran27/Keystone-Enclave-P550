#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python_bin="${project_dir}/.venv/bin/python"

if [[ ! -x "${python_bin}" ]]; then
  echo "Project Python environment not found. Run ./scripts/install-ubuntu-deps.sh first." >&2
  exit 2
fi

mkdir -p "${project_dir}/sources"

# Repair repositories copied through filesystems that did not preserve Unix
# modes or symlinks. On a fresh Linux clone this is a harmless no-op.
"${project_dir}/scripts/restore-source-modes.sh"

# kas owns the official Freedom-U-SDK/OE layer repositories.
"${project_dir}/scripts/kas-build.sh" checkout

"${project_dir}/scripts/restore-source-modes.sh"

# Fetch the additional board and Keystone repositories pinned in the lock file.
"${python_bin}" "${project_dir}/scripts/source-lock.py" fetch "$@"

"${project_dir}/scripts/restore-source-modes.sh"
"${python_bin}" "${project_dir}/scripts/source-lock.py" verify
