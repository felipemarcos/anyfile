#!/bin/zsh
# Starts a release: tags the current commit as v<version> and pushes the tag.
# GitHub Actions (.github/workflows/release.yml) then builds, signs the update and publishes it.
# Usage: Scripts/release.sh <version> ["Short summary for the tag"]
set -euo pipefail

VERSION="${1:?usage: release.sh <version> [summary]}"
SUMMARY="${2:-AnyFile $VERSION}"
TAG="v$VERSION"

[[ "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo "error: version must look like 1.2.3" >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "error: commit or stash your changes first" >&2; exit 1; }
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && { echo "error: $TAG already exists" >&2; exit 1; }

LAST=$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)
if [[ -n "$LAST" ]]; then
  # Refuse to go backwards: Sparkle only offers higher versions.
  HIGHEST=$(printf '%s\n%s\n' "${LAST#v}" "$VERSION" | sort -V | tail -1)
  [[ "$HIGHEST" == "$VERSION" && "${LAST#v}" != "$VERSION" ]] || { echo "error: $VERSION is not newer than $LAST" >&2; exit 1; }
  echo "Changes since $LAST:"
  git log --oneline "$LAST"..HEAD
fi

git push origin HEAD
git tag -a "$TAG" -m "$SUMMARY"
git push origin "$TAG"
echo "Pushed $TAG. Follow the build with: gh run watch"
