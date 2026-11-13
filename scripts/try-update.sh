#!/usr/bin/env bash
# Plays a real update on this Mac, before a release: an updater that does not work in a published
# version can never be repaired from afar.
#
#   bash scripts/try-update.sh
#
# It builds this checkout twice with Sparkle, as 0.0.1 and as 0.0.2, signs 0.0.2 as an update with
# a throwaway key made on the spot (never the owner's), serves the feed on 127.0.0.1, and runs
# 0.0.1 in place of the Fremspace that runs: two of them would manage the same windows. In its
# first seconds, or with "Check for Updates…" in its menu, it offers 0.0.2; installing it replaces
# the app and relaunches it. Press Return then: the script says which version ended up running and
# puts everything back.
#
# The apps are signed by the local identity, like the everyday build, so they keep its
# Accessibility grant. Nothing is left behind but Sparkle in .build/ and its tarball in the cache.
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=lib/swiftc-common.sh
source scripts/lib/swiftc-common.sh
# shellcheck source=lib/pins.sh
source scripts/lib/pins.sh

T="$(mktemp -d "${TMPDIR:-/tmp}/fremspace-update.XXXXXX")"
PORT="${FREMSPACE_TRY_UPDATE_PORT:-8765}"
APP="$T/app/Fremspace.app"
SERVER=""
# The Fremspace that runs now, to open it again at the end.
RUNNING="$(ps -axo comm= | sed -n 's|\(.*/Fremspace\.app\)/Contents/MacOS/Fremspace$|\1|p' | head -1)"

quit_fremspace() {
    osascript -e 'tell application id "dev.fremspace.app" to quit' >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do pgrep -x Fremspace >/dev/null || return 0; /bin/sleep 0.5; done
    pkill -x Fremspace 2>/dev/null || true
}

# What Sparkle remembers under the identifier of the app (when it last looked, a version skipped).
# Forgotten before the trial, so that 0.0.1 looks for an update as soon as it starts, and after
# it: the everyday build has no use for it.
forget_sparkle() {
    for key in SULastCheckTime SUSkippedVersion SUHasLaunchedBefore SUUpdateGroupIdentifier SUAutomaticallyUpdate \
               SUEnableAutomaticChecks SUSendProfileInfo SUUpdateRelaunchingMarker "NSWindow Frame SUUpdateAlert2"; do
        defaults delete dev.fremspace.app "$key" >/dev/null 2>&1 || true
    done
}

cleanup() {
    if [ -n "$SERVER" ]; then
        kill "$SERVER" 2>/dev/null || true
        wait "$SERVER" 2>/dev/null || true
    fi
    quit_fremspace
    forget_sparkle
    rm -rf "$T"
    if [ -n "$RUNNING" ] && [ -d "$RUNNING" ]; then
        open -g "$RUNNING"
        echo "back to $RUNNING"
    fi
}
trap cleanup EXIT

echo "==> tools and a throwaway key"
fremspace_fetch_sparkle
fremspace_build_core "$T/core" -O
"$SWIFTC" -O -sdk "$SDK" -target "$TARGET" -swift-version "$SWIFT_VERSION" scripts/appcast/main.swift \
    -I "$T/core" -L "$T/core" -lFremspaceCore -o "$T/appcast"
"$T/appcast" keypair "$T/private.key" "$T/public.key"

export FREMSPACE_SPARKLE=1
FREMSPACE_SPARKLE_PUBLIC_KEY="$(cat "$T/public.key")"
export FREMSPACE_SPARKLE_PUBLIC_KEY
export FREMSPACE_SPARKLE_FEED_URL="http://127.0.0.1:$PORT/appcast.xml"

echo "==> 0.0.1, the version installed"
FREMSPACE_VERSION=0.0.1 FREMSPACE_APP="$APP" bash scripts/build.sh | tail -1
echo "==> 0.0.2, its update"
FREMSPACE_VERSION=0.0.2 FREMSPACE_APP="$T/new/Fremspace.app" bash scripts/build.sh | tail -1

mkdir -p "$T/feed"
ZIP="$T/feed/Fremspace-0.0.2.zip"
ditto -c -k --sequesterRsrc --keepParent "$T/new/Fremspace.app" "$ZIP"
SIGN_UPDATE="$SPARKLE_DIR/bin/sign_update"
signed="$("$SIGN_UPDATE" --ed-key-file "$T/private.key" "$ZIP")"
signature="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' <<<"$signed")"
"$T/appcast" verify "$ZIP" "$signature" "$FREMSPACE_SPARKLE_PUBLIC_KEY"
printf '## 0.0.2\n\n- **An update to try.** If you read this in the update window, the notes arrive too.\n' > "$T/notes.md"
"$T/appcast" feed 0.0.2 "http://127.0.0.1:$PORT/Fremspace-0.0.2.zip" "$ZIP" "$signature" "$T/notes.md" > "$T/feed/appcast.xml"
"$SIGN_UPDATE" --ed-key-file "$T/private.key" "$T/feed/appcast.xml" >/dev/null
"$SIGN_UPDATE" --verify --ed-key-file "$T/private.key" "$T/feed/appcast.xml"

echo "==> the feed, on 127.0.0.1:$PORT"
(cd "$T/feed" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 >"$T/server.log" 2>&1) &
SERVER=$!
/bin/sleep 1
# The folder, not the feed: the count of who read the feed, at the end, is then the one of the app.
curl -fsS -o /dev/null "http://127.0.0.1:$PORT/"

echo "==> Fremspace 0.0.1 in place of the one that runs"
quit_fremspace
forget_sparkle
open -g "$APP"

cat <<EOF

Fremspace 0.0.1 is running, from $APP.
It looks for an update as it starts: a window should offer 0.0.2 with its notes within a few
seconds (if not: Check for Updates… in its menu bar menu). Choose Install, and let it relaunch.
EOF
if [ -t 0 ]; then
    read -r -p "Press Return when it is done (or to give up)… " _
else
    # Not a terminal (a run by a tool): wait a little, for a look at what Sparkle did by itself.
    /bin/sleep "${FREMSPACE_TRY_UPDATE_HOLD:-30}"
fi

NOW="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo '?')"
ASKED="$(grep -c 'GET /appcast.xml' "$T/server.log" || true)"
FETCHED="$(grep -c 'GET /Fremspace-0.0.2.zip' "$T/server.log" || true)"
echo
echo "the feed was read $ASKED time(s), the update downloaded $FETCHED time(s)"
if [ "$NOW" = "0.0.2" ] && pgrep -x Fremspace >/dev/null; then
    echo "UPDATED: the app is now 0.0.2 and it is running."
elif [ "$NOW" = "0.0.2" ]; then
    echo "REPLACED, NOT RUNNING: the app is 0.0.2 on disk but did not relaunch."
else
    echo "NOT UPDATED: the app is still $NOW."
fi
