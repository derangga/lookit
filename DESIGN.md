# lookit — Design

Domain vocabulary is in [CONTEXT.md](./CONTEXT.md). Settled decisions are in [docs/adr/](./docs/adr/).

```
lookit → Graph → A / E / R
│          │      │   │  │
│          │      │   │  └─ what each node needs        §5
│          │      │   └──── where the graph breaks      §4
│          │      └──────── what flows through nodes    §2
│          └─ nodes = functions, edges = data flow
└─ the problem: cursor-following zoom on one OBS scene item
```

## §1 Shapes

**IDs** — branded, never bare `String`/`Int`:
`SceneName` · `SceneItemId` · `InputName` · `InputKind` · `WindowID`

**Records:**
`Transform` (crop, bounds, scale, source dims) · `CaptureRect` (screen region + backing scale) · `VisibleRegion` (origin + size, source px) · `Target` · `Config` · `Pristine`

**Variants:**

```
Connection  = disconnected | connecting | identified
TargetState = unresolved(reason) | resolved(Target)
PanState    = following | frozen
Dirtiness   = clean | dirty(Pristine)
```

**Errors** — tagged, carrying context, never strings:

```
ObsError     = serverDisabled | refused | authFailed
             | requestFailed(code, comment) | dropped
TargetError  = noCaptureInScene | ambiguous([InputName])
             | windowNotFound(WindowID)
ConfigError  = unreadable | malformed(reason) | badKeybinding(String)
JournalError = writeFailed | restoreFailed
```

## §2 A — the happy path

**Startup:**

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
  → readScenes                       // the HUD's picker; cached, see §3
  → resolveTarget
    → obs.getCurrentProgramScene
    → obs.getSceneItemList
    → pickCaptureItem                // pure — skips camera by kind
    → obs.getInputSettings
    → captureBinding                 // pure
    → obs.getSceneItemTransform      // the candidate Pristine, and the source size
    → locateSource                   // boundary — window server or display list
    → matchesSource                  // pure — is this really OBS's source?
  → installHotkeys
  → showHUD
  → startTick
```

**Tick — 30Hz, the core loop:**

```ts
tick
  → readCursor
  → locateSource                     // re-read; the window or display may have moved
  → mapCursorToSourcePixels          // pure
  → nextPanCenter                    // pure — dead zone
  → ease                             // pure
  → zoomCrop                         // pure
  → obs.setSceneItemTransform
```

**Hotkey:**

```ts
onHotkey(zoomIn)
  → nextStop                         // pure
  → ensureJournalled                 // acquire dirty
  → recenterOnCursor
  → setTargetZoom                    // the tick loop animates it
```

**Scene switch:**

```ts
obs.events ▸ CurrentProgramSceneChanged
  → restoreTarget                    // release dirty
  → deleteJournal
  → readScenes                       // only to move the checkmark
  → resolveTarget
  → setZoom(1.0)
```

**HUD scene pick:**

```ts
hud ▸ scenePicked
  → obs.setCurrentProgramScene
  → ⟨nothing local⟩                  // OBS answers with the event above
```

Deliberately half a graph. The switch is not applied here and no state is
touched; OBS announces it back and the scene-switch graph runs unchanged, so
invariant 2 has one implementation rather than one per way of switching.

**HUD collapse:**

```ts
hud ▸ previewToggled
  → hud.setPreviewVisible            // layout only
  → previewFeed.stop / bump+start
```

Most of the tick loop is pure. That is not aesthetic — it is what makes [ADR 0001](./docs/adr/0001-drive-obs-via-websocket.md)'s escape hatch real.

## §3 Cardinality

```
Stream:  obs.events · tick(30Hz) · hotkeys · configFileChanges
         previewFeed(2Hz, 8Hz for 1s after a reframe) — stopped while collapsed
Effect:  connect · each request · locateSource · journal read/write
Bounded: CaptureRect valid 1 tick · sceneItemList valid until scene change
         sceneList valid until SceneListChanged
```

30Hz because the canvas is 30fps. 60 would be double the traffic for no visible gain.

The scene list is **cached**, not read on demand, because the picker is an
`NSMenu` and `popUp` is synchronous — there is no point in the click where a
round trip could be awaited. That makes the cache's staleness an invariant to
maintain rather than a convenience: it is re-read on identify, on
`SceneListChanged`, and on every scene switch.

## §4 E — where it breaks

```ts
main
  → loadConfig
    ⚠ unreadable    → escape: write defaults, continue
    ⚠ malformed     → escape: keep last-good, HUD warns   // never crash on hot-reload
    ⚠ badKeybinding → escape: skip that binding, HUD warns
  → obs.connect
    ⚠ refused        → RETRY backoff                       // OBS not up yet
    ⚠ serverDisabled → RETRY slowly + HUD says to enable it
    ⚠ authFailed     → escape: stop, HUD shows why         // retry cannot fix a wrong password
  → restoreJournalIfPresent
    ⚠ restoreFailed → escape: keep journal on disk, retry next launch
  → resolveTarget
    ⚠ noCaptureInScene → escape: unresolved, hotkeys no-op
    ⚠ ambiguous        → escape: menubar picker, remember
    ⚠ windowNotFound   → escape: unresolved
  → tick
    ⚠ cursor outside rect → not an error: PanState = frozen
    ⚠ dropped             → RETRY connect; the journal covers the dirty item
    ⚠ invalid crop        → DIE                            // invariant violation
onHotkey
  → ensureJournalled
    ⚠ writeFailed → escape: REFUSE TO ZOOM
hud ▸ scenePicked
  → obs.setCurrentProgramScene
    ⚠ requestFailed → escape: HUD warns, the scene simply does not change
readScenes
  ⚠ dropped → escape: empty list — the chip offers only "Open OBS"
previewFeed
  ⚠ any → escape: dim the last frame after two failures      // decoration
```

**No journal, no zoom.** Going dirty without a durable pristine record is the only thing that can damage the user's OBS layout, so it is a precondition, not best-effort.

Exactly one `die` in the whole design. Everything else is a value in E.

Each layer scopes its own E before passing outward:

```
transport      →  target        →  controller
E=ObsError        E=TargetError    E=(surfaced in HUD)
```

## §5 R — what each node needs

```
zoomCrop, nextPanCenter, ease, pickCaptureItem, mapCursor   R = never
locateSource                                                R = SourceLocator
readCursor                                                  R = CursorSource
tick                                                        R = Clock
every obs.*                                                 R = OBSClient
loadConfig / watch                                          R = ConfigStore
journal *                                                   R = JournalStore
installHotkeys                                              R = HotkeyRegistrar
```

Swift has no R channel and cannot prove R is discharged the way Effect can. The substitute: the pure core takes **only values**, so its R is structurally empty — there is nothing to inject. Keep it in its own directory with no AppKit and no networking imports.

## §6 Boundary — `unknown → trusted`

```
obs-websocket JSON  → Transform, SceneItemList, InputSettings, SceneList
obs op 5 frame      → ObsEvent = sceneChanged | sceneListChanged
screenshot data URI → Data                     // strict prefix, then base64
config.json         → Config
restore.json        → Pristine
CGWindowList dict   → CaptureRect
```

`ObsEvent` switches on `eventType`, never on shape: a dozen other events carry
a `sceneName`, so a successful decode identifies nothing.

Cursor coordinates come from the OS — trusted, no parse. Parse once at the edge; everything inside trusts the types.

## §7 Behavior — wraps without changing the graph

```
reconnect + backoff  ⟳ every obs.*
coalesce             ⟳ setSceneItemTransform   // drop stale frame if one is in flight
dedupe               ⟳ setSceneItemTransform   // drop a frame OBS already has
lastGood             ⟳ loadConfig
log                  ⟳ all
```

Frame coalescing keeps the 30Hz loop from queueing behind a slow round-trip.
Dedupe is the other half: crops are whole pixels, so a still cursor and a
**Frozen** shot both produce the identical request every tick, and OBS already
has it. Both live in `TransformSender` because neither changes the graph — the
tick loop still says "put the item here" 30 times a second. The dedupe assumes
this sender is the only writer of that transform, which is why releasing the
dirty scope has to `reset()` it: `restoreJournalIfPresent` writes the pristine
straight past it.

## §8 Scope

```ts
withConnection {           // release: close socket
  withHotkeys {            // release: unregister
    withDirtyTarget {      // acquire: journal + reframe
      ...                  // release: restore pristine + delete journal
    }
  }
}
```

The dirty target is a **resource**, not a state flag. That is [ADR 0002](./docs/adr/0002-journal-the-pristine-transform.md) made structural: "always restorable" becomes a property of the type rather than something that must be correct in five separate exit paths.

## §9 Swap R to prove it

```ts
// Production
tick
  → CursorSource.live          → NSEvent.mouseLocation
  → SourceLocator.live         → CGWindowListCopyWindowInfo / CGDisplayBounds
  → Clock.live                 → 30Hz timer
  → OBSClient.live             → websocket

// Tests
tick
  → CursorSource.scripted      → [(0,0), (900,400), (2000,900)]
  → SourceLocator.fixed        → 1470×956 @2x
  → Clock.manual               → step() per assertion
  → OBSClient.recording        → captures transforms, asserts nothing
```

Same graph, same A, same E. Assert on the recorded transform sequence — this exercises the eased pan end to end, not just `zoomCrop` in isolation.

## Environment facts

Established by inspection, not assumption:

| | |
|---|---|
| macOS | 15.7.7, Swift 6.1.2 (typed throws available) |
| OBS | 32.1.1, `obs-websocket` 5.7.3 bundled, port 4455, **enabled, auth required** — Hello/Identify handshake verified against the password in `config.json` |
| `SetSceneItemTransform` round-trip | measured over 60 sends on loopback: **median 0.27ms, p90 0.57ms, max 7.41ms** — two orders of magnitude under a 33ms tick |
| Canvas | 2992×1858 @ 30fps |
| Captures | window capture (`screen_capture` type 1) and display capture (type 0); application capture (type 2) has no single rect and stays unsupported |
| TCC | **none required** — `RegisterEventHotKey`, `NSEvent.mouseLocation` and window *bounds* all need no permission |
| Hotkeys | `⌘⌥=` / `⌘⌥-` / `⌘⌥0` free here (`closeViewHotkeysEnabled = 0`); these are the system zoom shortcuts on stock macOS |

## Open empirical questions

1. ~~Does `GetInputSettings` return a live or **stale** window id after the captured app relaunches?~~ **Answered, and worse than expected — already handled.**

   Read live over the websocket, the `chrome` source returns `application: com.google.Chrome`, `window: 384`. Id `384` on this machine resolves to a live **Helium** window. Window ids are *recycled*: a stale id does not fail, it names someone else's window.

   **Both halves confirmed, and the obvious fix was wrong.** Watched across a re-pick:

   | | before re-pick | after re-pick |
   |---|---|---|
   | `window` | `219` — dead, no such window | `46` — live |
   | `application` | `com.google.Chrome` | `com.google.Chrome` |
   | source pixels | `0 × 0` | `2992 × 1858` |
   | window 46 truly is | — | `net.imput.helium`, 1496×929 @2x |

   So the id **does** go stale, and OBS **does** keep the source size honest — a dead capture reports `0 × 0`. But `application` is **vestigial**: it survives a re-pick onto a different browser and describes application-capture mode, not this source. Validating the owner against *OBS's* bundle id would therefore reject the correct window forever.

   The bundle id to validate against must come from the **window server** at resolve time, never from OBS. The id itself is cross-checked at resolve by comparing the window's backing-pixel size against the source size OBS reports.

2. ~~Is `NSWindow.sharingType = .none` honoured by ScreenCaptureKit on macOS 15?~~ **Answered: yes.** `./scripts/verify-hud-not-captured.sh` captures the same region twice, once with the panel deliberately capturable and once normally, and fails if they match. On macOS 15.7.7 the HUD is present in the first and absent in the second.

3. Does 30Hz websocket easing look smooth, or stepped? Still open — this is the measurement ADR 0001 defers to, and it needs the tick loop.

   **Half answered: the transport is not the limit.** A transform round-trip runs a median 0.27ms against a 33ms budget, so if the motion looks stepped the cause is the tick cadence or the easing curve, not OBS. The `max 7.41ms` tail is why coalescing stays anyway — it is cheap, and a stall under load is exactly when a backlog would hurt.

   **A third suspect is now gone, which changes what a "stepped" report means.**
   The pan used to snap to the dead-zone edge, so the visible region moved at
   exactly cursor speed — a hand that jerks produced a shot that jerked, and no
   tick rate could smooth that. `panRate` now chases the target as
   `1 - e^(-rate·dt)` [lookit-qbc]. If the motion still reads as uneven after
   this, the cause is one of the two below and not the pan.

   **And a second suspect, found by the swap-R check rather than by eye.** The ease is smoothstep in *zoom*, but what the viewer sees is the visible region, which goes as `1 - 1/zoom`. That is concave, so the apparent motion is **front-loaded**: it lunges out of the start and crawls into the end, even though the zoom value itself is symmetric. If the motion reads as uneven rather than stepped, easing in log-zoom is the fix, not a faster tick. Left alone until [lookit-xm1] says whether it is visible.
