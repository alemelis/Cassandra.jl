# Cassandra.jl

A classical chess engine in Julia, built on [Bobby.jl](https://github.com/alemelis/Bobby.jl)
for move generation. Hand-crafted PeSTO evaluation, alpha-beta search with
the standard pruning toolbox, transposition table, opening book.

No neural networks. No training. The point is to push the classical line as
far as it goes — target 2500+ Elo on Lichess.

## What's in here

```
src/
  Cassandra.jl         single entry point: include order = dependency order
  Board.jl             apply_moves, START_FEN
  Config.jl            EngineConfig + JSON schema (single source for knobs)
  Eval/Classical.jl    PeSTO tapered eval + structural bonuses
  Search/
    TT.jl              transposition table
    MoveOrder.jl       MVV-LVA + killers + history
    AlphaBeta.jl       iterative deepening, qsearch, null-move, LMR
  Book.jl              Zobrist-keyed weighted opening book

bot/
  main.jl              Lichess bot + matchmaker + HTTP control server
  uci.jl               stdin/stdout UCI driver (used by arena/match.py)

dashboard/             static UI + small Python proxy server
arena/                 Cassandra-vs-Stockfish runner (Docker)

setups/                named EngineConfig files; deployed.json is live
logs/                  bot game log, traces, arena results
book/                  active book (book.json) + curated seed
```

## Run it

```bash
# bot (needs LICHESS_TOKEN in .env)
julia --project=. bot/main.jl

# UCI driver (for GUIs / arena)
julia --project=. bot/uci.jl

# arena vs Stockfish (Docker only)
docker compose --profile arena run --rm arena

# dashboard
docker compose up dashboard
# → http://localhost:8000
```

The bot reads engine knobs from `setups/deployed.json` at startup and on
every `/reload`. Edit / clone / deploy from the **Setups** tab in the
dashboard. See [`dashboard/docs/setups.md`](dashboard/docs/setups.md).

## Tests

```bash
julia --project=. -e 'using Pkg; Pkg.test()'
```

## Benchmark

```bash
julia --project=benchmark --check-bounds=no -O3 benchmark/search_bench.jl
```
