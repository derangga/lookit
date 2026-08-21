# lookit

A macOS menubar app that gives OBS a cursor-following zoom on a screen capture, so a live demo or a screencast can push in on small detail without you ever touching the OBS window.

## Overview

When you record a screencast, the hard part is not the recording, it is the reading. Text that looks fine on your monitor turns into mush once it is scaled down into a video player, so the viewer has to squint at a terminal prompt or a form field they cannot make out. The usual fix is to zoom in afterwards in an editor, which costs you an editing pass for every take.

lookit does the zooming while you record. It sits in the menubar, talks to OBS over the network, and crops one scene item so the part of the screen your cursor is on fills the frame. You press a hotkey to choose how tight the shot is, and lookit keeps the cursor inside the frame from then on by panning the crop smoothly as you move the mouse. When you press the reset hotkey, the shot eases back out and the scene item goes back to exactly the framing you had arranged in OBS.

What it gives you:

- **Cursor following.** Once you are zoomed in, the visible part of the capture follows your pointer. Small hand movements do not move the shot at all, because there is a dead zone in the middle of the frame that the cursor can roam inside freely. The shot only moves when you go past it, and then it moves by the smallest amount that brings the cursor back inside.
- **Zoom that snaps to stops.** You do not get a continuous zoom slider, you get a small list of levels such as 1x, 1.5x, 2x and 3x. Each hotkey press moves one step along that list, which means the framing in your recording is consistent instead of slightly different every time.
- **Smooth motion.** Every zoom change is eased over a few hundred milliseconds rather than jumping, and the panning is eased the same way, so the result looks like a camera move and not like a teleport.
- **A floating HUD.** A small always-visible panel shows the current zoom level, a live preview of the OBS program scene, and buttons that do the same thing as the hotkeys. It never steals keyboard focus when you click it, so clicking it does not interrupt whatever you are demonstrating, and it is marked as non-capturable so it never shows up in the recording itself.
- **Scene switching without leaving what you are doing.** The HUD has a scene picker listing every scene in OBS with the live one ticked, so going from your demo scene to a talking-head scene mid-recording does not mean finding the OBS window. Switching from here is the same switch as switching in OBS, restore of the outgoing scene item included.
- **A HUD you can put away.** One click collapses the preview and leaves just the row of controls, for when you want the panel out of your way but still want to reach the zoom. Collapsing also stops the preview feed, so a put-away HUD asks OBS for nothing at all.
- **Your OBS layout is never damaged.** Before lookit changes any framing, it writes the original framing of that scene item to a file on disk. If lookit crashes, if you force quit it, or if OBS goes down first, the next launch finds that file and puts your scene item back exactly as it was.
- **The face cam is never zoomed.** lookit picks what to zoom by looking at the kind of input each scene item uses, so a camera item is skipped permanently. It cannot accidentally crop into your face.
- **Live config reload.** The settings file is watched while lookit runs, so you can retune the zoom stops, the easing duration, the dead zone or the hotkeys in the middle of a session and see the change take effect immediately. A broken settings file never takes the app down, it keeps the last working settings and shows you a warning about what is wrong.

## Requirements

You need all of the following to run the app:

| What | Why |
|---|---|
| **macOS 13 or newer** | The app links AppKit and Carbon and is built against a recent SDK. It has been developed and verified on macOS 15.7.7. |
| **OBS Studio 28 or newer** | OBS 28 was the first version to bundle `obs-websocket` version 5, which is the protocol lookit speaks. Development and verification were done against OBS 32.1.1 with `obs-websocket` 5.7.3. |
| **The OBS WebSocket server turned on** | In OBS, open Tools, then WebSocket Server Settings, and tick Enable WebSocket server. Leave the port at 4455 unless you have a reason to change it. If a password is required, copy it, you will put it into the lookit config file. |
| **A window or display capture in your scene** | lookit zooms a capture, so the current OBS scene needs at least one. Application capture is the one flavour it cannot zoom, because it is not a single rectangle. If the scene has no capture at all, lookit says so and the hotkeys simply do nothing. |

There is one thing worth calling out because it surprises people: **lookit needs no special macOS permissions.** It does not ask for Screen Recording access and it does not ask for Accessibility access. That is because it never reads the contents of your screen and never watches your keystrokes globally. It only reads the pointer position, asks the window server for the position and size of one window or display, and registers three ordinary system hotkeys. OBS is the program doing the actual capturing, so OBS is the program that holds the Screen Recording permission.

### Installing and first run

Build the app as described further down, then open `lookit.app`. It appears as a magnifying glass in the menubar with no Dock icon, because it is a background app.

On the first run lookit writes a complete settings file to `~/.config/lookit/config.json` with every option filled in with its default value. The file is written complete on purpose, so that you can discover every setting by reading it rather than by reading documentation. It looks like this:

```json
{
  "deadZone": 0.6,
  "easeMs": 350,
  "hud": { "x": null, "y": null },
  "keys": {
    "reset": "cmd+opt+0",
    "zoomIn": "cmd+opt+=",
    "zoomOut": "cmd+opt+-"
  },
  "obs": { "host": "127.0.0.1", "password": "", "port": 4455 },
  "panRate": 12.0,
  "stops": [1.0, 1.5, 2.0, 3.0]
}
```

What each setting means:

- **`stops`** is the list of zoom levels the hotkeys move between. The first entry is the resting level and must be 1.0 in practice, since that is the whole capture. Values below 1.0 are dropped and the list is sorted for you.
- **`easeMs`** is how long a zoom change takes to complete, in milliseconds. It is clamped to the range 1 to 5000.
- **`deadZone`** is how much of the frame the cursor may wander inside before the shot starts to follow, as a fraction between 0 and 1. At 0 the shot tracks your pointer exactly and feels twitchy. At 1 the shot only moves when the cursor would otherwise leave the frame completely. The default of 0.6 is a middle ground that follows you without drifting during ordinary typing.
- **`panRate`** is how quickly the shot closes the gap once the cursor has left the dead zone, in "fraction of the remaining distance per second" terms. It is what stops the frame being welded to your pointer: at the default of 12 a flick of the mouse is followed by a camera move that catches up over about a fifth of a second, rather than the whole frame snapping sideways with your hand. Lower is heavier and more cinematic, higher is more immediate, and 0 turns the smoothing off entirely so the shot tracks in lock step. Clamped to the range 0 to 60, and the speed does not change with your canvas frame rate.
- **`keys`** are the three global hotkeys, written as a combination of modifiers and a key joined with plus signs. The defaults are the same combinations macOS uses for its own accessibility zoom, so if you have that feature turned on you will need to change these or turn that feature off.
- **`obs`** is where to find OBS. Set `password` to whatever the WebSocket Server Settings dialog shows if authentication is required. Fixing a wrong password here and saving the file is enough to reconnect, no restart needed.
- **`hud`** is where the floating panel sits on screen. You do not edit this by hand, lookit writes it when you drag the panel so that it comes back in the same place next time.

You can open this file from the menubar menu with Edit config, and force a reload with Reload config, though the file is watched automatically anyway.

## How it works under the hood

### The idea in one paragraph

OBS does not have a zoom feature, but it does have a per scene item transform that includes a crop. Cropping the left, right, top and bottom of a capture and letting OBS scale what is left back up to fill its bounding box is visually identical to zooming in on that region. So lookit does not do any image processing at all. It works out which rectangle of the capture should be visible, converts that rectangle into four crop numbers, and sends those numbers to OBS thirty times a second over a WebSocket connection. OBS does the actual rendering, at full quality, on the GPU, as part of its normal render pass.

### The pieces

The code is split into three modules, and the split is the important part of the design rather than an organisational habit:

- **`LookitCore`** is the pure core. It imports nothing at all, not AppKit, not Foundation, not even CoreGraphics. It holds the math: where the visible region sits, where the pan center should move to, how the easing curve behaves, which crop numbers a given region implies, and which scene item is a plausible capture. Because it takes only plain values and calls nothing, it can be tested with no OBS running and no window on screen, and it could be lifted into a native C++ OBS plugin unchanged if that ever became necessary.
- **`Lookit`** is the layer that touches the outside world. It owns the WebSocket connection to OBS, the parsing of everything that comes back from it, the window server lookups, the hotkey registration, the config file loading and watching, the crash journal, and the HUD panel.
- **`LookitApp`** is the menubar shell. It is deliberately thin. It owns the application lifecycle and wires the other two together, and nothing else, so that everything below it can be exercised without a running `NSApplication`.

### The startup path

```ts
main
  → loadConfig
    → readFile
    → parseConfig                    // boundary
    → compileKeybindings
  → obs.connect
    → websocket.open
    → identify
  → restoreJournalIfPresent
    → readJournal                    // boundary
    → obs.setSceneItemTransform      // pristine
    → deleteJournal
  → resolveTarget
    → obs.getCurrentProgramScene
    → obs.getSceneItemList
    → pickCaptureItem                // pure, skips camera by kind
    → obs.getInputSettings
    → obs.getSceneItemTransform      // the candidate pristine, and the source size
    → locateSource                   // boundary
    → matchesSource                  // pure, is this really OBS's window?
  → installHotkeys
  → showHUD
```

Reading that from the top: lookit loads its settings, opens the connection to OBS and completes the authentication handshake, and then, before it does anything else at all, it checks whether a journal file is sitting on disk from a previous run. If one is there it means the last run died while a scene item was still cropped, so the very first thing that happens is putting that item back the way it was. Only then does lookit go looking for something to zoom.

Finding something to zoom means asking OBS which scene is live, listing the items in it, and choosing the one that is a capture. Camera items are excluded by input kind rather than by name, which is why renaming your camera source cannot trick lookit into cropping into your face. If the scene contains more than one capture, lookit does not guess, it puts a small picker in the menubar menu and lets you say which one you meant, then remembers that choice for that scene.

There is one subtlety in that path worth explaining, because it caused a real bug. OBS stores the window it is capturing as a numeric window id, and macOS recycles those numbers. A window that has closed leaves its id behind for the system to hand out to something else, so a stale id does not fail cleanly, it quietly names some other application's window. lookit therefore cross checks: it asks the window server for the size of that window and compares it against the pixel dimensions OBS reports for the source, and it reads the owning application from the window server rather than trusting the value stored in the OBS source settings, because that stored value turns out to be left over from an older capture mode and survives even when you re-pick a completely different window.

### The tick loop

Once you have zoomed in, a loop runs at thirty times a second for as long as the shot is not at rest:

```ts
tick
  → readCursor
  → locateSource                     // re-read, the window or display may have moved
  → mapCursorToSourcePixels          // pure
  → nextPanCenter                    // pure, dead zone
  → ease                             // pure
  → zoomCrop                         // pure
  → obs.setSceneItemTransform
```

Each pass reads where the pointer is, re-reads where the captured window is on screen because the user may have dragged it, converts the pointer position from screen coordinates into pixel coordinates inside the capture, decides where the visible region should be centred given the dead zone, moves the current zoom and centre a step along the easing curve, turns the result into crop numbers, and sends them.

Almost every step in that list is pure math with no I/O in it. That is not an aesthetic preference, it is what makes the escape hatch real: if the motion ever looks too steppy over a network connection, the math moves into a native OBS plugin and nothing else in the app has to change.

Thirty times a second is chosen to match the canvas frame rate. Sending sixty updates a second to a canvas rendering at thirty would double the traffic for no visible improvement. In measurements on this machine a single transform round trip to OBS over the loopback interface took a median of 0.27 milliseconds, with a worst case of 7.41 milliseconds, against a budget of 33 milliseconds per tick, so the network is not the limiting factor here by a wide margin. That worst case is still why sends are coalesced: at most one transform is in flight and at most one waits behind it, and if a newer frame arrives while one is waiting it replaces it rather than queueing. The shot should chase where the cursor is now, never where it was four frames ago.

The loop stops entirely when the shot is back at rest, so an idle lookit is not spinning a timer or sending anything at all.

### Never damaging your layout

This is the part the design takes most seriously, because it is the only thing lookit does that can genuinely cost the user something. OBS saves scene item transforms into your scene collection, so a crop that is left behind is not a temporary glitch, it is a permanent edit to your setup that you would have to undo by hand.

The rule is: **no journal, no zoom.** Before the first crop is applied to a scene item, lookit writes that item's original transform to a file on disk and waits for the write to succeed. If the write fails, lookit refuses to zoom at all and tells you why in the menu. Zooming is never attempted on a best effort basis, having a durable record of how to undo it is a precondition.

Two more rules follow from that one. At most one scene item is ever in a modified state at any moment, which is why switching scenes in OBS restores the outgoing item before lookit even looks at the new scene. And clicking Quit in the HUD restores the framing and waits for OBS to confirm before terminating, which it can afford to do because a round trip costs well under a millisecond.

The journal is not deleted until the restore has been confirmed. If OBS is unreachable at the moment lookit tries to restore, the file stays on disk and the restore happens at the next launch instead.

### How failures are handled

Every place the app can break is classified as exactly one of three things, and each one is handled differently:

- **Retry.** The failure is temporary and will pass. OBS not being started yet gives a connection refused, so lookit retries with a backoff and keeps saying so in the HUD until OBS turns up.
- **Escape.** The failure is real but recoverable with a fallback. A settings file that does not parse keeps the previous working settings and shows a warning. A scene with no capture in it produces an unresolved state where the hotkeys do nothing rather than an error. A wrong password stops the retry loop instead of hammering OBS forever, because retrying cannot fix a wrong password, and it tells you to correct the file.
- **Die.** A genuine programming mistake, an invariant that should be impossible to violate. There is exactly one of these in the entire design, and it guards against a zero-sized capture reaching the crop math.

Everything else is an ordinary value flowing through the program rather than an exception being thrown around, and each layer translates the failures it knows about into terms the layer above understands, so the HUD never has to display a raw network error from three levels down.

### The HUD

The floating panel has two properties that are not negotiable. It must not take keyboard focus when you click it, because taking focus in the middle of a live demo would interrupt whatever you were showing. And it must never appear in the capture, which is achieved by marking the window as not shareable. That second one was verified rather than assumed: `scripts/verify-hud-not-captured.sh` captures the same region of the screen twice, once with the panel deliberately made capturable and once normally, and fails if the two images match.

The preview inside the HUD is a separate read-only feed from OBS that never writes anything. If it fails, the zoom is completely unaffected, which is the property that matters for a decorative feature attached to a tool that has a promise about not damaging your layout. Collapsing the preview stops that feed rather than merely hiding it, because a picture nobody can see is not worth a round trip twice a second.

The scene picker keeps a cached list of scenes rather than asking OBS when you click it, because a macOS menu opens synchronously and there is no point in the click where a network round trip could be waited on. The list is re-read whenever OBS says a scene was added, removed or reordered, and whenever the live scene changes. Picking a scene sends the switch to OBS and then does nothing else: OBS announces the change back, and lookit reacts to that announcement exactly as it does to a switch you made in OBS yourself, so the outgoing scene item is restored on the same path either way.

## Building from source

lookit is a Swift Package Manager project. There are no third party dependencies to fetch.

### Prerequisites

You need Swift 6.0 or newer from the **system** toolchain. Nothing else: there are no third party packages to fetch, so the build runs offline, and `bundle.sh` uses only `iconutil` and `codesign`, which come with the same install.

Check what you have:

```bash
swift --version       # want: Apple Swift version 6.x
```

If that fails or reports an older Swift, install one of:

- **The Xcode Command Line Tools**, which is the smaller of the two and enough on its own — it ships Swift, the macOS SDK, `iconutil` and `codesign`:

  ```bash
  xcode-select --install
  ```

- **Xcode**, from the App Store, if you want it anyway. Point the tools at it with `sudo xcode-select -s /Applications/Xcode.app`.

Two things worth knowing before you start:

- Swift must be the Apple toolchain, not one from Homebrew or a package manager. This app links AppKit and Carbon, and the Xcode SDK is the only thing that reliably provides those. If a `swift` from somewhere else is first on your `PATH`, the build fails in ways that look unrelated.
- Swift 6 arrived in Xcode 16, which needs a recent macOS to install. So you may need a newer macOS to *build* lookit than to *run* it — the built app itself is happy on macOS 13.

[Nix](https://nixos.org/) is optional. `nix develop` gives you the same shell the project was built in, which adds `swiftformat` and `jq` for development; it does not provide Swift, for the reason above.

### Steps

```bash
git clone <this-repo>
cd lookit

nix develop           # optional, gives you swiftformat and jq
swift build           # compile
./scripts/bundle.sh   # produce lookit.app
open lookit.app       # run it
```

`swift build` produces a bare executable, which runs but is not quite the app you want. The bundling script is what wraps it into a real `.app`, and that matters for three reasons: the `LSUIElement` flag that makes it a menubar app with no Dock icon lives in an `Info.plist`, macOS Login Items only accepts application bundles and not loose binaries, and a stable bundle identity is what any future permission grant would attach itself to. The script also compiles the icon set into an `.icns` and applies an ad-hoc code signature, which is not for distribution but does stop macOS from treating every rebuild as a brand new application.

For a release build, pass the flag through:

```bash
./scripts/bundle.sh --release
```

To have lookit start automatically, add `lookit.app` under System Settings, then General, then Login Items.

### Running the checks

The project has no test framework and no fixtures, just one runnable self-check built out of assertions:

```bash
swift run lookit-check
```

It covers the pure core and the parsers that sit at the boundaries, and it depends on `LookitCore` directly, which is also how the project proves that the core really has no hidden dependencies on the rest of the app.

There is one more check that has to be run by hand because it needs a real screen:

```bash
./scripts/verify-hud-not-captured.sh
```

That is the one that proves the HUD stays out of the capture.

### Repository layout

```
Sources/LookitCore/     the pure math, imports nothing
Sources/Lookit/         OBS transport, window lookups, config, journal, HUD
Sources/LookitApp/      the menubar shell
Sources/lookit-check/   the assert-based self check
scripts/                bundling and verification
docs/adr/               decisions that are settled, with the reasoning
CONTEXT.md              the vocabulary this project uses
DESIGN.md               the full analysis and the call graphs
```

If you plan to change anything, read `DESIGN.md` first. It contains the complete call graphs, the list of places the program can fail and how each one is handled, and the measurements that the design decisions were based on.

## License

MIT. See [LICENSE](./LICENSE) for the full text.
