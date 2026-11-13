# Sharing a layout

A configuration can be written to a `.fremspace-layout.json` and added to somebody else's. This
page says what goes in the file, what never does, and how a file from somebody else is read. The
rules are in `Sources/FremspaceCore/Share.swift` (with `ShareTests`), `LayoutPresets.swift` and
`LayoutWords.swift`. The editor's side is two pages: **Share** writes the file (`ShareEditor` in
`Settings/SettingsPages.swift`), **Layouts** shows the files and the ready-made layouts and uses
them (`Settings/LayoutsPage.swift`, the actions in `EditSession` and `LayoutsSession.swift`).

## Exporting

**Share → Export** writes the configuration selected, as it is in the editor. The page shows what
the file holds before it is written: how many displays, desktops, slots, drawers and scenes, the
apps it names, and what was left out. **Export…** asks where to save it, **Copy** puts the same
text on the clipboard, **Keep in Layouts** writes it among the layouts of the library (below).

### What goes in

- For each display that is not ignored: its desktops in order, with their label, their layout
  (each slot's place, its apps, whether it is locked, opens at login, takes Focus) and the
  display's drawers.
- The scenes: the desktops they show, the slot they put in Focus, the drawers they move, the apps
  they open.
- The names you gave: the configuration's, the displays' ("Main"), the desktops', the scenes'.
- The shape of each display that is connected when the file is written: its width over its
  height, to two decimals (1.78 for 16:9, 0.56 for the same display turned). It is the one thing
  the file says of a display itself, so that a layout made for a tall display is announced when
  it is put on a wide one, and drawn at its own shape until a display takes it. A display that is
  away when the file is written has no shape in it.

### What never goes in

- The displays' models and serial numbers, their size in points or in pixels. A display is its
  position in the file, the name you gave it (one without a name is "Display 2") and its shape.
- A display the configuration ignores.
- Shortcuts, general settings, and what Fremspace remembers (`state.json`): windows, titles, where
  things were.
- Where a desktop sends the windows that have no slot, when the config file says so by hand: it
  can name a display.

### What goes in only if you tick it

Browser profiles and window title filters are free text that can name an employer or a customer.
They are left out unless **Include browser profiles and window title filters** is ticked; the page
lists them beside the switch either way. Without them, two apps of a slot that differed by their
profile only become one.

## Adding a layout

**Layouts → Import a file…** reads a file from anywhere; a file dropped on the page is read the
same way, and the files of the library are drawn there (below). The file is somebody else's, so
nothing in it is taken at its word:

- its kind and version are read first: another kind of file is refused, and a file from a newer
  Fremspace says so instead of being half-read;
- it may weigh 1 MB at most, and hold 8 displays, 16 desktops a display, 16 slots a layout, 8 apps
  a slot, 32 scenes;
- names are cut to one line of 60 characters and 240 bytes; a slot or app identifier with anything
  but letters, digits, `.`, `_` and `-`, a rectangle outside its desktop, two slots with one
  identifier, two slots that overlap or two drawers on one edge refuse the whole file;
- a part of a scene that names a display, a desktop, a slot or a drawer the file does not have is
  dropped, the rest of the scene stays.

A file that holds one desktop and nothing else is a layout **for one desktop**: it is kept at once
among "Yours" and chosen (see below). Any other file is a **whole desk**, shown before anything is
added: one row for each display of the file, with its desktops drawn and the apps named in their
slots. An app that is not on your Mac is marked on the drawing itself. For each row you choose the
display of yours that takes its desktops, or **Leave it out**; one display of yours takes one
display of the file, and the drawings follow the shape of the display chosen. A row made for a
tall display and put on a wide one (or the reverse) says so. Beside the rows: the scenes in words,
with your displays' names; the apps that are missing; the apps that will be opened at your next
login; what is never in a file. **Add to** the configuration then:

- puts the file's desktops after yours on each display chosen;
- adds its drawers on the edges where you have none (yours stay where you have one);
- adds its scenes, their desktops moved to the positions they now have; a display left out takes
  its part of the scenes with it, and a scene with nothing left is not added.

Nothing of yours is replaced, the import is one step to undo, the editor then shows the first
desktop added, and nothing changes on screen until you save. **Only keep it in Layouts** adds
nothing and keeps the file in the library. macOS needs as many desktops as the configuration lists:
after saving, the Status page offers to add the ones that are missing. The slots of the apps that
are not on your Mac are added and stay empty. A slot opens its app at login unless that is switched
off in its inspector, and the file's slots come as their author set them: the apps they name that
are on your Mac will be opened at your next login.

## Layouts for one desktop

**Layouts → For one desktop** shows eight ready-made layouts (shapes only: you choose the apps) and
the desktops you kept, each as a small drawing. The one chosen is previewed beside, at the shape
of the display, on the desktop the editor shows (the two pickers change it), with a sentence that
says what would change there.

- **A ready-made layout** reshapes the desktop. The slots it had keep their name, their apps and
  their options, the one with the most room taking the largest shape. A shape left over is a new
  empty slot, and Save waits until it has an app. A slot left over stacks its apps in the smallest
  shape: nothing you placed is dropped. With **Focus on the largest slot**, the desktop's Focus
  goes there.
- **A desktop you kept** replaces the layout of the desktop and its Focus, and comes with its own
  apps. **Keep the desktop shown** writes the desktop the editor shows to the library: the same
  file as a configuration's, with one display and that desktop. Its drawers are the display's and
  are not in it; browser profiles and window title filters are in it only if the Share page's tick
  is on.
- **Use on this desktop** and **Add as a new desktop** are edits like any other: one step to undo,
  nothing moves until you save, and the editor then shows the desktop. A scene that put a slot in
  Focus forgets it when that slot is gone.

## The library

`~/Library/Application Support/Fremspace/Layouts/` holds the layout files kept: yours (**Keep in
Layouts** on the Share page, **Keep the desktop shown** on the Layouts page) and those of others
(imported and kept, or put in the folder: **Open the Layouts folder** shows it). The Layouts page
draws the files it can read, those of one desktop under "Yours" and the others under "Whole
desks"; **Remove from Layouts** moves a file to the Trash. A file is never written over another:
a second "Code" is `Code 2`. Only a plain file of 1 MB at most is read (a link is followed to the
file it points to).

## Where to post one

In the repository's **Discussions → Show and tell**, with a photo or a screenshot of the desk.
