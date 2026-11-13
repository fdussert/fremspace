#!/usr/bin/env bash
# Adapted from Fremkit (MIT).
# Shared swiftc plumbing.
#
# SwiftPM and Xcode are unusable on the development Mac (only the Command Line Tools: `swift build`
# and `swift test` abort, and the SDK ships no XCTest), so everything is built by calling swiftc
# directly. Source this file from the repo root; it defines SDK, OUT, TARGET and the build helpers.

# Pick an SDK the compiler can parse: the newest SDK shipped with the Command Line Tools can be
# newer than the compiler and fail to load the standard library.
fremspace_pick_sdk() {
    if [ -n "${FREMSPACE_SDK:-}" ]; then
        printf '%s\n' "$FREMSPACE_SDK"
        return 0
    fi
    local candidate
    for candidate in \
        /Library/Developer/CommandLineTools/SDKs/MacOSX26.2.sdk \
        /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk
    do
        if [ -d "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    xcrun --show-sdk-path
}

SDK="$(fremspace_pick_sdk)"
if [ ! -d "$SDK" ]; then
    echo "error: no usable macOS SDK found (set FREMSPACE_SDK to override)" >&2
    exit 1
fi

OUT=".build/swiftc"
SWIFTC="${FREMSPACE_SWIFTC:-swiftc}"

# Pinned deployment target, so the compiler enforces @available. `sysctl hw.optional.arm64` rather
# than `uname -m`, which reports x86_64 under a Rosetta shell on Apple silicon.
if [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = "1" ]; then
    ARCH="arm64"
else
    ARCH="$(uname -m)"
fi
TARGET="${FREMSPACE_TARGET:-${ARCH}-apple-macos13.0}"

# Swift language mode, pinned so a toolchain defaulting to Swift 6 does not change the rules.
SWIFT_VERSION="${FREMSPACE_SWIFT_VERSION:-5}"

# Build FremspaceCore as a static library plus its module.
# $1: output directory. $2 and beyond: extra swiftc flags (e.g. -enable-testing).
fremspace_build_core() {
    local out="$1"; shift
    mkdir -p "$out"
    "$SWIFTC" -sdk "$SDK" -target "$TARGET" -swift-version "$SWIFT_VERSION" "$@" \
        -emit-library -static -emit-module \
        -module-name FremspaceCore -parse-as-library \
        Sources/FremspaceCore/*.swift \
        -emit-module-path "$out/FremspaceCore.swiftmodule" \
        -o "$out/libFremspaceCore.a"
}
