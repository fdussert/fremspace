#!/usr/bin/env bash
# The disk image people download: the app, a link to /Applications, and a window that shows
# where to drag it (packaging/dmg/background.tiff behind two icons).
#
#   scripts/make-dmg.sh <Fremspace.app> <out.dmg>
#
# The window (its size, the picture, where the icons are) is something only the Finder writes: the
# image is mounted for a moment, the Finder is asked to arrange its window, and the result is
# compressed. That needs a session with the Finder running, and macOS asks once whether the
# terminal may control the Finder. FREMSPACE_PLAIN_DMG=1 skips the window (the same image, as
# the Finder shows any folder). Neither signs the image: scripts/release.sh does.
set -euo pipefail

APP="${1:?usage: scripts/make-dmg.sh <Fremspace.app> <out.dmg>}"
OUT="${2:?usage: scripts/make-dmg.sh <Fremspace.app> <out.dmg>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BACKGROUND="$ROOT/packaging/dmg/background.tiff"
VOLUME="Fremspace"
# Shared with packaging/dmg/background.swift: the picture's size and the centres of the icons.
WIDTH=640
HEIGHT=400
TITLE_BAR=28

WORK="$(mktemp -d)"
DEVICE=""
cleanup() {
    if [ -n "$DEVICE" ]; then hdiutil detach "$DEVICE" -force >/dev/null 2>&1 || true; fi
    rm -rf "$WORK"
}
trap cleanup EXIT

STAGE="$WORK/stage"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Fremspace.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$OUT"

if [ "${FREMSPACE_PLAIN_DMG:-0}" = "1" ]; then
    hdiutil create -volname "$VOLUME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$OUT" >/dev/null
    exit 0
fi

if [ -e "/Volumes/$VOLUME" ]; then
    echo "error: a volume named $VOLUME is mounted; eject it first (the Finder is told to arrange the window of the disk of that name)" >&2
    exit 1
fi
mkdir "$STAGE/.background"
cp "$BACKGROUND" "$STAGE/.background/background.tiff"

# Read-write for the Finder, with room for what it writes.
SIZE=$(( $(du -sm "$STAGE" | cut -f1) + 16 ))
hdiutil create -volname "$VOLUME" -srcfolder "$STAGE" -fs HFS+ -format UDRW -size "${SIZE}m" -ov "$WORK/rw.dmg" >/dev/null
DEVICE="$(hdiutil attach -readwrite -noverify -noautoopen "$WORK/rw.dmg" | awk '/\/Volumes\// { print $1; exit }')"
MOUNT="/Volumes/$VOLUME"

if ! osascript - "$VOLUME" "$WIDTH" "$((HEIGHT + TITLE_BAR))" >/dev/null <<'APPLESCRIPT'
on run argv
    set volumeName to item 1 of argv
    set windowWidth to (item 2 of argv) as integer
    set windowHeight to (item 3 of argv) as integer
    tell application "Finder"
        tell disk volumeName
            open
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            set the bounds of container window to {200, 140, 200 + windowWidth, 140 + windowHeight}
            set viewOptions to the icon view options of container window
            set arrangement of viewOptions to not arranged
            set icon size of viewOptions to 128
            set text size of viewOptions to 13
            set background picture of viewOptions to file ".background:background.tiff"
            set position of item "Fremspace.app" of container window to {170, 180}
            set position of item "Applications" of container window to {470, 180}
            -- Closed and opened again: the Finder writes the window's settings when it closes.
            close
            open
            update without registering applications
            delay 1
            close
        end tell
    end tell
end run
APPLESCRIPT
then
    echo "error: the Finder did not arrange the window of the disk image." >&2
    echo "  It needs a session with the Finder running, and System Settings > Privacy & Security > Automation" >&2
    echo "  must let this terminal control the Finder. FREMSPACE_PLAIN_DMG=1 builds the image without the window." >&2
    exit 1
fi

# The Finder writes .DS_Store a moment after the window closes.
for _ in $(seq 1 40); do
    [ -s "$MOUNT/.DS_Store" ] && break
    /bin/sleep 0.25
done
if [ ! -s "$MOUNT/.DS_Store" ]; then
    echo "error: the Finder wrote no window settings (.DS_Store) on the disk image" >&2
    exit 1
fi
rm -rf "$MOUNT/.fseventsd" "$MOUNT/.Trashes"
sync

for attempt in 1 2 3 4 5; do
    if hdiutil detach "$DEVICE" >/dev/null 2>&1; then DEVICE=""; break; fi
    /bin/sleep 1
done
if [ -n "$DEVICE" ]; then
    echo "error: the disk image could not be ejected (something still has a file of it open)" >&2
    exit 1
fi
hdiutil convert "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$OUT" >/dev/null
