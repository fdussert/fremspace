#!/usr/bin/env bash
# Adapted from Fremkit (MIT).
# Build Fremspace with swiftc (no SwiftPM, no Xcode) and assemble dist/Fremspace.app.
#
# FREMSPACE_SPARKLE=1 builds the app as it is distributed: with Sparkle, so that it updates itself
# (scripts/release.sh sets it). Without it, the everyday build: nothing to download, and an app
# that never replaces itself with a release.
#   FREMSPACE_VERSION              overrides the version in Version.swift (trying an update).
#   FREMSPACE_SPARKLE_FEED_URL     overrides the address of the feed (trying an update).
#   FREMSPACE_SPARKLE_PUBLIC_KEY   overrides packaging/sparkle/public-key.txt (trying an update).
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=lib/swiftc-common.sh
source scripts/lib/swiftc-common.sh

VERSION="${FREMSPACE_VERSION:-$(sed -n 's/^public let version = "\(.*\)"$/\1/p' Sources/FremspaceCore/Version.swift)}"
if [ -z "$VERSION" ]; then
    echo "error: no version found in Sources/FremspaceCore/Version.swift" >&2
    exit 1
fi
echo "SDK: $SDK, version $VERSION"

# Sparkle, for the distributed app only.
SPARKLE_FLAGS=()
if [ "${FREMSPACE_SPARKLE:-}" = "1" ]; then
    # shellcheck source=lib/pins.sh
    source scripts/lib/pins.sh
    echo "==> Sparkle $SPARKLE_VERSION"
    fremspace_fetch_sparkle
    SPARKLE_FLAGS=(-D FREMSPACE_SPARKLE -F "$SPARKLE_DIR" -framework Sparkle
                   -Xlinker -rpath -Xlinker @executable_path/../Frameworks)
fi

# Builds FremspaceCore and the app's executable for the current TARGET into $1.
build_binary() {
    local out="$1"
    echo "==> FremspaceCore ($TARGET)"
    fremspace_build_core "$out" -O
    echo "==> Fremspace ($TARGET)"
    "$SWIFTC" -O -sdk "$SDK" -target "$TARGET" -swift-version "$SWIFT_VERSION" \
        -module-name Fremspace \
        Sources/Fremspace/*.swift Sources/Fremspace/Settings/*.swift \
        -I "$out" -L "$out" -lFremspaceCore \
        -framework AppKit \
        -framework ApplicationServices \
        -framework Carbon \
        -framework SwiftUI \
        -framework ServiceManagement \
        -framework UserNotifications \
        -framework ScreenCaptureKit \
        ${SPARKLE_FLAGS[@]+"${SPARKLE_FLAGS[@]}"} \
        -o "$out/Fremspace"
}

# FREMSPACE_ARCHS="arm64 x86_64" builds one executable for both (a release); unset, this Mac's.
mkdir -p "$OUT"
if [ -n "${FREMSPACE_ARCHS:-}" ]; then
    SLICES=()
    for arch in $FREMSPACE_ARCHS; do
        TARGET="${arch}-apple-macos13.0"
        build_binary "$OUT/release-$arch"
        SLICES+=("$OUT/release-$arch/Fremspace")
    done
    BINARY="$OUT/Fremspace-universal"
    lipo -create "${SLICES[@]}" -output "$BINARY"
else
    build_binary "$OUT"
    BINARY="$OUT/Fremspace"
fi

echo "==> app bundle"
# FREMSPACE_APP: where the bundle goes (a release builds beside the everyday one).
APP="${FREMSPACE_APP:-dist/Fremspace.app}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/Fremspace"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Drawn by scripts/make-icon.swift.
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $VERSION" \
    "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [ "${FREMSPACE_SPARKLE:-}" = "1" ]; then
    # Sparkle, minus its XPC services: those exist for sandboxed apps, and Fremspace is not
    # sandboxed (Sparkle's documentation says they may then be removed). Less code shipped and signed.
    mkdir -p "$APP/Contents/Frameworks"
    rsync -a "$SPARKLE_DIR/Sparkle.framework" "$APP/Contents/Frameworks/"
    rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" \
           "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"
    # The feed is an asset of the newest release (docs/releasing.md). SUVerifyUpdateBeforeExtraction:
    # the archive's signature is checked before a byte of it is unpacked. SURequireSignedFeed: the
    # feed itself must be signed by the same key, so one served by anyone else is refused before
    # it can offer an update or show notes.
    /usr/libexec/PlistBuddy \
        -c "Add :SUFeedURL string ${FREMSPACE_SPARKLE_FEED_URL:-https://github.com/fdussert/fremspace/releases/latest/download/appcast.xml}" \
        -c "Add :SUEnableAutomaticChecks bool true" \
        -c "Add :SUVerifyUpdateBeforeExtraction bool true" \
        -c "Add :SURequireSignedFeed bool true" \
        "$APP/Contents/Info.plist"
    # The public half of the owner's key; the private half stays in their keychain and signs each
    # update (scripts/release.sh). Without it the app has no updater at all (AppDelegate), so such
    # a build runs but must never be released: release.sh checks.
    PUBLIC_KEY="$(fremspace_sparkle_public_key)"
    if [ -n "$PUBLIC_KEY" ]; then
        /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $PUBLIC_KEY" "$APP/Contents/Info.plist"
    else
        echo "warning: no Sparkle public key (packaging/sparkle/public-key.txt is empty); this build cannot update itself" >&2
    fi
fi

# macOS ties the Accessibility grant to the code signature. Ad hoc signatures change with every
# build, so each rebuild would drop the grant; a stable self-signed identity avoids that
# (scripts/create-signing-identity.sh). Ad hoc is the fallback when the identity is missing.
IDENTITY="${FREMSPACE_SIGN_IDENTITY:-Fremspace Dev}"
# By name ("Fremspace Dev") or by hash (a release names the Developer ID identity by its hash).
if security find-identity -v -p codesigning 2>/dev/null | grep -q -e "\"$IDENTITY\"" -e " $IDENTITY \""; then
    echo "signing with: $IDENTITY"
    SIGN_AS="$IDENTITY"
else
    echo "signing ad hoc (no \"$IDENTITY\" identity in the keychain; run scripts/create-signing-identity.sh)"
    SIGN_AS="-"
fi
# A release is timestamped by Apple's server (FREMSPACE_TIMESTAMP=1): notarization requires it.
TIMESTAMP="--timestamp=none"
if [ "${FREMSPACE_TIMESTAMP:-}" = "1" ]; then TIMESTAMP="--timestamp"; fi
sign() { codesign --force --options runtime "$TIMESTAMP" --sign "$SIGN_AS" "$@"; }
ENTITLEMENTS=()
if [ "${FREMSPACE_SPARKLE:-}" = "1" ]; then
    # Inside out, every piece with its own signature, never --deep: Sparkle's helpers, its
    # framework, then the app.
    SPARKLE_FW="$APP/Contents/Frameworks/Sparkle.framework"
    sign "$SPARKLE_FW/Versions/B/Autoupdate"
    sign "$SPARKLE_FW/Versions/B/Updater.app"
    sign "$SPARKLE_FW"
    # The hardened runtime only loads a framework signed by the app's own team. A self-signed or
    # ad hoc identity has no team, so the app would die loading Sparkle: such a build (local, to
    # try an update, never notarizable) gets library validation turned off. A release never does.
    if [ "$TIMESTAMP" != "--timestamp" ]; then
        LOCAL_ENTITLEMENTS="$OUT/local.entitlements"
        rm -f "$LOCAL_ENTITLEMENTS"
        /usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.disable-library-validation bool true" "$LOCAL_ENTITLEMENTS" >/dev/null
        ENTITLEMENTS=(--entitlements "$LOCAL_ENTITLEMENTS")
    fi
fi
sign ${ENTITLEMENTS[@]+"${ENTITLEMENTS[@]}"} "$APP"
codesign --verify --strict "$APP"
echo "bundle: $APP"
