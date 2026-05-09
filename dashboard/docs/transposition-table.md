# Transposition table

A transposition is the same position reached by different move orders. In
chess they are extremely common — `1.e4 e5 2.Nf3 Nc6` and `1.Nf3 Nc6 2.e4 e5`
reach the same board. Without caching, alpha-beta would re-search each
visit from scratch.

The TT (`src/Search/TT.jl`) is a hash map from **Zobrist position hash → entry**:

```julia
mutable struct TTEntry
    hash::UInt64
    depth::Int8
    score::Float32
    flag::UInt8       # EXACT / LOWER / UPPER
    best_idx::Int16   # ordering hint
end
```

Sized at `2^search.tt_size_log2` entries (default `2^20 ≈ 32 MB`).

---

## What "score" + "flag" mean

Alpha-beta doesn't always return the exact value of a position — sometimes
it returns a bound:

| Flag | Meaning |
|------|---------|
| `EXACT` | The score is the true minimax value at this depth. |
| `LOWER` (fail-high) | Search returned `score ≥ β` early; true value `≥ score`. |
| `UPPER` (fail-low) | Search returned with `score ≤ α`; true value `≤ score`. |

The probe (`tt_probe`) only returns a hit when the stored bound is
**useful for the current `[α, β]` window**:

- `EXACT` — always usable.
- `LOWER` — usable only if `score ≥ β` (we already know we beat β).
- `UPPER` — usable only if `score ≤ α` (we already know we can't reach α).

When the depth is shallower than what we need (`e.depth < depth`), we still
keep the `best_idx` as a **move-ordering hint** — that's the TT's other huge
contribution to alpha-beta efficiency.

---

## Mate-distance adjustment

Mate scores embed how many plies away the mate is (`MATE_SCORE − ply`). If a
mate-in-3 is found at root depth 5 and stored, then later we transpose into
the same position at root depth 7, the *position-relative* distance is the
same but the *root-relative* score should be 2 plies cheaper.

So we store *node-relative*: add `ply` on the way in, subtract on the way
out:

```julia
_score_to_tt(score, ply)   = score ± ply   (when |score| > MATE_BOUND)
_score_from_tt(score, ply) = score ∓ ply
```

This is the trick that lets mate scores be reused safely across
transpositions.

---

## Replacement policy

Current rule:

```julia
e.hash == hash && e.depth > depth && return  # keep deeper hit
otherwise: overwrite
```

That is: we always overwrite on collision **except** if the existing entry
is for the *same position* and was searched *deeper* than this one. The
rationale: deeper data is more authoritative.

This is the simplest correct scheme. It has a known weakness — **always-replace
costs entries searched at large depth from the root** as the TT fills up,
because shallower qsearch nodes pour in. The standard fix is **two-tier
buckets**: each slot holds two entries, one prioritised by depth ("depth-pref")
and one by recency ("always-replace"). With a 1 M-entry table this is a +20
Elo change at deeper time controls.

---

## Sizing

`tt_size_log2 = 20` → 1 M entries × ~24 B each ≈ **32 MB**. For a self-hosted
bot this is comfortable. For longer thinks (rapid+) larger TTs help; bump to
`22` (≈128 MB) at minimum. The hash slot is `hash % TT_SIZE + 1`; because
`TT_SIZE` is a power of two, that's a single bitmask in practice (Julia
will optimise it).

---

## Failure modes to be aware of

- **Hash collisions.** Two distinct positions with the same Zobrist hash. At
  64-bit Zobrist this is rare but not impossible; a corrupted entry is
  *possible*. The cost is a single bad score in one search. Modern engines
  store a few "verification bits" of the hash separately as a sanity check.
  Worth doing if you ever observe inexplicable blunders.
- **Aging.** The TT is shared across moves of the game. After 30 moves,
  most entries refer to positions we'll never visit again. Some engines tag
  each entry with a generation counter and prefer to overwrite stale
  entries. With a 32 MB table this has marginal impact; with 256 MB+ it
  matters.
- **Repetition cache vs TT.** Repetition detection uses a separate
  `Set{UInt64}` (the `seen` parameter in `_negamax`) and is cleared per
  iteration. The TT is *not* used for repetition because the TT score is
  position-relative, not history-relative.

---

## Knobs

| Knob | Default | Effect |
|------|---------|--------|
| `search.tt_size_log2` | 20 | TT size = `2^N` entries; needs restart to take effect |

`tt_clear!()` is exposed and is called between unrelated games / arena rounds
to avoid stale move-ordering hints leaking across.
