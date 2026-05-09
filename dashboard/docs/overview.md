# Cassandra — Overview

Cassandra is a classical chess engine written in Julia. It is built around a
small set of deliberately-chosen ideas; this wiki explains each of them in
enough depth that you can understand the implementation, tune it, and know
where to look for the next gain.

---

## What's in the binary

Cassandra is a single classical engine: hand-crafted PeSTO evaluation at the
leaves, alpha-beta search with the standard pruning toolbox, killers/history
move ordering, transposition table, and an opening book.

| Component | What it does | Cost / node |
|---|---|---|
| Leaf score (`classical_eval`) | PeSTO PSQT + tapered material + structural bonuses | hundreds of ns |
| Move ordering (`order_moves!`) | TT move → MVV-LVA → promotions → killers → history | tens of ns |
| Transposition table | Single-bucket, depth-preferring, mate-distance corrected | tens of ns |
| Search | Iterative deepening + α/β + qsearch + null-move + LMR + aspiration | the wrapper |
| Book | Zobrist-keyed weighted move table, hot-reloaded from JSON | one hash lookup |

Every term has a knob in `EngineConfig` and a row in
`ENGINE_CONFIG_SCHEMA`. The dashboard editor is auto-generated from the
schema — adding a tunable means adding a struct field plus a schema row.

---

## Pipeline at a glance

```
                                        ┌────────────────────────┐
                                        │ setups/*.json          │
                                        │ (named EngineConfigs)  │
                                        └────────────┬───────────┘
                                                     │ deploy
                                                     ▼
                                        ┌────────────────────────┐
                                        │ setups/deployed.json   │ ← single
                                        │ (active EngineConfig)  │   source
                                        └────────────┬───────────┘   of truth
                                                     │
              ┌──────────────────────────┬───────────┴──────────┐
              ▼                          ▼                      ▼
       ┌────────────────┐         ┌────────────────┐    ┌────────────────┐
       │ bot/main.jl    │         │ bot/uci.jl     │    │ arena/match.py │
       │ Lichess stream │         │ stdin/stdout   │    │ vs Stockfish   │
       └────────────────┘         └────────────────┘    └────────────────┘
              │                          │                      │
              └──────────────┬───────────┴──────────┬───────────┘
                             ▼                      ▼
                    Cassandra.select_move(board)   logs/*.jsonl
                       Book → search →
                         classical_eval
```

Every component is exposed in the dashboard:

- **Bot** tab — live game state, recent results, deployed setup
- **Arena** tab — local matches vs Stockfish at fixed strength (Docker)
- **Setups** tab — edit and deploy `EngineConfig` (search/eval/ordering/book)
- **Book** tab — opening book entries (FEN hash → weighted UCI moves)
- **Docs** tab — this wiki

---

## What "playing strength" comes from

For a classical engine, strength ≈ **`eval quality × log(nodes searched)`**.
Of the two factors, search depth dominates: doubling nodes/sec is worth
roughly +50 Elo; large eval improvements are worth +10–80 Elo. That's why
the wiki spends most of its pages on search and move ordering — they are
the tightest levers.

The 2500-Elo target is reachable with the existing algorithm set (negamax
+ α/β + qsearch + null-move + LMR + TT + iterative deepening), but only if
Cassandra can sustain ~1 M nodes/sec through the bot's time control. Today
the binding constraint is Bobby's move generator — see the **Bobby
bottlenecks** note in the project README for the speedup roadmap.

---

## Glossary

- **Ply** — one half-move (one side moves).
- **Node** — one position visited by the search.
- **NPS** — nodes per second.
- **PV** (principal variation) — the best line found so far.
- **TT** — transposition table; cache from position hash → score.
- **Zobrist** — a 64-bit hash where each piece-on-square contributes a random
  bitstring; XOR-update on every move.
- **Centipawn** (cp) — 1/100 of a pawn; the unit of evaluation.
- **MG / EG** — middlegame / endgame; used in tapered evaluation.
- **MVV-LVA** — Most Valuable Victim / Least Valuable Attacker, a capture-ordering rule.
- **Quiescence** — a depth-extending search that only considers tactical moves.
- **Cutoff** (β-cutoff) — the moment α/β proves a branch is irrelevant.

---

## Where to read next

1. [Search](search.md) — the heart of the engine.
2. [Move ordering](move-ordering.md) — the single biggest pruning amplifier.
3. [Evaluation](eval.md) — what the leaves return.
4. [Transposition table](transposition-table.md) — cache and replacement.
5. [Opening book](book.md) — the lookup that runs before any search.
6. [Setups](setups.md) — packaging knobs into deployable configs.
7. [Bot](bot.md) and [Dashboard](dashboard.md) — operations.
8. [Roadmap](roadmap.md) — what's next, and why.
