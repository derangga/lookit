# lookit

A macOS menubar companion for OBS that adds cursor-following zoom to a screen capture, so a live demo or screencast can push in on detail without touching the OBS interface.

## Language

### What gets zoomed

**Input**:
A capture device or window registered once in OBS — `chrome`, `terminal`, `camera`. Exists independently of any scene.
_Avoid_: Source

**Scene item**:
One placement of an Input inside one Scene. The same Input placed in two Scenes is two Scene items, each framed independently.
_Avoid_: Source, layer

**Target**:
The single Scene item that lookit is currently zooming. Determined by the active Scene, never by the user directly.
_Avoid_: Selected source, active source

**Camera item**:
A Scene item whose Input is a camera. Permanently ineligible to be the Target — the face cam is never zoomed.
_Avoid_: Webcam, facecam

**Capture rectangle**:
The region of the physical screen that a Target's Input represents. Everything the cursor does is meaningful only once expressed relative to this rectangle.

### Framing

**Zoom level**:
How tightly the Target is currently framed, where 1× is the whole Capture rectangle.
_Avoid_: Scale, magnification

**Stop**:
One of the discrete Zoom levels the hotkeys move between. A press advances one Stop; it never lands between them.
_Avoid_: Step, increment, notch

**Visible region**:
The portion of the Capture rectangle on screen at the current Zoom level. At 1× it is the whole rectangle.
_Avoid_: Viewport, crop, window

**Pan**:
Movement of the Visible region across the Capture rectangle at an unchanged Zoom level. lookit owns Pan; the user owns Zoom level.
_Avoid_: Scroll, track, follow

**Dead zone**:
The inner area of the Visible region in which the cursor may move without causing a Pan. Exists so ordinary small movements do not make the shot drift.
_Avoid_: Threshold, margin, deadband

**Frozen**:
The state of a Target that holds its Visible region because the cursor has left the Capture rectangle. Zoom level is unaffected.

**Unresolved**:
The state of a Target whose Capture rectangle cannot be located, because the window it captures no longer exists. Zooming is refused rather than applied blindly.

### Safety

**Pristine transform**:
A Target's framing as the user arranged it in OBS, before lookit altered anything. The state lookit is always obliged to be able to return to.
_Avoid_: Original, default, saved state

**Dirty**:
Describes a Target whose framing currently differs from its Pristine transform. At most one Scene item is Dirty at any moment.

**Journal**:
The durable record of the Pristine transform of the Dirty Target, written so that an ungraceful death cannot leave a Scene item permanently reframed.
_Avoid_: Backup, cache, snapshot

### Interface

**HUD**:
The always-visible floating panel showing the current Zoom level and offering the same adjustments as the hotkeys. Never appears in the capture.
_Avoid_: Overlay, widget, panel
