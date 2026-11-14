# Changelog

What changed for the person using Fremspace, release by release. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow semver, and the version is
the one in `Sources/FremspaceCore/Version.swift`.

Anything that changes what Fremspace does gets a line under **Unreleased** in the same commit. A
release renames that section, sets the version and is tagged `vX.Y.Z` (see `docs/releasing.md`).

## Unreleased

- A desktop can keep its windows **as placed**: exactly where they are, over one another if they
  are, instead of in slots cut out of the screen. "Keep windows as placed" on a free desktop (or
  "As placed" above the screen) takes the places of the windows it shows; after Save, Fremspace
  puts them back there whenever it places windows again: a display plugged in again, a login,
  ⌃⌥⌘R. Between two of those the windows stay where you drag them. With "no floating windows" on,
  such a desktop keeps only the windows it has a place for, like any layout. Which window is in
  front is not restored.
- Browser profiles are read whatever the browser's language. Fremspace took the profile from a
  window title written the English way, "Page - Brave – Work"; a French Brave writes "Page – Brave
  – Work", and none of its profiles was seen. A profile whose name holds a dash ("Client - Work")
  is read whole. The Beta, Dev, Nightly and Canary versions of Brave, Chrome and Edge are known
  too, and the tab suffixes of a French browser ("Onglet inactif", "Utilisation de la mémoire") are
  removed like the English ones.
- You choose which configuration applies. When several fit the connected displays, Fremspace took
  the one that arranges the most of them, with no way to say otherwise: a copy made to try one
  more display took over, and going back meant deleting it. "Use on these displays" is now in a
  configuration's menus (right-click, or the … button) and in a line above its layouts whenever it
  is not the one in use, which also says why when it cannot be (a display that is not connected,
  or not saved yet). The menu bar has a Configuration submenu when there is a choice. The choice is
  kept for that set of displays, and "Let Fremspace choose" gives it back.
- Renaming a configuration shows a real text field. The name was typed in white on the selected
  row's colour, with an insertion point of that same colour.
- After a restart of the Mac, Brave windows are recognised again and go back to their desktops.
  Brave names a sleeping tab "… - Inactive tab - 123 MB freed"; Fremspace removed that suffix
  without the last word, so a window whose tabs had slept no longer looked like itself once they
  were all awake, stayed on the desktop where Brave had put it and was remembered there. A window
  that is still not known when it appears is also looked at again over the next minute, and
  nothing is remembered for it meanwhile.
- ⌃⌥⌘R (Re-apply layout) also takes back a window that sits on a free desktop while its place is a
  slot elsewhere. It left free desktops alone, whatever was on them, and only "Restore everything
  now" sent such a window back. A window you moved to a free desktop yourself stays: that move is
  remembered.
- A window whose place is a slot, and that its app put on a free desktop, keeps that place: showing
  the free desktop no longer records it there, so "Restore everything now" can still send it back.
- The windows of a drawer's apps are no longer sent to the free desktop. With "no floating windows"
  on, a window that had not joined its drawer yet when Fremspace sorted the windows (at its start,
  on another desktop than the one shown) was taken for a window without a slot.
- After a restart of the Mac, a slot in Focus has its window in front again. An app started after
  it (the browser) put its own window in front of the one you had enlarged.
- After a restart of the Mac the drawers stay closed. Each app comes to the front as it starts, and
  a window of a drawer's app in front was taken for you asking for it: the drawer opened by itself.
- A Mac that wakes no longer scatters the desk. Waking, macOS shows the built-in display first and
  the others seconds later, and Fremspace took each step for a change of displays: the drawers came
  out, and windows stayed where macOS had dropped them. It now waits for the displays to hold still;
  when they are the same as before, the drawers stay as they were and every window is sent back to
  its desktop and slot, as ⌃⌥⌘R does. After a real change of displays the windows are sorted too.

## 0.1.2

- A desktop taken out of the configuration can be removed from the Mac too. The editor says, under
  the desktop tabs, which macOS desktops the configuration in use does not list, and offers to
  remove each one through Mission Control. It asks first: macOS moves that desktop's windows to
  another one and nothing undoes it. Nothing is removed on a save.
- A window beside a drawer no longer comes in front of the slot in Focus when Fremspace starts or
  a drawer closes.
- Removing or moving a desktop in the editor no longer takes every slot of that display out of
  Focus: a Focus follows its desktop, and only the Focus of a removed desktop goes.
- A desktop added to a configuration takes the macOS desktop that nothing uses on its display, when
  one was left before the end by a desktop removed from the middle. Its layout used to apply
  nowhere, and nothing said so. In the editor its tab goes where Mission Control shows that
  desktop, and the editor says which desktop it took.
- The editor says when Mission Control shows the desktops of a display in another order than the
  tabs, and in which order, and "Match the tabs" puts each layout, with its windows, on
  the desktop at its tab's position.
- Moving a desktop tab while the desktops were not in Mission Control's order sent layouts and
  windows to desktops nobody chose. A move now leaves the tabs and Mission Control in one order.
- An app that is given a slot leaves the drawer: its windows put in a drawer by hand go to the
  slot when the configuration is saved. Saving the slot used to change nothing on screen. A drawer
  that names the app in one of its own slots keeps its windows.
- An app that is given a slot also leaves the free desktop: its window went there while it had no
  slot ("No floating windows on layout desktops") and stayed there once it had one. What you sent
  to the free desktop with a command stays.
- An app can be taken out of a slot: a button beside each app of the slot, the first included, and
  "Take … out of this slot" in the menu of a tile. The first app could only be replaced by another.
- The editor shows the windows you sent to a drawer by hand: a drawer slot lists them under "Sent
  here by hand", with a button that takes one out at once, and its tile draws their icons inside
  a dashed line and counts them. They are in no configuration, and nothing showed that they were
  held there.

## 0.1.1

- The disk image opens on a window that shows where to drag Fremspace.
- "Report a problem": the project's forms for a bug or an idea open in the browser, from the
  Maintenance page, from the menu's Recovery and from the editor's Help menu.

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
  The Dock taken to another display leaves the closed drawers closed.
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
