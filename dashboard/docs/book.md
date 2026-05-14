# Opening book

Before any tree search, `select_move` consults the opening book. If the
current position is in the loaded book, a move is sampled and returned
immediately — no nodes searched. Time spent: ~10 µs.

## Format: Polyglot (`.bin`)

Cassandra reads the de-facto standard **Polyglot** binary format. Every
serious open-source chess engine ships one, and there are dozens of
ready-made files online covering ratings from beginner to GM:

- [gmcheems-org/free-opening-books](https://github.com/gmcheems-org/free-opening-books) —
  curated index. `gm2001.bin`, `Human.bin`, `Cerebellum`, `Titans.bin` are
  the popular ones.
- `polyglot` (the original C tool) and `pgn-extract` build `.bin` files
  from PGN collections, if you'd rather generate your own.

## Configuration

Three knobs in the setup's `book` block:

| Field | Meaning |
|---|---|
| `enabled` | Global kill switch. |
| `path` | Absolute path to the `.bin` file. Empty string = no book. |
| `chaos` | 0.0 = standard weight-proportional sampling; 1.0 = uniform over all entries for the position. Anything in between flattens the weight distribution. |
| `max_ply` | Stop consulting the book past this ply (default 20). |

The bot loads the file once at startup and reloads it whenever the
deployed setup changes. There's no dashboard CRUD — point `book.path` at
a file and restart, or live-edit the setup and the bot picks it up.

## The chaos dial

A standard book gives you Botvinnik openings every time. Polyglot books
already contain off-beat lines, just with low weights — say, `1.b3` with
weight 5 vs `1.e4` with weight 5000. Standard weighted sampling almost
never picks the weird ones.

`book.chaos` flattens that distribution. We raise each weight to
`(1 - chaos)`:

- `chaos = 0.0` → unchanged, mainline behavior.
- `chaos = 0.5` → 5000 vs 5 becomes ~71 vs ~2.4 (29× preference instead
  of 1000×). Off-beat moves get a real shot.
- `chaos = 1.0` → all entries equally likely. Maximum variety.

Use `chaos = 0` for a serious setup and `chaos = 0.5+` for a chaos
personality.

## How probing works (briefly)

1. Compute the Polyglot Zobrist hash of the position (~40 XORs — fast).
2. Binary-search the in-memory entry table for that hash.
3. Sample one of the matching entries with chaos-weighted probability.
4. Decode the 16-bit move integer to UCI, special-casing castling
   (Polyglot encodes king→rook square; UCI is king→destination).

If the position isn't in the book, we fall through to the search with
the full clock budget — no time wasted on the book lookup.
