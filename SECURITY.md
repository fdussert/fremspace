# Security

Fremspace holds the Accessibility permission: it can read the titles of every window and move them.
With the Hyper key on it also filters key presses to read Caps Lock. That makes its integrity matter
more than its size suggests.

## What it does with that

- It reads window titles, positions and the apps they belong to, to place windows. Titles are kept
  in memory and, for windows it must find again after a restart, in
  `~/Library/Application Support/Fremspace/state.json`. Nothing leaves the Mac: the one request the
  downloaded app makes is for the feed of its own versions (Sparkle), and it sends nothing with it.
- An update is accepted only when both the feed and the archive carry the project's EdDSA
  signature, checked before the archive is unpacked. The private key is in the maintainer's
  keychain and nowhere else.
- The key filter of the Hyper key reads one thing per key press: whether Caps Lock is held. It keeps
  no key, logs no key, and is not installed unless the setting is on.
- `fremspace://` links can be opened by any app without a prompt, and by a web page after the
  browser's one. A link can:
  - show a desktop (`desktop/<label>`) or a scene (`scene/<name>`, which also gives the Focus,
    opens or closes the drawers and opens the apps that the scene lists in the configuration);
  - run one of these commands (`run/<id>`): the palette, the editor, the window menu, re-apply the
    layouts (which also ends a pause), Focus and back, go to the slot beside, next or previous
    window of a stack, open or close a drawer, show one of the first four scenes, and the quick
    resizes of the window in front with their "restore".

  A link cannot write the configuration file (the slot swaps are refused), pause Fremspace, send a
  window to a drawer or press a menu item of another app (side by side); those stay on the
  keyboard and in the menu. A refused link beeps and is logged. No link takes a path or a value
  other than the name of a desktop, a scene or a command. Focus and the state of the drawers are
  remembered in `state.json`, as when a shortcut changes them.
- Releases are signed with a Developer ID under the hardened runtime and notarized by Apple.

## Reporting a vulnerability

Please do not open a public issue. Use GitHub's private vulnerability reporting on this repository
(Security, then "Report a vulnerability"). Say what you found, how to reproduce it and on which
version.

Only the latest release is supported.
