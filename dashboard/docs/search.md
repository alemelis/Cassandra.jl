# Search

Cassandra's search is **negamax alpha-beta with iterative deepening**, layered
with the standard set of pruning and reduction heuristics. Each layer below is
a distinct technique, gated by a flag in the active `EngineConfig` so you can
ablate one at a time.

The whole search lives in `src/Search/AlphaBeta.jl`. The two entry points:

- `select_move(model, board)` — what the bot calls. Tries the book first,
  otherwise runs `search`.
- `search(model, board; cfg)` — root iterative deepening loop.

---

## Why we even need search

A static evaluation function looks at one position and returns a number. But
the value of a position is really *the value reachable from it under best
play*. Search is how we bridge that gap: we look ahead, evaluate the leaves
statically, and propagate scores up under the assumption both sides play their
best move.

The fundamental trade-off: **deeper search = stronger play, but exponentially
more work**. Every halving of the effective branching factor (from ordering,
pruning, reductions) doubles the depth we can reach in the same time. That is
the whole game.

---

## Negamax & alpha-beta

**Negamax** is a compact form of minimax that exploits the zero-sum property:
a position's value from the current player's perspective is the negation of
its value from the opponent's. One function handles both sides, recursing as
`-search(child)`.

**Alpha-beta pruning** maintains a window `[α, β]`:

- `α` = the best score the maximiser is already guaranteed elsewhere.
- `β` = the best score the minimiser is already guaranteed elsewhere.

If a branch returns a score `≥ β`, the opponent would have steered the game
away from this position higher up the tree — we can stop searching it
("fail-high", a **β-cutoff**). If `≤ α`, the current player can't improve and
we record an upper bound ("fail-low").

In the best case, with perfect move ordering, α/β reaches depth `2d` for the
cost of unpruned depth `d` — i.e. it doubles the depth for the same node
budget. In the worst case (random ordering) it gives no improvement at all.
Hence: **move ordering is everything** (see [Move ordering](move-ordering.md)).

---

## Iterative deepening {#iterative-deepening}

The engine searches depth 1, then depth 2, then depth 3 … up to
`search.max_depth` or until the time limit fires. This *seems* wasteful but
two effects make it cheap and in fact **strictly better than going straight to
the target depth**:

1. **Move-order seeding.** The best move from depth `d` becomes the first move
   tried at depth `d+1` (via the TT and the root re-ordering loop in
   `search`). Good first moves cause early β-cutoffs, which is exactly what
   alpha-beta needs to be efficient.
2. **Anytime behaviour.** When the clock rings mid-iteration, we still have a
   complete result from the previous depth.

Knobs: `search.max_depth`, `search.time_limit_s`.

**Tuning.** Set `time_limit_s` to roughly `clock_seconds / 30` for a base
estimate (assumes ~60 moves per side per game, half the budget kept as
reserve). For ultra-bullet, drop to `clock_seconds / 50`.

**Next steps.** Time management is currently uniform per move; a real engine
spends more time on critical positions (significant score swing between
iterations, only one legal-looking move, in check) and less on obvious
recaptures. This is the single highest-Elo time-control improvement available.

---

## Aspiration windows {#aspiration-windows}

After iteration `d` returns score `s`, iteration `d+1` is launched with a
narrow window `[s − W, s + W]` where `W = search.aspiration_window_cp`. A
narrower window causes more β-cutoffs and accelerates the search.

If the score falls outside the window:

- **Fail-low** (`score ≤ lo`) — re-search with `lo = -∞`.
- **Fail-high** (`score ≥ hi`) — re-search with `hi = +∞`.

Set `search.aspiration_window_cp = 0` to disable (full window every depth).
The default 50 cp is a safe choice for the current eval; if your eval becomes
noisier (e.g. mobility added) you may need to widen.

**Next steps.** Replace the binary widening with a stepped widen
(`W → 2W → 4W → ∞`); cheaper than a full re-search when scores oscillate.

---

## Quiescence search {#quiescence-search}

After reaching the nominal depth limit, the engine does **not** evaluate
immediately. It enters quiescence, which keeps searching captures (and queen
promotions) until the position is "quiet". Without this, depth-`d` would
evaluate positions in the middle of a tactical exchange, scoring them as if
the just-captured piece is permanently won — the **horizon effect**.

Two pruning rules keep qsearch finite:

- **Stand-pat.** Before searching captures, evaluate statically. If
  `eval ≥ β`, return immediately — the side to move would never *enter* this
  position if she could already prove the bound. This is the "do nothing"
  baseline that captures must beat.
- **Delta pruning.** Skip a capture if even taking the captured piece for free
  cannot bring the score within `search.delta_pruning_margin_cp` of α
  (default 200). Cheap clearly-losing captures get culled instantly.

Knob: `search.qsearch` (on/off), `search.delta_pruning_margin_cp`.

**Next steps.** Add **SEE** (Static Exchange Evaluation) so qsearch can
prune *losing* captures (e.g. capturing a defended pawn with a queen). This
is one of the highest-leverage qsearch improvements available.

---

## Check extension {#check-extension}

When the side to move is in check, the search depth is **increased by one ply**
before recursing. Forced checking sequences are common tactical motifs and
without the extension we'd routinely cut off mate-in-N just past the depth
boundary.

Knob: `search.check_extension`.

**Next steps.** Singular extensions (extend if one move is much better than
the rest), recapture extensions, and pawn-to-7th extensions add another
~30 Elo each. They share the same machinery — bump `depth` by 1 in a
condition.

---

## Null-move pruning {#null-move-pruning}

At non-PV nodes with `depth ≥ search.null_move_min_depth` (default 3), the
engine **passes the turn** (a *null move*) and searches at reduced depth
`depth − 1 − R` (default `R = 2`). If even doing nothing fails high, the real
move will too — prune.

The pass is implemented in `_make_null_move`: same pieces, flip side,
clear ep, fresh Zobrist. Two safety guards:

- **Don't null in check** — passing the turn would be illegal anyway.
- **Don't null in pawn-only endgames** (`_has_non_pawn`) — this is the
  classic *zugzwang* trap: the side to move is *worse off* having to move,
  so "passing" gives a misleadingly good score.

Knobs: `search.null_move_enabled`, `search.null_move_R`,
`search.null_move_min_depth`.

**Tuning.** R = 2 is conservative; R = 3 or even adaptive R
(`R = 2 + depth/6`) is standard in modern engines and is worth ~30–50 Elo
once move ordering is solid enough that the resulting tactical misses are
rare.

---

## Late Move Reductions (LMR) {#late-move-reductions}

Moves later in the ordered list are less likely to be best — that's what
ordering *means*. So we search them at reduced depth first; if one
unexpectedly fails high (`score > α`) we re-search at full depth to
confirm.

Conditions (all must hold):

- LMR is enabled (`search.lmr_enabled`).
- Not in check.
- `depth ≥ search.lmr_min_depth` (default 3).
- Move number > `search.lmr_min_move_idx` (default 4).
- Quiet move (no capture, no promotion).

Reduction = `search.lmr_reduction` (default 1).

**Next steps.** Modern LMR uses a **logarithmic table** indexed by `(depth,
move_number)`, plus extra reductions on non-PV nodes and bad-history moves.
Replacing the flat reduction with a log table is a +30–60 Elo change
and is purely a code edit (no new infrastructure).

---

## Repetition & 50-move rule

Positions encountered on the current search path are stored in a
`Set{UInt64}` (`seen` in `_negamax`). Revisiting any returns 0 (draw, since
threefold repetition is forced). The 50-move rule returns 0 when
`board.halfmove ≥ 100`.

Both rules use Bobby's halfmove counter and Zobrist hash, so they are nearly
free.

**Caveat.** This treats the *first* repetition as a draw — strictly, the
threefold rule needs the same position three times. The simplification is
standard in alpha-beta engines and slightly *over*-conservative (the engine
avoids forcing repetitions it could win out of). Acceptable for now.

---

## Mate scoring & "prefer draw over loss"

Checkmate returns `MATE_SCORE − ply` rather than a flat constant — a mate-in-1
scores higher than a mate-in-5, so the engine always picks the *shortest*
available mate (and, defensively, the *longest* loss).

After each iteration the root code does a small safety pass:

```
if iter_best_score <= 0:
    if any move has score > 0  → pick a winning move
    elif any move has score == 0 → pick a drawing move
```

This guards against the case where the search returns the "least-bad" move at
score `−∞` (mate against us) when in fact a drawing move exists (e.g. a forced
3-fold repetition).

---

## What's missing — the path to 2500

In rough order of expected Elo per implementation effort:

1. **Faster move generation in Bobby** — the multiplier on every other gain.
   See the Bobby bottleneck note. (~+200–400 Elo from depth alone.)
2. **Logarithmic LMR table** + reduce more on non-PV and bad-history. (~+50)
3. **SEE** for qsearch pruning and capture ordering. (~+50)
4. **Adaptive null move** (`R = 2 + depth/6`). (~+30)
5. **Singular extensions**. (~+30)
6. **Time management** (pondering on critical positions). (~+30)
7. **History gravity / counter-move history**. (~+25)
8. **Pawn-structure & king-safety eval terms**. (~+30)
9. **Static null-move pruning** (also called *reverse futility*). (~+20)
10. **Internal Iterative Deepening** at PV nodes without a TT move. (~+15)

Each is independently testable: clone the deployed setup, flip a single knob,
deploy, run an arena session, compare win rates by `setup_hash`.
