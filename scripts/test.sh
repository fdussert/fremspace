#!/usr/bin/env bash
# Adapted from Fremkit (MIT).
# Compile and run the FremspaceCore tests with swiftc (no SwiftPM, no Apple XCTest).
#
# The test files are plain XCTest sources, linked against a tiny shim compiled as a module named
# XCTest (Tests/Shim/MiniXCTest.swift) and driven by an explicit registry (Tests/Shim/main.swift).
# Run from anywhere.
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=lib/swiftc-common.sh
source scripts/lib/swiftc-common.sh

# The shim has no runtime discovery: a test method missing from Tests/Shim/main.swift compiles
# fine and never runs. Catch that here.
echo "==> registry check"
declared=$(grep -ho 'func test' Tests/FremspaceCoreTests/*.swift | wc -l | tr -d ' ')
registered=$(grep -ho '("test' Tests/Shim/main.swift | wc -l | tr -d ' ')
if [ "$declared" != "$registered" ]; then
    echo "error: $declared test methods declared in Tests/FremspaceCoreTests but $registered registered in Tests/Shim/main.swift" >&2
    exit 1
fi
echo "$registered test methods declared and registered"

TESTING_OUT="$OUT/testing"
TEST_OUT="$OUT/test"
mkdir -p "$TESTING_OUT" "$TEST_OUT"
echo "SDK: $SDK"

# @testable import needs a library built with -enable-testing.
echo "==> FremspaceCore (testable)"
fremspace_build_core "$TESTING_OUT" -enable-testing -Onone

echo "==> XCTest shim"
"$SWIFTC" -sdk "$SDK" -target "$TARGET" -swift-version "$SWIFT_VERSION" \
    -emit-library -static -emit-module \
    -module-name XCTest -parse-as-library \
    Tests/Shim/MiniXCTest.swift \
    -emit-module-path "$TEST_OUT/XCTest.swiftmodule" \
    -o "$TEST_OUT/libXCTest.a"

echo "==> FremspaceCoreTests"
"$SWIFTC" -sdk "$SDK" -target "$TARGET" -swift-version "$SWIFT_VERSION" \
    -module-name FremspaceCoreTests \
    Tests/Shim/main.swift \
    Tests/FremspaceCoreTests/*.swift \
    -I "$TEST_OUT" -L "$TEST_OUT" -lXCTest \
    -I "$TESTING_OUT" -L "$TESTING_OUT" -lFremspaceCore \
    -o "$TEST_OUT/FremspaceCoreTests"

echo "==> running"
"$TEST_OUT/FremspaceCoreTests"
