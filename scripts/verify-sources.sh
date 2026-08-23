#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python_bin="${project_dir}/.venv/bin/python"

if [[ ! -x "${python_bin}" ]]; then
  echo "Project Python environment not found. Run ./scripts/install-ubuntu-deps.sh first." >&2
  exit 2
fi

exec "${python_bin}" "${project_dir}/scripts/source-lock.py" verify
