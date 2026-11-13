# Drawer put-away spike (drawer plan, Task 0)

Date: 2026-11-09. macOS 27.0.1, SIP untouched. Throwaway code in `~/spikes/fremspace-drawer/`
(`park.swift`, run inside a copy of `Fremspace.app` re-signed with the "Fremspace Dev" identity so it
inherits Fremspace's Accessibility grant). Fremspace was quit during the run and relaunched after.

Setup: right DELL (AX `(4872, -589, 3360, 1890)`, menu bar 30 pt, so the visible top is y = -559).
A Finder window at the drawer's top half and Sublime Text at its bottom half (1244 × 933 each,
left ⅜ drawer). Each window was parked through each side with an 8 pt strip asked to stay visible,
read back after 0.4 s, then brought back. Two rounds per side.

## Results

| Side | Asked | Got | Display / desktop | Verdict |
|---|---|---|---|---|
| Bottom (free) | y = 1293 (8 pt visible) | Finder y = 1249, Sublime y = 1269: **macOS keeps 52 / 32 pt visible** (a window's title bar must stay on screen) | stays on the right DELL, same desktop | **Works**, with a 32–52 pt band left visible |
| Top (free) | y = -1514 | refused: clamped back under the menu bar (y = -559) | stays | **Does not work** |
| Right (free) | x = 8224 (8 pt visible) | exactly as asked | stays on the right DELL, same desktop | **Works**, exact strip |
| Left (shared with the left DELL) | x = 3636 | as asked, but the window **moves to the left DELL and its desktop** (Space 21 → 20) | moves | **Does not work** (expected). Moving it back returned it to its original desktop. |

- Speed: AX moves of two windows took 0–17 ms each way (left side slowest, because of the display
  change). Well under the 150 ms target; the apps redraw within a frame or two.
- Activating a parked window's app (`NSRunningApplication.activate`) leaves the window parked:
  Fremspace must bring members in on the activation event (as planned).
- Finder and Sublime behaved the same, except the size of the visible band at the bottom (it depends
  on the app's title bar height).
- No flicker of other windows; the parked windows simply jump.

## Recommendation for the owner's trial drawer (left ⅜ of the right DELL)

The fallback order (spec) gives **bottom** for a left drawer on the right DELL: it works and stays on
the same desktop, but macOS forces 32–52 pt of each parked window to stay visible at the bottom left
of the screen, over the bottom of Brave. That band can serve as the tab (click or drop on it), so a
drawn tab on the left edge is optional.

The alternative is a drawer on the **right** edge of the right DELL: parking through the right side is
exact (8 pt strip) and is its own tab.

The owner chooses between the two for the trial; the plan supports both (`parkSide`).

## Second run (same day): hiding completely through a side

The owner found the bottom band too visible and accepted a drawer hidden completely (no tab).
Finder parked through the right DELL's free right side, asking for 1, 0 and -20 pt visible:

| Asked visible | Got | Display / desktop |
|---|---|---|
| 1 pt (x = 8231) | exactly as asked | stays on the right DELL, same desktop |
| 0 pt (x = 8232) | pulled back to 40 pt visible (x = 8192) | stays |
| -20 pt | pulled back to 40 pt visible | stays |

So a free left or right side hides a parked window down to a 1 pt line. **New order (owner):** the
drawer's own side if free, else the opposite side (the window crosses the display in one move,
unseen), else the bottom. The owner's left drawer on the right DELL parks through the right side.
The middle display (left DELL) has only its bottom free: there the band stays, which Task 6
(compact parked windows) reduces.
