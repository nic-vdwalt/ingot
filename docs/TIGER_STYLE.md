# Tiger Style (ingot / Odin edition)

Adapted from [TigerBeetle's TigerStyle](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md).
That document is written for Zig; this is its translation to **Odin** for the
`ingot` engine. When something here disagrees with the original, this file wins
for `ingot`, because it accounts for our language and our domain.

## Why have style?

Style is design. Our design goals, in order, are **safety, performance, and
developer experience**. Good style advances those goals; it is not decoration.
Simplicity is not a free pass — it is the hardest revision, the "super idea" that
solves several axes at once. We spend the mental energy up front, in design,
because an hour of design saves weeks in production.

**Zero technical debt.** Do it right the first time. Code, like steel, is
cheapest to change while it is hot. A showstopper caught in design is far cheaper
than one caught in production, so when we find one, we fix it now.

## Safety

These rules come from [NASA's Power of Ten](https://spinroot.com/gerard/pdf/P10.pdf),
translated to Odin.

### Control flow

- Use **only simple, explicit control flow**. **No recursion** — it makes bounds
  impossible to prove statically. Any loop that could run unbounded (an event
  loop, a drain loop) must either have a fixed upper bound or an assertion that
  it terminates.

- **Put a limit on everything.** Every loop and every queue has a fixed upper
  bound. `ingot` already does this — see `term.TERM_PUMP_MAX_BUFS`, which caps
  the PTY drain per frame. Follow that pattern: name the bound as a constant near
  the top of the file and explain *why* that number.

- Prefer bounded `for _ in 0 ..< N` over open `for {}`. Where a genuinely
  unbounded loop is unavoidable, `assert` the exit invariant.

### Assertions

**Assertions detect programmer errors.** Operating errors (a PTY closed, a socket
dropped, a file missing) are expected and must be *handled*. Assertion failures
are *unexpected*; the only correct response to corrupt program state is to crash.
Assertions downgrade catastrophic correctness bugs into loud, early liveness
bugs, and they are a force multiplier for fuzzing.

- **Assert function arguments, return values, pre/postconditions, and
  invariants.** Target an average of **at least two assertions per procedure**.
  A procedure exists to increase the probability that the program is correct;
  its assertions are part of how it does that.

- Odin gives you several tools — use the right one:
  - `assert(cond)` / `assert(cond, "message")` — runtime precondition/invariant.
    Compiled out in `-o:speed -disable-assert` builds, so never rely on its side
    effects.
  - `ensure(cond, "message")` — like `assert` but **kept in release builds**. Use
    it for checks that must hold even in shipped binaries (e.g. bounds derived
    from untrusted input before an unchecked slice).
  - `#assert(compile_time_cond)` — compile-time. Assert relationships between
    constants and type sizes; these are checked before the program even runs.
  - `panic("...")` / `unreachable()` — for states that must never occur.

- **Pair assertions.** For every property, try to assert it in at least two
  places / two code paths. Assert data valid right before you write it to the
  PTY, and again right after you read it back. Bugs live where data crosses the
  valid/invalid boundary.

- **Split compound assertions.** Prefer `assert(a); assert(b)` over
  `assert(a && b)` — the split form points at the exact failure.

- Use a single-line `if` to assert an implication: `if a do assert(b)`.

- **Assert the positive space you expect AND the negative space you don't.**
  Interesting bugs live on the boundary. Tests must exercise invalid data too,
  not only the happy path.

- Assertions are a safety net, not a substitute for understanding. Build the
  mental model first, encode it as assertions, then write the code and comments
  that justify the model. A fuzzer proves the presence of bugs, never their
  absence.

### Memory

- `ingot` is immediate-mode: **callers own their state and pass it in each
  frame.** Honour that — do not hide retained trees or grow per-frame heap
  allocations.

- Prefer **static / arena allocation** and reuse. Allocate long-lived buffers
  once (see the per-instance `read_buf` / `utf8_hold` in `term`) rather than
  per frame. For scratch work use `context.temp_allocator` and let the frame
  boundary reclaim it — never leak it into retained state.

- Declare variables at the **smallest possible scope** and keep the number of
  live variables small. Compute a value close to where it is used; don't hoist
  it up where it can be misused (avoid place-of-check to place-of-use gaps).

- Group allocation and its `defer delete/free` together, with a blank line
  before and after, so leaks are easy to spot.

### Types

- Odin is already explicitly sized — use it. Prefer `u32`, `i64`, etc. **Do not
  use `int`/`uint` at wire, file, or FFI boundaries**; a serialized field has a
  fixed width, so name it with one. `int` is fine for local indices and lengths
  where the platform width genuinely doesn't matter.

- Treat `index` (0-based), `count` (1-based), and `size` (bytes) as distinct
  concepts even though they are all integers. Going index → count adds one;
  count → size multiplies by the unit. Most off-by-one bugs are a casual
  interaction between these three.

- Show intent with division: reach for the checked / explicit form and say why
  when rounding matters.

### Procedures

- **Hard limit: 70 lines per procedure.** There is a real discontinuity between
  a procedure that fits on screen and one you must scroll. Most walls of code
  split cleanly; only a few splits feel right — find them.
  - Good shape is an inverse hourglass: few parameters, a simple return type,
    meaty logic in the middle.
  - **Centralize control flow.** Keep the `switch`/`if` in the parent; push
    branch-free fragments down into pure helpers. "Push ifs up, push fors down."
  - Keep leaf helpers pure: let the parent own the mutable state and pass in
    what the helper needs.

- **Handle every error / every returned `ok`.** The majority of catastrophic
  failures in real systems come from mishandled non-fatal errors. Never discard
  an `ok: bool` or an error union without a deliberate, commented decision. Do
  not silently ignore an `or_return`.

- **Preserve consumer contracts while hardening internals.** Existing exported
  names, signatures, public layouts, ownership, ordering, defaults, and failure
  behavior remain stable unless a versioned migration is approved. Add
  characterization tests before refactoring behavior-sensitive code. A stricter
  assertion is a contract change when existing valid consumers can reach it.

- **Separate programmer errors from operating errors.** Checked private helpers
  may strengthen internal invariants, but filesystem, device, socket, PTY, and
  user-input failures must continue through the package's documented recovery or
  result path.

- **Explicitly pass options at the call site** instead of leaning on zero-value
  defaults for *behaviour*. If a default ever changes, silent call sites become
  latent bugs.

- Compile at the strictest setting and treat warnings as defects. Our gate is
  `scripts/check.sh` (`odin check ... -vet -strict-style -vet-shadowing`).

## Performance

- Solve performance **in the design phase** — that's where the 1000x wins live,
  precisely when you can't yet profile. Have mechanical sympathy; work with the
  grain.

- Sketch back-of-the-envelope costs across the four resources — **network, disk,
  memory, CPU** — and their two characteristics, bandwidth and latency.

- Optimize the slowest resource first (network, disk, memory, CPU in that
  order), after weighting for how often each is hit — a cache miss that happens
  a million times can cost more than one fsync.

- **Batch** to amortize costs. `ingot` is immediate-mode and batches draw calls;
  keep that discipline. Give the CPU large, predictable chunks of work; don't
  make it zig-zag.

- Extract hot loops into stand-alone procedures taking primitive arguments (no
  `self`), so the reader — and the optimizer — can see there is nothing hidden.

## Developer experience

### Naming

- Get the nouns and verbs right; great names are the essence of great code.
- `ingot` and Odin both use `snake_case` for procedures, variables, and files —
  keep it. The underscore is our stand-in for a space; use it for descriptive
  names.
- Do not abbreviate, except a primitive integer used as a sort/loop index.
- Proper capitalization for acronyms in types (`DPIScale`, not `DpiScale`).
- Put **units and qualifiers last, most-significant first**: `latency_ms_max`,
  not `max_latency_ms`, so related names line up and sort together.
- When two names relate, give them the same length so call sites align:
  `source`/`target` beats `src`/`dest`, because `source_offset`/`target_offset`
  then line up too.
- Prefix a helper with its caller to show the call history:
  `term_pump` and `term_pump_callback`.
- Order matters for reading even when it doesn't for semantics: important things
  near the top of the file; `main` first; for structs, fields → nested types →
  procedures.
- Don't overload a term with two context-dependent meanings.

### Comments

- **Always say why.** Code shows *what*; comments justify the *why* and show your
  workings. `ingot`'s existing comments (e.g. the UTF-8 hold-back rationale in
  `term/term_pump.odin`) are the bar — match them.
- Comments are prose: a capital letter and a full stop. End-of-line comments may
  be phrases without punctuation.
- For a test or a subsystem, put a short paragraph at the top explaining the goal
  and the method so a reader can get up to speed or skip past.

### Cache invalidation

- Don't duplicate state or alias it — copies drift out of sync.
- Compute or check a value close to where it is used; don't introduce variables
  before they're needed or leave them lying around after.
- Prefer simpler signatures to reduce dimensionality at the call site: `void`
  beats `bool`, `bool` beats an int, a plain value beats an optional.

## Style by the numbers

- Run `odinfmt` (`.odinfmt.json` pins the settings). Do not hand-format around
  it.
- **Indent with tabs, width 4.** This is the Odin / `odinfmt` norm and what the
  entire `ingot` tree already uses. (TigerBeetle uses 4 spaces because that's the
  Zig norm — we deliberately keep tabs so the formatter never churns the tree.)
- **Hard limit lines to 100 columns.** Use the width, never exceed it. Set a
  column ruler in your editor (`.editorconfig` declares it).
- Add braces to an `if` unless it fits on a single line — defense in depth
  against "goto fail" bugs.

## Dependencies and tooling

- `ingot` is **pure Odin on `vendor:*`** (wgpu, glfw, stb) with committed
  libvterm static libs — effectively a zero-external-dependency policy. Keep it
  that way: every dependency is a supply-chain, safety, and performance risk that
  is amplified through everything that builds on the engine.
- Standardize on Odin for tooling too. Prefer an Odin program over a one-off
  shell script where it's practical, for portability and type safety.

## The last stage

Keep trying things, have fun, and remember it's called `ingot` because it starts
small and solid — a billet you forge, not a framework you inherit.
