# Releasing Fremspace

How the downloadable app is built, signed, notarized and published. Contributors never need any of
this: `scripts/build.sh` builds an app that runs from a checkout.

## What is shipped

`Fremspace-X.Y.Z.dmg`: `Fremspace.app` and a link to /Applications. The app is one executable for
Apple silicon and Intel, macOS 13 or later, signed with a Developer ID Application identity under the
hardened runtime (no entitlement: Fremspace asks for Accessibility at run time), notarized and
stapled, as is the DMG.

The distributed app also holds `Contents/Frameworks/Sparkle.framework`, which the everyday build
does not: it is what updates it. Sparkle is pinned in `scripts/lib/pins.sh` (version and SHA-256),
downloaded once into `~/Library/Caches/Fremspace-build` and checked against the pin at every
build. Beside the DMG, a release publishes what the installed apps read: `Fremspace-X.Y.Z.zip`
(the stapled app) and `appcast.xml` (the feed), both signed with the update key.

Fremspace cannot be on the Mac App Store: it is not sandboxed, and it moves windows between desktops
through private calls of the window server that the store refuses.

## Once

- A **Developer ID Application** certificate in the login keychain. It belongs to the developer
  team, not to an app: the one that signs another app of the same team signs Fremspace.
- A **notarytool keychain profile** (`xcrun notarytool store-credentials <name> --apple-id … --team-id …`).
  It holds the account's credentials, not an app's: `scripts/release.sh` uses `fremkit-notary` unless
  `FREMSPACE_NOTARY_PROFILE` names another.
- **The update key** (Sparkle's EdDSA key): the private half in the login keychain (item "Private
  key for signing Sparkle updates"), the public half in `packaging/sparkle/public-key.txt`, from
  where the build writes it into the app. Every installed app only accepts updates signed by that
  key, so losing it means no installed app can ever be updated again: keep a copy outside the Mac
  (`generate_keys -x <file>` exports it). The file holds the key of the owner's other app,
  Fremkit. To give Fremspace its own instead, before the first release and never after:
  `.build/sparkle-*/bin/generate_keys --account fremspace` prints the public key to put in the
  file, and `sign_update` then needs `--account fremspace` in `scripts/release.sh`.

## Each release

1. On `main`: set the version in `Sources/FremspaceCore/Version.swift`, rename `## Unreleased` in
   `CHANGELOG.md` to `## X.Y.Z` (and put an empty `## Unreleased` back above it), commit.
2. `bash scripts/release.sh X.Y.Z`. It refuses a dirty tree or a version that does not match, runs
   the tests, builds `dist/release/Fremspace.app` (the everyday `dist/Fremspace.app` is left alone),
   signs, notarizes and staples the app, then the DMG, and checks both with Gatekeeper. Then it
   zips the stapled app, signs the zip with the update key (macOS asks once whether `sign_update`
   may read it), checks that signature against the key the app carries, and writes and signs
   `appcast.xml`, whose release notes are the changelog's section.
   `FREMSPACE_SKIP_NOTARIZE=1` skips Apple, for a look at the result on this Mac.
3. It ends by printing the commands that publish (the tag, the GitHub release with the DMG under its
   versioned name and as `Fremspace.dmg`, the zip and `appcast.xml`). Nothing is pushed, tagged or
   uploaded before the owner runs them.

### Why the feed is a release asset

The app's feed is `https://github.com/fdussert/fremspace/releases/latest/download/appcast.xml`,
which GitHub redirects to the `appcast.xml` of the newest published release. Publishing the release
is then the one act that offers the update: there is no second place to keep in step, and no
branch to commit a feed to. The feed carries the newest release only, which is all Sparkle needs.
Two consequences: a release published without `appcast.xml` hides every later version from the
installed apps until one is published with it, and a pre-release is never "latest", so it is
offered to nobody. The app refuses a feed that is not signed: after any edit of `appcast.xml`,
`sign_update appcast.xml` again.

### Trying an update before a release

An updater that does not work in a published version can never be repaired from afar, so a real
update is played on this Mac first: `bash scripts/try-update.sh`. It builds the checkout twice
with Sparkle, as 0.0.1 and as 0.0.2, signs 0.0.2 with a throwaway key made on the spot (never the
owner's), serves the feed on 127.0.0.1 and runs 0.0.1 in place of the Fremspace that runs. Within
a few seconds a window offers 0.0.2 with its notes; Install replaces the app and relaunches it.
Back in the terminal, Return makes the script say which version ended up running and put the
everyday app back. The apps it builds are signed by the local identity, so they keep the
Accessibility grant of the checkout's app.

## The Accessibility grant

macOS ties the grant to the signature. Every release is signed by the same team, so an update keeps
the grant. A build from a checkout is signed by a local identity (`scripts/create-signing-identity.sh`)
or ad hoc: it is another app to macOS, with its own grant.

## The site

`site/` is the page at <https://fremspace.app/>: plain HTML, CSS and JavaScript, nothing to build.
Cloudflare serves that folder as the static assets of a Worker with no code: every time a commit
reaches `main` it runs `npx wrangler deploy`, which reads `wrangler.jsonc` at the root of the
repository (no build command), so a change to the page is live a minute after it is pushed.
`site/_headers` holds the security and cache headers Cloudflare sends, `site/404.html` the page
for an unknown address. The Download button points at
`releases/latest/download/Fremspace.dmg`, which exists once a release is published.

When a capture of the app changes, the picture shown for a shared link (`site/assets/social.png`,
1280 x 640) is drawn again from it.

## Not there yet

- **Homebrew.** A cask in a tap (`brew install --cask …`) once the repository is public.
