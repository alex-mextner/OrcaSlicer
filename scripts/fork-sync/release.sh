#!/usr/bin/env bash
# Build, test and publish a Linux release of this fork as a GitHub release.
#
#   scripts/fork-sync/release.sh [--merge <upstream-tag>] [--dry-run]
#
# --merge   first merge the given Snapmaker/OrcaSlicer release tag into the release branch
# --dry-run build, test and assemble dist/ but do not commit the build bump, push or publish
#
# Exit codes: 10 merge conflict (resolve, commit, rerun without --merge), 11 build failed,
# 12 tests failed, 13 smoke test failed, other non-zero: usage / environment errors.
#
# BUILD_BACKEND=runpod (default when a Runpod API key is configured) builds and tests on a
# temporary Runpod CPU pod (scripts/ubuntu2604/remote-build.sh, ~$1/h, deleted afterwards);
# BUILD_BACKEND=local builds in the local container and occupies all cores of this machine.
#
# The release carries the AppImage and version.json, the manifest that Linux builds poll
# (ORCA_LINUX_UPDATE_URL in version.inc points at releases/latest/download/version.json).
set -euo pipefail

ROOT=$(git -C "$(dirname "$(readlink -f "$0")")" rev-parse --show-toplevel)
cd "$ROOT"

FORK_REPO=${FORK_REPO:-alex-mextner/SnapOrca}
FORK_REMOTE=${FORK_REMOTE:-fork}
BRANCH=${BRANCH:-ubuntu-26.04}
UPSTREAM_URL=https://github.com/Snapmaker/OrcaSlicer.git
BUILD_IMAGE=snap-orca-build:26.04
if [[ -n ${RUNPOD_API_KEY:-} ]] || grep -qs '^apikey *= *"..*"' "$HOME/.runpod/config.toml"; then
    BUILD_BACKEND=${BUILD_BACKEND:-runpod}
else
    BUILD_BACKEND=${BUILD_BACKEND:-local}
fi

die() { echo "release.sh: $1" >&2; exit "${2:-1}"; }

MERGE_TAG=""
DRY_RUN=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --merge) MERGE_TAG=${2:?--merge needs a tag}; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        *) die "unknown argument $1" ;;
    esac
done

# One release at a time: a manual run and the timer's omp session would race for the same tag.
exec 8>"$(git rev-parse --git-dir)/fork-release.lock"
flock -n 8 || die "another release.sh is running"

[[ $(git rev-parse --abbrev-ref HEAD) == "$BRANCH" ]] || die "not on $BRANCH"
git diff --quiet && git diff --cached --quiet || die "working tree has uncommitted changes"

if [[ -n "$MERGE_TAG" ]]; then
    git fetch --no-tags "$UPSTREAM_URL" "+refs/tags/$MERGE_TAG:refs/tags/$MERGE_TAG"
    if ! git merge-base --is-ancestor "$MERGE_TAG" HEAD; then
        echo "== merging $MERGE_TAG"
        git merge --no-edit -m "Merge Snapmaker $MERGE_TAG" "$MERGE_TAG" || die "merge of $MERGE_TAG has conflicts" 10
    fi
fi

version=$(sed -nE 's/^set\(Snapmaker_VERSION "([^"]+)"\).*/\1/p' version.inc)
[[ -n "$version" ]] || die "Snapmaker_VERSION not found in version.inc"
last_build=$(git ls-remote --tags "https://github.com/$FORK_REPO.git" "refs/tags/v$version-linux.*" \
    | sed -nE 's#.*/v[^/]*-linux\.([0-9]+)$#\1#p' | sort -n | tail -1)
build=$(( ${last_build:-0} + 1 ))
tag="v$version-linux.$build"
echo "== release $tag"

sed -i -E "s/^set\(ORCA_FORK_BUILD \"[0-9]+\"\)/set(ORCA_FORK_BUILD \"$build\")/" version.inc
grep -q "^set(ORCA_FORK_BUILD \"$build\")" version.inc || die "could not set ORCA_FORK_BUILD in version.inc"

published=0
# Leave the tree clean unless the build bump was committed.
restore_version_inc() { if [[ $published == 0 ]]; then git checkout -q -- version.inc; fi; }
trap restore_version_inc EXIT

appimage="build/Snapmaker_Orca_Linux_V$version.AppImage"
rm -f "$appimage"
if [[ $BUILD_BACKEND == runpod ]]; then
    echo "== build + tests on a Runpod pod"
    scripts/ubuntu2604/remote-build.sh || { rc=$?; die "remote build failed" "$rc"; }
else
    echo "== build"
    scripts/ubuntu2604/build.sh -distr || die "build failed" 11
    # build_linux.sh builds only the Snapmaker_Orca target; -t merely configures the tests.
    scripts/ubuntu2604/build.sh -- cmake --build build --config Release || die "test build failed" 11

    echo "== tests"
    docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -v "$ROOT:$ROOT" -w "$ROOT/build" "$BUILD_IMAGE" \
        ctest -C Release -j1 --output-on-failure || die "tests failed" 12
fi

[[ -x "$appimage" ]] || die "missing $appimage" 11

echo "== smoke: CLI slice with Snapmaker U1 profiles"
smoke=$(mktemp -d)
scripts/flatten_profile.py -o "$smoke/profiles" \
    --machine "Snapmaker U1 (0.4 nozzle)" \
    --process "0.20mm Standard @Snapmaker U1 (0.4 nozzle)" \
    --filament "Snapmaker PLA Basic @U1" >/dev/null
# Inside the build container (no host /dev, no USB), like everything else this script runs.
docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -v "$ROOT:$ROOT" -v "$smoke:$smoke" -w "$ROOT" "$BUILD_IMAGE" \
    "$ROOT/$appimage" --appimage-extract-and-run --datadir "$smoke/data" --slice 0 --outputdir "$smoke/out" \
    --load-settings "$smoke/profiles/machine-Snapmaker U1 (0.4 nozzle).json;$smoke/profiles/process-0.20mm Standard @Snapmaker U1 (0.4 nozzle).json" \
    --load-filaments "$smoke/profiles/filament-Snapmaker PLA Basic @U1.json" \
    tests/data/20mm_cube.obj >"$smoke/slice.log" 2>&1 || die "smoke slice crashed, see $smoke/slice.log" 13
python3 - "$smoke/out" <<'EOF' || die "smoke slice produced no valid G-code, see $smoke" 13
import json, pathlib, sys
out = pathlib.Path(sys.argv[1])
result = json.loads((out / "result.json").read_text())
gcode = (out / "plate_1.gcode").read_text(errors="replace")
assert result["return_code"] == 0, result
assert gcode.count(";LAYER_CHANGE") > 10 and "printer_model = Snapmaker U1" in gcode
EOF
rm -rf "$smoke"

echo "== assemble dist/"
rm -rf dist && mkdir -p dist
asset="Snapmaker_Orca-$tag-x86_64.AppImage"
cp "$appimage" "dist/$asset"
sha256=$(sha256sum "dist/$asset" | cut -d' ' -f1)
size=$(stat -c %s "dist/$asset")
prev_tag=$(git describe --tags --abbrev=0 --match 'v*-linux.*' 2>/dev/null || true)
# First fork release: list the fork's own commits since the Snapmaker release it is based on.
base=$prev_tag
if [[ -z $base ]] && git fetch -q --no-tags "$UPSTREAM_URL" "+refs/tags/v$version:refs/tags/v$version"; then
    base=v$version
fi
changes=$(git log --no-merges --format='- %s' ${base:+"$base"..}HEAD -- . ':!version.inc' | head -50)
cat >dist/notes.md <<EOF
Snapmaker Orca $version for Linux (Ubuntu 26.04), fork build $build.

Based on Snapmaker release [v$version](https://github.com/Snapmaker/OrcaSlicer/releases/tag/v$version).
Installed AppImages update themselves from this release (Help → Check for Update, also checked on startup).

Changes in this fork since ${prev_tag:-the upstream release}:
$changes
EOF
python3 - "$version" "$build" "$tag" "$asset" "$sha256" "$size" "$FORK_REPO" >dist/version.json <<'EOF'
import json, sys
version, build, tag, asset, sha256, size, repo = sys.argv[1:]
notes = open("dist/notes.md").read()
print(json.dumps({"code": 200, "message": "OK", "data": {
    "version": version, "fork_build": int(build), "release_type": "stable", "platform_type": "linux",
    "is_force_upgrade": False,
    "full": {"file_describe": notes, "default": {
        "file_url": f"https://github.com/{repo}/releases/download/{tag}/{asset}",
        "file_sha256": sha256, "file_size": int(size)}}}}, indent=2))
EOF

if [[ $DRY_RUN == 1 ]]; then
    echo "== dry run: dist/ ready, nothing committed or published"
    exit 0
fi

echo "== publish $tag"
# Resumable: the tag is created by GitHub together with the release, so a run that failed before
# that point (push or release creation) is completed by rerunning, which then computes the same
# build number.
if ! git diff --quiet -- version.inc; then
    git commit -q -m "release: $tag" version.inc
fi
published=1
git push -q "$FORK_REMOTE" "$BRANCH"
# Draft first, so clients never see a published release without its version.json / AppImage.
if ! gh release view "$tag" --repo "$FORK_REPO" >/dev/null 2>&1; then
    gh release create "$tag" --repo "$FORK_REPO" --target "$(git rev-parse HEAD)" --draft \
        --title "Snapmaker Orca $version — Linux build $build" --notes-file dist/notes.md
fi
gh release upload "$tag" --repo "$FORK_REPO" --clobber "dist/$asset" dist/version.json
gh release edit "$tag" --repo "$FORK_REPO" --draft=false --latest
git fetch -q "$FORK_REMOTE" "+refs/tags/$tag:refs/tags/$tag"
echo "== published https://github.com/$FORK_REPO/releases/tag/$tag"
