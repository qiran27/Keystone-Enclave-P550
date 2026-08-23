#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sources_dir="${project_dir}/sources"

if [[ ! -d "${sources_dir}" ]]; then
  echo "Source directory not found: ${sources_dir}" >&2
  exit 2
fi

repo_count=0
while IFS= read -r -d '' git_marker; do
  repo_dir="$(dirname "${git_marker}")"
  echo "Restoring tracked file types and modes: ${repo_dir#${project_dir}/}"

  git -C "${repo_dir}" config core.symlinks true
  git -C "${repo_dir}" config core.fileMode true

  while IFS= read -r -d '' entry; do
    metadata="${entry%%$'\t'*}"
    path="${entry#*$'\t'}"
    mode="${metadata%% *}"
    case "${mode}" in
      100755) [[ ! -e "${repo_dir}/${path}" ]] || chmod 0755 "${repo_dir}/${path}" ;;
      100644) [[ ! -e "${repo_dir}/${path}" ]] || chmod 0644 "${repo_dir}/${path}" ;;
      120000)
        if [[ ! -L "${repo_dir}/${path}" ]]; then
          link_target="$(git -C "${repo_dir}" cat-file -p ":${path}")"
          rm -f -- "${repo_dir}/${path}"
          ln -s -- "${link_target}" "${repo_dir}/${path}"
        fi
        ;;
    esac
  done < <(git -C "${repo_dir}" ls-files --stage -z)

  repo_count=$((repo_count + 1))
done < <(find "${sources_dir}" \( -type d -o -type f \) -name .git -print0)

echo "Restored tracked file modes in ${repo_count} source repositories."
