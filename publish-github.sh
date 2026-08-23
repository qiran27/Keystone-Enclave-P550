#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${project_dir}"

usage() {
  cat <<'EOF'
Usage:
  ./publish-github.sh prepare
  ./publish-github.sh publish [GITHUB_REPOSITORY_URL] [REMOTE_BRANCH]

Examples:
  ./publish-github.sh prepare
  ./publish-github.sh publish https://github.com/USER/keystone-p550-system.git main

The script stages only the reproducibility metadata, integration layer,
documentation and helper scripts. It never stages sources, build output,
download caches, sstate, virtual environments or arbitrary root files.
EOF
}

mode="${1:-prepare}"
if [[ "${mode}" != "prepare" && "${mode}" != "publish" ]]; then
  usage >&2
  exit 2
fi

if [[ ! -d .git ]]; then
  echo "Not a Git repository: ${project_dir}" >&2
  exit 2
fi

required_paths=(
  .gitattributes
  .gitignore
  README.md
  PORTING-REPORT.md
  sources.lock.yml
  release-assets.lock.yml
  docs
  kas
  meta-keystone-p550
  scripts
  fetch-sources.sh
  fetch-release-assets.sh
  prepare-flash-assets.sh
  publish-github.sh
  publish-release-assets.sh
  scripts/check-project.sh
  sources/.gitkeep
)

for path in "${required_paths[@]}"; do
  if [[ ! -e "${path}" ]]; then
    echo "Required publish path is missing: ${path}" >&2
    exit 2
  fi
done

# The allowlist prevents local notes and generated artifacts from being added
# by a broad `git add .` command.
git add -A -- "${required_paths[@]}"

# This helper belonged to the retired full-rootfs workflow. Remove a stale
# staged copy when upgrading a repository that had already prepared it.
git rm --cached --ignore-unmatch -q -- prefetch-build-sources.sh

git update-index --chmod=+x \
  fetch-sources.sh \
  fetch-release-assets.sh \
  prepare-flash-assets.sh \
  publish-github.sh \
  publish-release-assets.sh
while IFS= read -r -d '' script; do
  git update-index --chmod=+x "${script#./}"
done < <(find scripts -maxdepth 1 -type f -name '*.sh' -print0)

git update-index --chmod=-x scripts/source-lock.py
./scripts/check-project.sh

while IFS= read -r staged_file; do
  staged_size="$(git cat-file -s ":${staged_file}")"
  if (( staged_size > 2 * 1024 * 1024 )); then
    echo "Refusing to publish unexpectedly large source file (${staged_size} bytes):" >&2
    echo "  ${staged_file}" >&2
    exit 2
  fi
done < <(git diff --cached --name-only --diff-filter=ACMR)

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
  echo "Refusing to publish generated or embedded source files:" >&2
  printf '  %s\n' "${unexpected[@]}" >&2
  echo "Remove them from the Git index before publishing." >&2
  exit 2
fi

echo "Files prepared for publication:"
git --no-pager diff --cached --name-status
echo
git --no-pager diff --cached --stat

if [[ "${mode}" == "prepare" ]]; then
  echo
  echo "Preparation complete. Review with: git diff --cached"
  echo "Publish later with: ./publish-github.sh publish [URL] [BRANCH]"
  exit 0
fi

remote_url="${2:-}"
remote_branch="${3:-$(git branch --show-current)}"
remote_branch="${remote_branch:-main}"

if existing_url="$(git remote get-url origin 2>/dev/null)"; then
  if [[ -n "${remote_url}" && "${remote_url}" != "${existing_url}" ]]; then
    echo "origin already points to a different URL; refusing to replace it." >&2
    exit 2
  fi
else
  if [[ -z "${remote_url}" ]]; then
    echo "No origin remote exists. Pass the GitHub repository URL." >&2
    exit 2
  fi
  git remote add origin "${remote_url}"
fi

echo
echo "Target: origin, branch ${remote_branch}"
if [[ "${PUBLISH_ASSUME_YES:-0}" != "1" ]]; then
  read -r -p "Type 'yes' to commit and push the staged allowlist: " answer
  if [[ "${answer}" != "yes" ]]; then
    echo "Publish cancelled. Staged files were left unchanged."
    exit 1
  fi
fi

if ! git diff --cached --quiet; then
  git commit -m "${PUBLISH_COMMIT_MESSAGE:-Add hybrid Ubuntu and Keystone P550 project}"
fi

if ! git rev-parse --verify HEAD >/dev/null 2>&1; then
  echo "There is no commit to publish." >&2
  exit 2
fi

git push -u origin "HEAD:${remote_branch}"
echo "Published successfully to origin/${remote_branch}."
