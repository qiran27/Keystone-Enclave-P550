#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
git_cache="${project_dir}/downloads/git2"

mkdir -p "${git_cache}"

seed_repo() {
  local source_name="$1"
  local cache_name="$2"
  local revision="$3"
  local source_repo="${project_dir}/sources/${source_name}"
  local cache_repo="${git_cache}/${cache_name}"
  local cache_ref="refs/heads/keystone-p550-cache/${revision}"

  if [[ ! -d "${source_repo}/.git" ]]; then
    echo "Missing source repository: ${source_repo}" >&2
    echo "Run ./fetch-sources.sh before building." >&2
    exit 2
  fi

  if ! git -C "${source_repo}" cat-file -e "${revision}^{commit}" 2>/dev/null; then
    echo "${source_name} does not contain locked revision ${revision}." >&2
    echo "Run ./fetch-sources.sh and ./scripts/verify-sources.sh again." >&2
    exit 2
  fi

  if [[ ! -e "${cache_repo}" ]]; then
    git clone --quiet --mirror "${source_repo}" "${cache_repo}"
  elif ! git --git-dir="${cache_repo}" rev-parse --is-bare-repository >/dev/null 2>&1; then
    echo "BitBake cache path is not a bare Git repository: ${cache_repo}" >&2
    exit 2
  fi

  if ! git --git-dir="${cache_repo}" cat-file -e "${revision}^{commit}" 2>/dev/null; then
    git --git-dir="${cache_repo}" fetch --quiet --no-tags "${source_repo}" "${revision}"
  fi

  # A fetch by raw object ID only records FETCH_HEAD. That object can later be
  # discarded when BitBake updates or repacks an existing shallow mirror.
  # Keep every pinned revision reachable through a private persistent ref.
  git --git-dir="${cache_repo}" update-ref "${cache_ref}" "${revision}"

  if ! git --git-dir="${cache_repo}" cat-file -e "${revision}^{commit}" 2>/dev/null; then
    echo "Failed to seed ${cache_name} with ${revision}." >&2
    exit 2
  fi

  if [[ "$(git --git-dir="${cache_repo}" rev-parse --verify "${cache_ref}")" != "${revision}" ]]; then
    echo "Failed to pin ${cache_name} cache ref ${cache_ref}." >&2
    exit 2
  fi

  printf 'SEEDED   %-52s %s\n' "${cache_name}" "${revision}"
}

# Cache names follow BitBake's git fetcher convention: host plus a path whose
# slashes are replaced by dots. These are the P550-specific repositories that
# fetch-sources.sh already clones and verifies at locked revisions.
seed_repo u-boot \
  github.com.eswincomputing.u-boot.git \
  6c8f710028e52709b29b70809131509f2edfb1e5
seed_repo nsign \
  github.com.eswincomputing.Esbd-77serial-nsign.git \
  0ec1fc15df7677ec70506cc3ca81c636a335c308
seed_repo opensbi \
  github.com.riscv.opensbi.git \
  bd613dd92113f683052acfb23d9dc8ba60029e0a
seed_repo hifive-premier-p550-tools \
  github.com.sifive.hifive-premier-p550-tools.git \
  5c81fa1ccc38b63d4ef71292d4ff5f971f976f4d
seed_repo hifive-premier-p550-tools \
  github.com.sifive.hifive-premier-p550-tools.git \
  43ec142e5a9d95820b0a06e51863931229e6f71b
seed_repo riscv-linux \
  github.com.sifive.riscv-linux.git \
  3340c5ae8c9d093fdf23ed8c68437846cac893b6
seed_repo yocto-kernel-cache \
  git.yoctoproject.org.yocto-kernel-cache \
  bc26c6c6b91fa0e4de4920544cc4aeeb3dedd894
