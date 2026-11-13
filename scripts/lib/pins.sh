#!/usr/bin/env bash
# What a release build pins: Sparkle, the one thing Fremspace is built with that is not on the Mac.
# Only the distributed app has it (FREMSPACE_SPARKLE=1, which scripts/release.sh sets); the everyday
# build fetches nothing. Source from the repo root.

# Sparkle 2: the release tarball, and its SHA-256 as GitHub publishes it for the asset. A file that
# changed on the server fails the build instead of shipping. Bump both together.
SPARKLE_VERSION="2.10.0"
SPARKLE_TARBALL="Sparkle-${SPARKLE_VERSION}.tar.xz"
SPARKLE_SHA256="c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c"
# Where it is unpacked; sign_update and generate_keys are in its bin/.
SPARKLE_DIR=".build/sparkle-${SPARKLE_VERSION}"
# Downloaded once, kept across builds and clean checkouts.
SPARKLE_CACHE="${FREMSPACE_BUILD_CACHE:-$HOME/Library/Caches/Fremspace-build}"

# Sparkle.framework and its tools in $SPARKLE_DIR: downloaded if the cache has no tarball, checked
# against the pinned hash every time, unpacked once.
fremspace_fetch_sparkle() {
    mkdir -p "$SPARKLE_CACHE"
    local tarball="$SPARKLE_CACHE/$SPARKLE_TARBALL"
    if [ ! -f "$tarball" ]; then
        local url="https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/${SPARKLE_TARBALL}"
        echo "downloading $url"
        curl -fL --retry 3 -o "$tarball.part" "$url"
        mv "$tarball.part" "$tarball"
    fi
    local actual
    actual="$(shasum -a 256 "$tarball" | awk '{print $1}')"
    if [ "$actual" != "$SPARKLE_SHA256" ]; then
        echo "error: $SPARKLE_TARBALL is $actual, pinned $SPARKLE_SHA256" >&2
        return 1
    fi
    if [ ! -d "$SPARKLE_DIR/Sparkle.framework" ]; then
        rm -rf "$SPARKLE_DIR" && mkdir -p "$SPARKLE_DIR"
        tar -xJf "$tarball" -C "$SPARKLE_DIR"
    fi
}

# The public half of the key that signs updates, as the app carries it (SUPublicEDKey).
# FREMSPACE_SPARKLE_PUBLIC_KEY overrides the file, for trying an update with a throwaway key.
fremspace_sparkle_public_key() {
    if [ -n "${FREMSPACE_SPARKLE_PUBLIC_KEY:-}" ]; then
        printf '%s\n' "$FREMSPACE_SPARKLE_PUBLIC_KEY"
    else
        { grep -v '^#' packaging/sparkle/public-key.txt || true; } | tr -d '[:space:]'
    fi
}
