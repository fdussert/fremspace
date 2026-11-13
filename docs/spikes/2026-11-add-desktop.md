# Add-desktop spike (plan 2, Task 0)

Date: 2026-11-09. macOS 27.0.1, SIP untouched. Throwaway code in `~/spikes/fremspace-desktops/add.swift`,
run inside a copy of `Fremspace.app` re-signed with "Fremspace Dev" (it inherits the Accessibility
grant). The owner watched the screen and confirmed Mission Control opened.

## Findings

- **Opening Mission Control:** `CoreDockSendNotification("com.apple.expose.awake", 0)` (private,
  ApplicationServices) or `open -a "Mission Control"` both open it from a background app. Escape
  (key code 53, posted with `CGEvent`) closes it.
- **The UI lives in `WindowManager`, not the Dock, on macOS 27.** The Dock still has an empty
  `AXGroup` with identifier `mc`. Mission Control's tree is in the `com.apple.WindowManager`
  process:
  `AXApplication 'WindowManager' > AXGroup #mc.display (one per display, frame = the display in AX
  coordinates) > AXGroup #mc.spaces 'Spaces Bar' > { AXList #mc.spaces.list > AXButton per Space
  ('Desktop 1', 'Orca' for a full-screen Space…), AXButton #mc.spaces.add 'add desktop' }`.
  Window thumbnails are `AXButton`s with identifiers `<bundle id>.space.<space id>`.
- The `mc.spaces.add` button's frame is not in global coordinates (display-local), so a display's
  button must be found through its parent `mc.display` group, whose frame is global.
- **Adding:** `AXPress` on `#mc.spaces.add` adds a desktop at the end of that display's list:
  **10/10** (5 per DELL), the new desktop visible in `CGSCopyManagedDisplaySpaces` and in the bar
  within ~50 ms.
- **Removing:** desktop buttons ('Desktop N', not full-screen Spaces) carry an `AXRemoveDesktop`
  action. 10/10, used to clean up after each add. Fremspace never removes desktops (spec); this was
  only used to leave the owner's desktops as they were.
- Visible effect: Mission Control opens, the desktop appears in the bar, Mission Control closes.
  About one second in total with the waits used here.

## Decision for Task 10

Use it: `Desktops.add(on:count:)` opens Mission Control, finds the display's `mc.display` group by
frame, presses `mc.spaces.add` `count` times (checking the desktop count after each press), closes
Mission Control with Escape, and returns false (with the message to add them by hand) if
`WindowManager` or the button is not found within 2 s.

## Moving a window through Mission Control (same day, owner's question)

Question: since Mission Control's thumbnails are reachable through `WindowManager`, can a window be
moved to another desktop by dragging its thumbnail onto a desktop of the Spaces bar (what a user does
by hand)?

- Thumbnails expose only `AXPress`; desktops expose `AXPress` and `AXRemoveDesktop`. No AX move action.
- Synthetic drag (`CGEvent` mouse down on the Calculator thumbnail, drags to the "Desktop 2" button
  of the bar, hover with small moves, mouse up), four variants: HID or session tap, click state 1,
  two-leg or straight path, 1 s hover. A screenshot shows the thumbnail lifted at the start of the
  drag; the drop is ignored every time: the window stays on its desktop (`CGSCopySpacesForWindows`
  unchanged).
- Same verdict as the Spaces spike's title-bar drag: synthetic drags do not move windows across
  desktops. Cleanup: the temporary desktop was removed with `AXRemoveDesktop`; desktops are as
  before.

Plan 3 keeps the Spaces spike's recommendation (restore by switching desktop then launching the app).
