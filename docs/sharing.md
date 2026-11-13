# Sharing a layout

A configuration can be written to a `.fremspace-layout.json` and added to somebody else's. This
page says what goes in the file, what never does, and how a file from somebody else is read. The
rules are in `Sources/FremspaceCore/Share.swift` (with `ShareTests`); the editor's side is the
**Share** page (`ShareEditor` in `Settings/SettingsPages.swift`, the actions in `EditSession`).

## Exporting

**Share → Export** writes the configuration selected, as it is in the editor. The page shows what
the file holds before it is written: how many displays, desktops, slots, drawers and scenes, the
apps it names, and what was left out. **Export…** asks where to save it, **Copy** puts the same
text on the clipboard, **Keep in the library** writes it among the layouts of the library (below).

### What goes in

- For each display that is not ignored: its desktops in order, with their label, their layout
  (each slot's place, its apps, whether it is locked, opens at login, takes Focus) and the
  display's drawers.
- The scenes: the desktops they show, the slot they put in Focus, the drawers they move, the apps
  they open.
- The names you gave: the configuration's, the displays' ("Main"), the desktops', the scenes'.

### What never goes in

- The displays' models and serial numbers. A display is its position in the file and the name you
  gave it; one without a name is "Display 2".
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

**Share → Add a layout** lists the library and reads a file from anywhere (**Add from a file…**).
The file is somebody else's, so nothing in it is taken at its word:

- its kind and version are read first: another kind of file is refused, and a file from a newer
  Fremspace says so instead of being half-read;
- it may weigh 1 MB at most, and hold 8 displays, 16 desktops a display, 16 slots a layout, 8 apps
  a slot, 32 scenes;
- names are cut to one line of 60 characters and 240 bytes; a slot or app identifier with anything
  but letters, digits, `.`, `_` and `-`, a rectangle outside its desktop, two slots with one
  identifier, two slots that overlap or two drawers on one edge refuse the whole file;
- a part of a scene that names a display, a desktop, a slot or a drawer the file does not have is
  dropped, the rest of the scene stays.

Then you choose, for each display of the file, the display of yours that takes its desktops, or
**Leave out**. One display of yours takes one display of the file. **Add** then:

- puts the file's desktops after yours on each display chosen;
- adds its drawers on the edges where you have none (yours stay where you have one);
- adds its scenes, their desktops moved to the positions they now have; a display left out takes
  its part of the scenes with it, and a scene with nothing left is not added.

Nothing of yours is replaced, the import is one step to undo, and nothing changes on screen until
you save. macOS needs as many desktops as the configuration lists: after saving, the Status page
offers to add the ones that are missing. Apps the file names that are not on your Mac are listed;
their slots are added and stay empty. A slot opens its app at login unless that is switched off
in its inspector, and the file's slots come as their author set them: the apps they name that are
on your Mac will be opened at your next login.

## The library

`~/Library/Application Support/Fremspace/Layouts/` holds layout files ready to be added: yours
(**Keep in the library**) and those of others (put the file in the folder, **Open the library
folder** shows it). The Share page lists the files it can read, with their displays and desktops;
the bin moves a file to the Trash. Only a plain file of 1 MB at most is read (a link is followed
to the file it points to).

## Where to post one

In the repository's **Discussions → Show and tell**, with a photo or a screenshot of the desk.
