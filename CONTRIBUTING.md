# Contributing

Thanks for wanting to help. Where to start depends on what you have in mind:

- **A bug or an idea**: open an [issue](https://github.com/fdussert/fremspace/issues/new/choose).
  A macOS update that breaks Fremspace is the most useful thing to report: say the macOS version
  and what stopped working.
- **A question**: ask in [Q&A](https://github.com/fdussert/fremspace/discussions/categories/q-a).
- **Your desk**: post it in
  [Show and tell](https://github.com/fdussert/fremspace/discussions/categories/show-and-tell),
  with the layout file if you want others to load it (see `docs/sharing.md`).
- **A fix**: pull requests are welcome, most of all for a Mac, a display or a macOS the maintainer
  does not have.
- **A feature**: open an issue first (the "Idea" form), before writing code. See below for what
  to expect. Working with a coding agent? Point it at [AGENTS.md](AGENTS.md).
- **A security issue**: see [SECURITY.md](SECURITY.md), not a public issue.

A pull request says what it changes and how to see it; the template asks for both.

## What to expect

Fremspace is one person's tool, shared as it is. Most of it cannot be checked by the test suite:
a change is tried by hand, on real displays, and then has to keep working across macOS versions.
So the bar for a feature is high, and "no" is a common answer to a good idea: a pull request for
a feature that was not agreed in an issue first is likely to be closed. Answers come when there is
time; there is no promised delay. The licence is MIT: a fork that goes its own way is welcome too.

## The rules of the house

- `scripts/test.sh` must pass. The rules live in `Sources/FremspaceCore` and are tested there; a
  change to a rule comes with its test. Every test is registered by hand in `Tests/Shim/main.swift`.
- `scripts/build.sh` builds `dist/Fremspace.app` with the Command Line Tools alone (no Xcode, no
  SwiftPM). Run `scripts/create-signing-identity.sh` once so the Accessibility grant survives your
  rebuilds.
- Code, comments, commit messages and documents are in English. Comments say why, not what.
- What changes for the person using Fremspace gets a line under **Unreleased** in `CHANGELOG.md`.
- Anything that needs real key presses or a real display (hot keys, the Hyper key, the notch) cannot
  be tested by the suite: say in the pull request what you tried by hand, on which Mac and macOS.

## What will be refused

- Network code, telemetry, or a dependency to fetch. (The one request the downloaded app makes is
  for its own updates, through Sparkle, in release builds only.)
- A change that asks for another permission without a feature that cannot work otherwise.

Releases are built and signed by the maintainer only (`docs/releasing.md`).
