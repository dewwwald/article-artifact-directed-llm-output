# Article Brief: Building a Directed-Decoding Demo in Zig

This is a brief for an AI (or human) writing an article about the project in
this repository. It summarizes what was built, in what order, why, and what
went wrong along the way — the bugs are as much the story as the design.

## One-paragraph summary

A solo developer built, over one long iterative session, a Zig 0.16
application that lets a user ask a natural-language question about a small
SQLite-backed dataset ("give me all items that have name gadget and price
50"), turns that question into a structured, custom AST query via a local
LLM (Google's Gemma, served locally through LM Studio), validates the LLM's
output character-by-character against the AST's grammar as it comes back,
retries with explicit feedback when it's wrong, and runs the resulting query
against the database — all wrapped in a web UI that animates the entire
pipeline in real time (an architecture diagram with traveling "packets," and
a "brick wall" that builds up character by character as the AST is
validated). The end goal, stated partway through, was to use this as source
material for an article about **directed/guided decoding**.

## Why this project is a good subject

It's a working demonstration of a distinction that's usually glossed over in
generic "guided decoding" explainers: the difference between **true
constrained decoding** (masking invalid tokens during generation, at the
sampler level) and **post-hoc validation** (checking a finished response and
retrying if it's wrong). This project implements *both*, layered on top of
each other, and the build process organically surfaced the tradeoffs between
them — including a moment where the developer initially believed they'd
built the former when they'd actually built the latter, and had to correct
that understanding mid-project.

## Architecture (final state)

```
Browser (web/index.html)
  <-- WebSocket (JSON events) -->
Zig server (web/server.zig, std.http.Server)
  -> query.zig (orchestrates one request)
       -> ast/doc.zig          (plain-English grammar doc -> system prompt)
       -> ast/json_schema.zig  (real JSON Schema -> response_format, for real constrained decoding)
       -> llm/client.zig       (HTTP call to LM Studio's OpenAI-compatible API)
       -> llm/prefix_validator.zig (incremental validator: JSON syntax + AST schema shape)
       -> ast/matcher.zig      (JSONPath-lite resolver + AST evaluator, "which items matched")
       -> db/ (repository/entity, raw SQL via zig-sqlite, no ORM)
       -> render/ (Event/Bus/Renderer - fans events out to terminal + websocket)
  <-- HTTP (response_format: json_schema) -->
LM Studio (local server, Gemma model, MLX backend using the Outlines library
           for grammar-constrained sampling)
```

The AST itself is a small custom query language: an array of `Node` objects,
each with `operand` (AND/OR, how it combines with the previous node),
`action` (EQUALS/NOT_EQUALS/CONTAINS/NOT_CONTAINS), `path` (a JSONPath-lite
string like `$.items[]` or `$.name`), `value`, and an optional nested `then`
array applied to each element when `path` ends in a wildcard `[]`.

## Chronological build log

The project started as **just comments** in `main.zig` sketching the idea:
an AST for AND/OR/EQUALS/CONTAINS matching against JSON, plus a vague note
about eventually using LM Studio + Gemma to generate ASTs from prompts.

1. **Core AST matcher.** Built `Node`/`Segment`/`Operand`/`Action`, a
   JSONPath-lite resolver, and the matching engine. Consolidated the
   originally-sketched ambiguous "ISNOT" action into two clean actions,
   `NOT_EQUALS` and `NOT_CONTAINS`, at the user's direction.
2. **SQLite persistence.** Added a real `items` table via the `zig-sqlite`
   package (no ORM — hand-written SQL, described by the user as "raw PDO"
   even though PDO is PHP-specific; interpreted correctly as "raw SQL, no
   ORM" and confirmed).
3. **Refactor passes.** The user repeatedly asked for reorganization as the
   file grew: split into `entity`/`repository` folders (mirroring a
   lightweight DDD pattern), consolidated into a unified `db/` folder,
   then extracted a matching `ast/` folder (entity types + a `matcher.zig`
   for the logic) once the AST logic started crowding `main.zig` again.
   Full CRUD (`create`/`find`/`all`/`update`/`delete`) was added to the
   repository at this point, matching the user's explicit `*CrudService`
   naming request.
4. **The LLM integration begins.** Three purpose-built pieces:
   - `ast/doc.zig`: a plain-English description of the grammar, meant to be
     the system prompt.
   - `ast/schema.zig`: a hand-built, machine-readable description of the
     `Node` shape (valid keys, enum-constrained fields) for a *custom*
     validator (not a standard JSON Schema).
   - `llm/prefix_validator.zig`: an incremental validator built on
     `std.json.Scanner`'s genuine streaming API (`feedInput`/`next`,
     `error.BufferUnderrun` meaning "valid so far, need more data"). A
     hand-rolled stack machine layered on top enforces the `Node` schema
     as bytes arrive — rejecting a bad key or an out-of-set enum value the
     moment it becomes impossible, not just at the end.
   - **First real bug**, caught immediately by the test suite: the
     validator popped a `Node`'s stack frame after its *first* key/value
     pair instead of cycling back to accept the rest of the object's keys.
     A one-line-looking bug with a non-obvious fix (transform the frame
     back to "expecting a key" instead of popping it; only `object_end`
     should pop).
   - `llm/client.zig`: an HTTP client to LM Studio's OpenAI-compatible
     `/v1/chat/completions`, built against Zig 0.16's new `std.Io`-based
     `std.http.Client`.
5. **Made it interactive + return actual matches.** Added a stdin prompt,
   and extended the matcher with `filterIndices` (which *items* matched,
   not just yes/no). Found and fixed a real bug live: `Node.operand` was a
   required field, but the prompt doc said it was "ignored on the first
   node," so the model sometimes omitted it — crashing JSON parsing.
   Fixed by giving it a default value.
6. **The "is this really guided decoding?" turn.** The user asked directly.
   The honest answer: no — what existed was post-hoc validation of a
   complete, already-generated response, not token-level steering (which
   needs logit access a plain chat-completions call doesn't expose). The
   user's proposed fix — feed the specific rejection reason back to the
   model and ask it to regenerate — was implemented as a bounded retry
   loop (`buildRetryPrompt`, max 3 attempts).
7. **The real constrained-decoding discovery.** The user pasted an AI
   search-overview snippet claiming LM Studio supports genuine
   grammar-constrained decoding via `response_format: {type: "json_schema",
   ...}`. This was independently verified against LM Studio's actual docs
   (not taken on faith) — confirmed true: GGUF models use llama.cpp's
   grammar sampling, MLX models (the one in use here) use the Outlines
   library, and it really does mask invalid tokens during generation, not
   just validate afterward. Built `ast/json_schema.zig` (a real JSON
   Schema with `$defs`/`$ref` for the recursive `Node.then` structure) and
   wired it into `llm/client.zig`'s request body. The custom
   validator + retry loop was deliberately kept as a second layer, both as
   a safety net (LM Studio's own docs warn structured output is unreliable
   under ~7B parameters — the model in use is 4B) and because it still
   catches an entire class of problem JSON Schema can't express (see
   "schema vs. semantics" below).
8. **The render event bus.** Anticipating a future web UI, the user asked
   for a pluggable event bus now, "so we can swap the renderer for a web
   renderer through websocket" later. Built as a small vtable-based
   `Renderer` interface + a `Bus` that fans events out to N subscribers,
   with `Event` as a plain tagged-union (trivially serializable). Shipped
   first with just a `TerminalRenderer`.
9. **The web UI.** Chat pane (left) + a live visualization pane (right).
   Discovered mid-design that Zig 0.16's `std.http.Server` has *built-in*
   WebSocket support (handshake + framing, no hand-rolled protocol code
   needed) — this made "real websockets" (as the user asked for) far less
   risky than initially assumed. `query.zig` was extracted from `main.zig`
   so the orchestration logic could be shared between a future CLI and the
   new web server. Two real bugs found via live testing (not just code
   review):
   - `respondWebSocket()` doesn't auto-flush its handshake response (says
     so in its own doc comment) — the server was deadlocked waiting to
     read from a client that was still waiting for a handshake it never
     received. One-line fix (`ws.flush()`), but only found by actually
     driving a raw `curl` handshake and a Python `websocket-client` script.
   - The connection-accept loop was sequential. A real browser opens the
     page-load connection *and* a separate WebSocket connection at nearly
     the same time; the server got stuck servicing the first and never
     accepted the second, manifesting as an infinite "connecting..." in
     the browser. Fixed by switching to `Io.Group` + `group.concurrent` —
     the exact same concurrency pattern Zig's own build system uses for
     its `--fuzz` web UI, found by reading that code as a reference.
10. **The visualization itself.** An animated 3-node diagram (Browser / Zig
    Server / LM Studio) with color-coded "packets" traveling along the
    links on key events, plus a "brick wall" that builds up character by
    character as each byte is fed to the validator, paced by a client-side
    queue (decoupling animation speed from network/server timing). Colors
    were pulled from a design-system skill's validated categorical palette
    — notably, an instinctive choice to swap one color to avoid a
    perceived clash with a status color *failed* the palette's automated
    CVD-safety validator, while the plain, by-the-book default order
    passed cleanly. Verified live via browser automation (not just visual
    inspection of the HTML/CSS/JS) — which caught a real bug: the frontend
    compared Zig's serialized `Status` union against a bare string, when
    it actually serializes as `{"valid_complete": {}}`.
11. **The "cost vs. price" bug.** Live testing surfaced that asking for
    items that "cost 50" failed, because neither the AST doc nor the JSON
    Schema told the model anything about the *data's* actual fields — both
    only describe the AST's own grammar. Added a hint (derived from the
    `Item` struct's real fields via reflection, so it can't drift) telling
    the model exactly which fields exist and to map synonyms onto them.
    The first version of this fix caused a **regression**, caught by a
    user-supplied screenshot: the hint's phrasing looked like a literal
    path template, so the model started emitting bare `"price"` instead of
    `"$.price"`, crashing the path resolver. Fixed the wording, and
    additionally made path-resolution failures retry through the same
    feedback loop as validator rejections, rather than crashing the
    request — a defense-in-depth fix for a whole class of failure, not
    just this instance.
12. **Visualizing iteration.** The brick wall was redesigned from "one wall,
    wiped on each retry" to a stacked history — one labeled section per
    attempt ("Attempt 1", "Attempt 2 of 3", ...), each with its own
    pass/fail pill, plus a pulsing badge on the LM Studio diagram node
    showing the current attempt count. This was specifically requested so
    retries visibly read as "the model iterating on the AST," not a silent
    restart.
13. **Pretty-printing.** The brick wall showed the model's raw, unformatted
    JSON. Added a client-side JSON pretty-printer + syntax highlighter that
    swaps in once an attempt is confirmed valid. This surfaced two more
    live-testing-only bugs: a stray unmatched parenthesis in the
    highlighting regex threw a `SyntaxError` that silently broke the
    *entire* page script (nothing worked at all — caught via the browser's
    console, not visual inspection); and a subtler ordering bug where the
    "finalize to pretty JSON" step ran *before* the paced brick queue had
    actually finished drawing all the characters, so `JSON.parse` ran on
    incomplete text and silently failed. Fixed by moving the finalize step
    (and the chat-reply step) into the *same* paced queue as the bricks,
    guaranteeing they only run once everything before them has actually
    rendered.
14. **Docs.** MIT license, a README (requirements, run/usage instructions,
    a Mermaid architecture diagram, a module table), and this brief.

## Key themes for the article

- **Post-hoc validation vs. true constrained decoding.** Most casual
  "guided decoding" demos (including this project's first pass) are
  actually the former: generate a full response, then check it. This
  project makes the distinction concrete and ends up implementing both,
  layered — real grammar-constrained decoding via LM Studio's
  `response_format`, with a validate-and-retry loop as a second line of
  defense.
- **A schema constrains shape, not intent.** Even a perfect JSON Schema
  can't express "always nest per-element checks under `then`" or "map the
  word 'cost' onto the field `price`" — those are semantic/convention
  concerns, and the model happily produced structurally valid JSON that
  was still useless multiple times. Fixing this needed careful, precisely
  worded natural-language hints — and a sloppily worded hint caused a
  regression of its own, which is a good demonstration that prompt
  engineering has its own failure modes just like code does.
- **Small local models are genuinely unreliable in specific, reproducible
  ways** — nulling out fields, omitting required keys, inventing
  non-conventional path syntax — and a bounded retry-with-explicit-feedback
  loop measurably helps without requiring a bigger model.
- **"Compute it, don't eyeball it" applies beyond colors.** The
  color-palette validator catching a bad instinctive choice is a small
  but clean example of a broader theme running through the whole build:
  almost every real bug in this project was caught by *running something*
  (tests, a live curl handshake, a Python WebSocket client, actual browser
  automation with console-log inspection) rather than by reading code and
  trusting it.
- **Zig 0.16 specifics worth a technical aside:** the new `std.Io`
  interface (`Io.Threaded`, `Io.sleep`, `Io.Group`/`concurrent`),
  `std.json.Scanner`'s real incremental-parsing API as the foundation for
  a custom streaming validator, and `std.http.Server`'s built-in (easy to
  miss) WebSocket support.

## Tech stack

Zig 0.16.0 · SQLite via the `zig-sqlite` package (bundled amalgamation, no
system dependency) · LM Studio running Google's Gemma (MLX, 4B parameters)
· `std.http.Client`/`std.http.Server` for both directions of networking ·
a hand-rolled JSON Schema for `response_format` · vanilla HTML/CSS/JS for
the frontend (no framework, no build step) · a design-system skill's
validated color palette for the visualization.
