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
# fine and never runs. Catch that here, name by name: with the two counts alone, one method
# registered twice in place of one left out would pass. Each test file holds one suite, named
# after the file.
echo "==> registry check"
declared=$(for file in Tests/FremspaceCoreTests/*.swift; do
    suite=$(basename "$file" .swift)
    { grep -o 'func test[A-Za-z0-9_]*' "$file" || true; } | sed "s/^func /$suite./"
done | sort)
# One line per entry: "Suite.method" and the name it is registered under.
entries=$(sed -n 's/.*("\(test[A-Za-z0-9_]*\)", {.*(\$0 as! \([A-Za-z0-9_]*\))\.\(test[A-Za-z0-9_]*\)().*/\2.\3 \1/p' Tests/Shim/main.swift)
registered=$(printf '%s\n' "$entries" | cut -d' ' -f1 | sort)
written=$({ grep -o '("test' Tests/Shim/main.swift || true; } | wc -l | tr -d ' ')
count=$(printf '%s\n' "$registered" | grep -c . || true)
if [ "$written" != "$count" ]; then
    echo "error: $written entries in Tests/Shim/main.swift but $count are written as (\"name\", { ... (\$0 as! Suite).name() })" >&2
    exit 1
fi
misnamed=$(printf '%s\n' "$entries" | awk '{ split($1, part, "."); if (part[2] != $2) print "  " $2 " runs " $1 }')
if [ -n "$misnamed" ]; then
    printf 'error: registered under another name than the method they run:\n%s\n' "$misnamed" >&2
    exit 1
fi
twice=$(printf '%s\n' "$registered" | uniq -d)
if [ -n "$twice" ]; then
    printf 'error: registered more than once in Tests/Shim/main.swift:\n%s\n' "$twice" >&2
    exit 1
fi
if [ "$declared" != "$registered" ]; then
    echo "error: Tests/FremspaceCoreTests (<) and Tests/Shim/main.swift (>) do not list the same tests:" >&2
    diff <(printf '%s\n' "$declared") <(printf '%s\n' "$registered") | grep '^[<>]' >&2 || true
    exit 1
fi
echo "$count test methods declared and registered"

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
