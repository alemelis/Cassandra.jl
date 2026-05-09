# Opening book

Before any tree search, `select_move` consults the opening book. If the
current position's Zobrist hash is in the book, a move is sampled and
returned immediately — no nodes searched. This costs ~0 time per move and
serves three purposes:

1. **Skip the openings.** Openings have been analysed for centuries; the
   engine cannot meaningfully improve on `1.e4` from `Nh3`.
2. **Inject variety.** A weighted sample (rather than always the top move)
   prevents the bot from playing the same line every game and makes it
   harder for opponents to prep.
3. **Steer style.** A curated book lets you bias toward sharp, classical, or
   defensive openings — useful for testing eval/search behaviour in
   specific position types.

Code: `src/Book.jl`. The book is a global singleton, JSON-backed at
`book/book.json` (or `$CASSANDRA_BOOK`).

---

## Format

```json
{
  "version": 1,
  "entries": {
    "<UInt64 zobrist hash>": [
      { "move": "e2e4", "weight": 5, "label": "King's Pawn" },
      { "move": "d2d4", "weight": 3, "label": "Queen's Pawn" }
    ],
    ...
  }
}
```

A position can have multiple book moves; on probe a weighted sample is drawn:

```julia
total = sum(weight)
r = rand() * total
walk entries, accumulate weight, return the move that contains r
```

`weight` is an integer "frequency" — set to `1` by default, raise it for moves
you want played more often. A weight of `0` effectively disables an entry
without deleting it (it can never be sampled, since `r > 0`).

---

## Curated lines

`book/curated.json` ships a small set of named opening lines:

```json
{
  "lines": [
    { "name": "Italian Game", "moves": "e2e4 e7e5 g1f3 b8c6 f1c4" },
    ...
  ]
}
```

`Book.import_curated!()` walks each line's UCI moves, computing the Zobrist
hash after each ply, and inserts `(hash → move)` so the book covers every
position *along* the line, not just the leaf. The dashboard's "Import
curated" button calls this.

---

## Probing

```julia
function probe(board)
    moves = ENTRIES[][board.hash]
    isnothing(moves) && return nothing
    weighted_sample(moves)
end
```

Gated by `book.enabled` (in `EngineConfig`) and `book.max_ply`. Beyond
`max_ply` (default 16), the book is ignored even if it has the position —
this prevents the book from playing the entire game in long forced lines.

The book is **hot-reloaded** on every probe: if `mtime(book.json)` has
changed, `load!` is re-run inside a lock. Editing the book through the
dashboard takes effect on the bot's next move; no restart required.

---

## Mutation API

| Function | What |
|----------|------|
| `add_line!(name, "e2e4 e7e5 …")` | Walk the line, upsert (hash, move) at each ply |
| `delete_entry!(hash, uci)` | Remove a single move from a position |
| `clear!()` | Empty the book |
| `import_curated!(path)` | Load lines from `curated.json` |
| `save!(path)` | Persist to disk |

All are wrapped in `LOCK` (a `ReentrantLock`) — safe to call from the bot's
HTTP control server while a game is in progress.

---

## What's missing

- **Polyglot import.** The chess world standardises on `.bin` Polyglot
  format (a sorted array of `(hash, move, weight, learn)` tuples). Importing
  a published Polyglot book (e.g. Cerebellum or gm2600.bin) would give
  Cassandra a strong opening repertoire instantly. The Zobrist seeds differ
  from Bobby's — needs a hash-conversion or a separate Polyglot-key
  computation.
- **Book learning.** Track win rates per `(position, move)` and downweight
  losing branches. Cheap to implement on top of the existing weight field;
  worth doing once we have enough games per opening to be statistically
  meaningful.
- **Depth-aware exit.** Currently book→search is a hard binary. Smoother:
  if the book has the position but the move it would play has a low weight,
  fall through to search. Avoids playing rare/bad book entries.
