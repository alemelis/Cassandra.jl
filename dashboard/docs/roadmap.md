# Roadmap

Where Cassandra is heading, in a single page. Source of truth for "what
should I work on next?".

Cassandra is a **classical** engine. Neural networks are out of scope.

---

## The 2500-Elo path

Today the engine is bottlenecked by Bobby's move generator — every other
gain compounds with deeper search, and deeper search compounds with NPS.

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

## Stretch — past 2500

- **Texel-tuned eval coefficients.** Gradient descent on Stockfish-labelled
  positions to retune PSQT and structural bonuses. +30–80 Elo without any
  algorithmic change.
- **Lazy-SMP** when single-thread NPS plateaus. Multiple parallel search
  threads sharing the TT. +50–80 Elo per thread doubling, with diminishing
  returns past 4–8 threads.
- **Endgame tablebases (Syzygy).** A correct EGTB integration is +50 Elo at
  the cost of ~100 GB of static data and Bobby-side TB-probing primitives.

---

## Things deliberately *not* on the roadmap

- **Neural networks of any kind.** Not building one. The whole point of the
  classical line is to push it as far as it goes.
- **MCTS / PUCT.** Different engine. Not building one.
- **Distributed search.** Single-machine bot.
- **Variants** (Chess960, Atomic, …). Standard chess only.
