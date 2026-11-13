# For coding agents

Fremspace is a macOS window manager in Swift, built with plain `swiftc`. Read this before changing it.

## Build and test

- `scripts/test.sh`: FremspaceCore's unit tests. There is no XCTest on the development Mac: the tests
  use XCTest syntax on a small shim, and **every test method is registered by hand** in
  `Tests/Shim/main.swift`. A test you do not register never runs. A `try` inside `XCTAssert…` does
  not compile on the shim: compute the value first, and register a throwing test with `try`.
- `scripts/build.sh`: `dist/Fremspace.app`. No SwiftPM, no Xcode project, no dependency.
- Swift 5 mode, macOS 13 target.

## Where things go

- `Sources/FremspaceCore`: the rules (layouts, routing, matching, geometry, the config file), with
  no AppKit. A rule goes here, with its test.
- `Sources/Fremspace`: the app (Accessibility, the window server's private calls, the editor in
  SwiftUI). Not covered by the tests.
- `docs/spikes`: what was found about the window server's private calls, with the measurements.
  The maintainer's design notes are not in the repository; the reasons that matter are in the
  comments of the code and in `CHANGELOG.md`.

## Rules agents tend to break

- Do not claim something works because the tests pass when it needs real key presses, a real
  display or an unlocked session (hot keys, the Hyper key, the notch, anything through
  Accessibility). Say what was checked and what was not.
- A locked screen makes every app answer Accessibility with no window: it looks like a broken build.
- Settings in the config file apply when the owner saves in the editor, never as they are changed.
- No network code, no telemetry, no dependency, no new permission. Two exceptions are decided.
  Window previews need Screen Recording, are off unless switched on, and ask for it only then.
  The distributed app updates itself through Sparkle (`Updater.swift`, compiled only with
  `FREMSPACE_SPARKLE`, which `scripts/release.sh` sets): it fetches the feed of its versions and
  sends nothing. The everyday build has no Sparkle and makes no request at all.
  Already there, and listed in the README: macOS asks for notifications the first time a window
  command confirms something (`WindowCommands.notify`); nothing depends on the answer.
- Everything in the repository is in English. Comments say why, not what.
- Nothing personal in tests, fixtures, captures or documents: no display serial, window title,
  organisation or e-mail.
- A line under **Unreleased** in `CHANGELOG.md` for anything the person using Fremspace would notice.
- Never push, tag or publish a release: `scripts/release.sh` stops before that, for the maintainer.
