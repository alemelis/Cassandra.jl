# Move ordering

Move ordering is the single biggest amplifier of alpha-beta efficiency. With
perfect ordering, α/β reaches depth `2d` in the cost of depth `d`; with random
ordering it costs the full `b^d`. So every cheap heuristic that improves the
ordering of the *first few* moves is worth more than almost any pruning
refinement deeper in the tree.

Code: `src/Search/MoveOrder.jl`. The ordering function is called once per
node, on the freshly-generated move list, and produces a `Vector{Int16}`
permutation.

---

## The priority ladder

For each move we compute a single Float32 score `_move_priority` and sort
descending. The bands are spaced by orders of magnitude so each layer
strictly dominates the next:

| Tier | Bonus | What |
|------|-------|------|
| 1 | `2_000_000` | TT best move (the move stored from a prior search of this position) |
| 2 | `1_000_000 + 10·victim − attacker` | Captures, MVV-LVA |
| 3 | `900_000` | Non-capture promotions |
| 4 | `800_000` | Killer-move match |
| 5 | `history[piece, to]` | History heuristic |
| 6 | `+ logits[uci_idx]` | Optional NN policy logits |

Each tier is explained below.

---

## TT best move

If we've searched this exact position before — even at a shallower depth — the
move that was best then is overwhelmingly likely to be best now. Trying it
first means we usually fail-high on move 1 and skip the entire move list.

A TT-move hit on the first try is the difference between visiting one child
and visiting all of them. This single rule is responsible for most of the
"effective branching factor" that classical engines achieve.

---

## MVV-LVA (Most Valuable Victim / Least Valuable Attacker)

Captures are sorted by:

```
score = 1_000_000 + 10 × victim_value − attacker_value
```

So `PxQ` (pawn takes queen) ranks higher than `QxP`. The intuition: capturing
high-value pieces is more often good, and capturing them with low-value pieces
is *much* more often good (you keep the attacker after the trade).

This is cheap (table lookup, two indices) but coarse — it doesn't know which
captures are *defended*. A queen capturing an undefended pawn is great; a
queen capturing a pawn defended by a pawn is a blunder. Both currently get
the same MVV-LVA score.

**Next steps.** Add **SEE** (Static Exchange Evaluation): simulate the full
recapture sequence on a square, return the net material change. Use it to:

- Re-rank captures (`SEE ≥ 0` first, `SEE < 0` last).
- Prune `SEE < 0` captures in qsearch entirely.

This is the single biggest move-ordering improvement still on the table — and
it requires only a per-square recapture simulation that Bobby's bitboards
make easy.

---

## Killer moves

A "killer" is a quiet move that recently caused a β-cutoff at the same ply.
We keep two slots per ply (`killers[ply] = (k1, k2)`), shifting in the new
killer on cutoff. On the next sibling node, if a killer move appears in the
move list it gets a large bonus — the heuristic is that *similar positions
share refutations*.

Why two slots: the most recent and one before; protects against thrashing
when the same pair of refutations alternate.

Knob: `ordering.killers`.

---

## History heuristic

A `[7 × 64]` table indexed by `(piece_type, to_square)`. On every β-cutoff
from a quiet move we increment

```
history[pt, to] += depth²
```

Squared because cutoffs at deeper search are more authoritative — they reflect
more lookahead. Capped at 1 million to avoid arithmetic overflow.

The history is added to the move's score directly, so it acts as a soft
"this kind of move tends to be good here" prior. It doesn't override killers
or captures (those are in higher bands) — it only re-ranks the long tail of
quiet moves.

Knob: `ordering.history`.

**Next steps.**

- **History gravity / aging.** Periodically halve all entries so old data
  doesn't dominate. Otherwise a strong cutoff in the opening drowns out
  middlegame information.
- **Counter-move history.** Index by `(prev_move, piece, to)` instead of just
  `(piece, to)`. Captures the idea that some replies are reflexively
  refuting.
- **Follow-up history.** Index by the move *two plies ago*. Together with
  counter-move history, this is the modern way; +30–50 Elo when implemented
  alongside.

---

## Killer/history are reset between searches

`reset_ctx!` zeros killers and history at the start of each iteration. This
is conservative — across iterations would let the heuristics warm up faster.
The reason it's done: with the very strong TT hit rate from iterative
deepening, the marginal benefit of carrying state is small, and the reset
avoids a class of subtle bugs where stale entries refer to moves that no
longer make sense at this depth.

---

## Optional NN policy logits

When `ordering.use_policy_logits` is true and a model is loaded, the policy
head's softmax-pre-output is added as a small tiebreaker:

```
score += logits[UCI2IDX[uci(move)]]
```

Forward-pass cost is currently >> per-node search cost, so the logits are
computed **once per node**, not per move. Even so, this only pays off if the
policy is meaningfully better than the existing classical ordering — at the
puzzle-trained quality level it has been a wash. Default off.

**Tuning.**

- Train more (or on stronger games) before relying on policy logits.
- Cache logits in the TT entry — they don't change for a given position.
- Or: only consult the policy at PV nodes, where ordering matters most.

---

## Diagnostics

Cassandra doesn't currently log a "move-ordering quality" metric, but the
right one is the **β-cutoff first-move ratio**: of all nodes that produced a
cutoff, what fraction did so on move #1? A healthy classical engine sees
≥ 90 %; below 80 % indicates ordering bugs. This is a 5-line addition to
`SearchContext` and would be cheap and very useful for tuning the
heuristics above.
