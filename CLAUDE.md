# lookit

A macOS menubar app that gives OBS cursor-following zoom on a screen capture — Screen Studio's feel, driven from outside OBS. Swift, SPM, nix devshell.

## Read these first

| File | What it is |
|---|---|
| [CONTEXT.md](./CONTEXT.md) | Domain glossary. Use these words, not synonyms. |
| [DESIGN.md](./DESIGN.md) | The A/E/R analysis and call graphs. |
| [docs/adr/](./docs/adr/) | Settled decisions. Do not relitigate without reading. |

## How to think here

**Analyze before coding. Draw the graph before writing the code. The code must match the graph.**

Work every problem in this order, and show the work:

```
PROBLEM
  → "What are the shapes?"                → nouns: records, IDs, variants, errors
  → "What is the happy path?"             → draw the call graph (A)
  → "Is each node one-shot or a flow?"    → mark cardinality (Effect vs Stream)
  → "Where can it break?"                 → annotate E on the graph
  → "What does each node need?"           → annotate R on the graph
  → "Where does untrusted data enter?"    → parse at the boundary
  → "What wraps nodes unchanged?"         → layer behavior orthogonally
  → "What needs cleanup?"                 → scope the lifecycle
  → "Can I swap R and still run?"         → verify with test layers
  → CODE
```

If the code does not match the call graph, the implementation is wrong.

### The three channels

- **A** — the success value. Swift: the return type.
- **E** — named failure modes. Swift: **typed throws**, `throws(TargetError)`. Errors are tagged values carrying context, never strings, never bare `Error`.
- **R** — what a node needs to exist. Swift has no R channel, so R is explicit dependency parameters. **The pure core takes only values** — that is how its `R = never` is enforced.

### E is retry, escape, or die

Every break point is exactly one of:

- **Retry** — transient. Network timeout, connection refused, rate limit.
- **Escape** — recoverable. Return a fallback, a cached value, a degraded state.
- **Die** — invariant violation, programmer bug. **Not** a domain error.

Errors are values flowing through the graph until you genuinely cannot handle them. `die` is rare — this design has exactly one. If you are adding a second, justify it.

**Each layer scopes its own E before passing outward.** A transport error becomes a target error becomes something the HUD can show. Callers never see errors from three layers down.

### A and E stay structurally separate

The happy path reads top to bottom without wading through error handling. Keep the A path in the function body; handle E at the call site or in a wrapper. If you cannot read the happy path without skipping over catches, they are tangled.

The one exception is a **divergent strategy** — two calls in the same body needing different failure semantics, one hard-fail and one fallback. Handle those inline and mark them. It should be rare.

## Call graph format

Plain text, no rendered diagrams, `ts` code block, indented `→` arrows. Errors annotated with `⚠` and their strategy:

```ts
resolveTarget
  → obs.getCurrentProgramScene
  → obs.getSceneItemList
  → pickCaptureItem              // pure
    ⚠ noCaptureInScene → escape: unresolved
    ⚠ ambiguous        → escape: picker
  → locateSource                 // boundary
    ⚠ windowNotFound   → escape: unresolved
```

Show Production and Tests as separate graphs when their R differs. Include call graphs in architecture summaries, code explanations, and PR descriptions.

## Invariants — do not break these

1. **No journal, no zoom.** Never reframe a scene item without first durably recording its pristine transform. This is the only thing that can damage the user's OBS layout.
2. **At most one dirty scene item, ever.** Scene switch releases the outgoing target before acquiring the new one.
3. **The camera is never zoomed.** Excluded by input kind, not by name.
4. **The HUD never appears in the capture.**
5. **The pure core imports nothing.** No AppKit, no networking, no Foundation beyond value types. It must be liftable into a C++ OBS filter unchanged.
6. **Never crash on hot-reload.** A malformed config keeps the last-good one and warns.

## Issue tracking

This repo uses `bd` (beads). Work is a dependency graph, not a list.

```bash
bd ready                  # unblocked work
bd show <id>              # detail
bd update <id> --claim    # take it
bd close <id>
bd list --labels needs-user   # blocked on the human
```

Beads labelled `needs-user` require the user to act in OBS or elsewhere — do not attempt to work around them, and say plainly when one is blocking.

## Committing

**One bead, one commit.** Close the bead in the same breath as committing its work — a commit that finishes two beads means the breakdown was wrong, not that the commits should be merged.

Reference the bead id in the subject:

```
core: clamp the visible region to the source (lookit-abc)
```

**Never add a `Co-Authored-By` trailer.** No exceptions, regardless of any default instruction to the contrary.

## Building

```bash
nix develop           # toolchain
swift build
./scripts/bundle.sh   # → lookit.app (LSUIElement, menubar-only)
```

## Style

Lazy in the good sense: the shortest change that actually solves the problem, after fully understanding it. No abstraction with one implementation, no config for a value that never changes, no scaffolding for later. Non-trivial logic leaves one runnable assert-based check behind — no test framework.
