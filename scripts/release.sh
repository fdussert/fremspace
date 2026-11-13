#!/usr/bin/env bash
# Adapted from Fremkit (MIT).
# Build everything a release publishes, and stop before publishing anything.
#
#   bash scripts/release.sh X.Y.Z
#
# Run it on the release commit (Version.swift says X.Y.Z, CHANGELOG.md has a "## X.Y.Z" section;
# see docs/releasing.md). It refuses a dirty tree or a version that does not match, runs the tests,
# then builds Fremspace.app for Apple silicon and Intel in dist/release (the everyday dist/Fremspace.app
# is left alone), signs it with the Developer ID identity, notarizes and staples it, and does the
# same for a DMG holding the app and a link to /Applications. Then, for the apps already installed:
# it zips the stapled app, signs that zip with the update key in the login keychain (Sparkle's
# sign_update), and writes and signs the feed, appcast.xml. It ends by printing the commands that
# publish, for the owner to run. Nothing here pushes, tags or uploads.
#
# Environment:
#   FREMSPACE_SIGN_IDENTITY     the identity to sign with (name or hash). Default: the first
#                               "Developer ID Application" identity in the keychain.
#   FREMSPACE_NOTARY_PROFILE    the notarytool keychain profile (`xcrun notarytool
#                               store-credentials`; this script never sees the Apple ID or its
#                               password). Default: fremkit-notary, the profile the owner already has.
#   FREMSPACE_SKIP_NOTARIZE=1   do not notarize: a DMG and an update to try locally, which
#                               Gatekeeper refuses on any other Mac.
#   FREMSPACE_SPARKLE_KEY_FILE  sign the update with this private key file instead of the keychain
#                               (`sign_update --ed-key-file`), with FREMSPACE_SPARKLE_PUBLIC_KEY
#                               for its public half. For trying an update, never for a release.
set -euo pipefail

cd "$(dirname "$0")/.."

WANTED="${1:-}"
VERSION="$(sed -n 's/^public let version = "\(.*\)"$/\1/p' Sources/FremspaceCore/Version.swift)"
if [ -z "$WANTED" ]; then
    echo "usage: bash scripts/release.sh X.Y.Z (Version.swift says $VERSION)" >&2
    exit 1
fi

# --- Refusals -----------------------------------------------------------------------------------
if [ "$WANTED" != "$VERSION" ]; then
    echo "error: asked for $WANTED, Sources/FremspaceCore/Version.swift says $VERSION" >&2
    exit 1
fi
if [ -n "$(git status --porcelain)" ]; then
    echo "error: the working tree is not clean; a release is built from a commit" >&2
    exit 1
fi
if ! grep -q "^## $VERSION\$" CHANGELOG.md; then
    echo "error: CHANGELOG.md has no \"## $VERSION\" section" >&2
    exit 1
fi
IDENTITY="${FREMSPACE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/^ *[0-9]*) \([0-9A-F]\{40\}\) "Developer ID Application: .*/\1/p' | head -1)}"
if [ -z "$IDENTITY" ]; then
    echo "error: no Developer ID Application identity in the keychain (set FREMSPACE_SIGN_IDENTITY)" >&2
    exit 1
fi
PROFILE="${FREMSPACE_NOTARY_PROFILE:-fremkit-notary}"
# What trying an update overrides must never reach a release: an app shipped with a throwaway key,
# another feed or another version could not be updated, ever. A local look (FREMSPACE_SKIP_NOTARIZE)
# may use them.
if [ "${FREMSPACE_SKIP_NOTARIZE:-}" != "1" ]; then
    for override in FREMSPACE_VERSION FREMSPACE_SPARKLE_PUBLIC_KEY FREMSPACE_SPARKLE_FEED_URL FREMSPACE_SPARKLE_KEY_FILE; do
        if [ -n "${!override:-}" ]; then
            echo "error: $override is set; unset it for a release (it is for trying an update)" >&2
            exit 1
        fi
    done
fi
# shellcheck source=lib/pins.sh
source scripts/lib/pins.sh
APP_KEY="$(fremspace_sparkle_public_key)"
if [ -z "$APP_KEY" ]; then
    echo "error: packaging/sparkle/public-key.txt holds no key; an app without one can never be updated" >&2
    exit 1
fi
REPO_URL="https://github.com/fdussert/fremspace"

DIST="dist/release"
APP="$DIST/Fremspace.app"
DMG="$DIST/Fremspace-$VERSION.dmg"
WORK=".build/release"
rm -rf "$DIST" "$WORK" .build/swiftc/release-*
mkdir -p "$DIST" "$WORK"

# --- Tests, build, sign -------------------------------------------------------------------------
echo "==> tests"
bash scripts/test.sh | tail -1

FREMSPACE_APP="$APP" FREMSPACE_ARCHS="arm64 x86_64" FREMSPACE_SIGN_IDENTITY="$IDENTITY" FREMSPACE_TIMESTAMP=1 \
    FREMSPACE_SPARKLE=1 bash scripts/build.sh

if [ "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist" 2>/dev/null)" != "$APP_KEY" ]; then
    echo "error: $APP does not carry the update key; it could never be updated" >&2
    exit 1
fi

ARCHS="$(lipo -archs "$APP/Contents/MacOS/Fremspace")"
if [ "$ARCHS" != "arm64 x86_64" ] && [ "$ARCHS" != "x86_64 arm64" ]; then
    echo "error: the executable holds \"$ARCHS\", not both architectures" >&2
    exit 1
fi
# Read once into a variable: `codesign … | grep -q` under pipefail fails whenever grep stops
# reading early and codesign gets SIGPIPE.
SIGNATURE="$(codesign -dvv "$APP" 2>&1 || true)"
if ! grep -q '^Authority=Developer ID Application:' <<<"$SIGNATURE"; then
    echo "error: $APP is not signed with a Developer ID Application identity; Apple would refuse it" >&2
    exit 1
fi
if ! grep -q 'flags=.*runtime' <<<"$SIGNATURE"; then
    echo "error: $APP is not signed with the hardened runtime" >&2
    exit 1
fi

# Submits $1 and waits. On anything but "Accepted", prints Apple's log for it and fails.
notarize() {
    local file="$1" result="$WORK/$(basename "$1").json"
    echo "==> notarizing $(basename "$file") (this takes a few minutes)"
    xcrun notarytool submit "$file" --keychain-profile "$PROFILE" --wait \
        --output-format json > "$result" || true
    local status id
    status="$(plutil -extract status raw -o - "$result" 2>/dev/null || echo unknown)"
    id="$(plutil -extract id raw -o - "$result" 2>/dev/null || echo '')"
    echo "    submission ${id:-?}: $status"
    if [ "$status" != "Accepted" ]; then
        cat "$result" >&2
        if [ -n "$id" ]; then
            echo "==> notarytool log $id" >&2
            xcrun notarytool log "$id" --keychain-profile "$PROFILE" >&2 || true
        fi
        exit 1
    fi
}

# Plain hdiutil: the app and a link to /Applications to drag it onto, nothing else.
make_dmg() {
    echo "==> DMG"
    local stage="$WORK/dmg"
    rm -rf "$stage"
    mkdir -p "$stage"
    ditto "$APP" "$stage/Fremspace.app"
    ln -s /Applications "$stage/Applications"
    rm -f "$DMG"
    hdiutil create -volname "Fremspace" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
    codesign --force --timestamp --sign "$IDENTITY" "$DMG"
}

# What the installed apps download: the app zipped the way Sparkle documents, and the feed that
# announces it. The private key never leaves the keychain: sign_update reads it there (macOS may
# ask to allow that once).
ZIP="$DIST/Fremspace-$VERSION.zip"
make_update() {
    echo "==> update archive and feed"
    # shellcheck source=lib/swiftc-common.sh
    source scripts/lib/swiftc-common.sh
    fremspace_build_core "$WORK/core" -O
    "$SWIFTC" -O -sdk "$SDK" -target "$TARGET" -swift-version "$SWIFT_VERSION" scripts/appcast/main.swift \
        -I "$WORK/core" -L "$WORK/core" -lFremspaceCore -o "$WORK/appcast"
    local sign_update="$SPARKLE_DIR/bin/sign_update" key=()
    if [ -n "${FREMSPACE_SPARKLE_KEY_FILE:-}" ]; then key=(--ed-key-file "$FREMSPACE_SPARKLE_KEY_FILE"); fi

    rm -f "$ZIP"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
    local signed signature
    signed="$("$sign_update" ${key[@]+"${key[@]}"} "$ZIP")"
    signature="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' <<<"$signed")"
    if [ -z "$signature" ]; then
        echo "error: sign_update printed no signature: $signed" >&2
        exit 1
    fi
    # Checked against the key the app carries, the way Sparkle will: a signature from any other
    # key (a test key left in FREMSPACE_SPARKLE_KEY_FILE, a second keychain item) would publish an
    # update that every installed app refuses.
    "$WORK/appcast" verify "$ZIP" "$signature" "$APP_KEY"
    "$WORK/appcast" feed "$VERSION" "$REPO_URL/releases/download/v$VERSION/Fremspace-$VERSION.zip" "$ZIP" "$signature" \
        CHANGELOG.md > "$DIST/appcast.xml"
    # The app refuses a feed that is not signed (SURequireSignedFeed). sign_update writes the
    # signature into the XML: nothing may touch the file after this.
    "$sign_update" ${key[@]+"${key[@]}"} "$DIST/appcast.xml" >/dev/null
    "$sign_update" --verify ${key[@]+"${key[@]}"} "$DIST/appcast.xml"
}

if [ "${FREMSPACE_SKIP_NOTARIZE:-}" = "1" ]; then
    make_dmg
    make_update
    codesign --verify --strict --verbose=2 "$APP"
    echo "signed, NOT notarized (FREMSPACE_SKIP_NOTARIZE=1): $DMG, $ZIP, $DIST/appcast.xml"
    exit 0
fi

# --- Notarize, staple ---------------------------------------------------------------------------
ditto -c -k --keepParent "$APP" "$WORK/Fremspace.zip"
notarize "$WORK/Fremspace.zip"
xcrun stapler staple "$APP"

make_dmg
notarize "$DMG"
xcrun stapler staple "$DMG"

# After the staple: the app an update installs carries its ticket too.
make_update

# --- Verification -------------------------------------------------------------------------------
echo "==> verification"
codesign --verify --strict --verbose=2 "$APP"
spctl -a -t exec -vv "$APP"
spctl -a -t open --context context:primary-signature -vv "$DMG"
xcrun stapler validate "$APP"
xcrun stapler validate "$DMG"

# The same DMG under a name that never changes, so a page can link
# <repo>/releases/latest/download/Fremspace.dmg and start the download itself.
cp "$DMG" "$DIST/Fremspace.dmg"
# The section of the changelog, as the release's notes.
awk -v version="$VERSION" '
    $0 == "## " version { on = 1; next }
    on && /^## / { exit }
    on { print }
' CHANGELOG.md > "$DIST/notes.md"
SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"

cat <<DONE

Built, signed, notarized and stapled:
  $DMG
  sha256 $SHA
For the apps already installed (signed with the update key):
  $ZIP
  $DIST/appcast.xml

Nothing was published. To publish, from the release commit on main:
  git tag v$VERSION && git push origin main v$VERSION
  gh release create v$VERSION "$DMG" "$DIST/Fremspace.dmg" "$ZIP" "$DIST/appcast.xml" \\
      --title "Fremspace $VERSION" --notes-file "$DIST/notes.md"
The feed is $REPO_URL/releases/latest/download/appcast.xml: publishing the release is what
offers the update. A release without appcast.xml would hide every later one from installed apps.
DONE
