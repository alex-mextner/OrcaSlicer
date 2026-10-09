#!/usr/bin/env bash
# Builds Snapmaker Orca on a temporary Runpod CPU pod instead of this machine: dependencies (or a
# cached copy of them), the slicer, the AppImage and the tests, then runs ctest there and copies the
# AppImage into build/. The pod is deleted when this script exits; as backstops a detached local
# process, and the pod itself when Runpod gives it its credentials, delete it after RUNPOD_MAX_HOURS.
#
#   scripts/ubuntu2604/remote-build.sh
#
# The pod checks out HEAD from the fork (pushed to a temporary remote-build/<sha> branch, deleted
# afterwards) and receives uncommitted changes over rsync, so the build matches the working tree.
# Built dependencies are cached as a prerelease deps-<hash> of the fork, keyed on the deps/ tree and
# provision.sh; a cache miss builds them on the pod and uploads them from here.
#
# Needs: a Runpod API key (RUNPOD_API_KEY, or ~/.runpod/config.toml from `runpodctl doctor`), gh
# logged in with push access to FORK_REPO, and an SSH key (SSH_KEY, default ~/.ssh/id_ed25519).
# Exit codes: 11 build failed, 12 tests failed, other non-zero: pod / transfer errors.
set -euo pipefail

HERE=$(dirname "$(readlink -f "$0")")
ROOT=$(git -C "$HERE" rev-parse --show-toplevel)
cd "$ROOT"

FORK_REPO=${FORK_REPO:-alex-mextner/SnapOrca}
FLAVORS=${RUNPOD_CPU_FLAVORS:-cpu5c,cpu3c} # compute-optimized, 2 GB RAM per vCPU
VCPU=${RUNPOD_VCPU:-32}                    # power of two, flavor maximum is 32
MAX_HOURS=${RUNPOD_MAX_HOURS:-3}
SSH_KEY=${SSH_KEY:-$HOME/.ssh/id_ed25519}
API=https://rest.runpod.io/v1

die() { echo "remote-build.sh: $1" >&2; exit "${2:-1}"; }

api_key=${RUNPOD_API_KEY:-$(sed -nE 's/^apikey *= *"(.*)"/\1/p' "$HOME/.runpod/config.toml" 2>/dev/null || true)}
[[ -n $api_key ]] || die "no Runpod API key: set RUNPOD_API_KEY or run runpodctl doctor"
[[ -r $SSH_KEY.pub ]] || die "missing $SSH_KEY.pub"
# Key passed through a curl config on stdin, not argv (visible in ps).
api() { printf 'header = "Authorization: Bearer %s"\n' "$api_key" | curl -fsS -m 60 -K - -H 'Content-Type: application/json' "$@"; }
# field KEY [SUBKEY]: value from the JSON object on stdin, empty when missing or not JSON.
field() {
    python3 -c 'import json, sys
try:
    v = json.load(sys.stdin)
    for k in sys.argv[1:]:
        v = v.get(k) if isinstance(v, dict) else None
except ValueError:
    v = None
print("" if v is None else v)' "$@"
}

tmp=$(mktemp -d)
sha=$(git rev-parse HEAD)
build_ref=refs/heads/remote-build/$sha
fork_url=https://github.com/$FORK_REPO.git
pod_id=""
watchdog_pid=""

cleanup() {
    local rc=$?
    if [[ -n $pod_id ]]; then
        local id=$pod_id
        pod_id=""
        echo "== deleting pod $id"
        api -X DELETE "$API/pods/$id" >/dev/null || echo "remote-build.sh: could not delete pod $id, delete it in the Runpod console" >&2
    fi
    [[ -z $watchdog_pid ]] || kill -- "-$watchdog_pid" 2>/dev/null || true # its session: bash + sleep
    git push -q "$fork_url" ":$build_ref" 2>/dev/null || true
    rm -rf "$tmp"
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# Dependencies cache key: everything that feeds deps/build/destdir.
deps_tag=""
if [[ -z $(git status --porcelain -- deps scripts/ubuntu2604/provision.sh) ]]; then
    deps_tag="deps-$(git rev-parse HEAD:deps | cut -c1-12)-$(git rev-parse HEAD:scripts/ubuntu2604/provision.sh | cut -c1-8)"
fi
deps_url=""
if [[ -n $deps_tag ]] && gh release view "$deps_tag" --repo "$FORK_REPO" --json assets --jq '.assets[].name' 2>/dev/null | grep -qx destdir.tar.zst; then
    deps_url="https://github.com/$FORK_REPO/releases/download/$deps_tag/destdir.tar.zst"
fi
echo "== deps: ${deps_url:-build on the pod (no cache for ${deps_tag:-a modified deps/ tree})}"

echo "== pushing $sha to $build_ref"
git push -q "$fork_url" "$sha:$build_ref" # named by the sha: an existing branch already matches

# The pod runs plain ubuntu:26.04 with sshd started from the start command: enough to provision it
# over SSH with the same provision.sh as the local container image.
boot=$(cat <<'EOF'
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends openssh-server ca-certificates curl git rsync zstd >/dev/null
if [[ -n ${RUNPOD_API_KEY:-} && -n ${RUNPOD_POD_ID:-} ]]; then
    ( sleep "$BUILD_MAX_SECONDS"; curl -fsS -X DELETE -H "Authorization: Bearer $RUNPOD_API_KEY" "https://rest.runpod.io/v1/pods/$RUNPOD_POD_ID" ) &
fi
mkdir -p /root/.ssh /run/sshd
chmod 700 /root/.ssh
printf '%s\n' "$BUILD_SSH_KEY" >/root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
ssh-keygen -A
exec /usr/sbin/sshd -D -e
EOF
)
request=$(python3 - "$FLAVORS" "$VCPU" "$((MAX_HOURS * 3600))" "$(cat "$SSH_KEY.pub")" "$boot" <<'EOF'
import json, sys
flavors, vcpu, max_seconds, pubkey, boot = sys.argv[1:]
print(json.dumps({
    "name": "snap-orca-build", "computeType": "CPU", "cloudType": "SECURE",
    "cpuFlavorIds": flavors.split(","), "cpuFlavorPriority": "custom", "vcpuCount": int(vcpu),
    "imageName": "ubuntu:26.04", "containerDiskInGb": 100, "ports": ["22/tcp"],
    "env": {"BUILD_SSH_KEY": pubkey, "BUILD_MAX_SECONDS": max_seconds},
    "dockerStartCmd": ["bash", "-c", boot],
}))
EOF
)
echo "== creating pod ($VCPU vCPU, ${FLAVORS})"
pod=$(api -X POST "$API/pods" -d "$request") || die "pod creation failed"
pod_id=$(field id <<<"$pod")
echo "== pod $pod_id: $(field cpuFlavorId <<<"$pod") $(field vcpuCount <<<"$pod") vCPU $(field memoryInGb <<<"$pod") GB, \$$(field costPerHr <<<"$pod")/h"
# Backstop if this script dies without its EXIT trap (kill -9, crash): a detached deleter, with the
# key in its environment rather than argv. It does not survive this machine going down; the pod's
# own deleter (when Runpod gives the pod its credentials, reported below) does.
RP_KEY=$api_key RP_POD=$pod_id setsid bash -c "sleep $((MAX_HOURS * 3600)); "'printf "header = \"Authorization: Bearer %s\"\n" "$RP_KEY" | curl -fsS -m 60 -K - -X DELETE "'"$API"'/pods/$RP_POD"' \
    </dev/null >/dev/null 2>&1 &
watchdog_pid=$!

ip="" port=""
for _ in $(seq 120); do
    pod=$(api "$API/pods/$pod_id" || true)
    ip=$(field publicIp <<<"$pod")
    port=$(field portMappings 22 <<<"$pod")
    [[ -n $ip && -n $port ]] && break
    sleep 5
done
[[ -n $ip && -n $port ]] || die "pod $pod_id got no public SSH port"

ssh_opts=(-i "$SSH_KEY" -p "$port" -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=30
          -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$tmp/known_hosts")
on_pod() { ssh "${ssh_opts[@]}" "root@$ip" "$@"; }
# on_pod_script ARG...: runs the script on stdin with these arguments (quoted: ssh joins argv into
# one command line, which would drop empty arguments and split ones with spaces).
on_pod_script() { on_pod "bash -s --$(printf ' %q' "$@")"; }
for _ in $(seq 60); do
    on_pod true 2>/dev/null && break
    sleep 5
done
on_pod true || die "pod $pod_id: SSH on $ip:$port does not answer"
echo "== pod reachable at $ip:$port"
if on_pod 'tr "\0" "\n" </proc/1/environ | grep -q "^RUNPOD_API_KEY=." && tr "\0" "\n" </proc/1/environ | grep -q "^RUNPOD_POD_ID=."'; then
    echo "== pod deletes itself after ${MAX_HOURS}h if this machine loses it"
else
    echo "remote-build.sh: warning: Runpod gave the pod no API key, so it cannot delete itself; a pod orphaned by this machine going down keeps billing" >&2
fi

echo "== checkout + provision"
on_pod_script "$ROOT" "$fork_url" "$sha" <<'EOF'
set -euo pipefail
mkdir -p "$1" && cd "$1"
git init -q && git fetch -q --depth 1 "$2" "$3" && git checkout -q FETCH_HEAD
EOF

# Uncommitted changes: modified and untracked (not ignored) files, and deletions.
git diff --name-only -z HEAD --diff-filter=d >"$tmp/changed"
git ls-files -z -o --exclude-standard >>"$tmp/changed"
if [[ -s $tmp/changed ]]; then
    echo "== syncing $(tr -cd '\0' <"$tmp/changed" | wc -c) uncommitted files"
    rsync -az --from0 --files-from="$tmp/changed" -e "ssh ${ssh_opts[*]}" ./ "root@$ip:$ROOT/"
fi
deleted=$(git diff --name-only HEAD --diff-filter=D)
if [[ -n $deleted ]]; then
    printf '%s\n' "$deleted" | on_pod "cd '$ROOT' && xargs -d '\n' rm -f --"
fi

on_pod_script "$ROOT" "$deps_url" <<'EOF'
set -euo pipefail
cd "$1"
bash scripts/ubuntu2604/provision.sh >/root/provision.log 2>&1 || { tail -50 /root/provision.log; exit 1; }
if [[ -n $2 ]]; then
    mkdir -p deps/build
    curl -fsSL "$2" | zstd -dc | tar -x -C deps/build
fi
EOF

# Parallel jobs: the vCPUs the pod may use (cgroup quota, nproc shows the host), capped at
# 2 GB of RAM per job (the heaviest libslic3r units need about that much).
flags=$([[ -n $deps_url ]] && echo -sitr || echo -dsitr)
echo "== build ($flags)"
on_pod_script "$ROOT" "$flags" <<'EOF' || { rc=$?; [[ $rc == 12 ]] && die "tests failed on the pod" 12; die "build failed on the pod" 11; }
set -euo pipefail
cd "$1"
cpus=$(nproc)
read -r quota period </sys/fs/cgroup/cpu.max 2>/dev/null || quota=max
[[ $quota != max ]] && cpus=$(( quota / period ))
mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
limit=$(cat /sys/fs/cgroup/memory.max 2>/dev/null || echo max)
[[ $limit != max ]] && mem_kb=$(( limit / 1024 ))
jobs=$(( mem_kb / 1024 / 1024 / 2 ))
(( jobs > cpus )) && jobs=$cpus
(( jobs < 1 )) && jobs=1
echo "cpus=$cpus mem=$(( mem_kb / 1024 / 1024 ))G jobs=$jobs"
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 CMAKE_BUILD_PARALLEL_LEVEL=$jobs
./build_linux.sh "$2" || exit 11
# build_linux.sh builds only the Snapmaker_Orca target; -t merely configures the tests.
cmake --build build --config Release || exit 11
echo "== tests"
cd build && ctest -C Release -j1 --output-on-failure || exit 12
EOF

echo "== fetching the AppImage"
rsync -a -e "ssh ${ssh_opts[*]}" "root@$ip:$ROOT/build/Snapmaker_Orca_Linux_V*.AppImage" build/

if [[ -z $deps_url && -n $deps_tag ]]; then
    echo "== caching dependencies as $deps_tag"
    on_pod "tar -C '$ROOT/deps/build' -cf - destdir | zstd -T0 -q -10 -o /root/destdir.tar.zst"
    rsync -a -e "ssh ${ssh_opts[*]}" "root@$ip:/root/destdir.tar.zst" "$tmp/"
    gh release view "$deps_tag" --repo "$FORK_REPO" >/dev/null 2>&1 ||
        gh release create "$deps_tag" --repo "$FORK_REPO" --prerelease --target "$sha" \
            --title "Build dependencies $deps_tag (internal)" \
            --notes "Prebuilt deps/build/destdir for scripts/ubuntu2604/remote-build.sh. Not a slicer release."
    gh release upload "$deps_tag" --repo "$FORK_REPO" --clobber "$tmp/destdir.tar.zst" ||
        echo "remote-build.sh: deps cache upload failed; the next build rebuilds them" >&2
fi
echo "== done: $(ls build/Snapmaker_Orca_Linux_V*.AppImage)"
