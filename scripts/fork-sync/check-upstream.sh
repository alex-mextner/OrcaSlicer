#!/usr/bin/env bash
# Timer entry point (snap-orca-sync.timer): when Snapmaker publishes a new stable release, start a
# headless omp session that merges it into the fork, builds, tests and publishes a Linux release
# (scripts/fork-sync/release.sh). Cheap no-op when there is nothing new.
#
#   scripts/fork-sync/check-upstream.sh [--force <tag>]
set -euo pipefail

ROOT=$(git -C "$(dirname "$(readlink -f "$0")")" rev-parse --show-toplevel)
STATE=${XDG_STATE_HOME:-$HOME/.local/state}/snap-orca-sync
FORK_REPO=${FORK_REPO:-alex-mextner/SnapOrca}
BRANCH=${BRANCH:-ubuntu-26.04}
mkdir -p "$STATE/logs"

exec 9>"$STATE/lock"
flock -n 9 || { echo "another sync is running"; exit 0; }

notify() { notify-send --app-name "Snapmaker Orca sync" "$1" "$2" 2>/dev/null || true; echo "$1: $2"; }

if [[ ${1:-} == --force ]]; then
    tag=${2:?--force needs a tag}
else
    tag=$(gh api repos/Snapmaker/OrcaSlicer/releases/latest --jq .tag_name)
fi
[[ -n "$tag" ]] || exit 0

cd "$ROOT"
git fetch -q --no-tags https://github.com/Snapmaker/OrcaSlicer.git "+refs/tags/$tag:refs/tags/$tag"
git fetch -q fork "$BRANCH" --tags
# Done only when the latest fork release contains the tag: release.sh pushes the merge before it
# publishes, so a merged-but-unpublished tag must be retried (release.sh skips the merge then).
published() {
    local latest
    latest=$(gh release view --repo "$FORK_REPO" --json tagName --jq .tagName 2>/dev/null || true)
    [[ -n "$latest" ]] && git rev-parse -q --verify "refs/tags/$latest" >/dev/null &&
        git merge-base --is-ancestor "$tag" "$latest" && echo "$latest"
}
if published >/dev/null; then
    exit 0
fi
if [[ ${1:-} != --force && "$(cat "$STATE/failed" 2>/dev/null)" == "$tag" ]]; then
    exit 0 # failed before; needs a human (or --force) to retry
fi

log="$STATE/logs/$(date +%F-%H%M%S)-$tag.log"
notify "New Snapmaker release $tag" "Merging into the fork and building a Linux release (log: $log)"

prompt=$(sed "s/{{TAG}}/$tag/g; s#{{LOG_DIR}}#$STATE/logs#g" "$ROOT/scripts/fork-sync/omp-prompt.md")
# --advisor: a second model reviews each turn of the unattended merge/fix session.
omp -p --no-session --no-title --auto-approve --advisor --max-time 6h --cwd "$ROOT" "$prompt" >"$log" 2>&1 || true

git fetch -q fork "$BRANCH" --tags
if latest=$(published); then
    rm -f "$STATE/failed"
    notify "Snapmaker Orca $latest published" "https://github.com/$FORK_REPO/releases/tag/$latest"
else
    echo "$tag" >"$STATE/failed"
    notify "Snapmaker Orca sync for $tag failed" "See $log"
    exit 1
fi
