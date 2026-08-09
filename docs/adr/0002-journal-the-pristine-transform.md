# Reframe the user's live Scene item, and journal its Pristine transform

lookit zooms by altering the user's actual Scene item. OBS persists Scene item transforms to the scene collection, so an ungraceful death — crash, force-quit, OBS exiting first — would leave that item permanently reframed and the user editing it back by hand. Before the first alteration, lookit therefore writes the item's Pristine transform to disk; a clean exit restores and deletes it, and finding that file at launch means the previous run died Dirty and the layout is restored before anything else happens.

## Considered options

**Zoom a hidden duplicate Scene item.** Structurally safer — the user's item is never touched, so no failure can corrupt it. Rejected because failure still leaves a mess, just a different one: a stray duplicate visible in the user's scene list, plus visibility juggling on every zoom. Trading "one cropped item" for "one orphan item and more moving parts" is not a win.

**Restore on exit only, no journal.** Covers ordinary quits with no file and no state to reason about, but leaves `kill -9` and OBS crashes as unhandled paths that silently damage the user's layout.

## Consequences

At most one Scene item is Dirty at any moment. This is why switching Scenes restores the outgoing Target rather than remembering its Zoom level: a per-Scene memory would make the journal track a set, and the invariant is worth more than the continuity.
