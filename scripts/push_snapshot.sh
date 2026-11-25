#!/bin/bash
# Push a source-only snapshot of the working tree to a remote branch.
#
# The local repository keeps its full history (including build artifacts that
# were committed years ago), while the remote receives a small tree without
# .build*/.derived-* directories, review captures, marketing/video assets or
# submodules. This keeps the first/next push under GitHub's 2 GB limit.
#
# Usage: scripts/push_snapshot.sh [remote] [branch]
set -euo pipefail
cd "$(dirname "$0")/.."

REMOTE="${1:-origin}"
BRANCH="${2:-main}"
INDEX_FILE="$(mktemp -t pocketccd-snapshot-index)"
trap 'rm -f "$INDEX_FILE"' EXIT
export GIT_INDEX_FILE="$INDEX_FILE"

git read-tree --empty
git add -- ./*.swift .gitignore README.md AGENTS.md Info.plist PocketCCD.entitlements \
  PrivacyInfo.xcprivacy InfoPlist.xcstrings Localizable.xcstrings \
  PocketCCD.xcodeproj/project.pbxproj PocketCCD.xcodeproj/xcshareddata \
  Assets.xcassets docs scripts Research calibration brand \
  ':!**/.DS_Store'

TREE=$(git write-tree)
git fetch --quiet "$REMOTE" "$BRANCH" 2>/dev/null || true
PARENT=()
if git rev-parse --verify --quiet FETCH_HEAD >/dev/null; then
  PARENT=(-p "$(git rev-parse FETCH_HEAD)")
fi
COMMIT=$(git commit-tree "$TREE" "${PARENT[@]}" \
  -m "Source snapshot: $(date +%Y-%m-%d %H:%M)")
git push "$REMOTE" "$COMMIT:refs/heads/$BRANCH"
echo "Pushed source snapshot $COMMIT to $REMOTE/$BRANCH"
