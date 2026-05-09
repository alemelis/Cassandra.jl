# Roadmap

Where Cassandra is heading, in a single page. Source of truth for "what
should I work on next?".

---

## Stage status

| Stage | Goal | Status |
|---|---|---|
| 0 | Scaffolding: model, dataset, training, eval harness | ✅ done |
| 1 | Puzzle training — policy head learns tactics | ✅ done (`silent_lasker`) |
| 2 | PGN training on strong human games — value head learns position | 🔄 in progress |
| 3 | Alpha-beta search with classical eval + NN move ordering | ✅ shipped, tunable |
| 4 | Lichess deployment for absolute Elo baseline | 🔄 live (~unrated → climbing) |
| 5 | Self-play loop — promote on >55 % win rate | planned |
| 6 | NN value head wired into leaf eval | planned |
| 7 | NNUE-style incremental eval | exploratory |

---

## The 2500-Elo path

The most ambitious near-term target. Today the engine is bottlenecked by
Bobby's move generator — every other gain compounds with deeper search, and
deeper search compounds with NPS.

In rough order of expected Elo gain per implementation effort:

1. **Bobby NPS** — the multiplier. See the bottleneck note. Each 2× in NPS
   ≈ +50 Elo from depth alone, and the algorithmic improvements below all
   benefit *more* when search is deeper. **Estimate: +200–400 Elo.**
2. **Logarithmic LMR table** + reduce-more on non-PV/bad-history. Trivial
   patch in `_negamax`. ~+50 Elo.
3. **SEE** in qsearch + capture ordering. Bitboard primitive; requires a
   new helper in Bobby or in `Eval/`. ~+50 Elo.
4. **Adaptive null-move** (`R = 2 + depth/6`). One-line change. ~+30 Elo.
5. **Singular extensions** at PV nodes. Same machinery as check extension.
   ~+30 Elo.
6. **Time management** — spend more on critical positions, less on obvious
   ones. ~+30 Elo.
7. **King safety + passed pawns + mobility** in eval. ~+50 Elo combined.
8. **Counter-move + follow-up history** in move ordering. ~+30 Elo.
9. **Two-tier TT** (depth-pref + always-replace buckets). ~+15 Elo.
10. **Static null-move pruning** (reverse futility). ~+15 Elo.

Sum: **~+500 Elo from a current ~2000 baseline → ~2500.** Conservative;
some compound multiplicatively with deeper search.

The order above reflects ROI, not strict dependencies. (1) should come
first because everything else benefits from it.

---

## Stage 6 — NN value at leaves

Once stage 2 produces a value head significantly better than the classical
eval (verifiable by replacing `classical_eval` in `_negamax` and running an
arena match), ship it. The change itself is one line; the cost is the
forward pass per leaf.

Two performance moves make it tractable:

- **Cache value on the TT entry** — same hash → same value. We already cache
  for ordering hints; extending to scalar value is one field.
- **Batch leaf evaluation** — group siblings into a batched forward pass.
  Requires restructuring the leaf path; ~+15 Elo without batching, ~+50
  with.

---

## Stage 7 — NNUE

NNUE = Efficiently Updatable Neural Network. A specialised, sparse
architecture where the input is a king-relative piece-on-square encoding,
and the first layer can be incrementally updated on every make/unmake at
near-zero cost. Allows millions of evals/sec on a CPU.

Prerequisites:

- Bobby implements true incremental make/unmake (currently it copies the
  board; see Bobby bottlenecks).
- A position-eval-labelled dataset (millions of positions with Stockfish
  evaluations as targets).
- An NNUE-shaped network with sparse first layer.

This is the gold standard for classical engines with neural eval. Top
engines (Stockfish, Berserk, Obsidian) all use it. For Cassandra it is the
**only path past 2700 Elo** without going full Leela-style MCTS.

---

## Things deliberately *not* on the roadmap

- **MCTS / PUCT.** Different engine. Not building one.
- **Endgame tablebases.** A correct EGTB integration is +50 Elo at the
  cost of ~100 GB of static data and Bobby-side TB-probing primitives.
  Worth doing eventually; not before stage 6.
- **Distributed search.** Single-machine bot. Lazy-SMP would be the right
  parallelism model when we have it; not before NPS is ~order-of-magnitude
  higher.
- **Variants** (Chess960, Atomic, …). Standard chess only.
