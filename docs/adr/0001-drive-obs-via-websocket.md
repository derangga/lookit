# Drive OBS via obs-websocket, not a native plugin

Zoom in OBS is a Scene item transform, and the obvious way to animate one is a native C++ OBS filter — GPU-side, frame-accurate, no round-trips. We are instead driving `obs-websocket` from an external Swift app, because the hotkeys, HUD, config and crash journal all have to be a macOS app regardless, and building them plus a C++ filter means maintaining two codebases and pinning against the OBS SDK across major versions.

## Consequences

Each eased frame is a websocket round-trip applied on OBS's next render tick, so the motion is quantised to the canvas frame rate (30fps here) and may show stepping that a filter would not. This is accepted as unmeasured risk rather than designed around.

The mitigation is containment, not avoidance: the Visible-region math lives in one pure function with no OBS or networking in it. If the motion proves visibly steppy, that function is lifted into a filter and everything else — hotkey handling, Target resolution, HUD, journal, config — is unaffected.
