#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
venv_dir="${KAS_VENV_DIR:-${project_dir}/.venv}"

apt_proxy_args=()
if [[ -n "${http_proxy:-}" ]]; then
  apt_proxy_args+=("-o" "Acquire::http::Proxy=${http_proxy}")
fi
if [[ -n "${https_proxy:-}" ]]; then
  apt_proxy_args+=("-o" "Acquire::https::Proxy=${https_proxy}")
fi

# A host may have foreign architectures registered for other work. Ubuntu's
# normal native mirrors do not publish every foreign-architecture index, so
# refresh only the native architecture without changing dpkg configuration.
native_arch="$(dpkg --print-architecture)"
apt_native_args=("-o" "APT::Architectures::=${native_arch}")

sudo apt-get "${apt_proxy_args[@]}" "${apt_native_args[@]}" update

lz4_package="lz4"
lz4_candidate="$(apt-cache policy "${lz4_package}" | awk '/Candidate:/ { print $2 }')"
if [[ -z "${lz4_candidate}" || "${lz4_candidate}" == "(none)" ]]; then
  # Ubuntu 18.04 publishes the same command-line tools as liblz4-tool.
  lz4_package="liblz4-tool"
fi

sudo apt-get "${apt_proxy_args[@]}" install -y \
  build-essential \
  chrpath \
  cpio \
  debianutils \
  diffstat \
  file \
  gawk \
  gcc \
  git \
  iputils-ping \
  locales \
  "${lz4_package}" \
  python3 \
  python3-git \
  python3-jinja2 \
  python3-pexpect \
  python3-pip \
  python3-subunit \
  python3-venv \
  socat \
  texinfo \
  unzip \
  wget \
  xz-utils \
  zstd

if ! locale -a | grep -qi '^en_US\.utf8$'; then
  sudo locale-gen en_US.UTF-8
fi

python_bin="${PYTHON_BIN:-}"
if [[ -z "${python_bin}" ]]; then
  for candidate in python3.13 python3.12 python3.11 python3.10 python3.9 python3; do
    if command -v "${candidate}" >/dev/null 2>&1 && \
       "${candidate}" -c 'import sqlite3, sys, venv; raise SystemExit(sys.version_info < (3, 9))' >/dev/null 2>&1; then
      python_bin="$(command -v "${candidate}")"
      break
    fi
  done
fi

if [[ -z "${python_bin}" ]] || \
   ! "${python_bin}" -c 'import sqlite3, sys, venv; raise SystemExit(sys.version_info < (3, 9))' >/dev/null 2>&1; then
  echo "kas 5.4 requires a complete Python 3.9 or newer installation." >&2
  echo "Set PYTHON_BIN to that interpreter, or use Ubuntu 22.04/24.04." >&2
  exit 3
fi

"${python_bin}" -m venv --clear "${venv_dir}"
"${venv_dir}/bin/pip" install --upgrade pip
"${venv_dir}/bin/pip" install --upgrade 'kas==5.4'

echo "Ubuntu build dependencies are ready; kas is installed in ${venv_dir}."
