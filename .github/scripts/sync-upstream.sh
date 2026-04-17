#!/usr/bin/env bash
# Sync fork from upstream: only changed paths (not .github/ or README.md).
# Writes step outputs to GITHUB_OUTPUT (GitHub Actions).
set -euo pipefail

: "${GITHUB_OUTPUT:?}"

UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/Auxilor/eco.git}"

git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git config user.name "github-actions[bot]"

git remote add upstream "$UPSTREAM_URL" 2>/dev/null || true
git fetch origin --tags
git fetch upstream --tags

DEFAULT_BRANCH="$(git symbolic-ref refs/remotes/origin/HEAD | sed 's@^refs/remotes/origin/@@')"
echo "default_branch=$DEFAULT_BRANCH" >> "$GITHUB_OUTPUT"

UPSTREAM_DEFAULT="$(git ls-remote --symref upstream HEAD | awk '/^ref:/ {sub(/^refs\/heads\//, "", $2); print $2; exit}')"
if [ -z "${UPSTREAM_DEFAULT}" ]; then
  echo "Could not detect upstream default branch."
  exit 1
fi
echo "upstream_default=$UPSTREAM_DEFAULT" >> "$GITHUB_OUTPUT"

NEW_SHA="$(git rev-parse "upstream/${UPSTREAM_DEFAULT}")"
echo "upstream_sha=$NEW_SHA" >> "$GITHUB_OUTPUT"

SYNC_CONTENT="$(git show "origin/${DEFAULT_BRANCH}:.upstream-sync" 2>/dev/null || true)"
OLD_SHA="$(printf '%s\n' "$SYNC_CONTENT" | grep '^UPSTREAM_SHA=' | head -1 | cut -d= -f2- | tr -d '\r' | tr -d ' ')"

OLD_VER="$(git show "origin/${DEFAULT_BRANCH}:gradle.properties" 2>/dev/null | grep -E '^version[[:space:]]*=' | head -1 | sed 's/^[^=]*=[[:space:]]*//;s/[[:space:]]*$//;s/#.*//' || true)"

if [ -n "$OLD_SHA" ] && [ "$OLD_SHA" = "$NEW_SHA" ]; then
  echo "Upstream unchanged ($NEW_SHA). Skipping."
  echo "has_update=false" >> "$GITHUB_OUTPUT"
  echo "run_build=false" >> "$GITHUB_OUTPUT"
  exit 0
fi

if [ -n "$OLD_SHA" ] && ! git cat-file -e "${OLD_SHA}^{commit}" 2>/dev/null; then
  echo "Warning: stored UPSTREAM_SHA is missing from history; doing full tree sync from upstream."
  OLD_SHA=""
fi

FORK_SHA="$(git rev-parse "origin/${DEFAULT_BRANCH}")"
git checkout -B "$DEFAULT_BRANCH" "origin/${DEFAULT_BRANCH}"

DELTA_NONPROTECTED=0
if [ -z "$OLD_SHA" ]; then
  echo "No prior upstream pointer: syncing all upstream files (except .github and README.md)."
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    case "$f" in .github/*|.github|README.md) continue ;; esac
    DELTA_NONPROTECTED=$((DELTA_NONPROTECTED + 1))
    git checkout "$NEW_SHA" -- "$f"
  done < <(git ls-tree -r --name-only "$NEW_SHA")
else
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    case "$f" in .github/*|.github|README.md) continue ;; esac
    DELTA_NONPROTECTED=$((DELTA_NONPROTECTED + 1))
  done < <(git diff --name-only "$OLD_SHA" "$NEW_SHA")
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    case "$f" in .github/*|.github|README.md) continue ;; esac
    git rm -f --ignore-unmatch -- "$f" 2>/dev/null || true
  done < <(git diff --diff-filter=D --name-only "$OLD_SHA" "$NEW_SHA")
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    case "$f" in .github/*|.github|README.md) continue ;; esac
    git checkout "$NEW_SHA" -- "$f"
  done < <(git diff --diff-filter=d --name-only "$OLD_SHA" "$NEW_SHA")
fi

git checkout "$FORK_SHA" -- .github README.md

if [ "$DELTA_NONPROTECTED" -eq 0 ] && [ -n "$OLD_SHA" ]; then
  echo "Upstream moved but only .github/README (or skipped paths) changed; advancing pointer without build."
  echo "UPSTREAM_SHA=$NEW_SHA" > .upstream-sync
  echo "has_update=pointer" >> "$GITHUB_OUTPUT"
  echo "run_build=false" >> "$GITHUB_OUTPUT"
  exit 0
fi

PV="$(grep -E '^version[[:space:]]*=' gradle.properties | head -1 | sed 's/^[^=]*=[[:space:]]*//;s/[[:space:]]*$//;s/#.*//')"
if [ -z "$PV" ]; then
  echo "Could not read version from gradle.properties."
  exit 1
fi
echo "gradle_version=$PV" >> "$GITHUB_OUTPUT"

# Upstream uses bare semver tags (e.g. 7.2.2). We use v7.2.2 for releases but must avoid
# clobbering an existing v7.2.2 on origin (rerun, manual release, or duplicate workflow).
tag_exists() {
  local name="$1"
  if git rev-parse "$name^{}" >/dev/null 2>&1; then
    return 0
  fi
  if git ls-remote --tags origin "refs/tags/$name" 2>/dev/null | grep -q .; then
    return 0
  fi
  return 1
}

next_rebuild_suffix() {
  local pv="$1"
  local max_r=0
  local t n
  for t in $(git tag -l "v${pv}-rebuild-*"); do
    n="${t##*-rebuild-}"
    case "$n" in ''|*[!0-9]*) continue ;; esac
    if [ "$n" -gt "$max_r" ]; then max_r="$n"; fi
  done
  echo $((max_r + 1))
}

if [ -z "$OLD_VER" ] || [ "$PV" != "$OLD_VER" ]; then
  if tag_exists "v${PV}"; then
    NEXT_R="$(next_rebuild_suffix "$PV")"
    TAG_NAME="v${PV}-rebuild-${NEXT_R}"
    RELEASE_NAME="${PV} (Re-Build-${NEXT_R})"
    KIND="rebuild"
    echo "Note: tag v${PV} already exists; using ${TAG_NAME} for this release."
  else
    TAG_NAME="v${PV}"
    RELEASE_NAME="${PV} (Auto Build)"
    KIND="auto"
  fi
else
  NEXT_R="$(next_rebuild_suffix "$PV")"
  TAG_NAME="v${PV}-rebuild-${NEXT_R}"
  RELEASE_NAME="${PV} (Re-Build-${NEXT_R})"
  KIND="rebuild"
fi

echo "tag_name=$TAG_NAME" >> "$GITHUB_OUTPUT"
echo "release_name=$RELEASE_NAME" >> "$GITHUB_OUTPUT"
echo "build_kind=$KIND" >> "$GITHUB_OUTPUT"
echo "has_update=true" >> "$GITHUB_OUTPUT"
echo "run_build=true" >> "$GITHUB_OUTPUT"

echo "UPSTREAM_SHA=$NEW_SHA" > .upstream-sync
