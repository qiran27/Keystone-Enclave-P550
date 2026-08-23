#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${project_dir}"

mapfile -t shell_scripts < <(
  find . -path './.git' -prune -o \
    -path './sources' -prune -o \
    -path './build' -prune -o \
    -path './artifacts' -prune -o \
    -type f -name '*.sh' -print | sort
)

for script in "${shell_scripts[@]}"; do
  bash -n "${script}"
done
echo "PASS: bash syntax (${#shell_scripts[@]} scripts)"

git diff --check
git diff --cached --check
echo "PASS: Git whitespace checks"

unexpected=()
while IFS= read -r tracked; do
  case "${tracked}" in
    sources/.gitkeep) ;;
    sources/*|build/*|downloads/*|sstate-cache/*|release-cache/*|\
    artifacts/*|flash/*|.venv/*|tmp/*)
      unexpected+=("${tracked}")
      ;;
  esac
done < <(git ls-files)

if (( ${#unexpected[@]} > 0 )); then
  echo "Generated data or component clones are tracked:" >&2
  printf '  %s\n' "${unexpected[@]}" >&2
  exit 2
fi
echo "PASS: generated directories are not tracked"

while IFS= read -r tracked; do
  tracked_size="$(git cat-file -s ":${tracked}")"
  if (( tracked_size > 2 * 1024 * 1024 )); then
    echo "Unexpectedly large tracked file (${tracked_size} bytes): ${tracked}" >&2
    exit 2
  fi
done < <(git ls-files)
echo "PASS: no tracked file exceeds 2 MiB"

if [[ -d sources/keystone-vf2/.git && -x .venv/bin/python ]]; then
  ./scripts/verify-sources.sh
elif [[ -d sources/keystone-vf2/.git ]]; then
  echo "SKIP: source revision check (project Python environment is absent)"
else
  echo "SKIP: source revision check (sources have not been fetched)"
fi

echo "Project checks passed."
