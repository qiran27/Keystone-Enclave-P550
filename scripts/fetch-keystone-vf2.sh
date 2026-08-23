#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
destination="${project_dir}/sources/keystone-vf2"
url="https://github.com/its-valentinvp/keystone.git"
revision="c5f7ac3977f50309ac816b54f470c4021573bf5e"

mkdir -p "${project_dir}/sources"
if [[ ! -d "${destination}/.git" ]]; then
  git clone --filter=blob:none --no-checkout --branch vf2-support \
    --single-branch "${url}" "${destination}"
fi

git -C "${destination}" remote set-url origin "${url}"
# Ignore host-filesystem executable-bit reporting when a checkout was copied
# through Windows/NTFS; content changes are still detected below.
git -C "${destination}" config core.fileMode false
git -C "${destination}" config core.autocrlf false
if ! git -C "${destination}" cat-file -e "${revision}^{commit}" 2>/dev/null; then
  git -C "${destination}" fetch --no-tags origin "${revision}"
fi

if ! git -C "${destination}" diff --quiet --ignore-space-at-eol || \
   ! git -C "${destination}" diff --cached --quiet || \
   [[ -n "$(git -C "${destination}" ls-files --others --exclude-standard)" ]]; then
  echo "Refusing to change dirty source tree: ${destination}" >&2
  exit 2
fi
git -C "${destination}" checkout --quiet --detach "${revision}"

actual="$(git -C "${destination}" rev-parse HEAD)"
[[ "${actual}" == "${revision}" ]]
echo "Keystone VF2 source ready: ${actual}"
