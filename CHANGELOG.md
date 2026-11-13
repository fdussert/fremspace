# Changelog

What changed for the person using Fremspace, release by release. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow semver, and the version is
the one in `Sources/FremspaceCore/Version.swift`.

Anything that changes what Fremspace does gets a line under **Unreleased** in the same commit. A
release renames that section, sets the version and is tagged `vX.Y.Z` (see `docs/releasing.md`).

## Unreleased

## 0.1.0

The first version to be packaged.

- **Layouts per desktop.** Each desktop (Space) of each display has a layout of slots; an app's
  windows go to their slot and stay there. Free desktops take whatever has no slot.
  With "No floating windows on layout desktops", a window dropped where it has no slot goes to a
  free desktop, and a fixed-size window (a mail reminder) joins the desktop of its app. A window
  Fremspace opens itself (the Layouts folder, the config file) stays where you are.
  "Apps that may float" lists the apps left alone (Finder, Calculator): their windows stay on the
  desktop where they open, over its layout, and are not pulled to a slot their app has elsewhere.
- **Configurations per set of displays.** The desk, the laptop alone, another office: the one that
  matches the displays connected is applied. A "travel version" turns the slots of the big
  displays into desktops of the laptop. A display can have a name of yours ("Left") instead of the
  model macOS shows.
- **Focus.** One shortcut gives a slot the whole desktop, the same shortcut gives it back. Any
  number of slots of a desktop can have it.
- **Stacks.** Several windows in one slot, and a shortcut to go through them.
- **Side by side.** ⌃⌥⌘S opens a second window of the app in front and puts the two half and half,
  in the window's slot or on its display; the same shortcut stacks them again. The second window
  is asked of the app through its "New Window" menu item; an app that has none is left alone.
- **Drawers.** Windows parked off the side of a display, slid in and out by a shortcut.
- **Restore after login.** The apps that have a slot are opened and every window is put back.
  What is remembered for that (titles, a browser's tab titles, a document's address) is listed in
  `SECURITY.md`; a window that did not come back is forgotten after 90 days.
- **Palette.** One field finds an open window on any desktop, an app to launch, a desktop, a scene
  or a command; without a query it is a switcher, over a map of every desktop that the arrow keys
  go through.
- **Scenes.** Several displays change desktop at once. A scene can also put a slot in Focus, open
  or close a drawer and open apps that are not running; asked for again while it is shown, it is
  left: the displays go back to the desktops they showed, and the Focus it gave and the drawers it
  moved to what they were.
- **Layouts to choose and to share.** The Layouts page shows layouts as pictures. For one
  desktop: eight ready-made layouts (shapes; you choose the apps) and the desktops you kept, with
  a preview of what the one chosen makes of your desktop, drawn at the shape of its display, and
  a sentence that says what changes. A ready-made layout keeps the apps the desktop had, the
  largest slot first; a desktop you kept comes with its own. Either is used on the desktop or
  added as a new one, in one step to undo, and nothing moves until you save. For a whole desk:
  the Share page writes a configuration to a `.fremspace-layout.json` (desktops, layouts, drawers,
  scenes, and the shape of each display) without the displays' models or serial numbers, and with
  browser profiles and title filters only if you tick them. A layout file, imported, dropped on
  the page or kept beside the config file, is seen before it is added: each of its displays with
  its desktops drawn, the apps named in their slots, an app that is not on your Mac marked on the
  drawing, a layout made for a tall display announced on a wide one, and its scenes in words. Its
  desktops and scenes are added after yours on the displays you choose.
- **The notch.** A desktop's name hangs from it when the display changes desktop; resting the
  pointer on it opens the map of desktops, which takes the arrow keys, Return and Escape while the
  pointer is on the map (resting on the notch alone, the keys stay with the app in front).
- **Window previews**, an option that is off unless you switch it on. The palette shows a picture
  of the selected window; the maps of desktops and the editor show the window of each slot. It
  needs the Screen Recording permission, which macOS asks for when you save with the option on;
  the pictures stay in memory.
- **Hyper key.** Caps Lock can stand for ⌃⌥⌘, with no other tool.
- **Quick sizes.** A half, a third or two thirds of the display, the whole of it or its center for
  the window in front, from the menu of window commands (⌃⌥⌘W). They have no shortcut until you
  give them one on the Shortcuts page.
- **Calls in full screen.** The meeting window of Microsoft Teams or Zoom goes to full screen when
  the call starts.
- **Commands that change the layouts** ("Lock on this desktop", "Make focusable", swapping two
  slots, an edge resized with "resize layouts" on) write the config file at once. While the editor
  holds changes that are not saved they do nothing and say why, so that the editor can always save.
  "Lock on this desktop" makes no slot that would lie over another, and says so.
  `config.json.bak` is the file as it was before the editor's last Save: these commands leave it.
  A config file that is a link (kept with your dotfiles) is written through the link.
- **An editor** for the layouts. It opens on the displays it found and one button to set them up,
  with a desktop per desktop macOS has; a free desktop offers "Capture this desktop" where its
  layout will be. Each slot's tile says what is particular to it (Focus, unlocked, several apps)
  and its size in plain fractions ("3/5"); a drawer shows how far it comes over the layout when
  the pointer is on its rail. The inspector shows the selected slot alone, with its apps in one
  list. Scenes and Share say which configuration they are about and can change it. Settings that
  act without Save are marked "At once". Also: desktops reordered by dragging their tab, a Status
  page that lists what needs attention, a search across the settings, every shortcut changeable,
  and `fremspace://` links for other tools. A shortcut written by hand in the config file that
  cannot be used (a misspelt modifier, no ⌃, ⌥ or ⌘) is not registered, and the menu names it.
- **The editor is a Mac window.** While it is open Fremspace has a menu bar: Save and Revert to
  Saved, Undo, Redo and Find, and a Layout menu with the keys of the editor (split with ⌘D, the
  slot beside with ⌥⌘ and an arrow, a slot one stop larger or smaller with ⇧⌥⌘ and an arrow, the
  desktops with ⌘1 to ⌘9 and ⌃⇥, the displays with ⌃⌥⇥). The window is named after what it shows.
  Closing it or quitting with unsaved changes asks first; the bar beside Save says where the
  unsaved changes are and the sidebar marks those rows; Revert can be undone. A control that is
  off says why under the pointer. VoiceOver names each slot, can select, split and remove it, and
  moves a divider from stop to stop. Slot tiles share one ground, with the app's colour as a line
  along the top; a shortcut is shown as its keys, and one on ⌘ or ⌥ alone is taken with a
  warning; a shortcut being typed stops listening when you leave the window. "Add desktops" in
  the editor adds what the saved configuration in use lacks, never what is still unsaved.
- **What needs macOS 26.4.** Sending a window to another desktop: to the desktop of its slot, back
  where it was after a restart, a drawer following its display. On an older macOS the windows are
  arranged on the desktop where they are, and the Status page says so.
- **Updates.** The downloaded app updates itself (Sparkle): about once a day it looks for a newer
  version, and **Check for Updates…** is in the menu. It fetches one file and sends nothing; the
  switch is on the General page.
