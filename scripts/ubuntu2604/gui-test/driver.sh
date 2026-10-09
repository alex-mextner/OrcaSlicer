#!/usr/bin/env bash
# Runs INSIDE the GUI test container (started by update-test.sh), never on the host.
# Drives the AppImage self-update flow on a private headless Xvfb display: serves the manifest,
# starts the app via app-runner.py, closes the setup wizard, clicks Download, answers the restart
# question (Yes: normal, No: force) and, for normal, closes the relaunched instance.
# Works in /work (prepared by update-test.sh); writes driver.log, events.log, browser.log, shots/.
# Usage: driver.sh normal|force   Env: SO_RO=1 (read-only control run).
set -u

VARIANT=$1
W=/work
H=$(dirname "$(readlink -f "$0")")
APP=$(echo "$W"/app/*.AppImage)
EVENTS=$W/events.log
PORT=18765
export DISPLAY=:99 HOME=$W/home APPIMAGE_EXTRACT_AND_RUN=1 NO_AT_BRIDGE=1

log() { echo "$(date +%T) $*" | tee -a "$W/driver.log"; }
shot() { import -window root "$W/shots/$1.png" 2>/dev/null && log "screenshot shots/$1.png"; }

cleanup() {
    shot zz-final
    pkill -f appimage_extracted_ 2>/dev/null
    pkill -f "$APP" 2>/dev/null
    kill "$HTTP_PID" "$RUNNER" 2>/dev/null
}
trap cleanup EXIT
HTTP_PID='' RUNNER=''

# Every browser-launch path the app can take logs to browser.log instead of opening anything.
mkdir -p "$W/fakebin" "$W/shots" "$HOME"
for b in xdg-open x-www-browser sensible-browser www-browser firefox gio gnome-open kde-open; do
    printf '#!/bin/sh\necho "$(date +%%T) BROWSER-LAUNCH via %s: $*" >> %s/browser.log\n' "$b" "$W" >"$W/fakebin/$b"
    chmod +x "$W/fakebin/$b"
done
export PATH=$W/fakebin:$PATH BROWSER=$W/fakebin/xdg-open

Xvfb :99 -screen 0 1600x1000x24 -nolisten tcp >"$W/xvfb.log" 2>&1 &
for _ in $(seq 50); do xdpyinfo >/dev/null 2>&1 && break; sleep 0.2; done
xdpyinfo >/dev/null 2>&1 || { log "Xvfb did not start"; exit 1; }
openbox >"$W/openbox.log" 2>&1 &
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$W/srv" >"$W/http.log" 2>&1 &
HTTP_PID=$!

python3 "$H/app-runner.py" "$APP" "$W/data" "$EVENTS" >>"$W/driver.log" 2>&1 &
RUNNER=$!
log "variant=$VARIANT ro=${SO_RO:-0} app=$APP runner=$RUNNER"

# wait_win REGEX SECONDS: print the id of the first visible window whose title matches.
# Polls `xdotool search` (instead of --sync) so a crashed app ends the wait at once.
wait_win() {
    local end=$((SECONDS + $2)) wid
    while ((SECONDS < end)); do
        wid=$(xdotool search --onlyvisible --name "$1" 2>/dev/null | head -n1)
        [ -n "$wid" ] && { echo "$wid"; return 0; }
        kill -0 "$RUNNER" 2>/dev/null || return 1
        sleep 0.5
    done
    return 1
}

# wait_gone WID SECONDS: wait until the window is unmapped or destroyed.
wait_gone() {
    local end=$((SECONDS + $2))
    while ((SECONDS < end)); do
        xdotool search --onlyvisible --name . 2>/dev/null | grep -qx "$1" || return 0
        sleep 0.3
    done
    return 1
}

# wait_line FILE REGEX SECONDS: wait until a line matching REGEX appears in FILE.
wait_line() {
    local end=$((SECONDS + $3))
    while ((SECONDS < end)); do
        grep -qE "$2" "$1" 2>/dev/null && return 0
        sleep 0.5
    done
    return 1
}

# click_button WID DX DY ABS_X ABS_Y NAME: move the dialog to a fixed spot (openbox may place it
# partly off-screen) and click at offset DX,DY from its top-left corner. If the window is still
# there afterwards, retry at the absolute screen position measured on the default layout.
click_button() {
    local wid=$1 X Y WIDTH HEIGHT
    xdotool windowmove --sync "$wid" 100 100 2>/dev/null
    sleep 0.5
    eval "$(xdotool getwindowgeometry --shell "$wid" | grep -E '^(X|Y|WIDTH|HEIGHT)=')"
    shot "click-$6"
    log "click $6 at $((X + $2)),$((Y + $3)) (window $wid ${WIDTH}x${HEIGHT}+$X+$Y)"
    xdotool mousemove --sync $((X + $2)) $((Y + $3)) click 1
    wait_gone "$wid" 5 && return 0
    log "window $wid still open, fallback click $6 at $4,$5"
    xdotool mousemove --sync "$4" "$5" click 1
    wait_gone "$wid" 5
}

# close_window WID NAME: WM close request (as the title bar [x]), via _NET_CLOSE_WINDOW.
close_window() {
    log "close $2 (window $1)"
    wmctrl -i -c "$1"
    wait_gone "$1" 20
}

# close_wizard: the setup wizard opens on every start (it is never completed); the update check
# runs after it is closed.
close_wizard() {
    local wid
    if ! wid=$(wait_win '^Setup Wizard' 180); then
        log "no Setup Wizard window"
        return 1
    fi
    sleep 2 # let the wizard's web view settle before closing it
    shot "$1-wizard"
    close_window "$wid" "Setup Wizard" || log "Setup Wizard did not close"
}

# close_main: close the main window (titled after the open project, "*Untitled" when empty).
close_main() {
    local wid
    wid=$(wait_win 'Untitled' 30) || return 1
    shot "$1-main-window"
    close_window "$wid" "main window"
}

fail() { log "FLOW: $*"; shot zz-flow-failed; exit 1; }

close_wizard 01 || fail "first instance: setup wizard not seen"

if [ "$VARIANT" = force ]; then
    title='needs an (upgrade|update)'
else
    title='^New version of Snapmaker Orca'
fi
wid=$(wait_win "$title" 120) || fail "update dialog ($title) not seen"
sleep 1
shot 02-update-dialog
# Offsets are relative to the window position xdotool reports (frame-adjusted) after the move;
# the absolute fallbacks are the button positions of openbox's default placement.
if [ "$VARIANT" = force ]; then
    click_button "$wid" 410 79 1086 539 Download || fail "Download click had no effect"
else
    click_button "$wid" 409 474 881 747 Download || fail "Download click had no effect"
fi

if [ "${SO_RO:-0}" = 1 ]; then
    # Control run: the AppImage is not writable, so Download must fall back to the browser.
    wait_line "$W/browser.log" BROWSER-LAUNCH 30 || fail "no browser launch in read-only control run"
    log "browser launch seen (read-only control)"
    if [ "$VARIANT" = normal ]; then
        close_main 05 || fail "main window not closed"
    fi
else
    shot 03-downloading
    # The update renames the verified download over the AppImage, then asks to restart. (The app
    # log is buffered, so its "AppImage update: installed" line is checked after exit instead.)
    inode=$(stat -c %i "$APP")
    end=$((SECONDS + 180))
    while [ "$(stat -c %i "$APP")" = "$inode" ]; do
        ((SECONDS < end)) && kill -0 "$RUNNER" 2>/dev/null || fail "AppImage was not replaced"
        sleep 0.5
    done
    log "AppImage replaced"
    # Stop serving: the relaunched instance must not be offered the same update again.
    kill "$HTTP_PID" 2>/dev/null
    wid=$(wait_win '^Update$' 30) || fail "restart question not seen"
    sleep 1
    shot 04-restart-question
    if [ "$VARIANT" = force ]; then
        click_button "$wid" 467 79 992 539 No || fail "No click had no effect"
    else
        click_button "$wid" 357 79 882 539 Yes || fail "Yes click had no effect"
    fi
fi

wait_line "$EVENTS" 'first_exit=' 60 || fail "first instance did not exit"
log "first instance exited"

if [ "$VARIANT" = normal ] && [ "${SO_RO:-0}" != 1 ]; then
    wait_line "$EVENTS" 'relaunch_cmd=' 60 || fail "no relaunched instance"
    close_wizard 06 || fail "relaunched instance: setup wizard not seen"
    close_main 07 || fail "relaunched main window not closed"
fi

wait_line "$EVENTS" '^.* done$' 90 || fail "app processes still running"
log "all app processes exited"
