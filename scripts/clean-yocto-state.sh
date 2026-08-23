#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
apply=0
assume_yes=0

for argument in "$@"; do
  case "${argument}" in
    --apply) apply=1 ;;
    --yes) assume_yes=1 ;;
    *)
      echo "Usage: ./scripts/clean-yocto-state.sh [--apply [--yes]]" >&2
      exit 2
      ;;
  esac
done

if [[ ! -f "${project_dir}/sources.lock.yml" || ! -f "${project_dir}/README.md" ]]; then
  echo "Project identity check failed: ${project_dir}" >&2
  exit 2
fi

targets=(
  "${project_dir}/build"
  "${project_dir}/sstate-cache"
  "${project_dir}/downloads"
  "${project_dir}/build.log"
  "${project_dir}/fetch.log"
)

echo "Obsolete full-image Yocto state below ${project_dir}:"
for target in "${targets[@]}"; do
  if [[ -e "${target}" ]]; then
    du -sh -- "${target}" 2>/dev/null || printf 'present  %s\n' "${target}"
  else
    printf 'absent   %s\n' "${target}"
  fi
done

cat <<EOF

Preserved:
  ${project_dir}/sources
  ${project_dir}/.venv
  ${project_dir}/release-cache
  all project scripts, metadata and documentation
EOF

if (( apply == 0 )); then
  echo
  echo "Dry run only. Re-run with --apply to remove the listed paths."
  exit 0
fi

if (( assume_yes == 0 )); then
  echo
  read -r -p "Type DELETE-YOCTO-STATE to continue: " answer
  if [[ "${answer}" != "DELETE-YOCTO-STATE" ]]; then
    echo "Cleanup cancelled."
    exit 1
  fi
fi

for target in "${targets[@]}"; do
  case "${target}" in
    "${project_dir}/build"|"${project_dir}/sstate-cache"|\
    "${project_dir}/downloads"|"${project_dir}/build.log"|\
    "${project_dir}/fetch.log")
      rm -rf -- "${target}"
      ;;
    *)
      echo "Refusing unexpected cleanup target: ${target}" >&2
      exit 2
      ;;
  esac
done

echo "Obsolete Yocto state removed."
df -h "${project_dir}"
