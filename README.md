# Cassandra.jl

A learning chess engine in Julia. Built on [Bobby.jl](https://github.com/alemelis/Bobby.jl) for move generation; learns to play through puzzles, supervised training on human games, and self-play.

## Current state

- Random-policy bot running on Lichess as **cassandra-jl**
- Dual-headed MLP (value + policy) instantiates, runs forward passes, saves/loads
- Training infrastructure in place: binary dataset I/O, training loop, eval harness
- Move selection goes through the model (softmax over legal moves); untrained = effectively random

## Architecture

```
Input: 8×8×20 tensor → flatten → 1280 floats

Shared trunk:   Dense(1280→256, relu) → Dense(256→128, relu)

Value head:     Dense(128→32, relu) → Dense(32→1, tanh)    → scalar ∈ [-1, 1]
Policy head:    Dense(128→1924)                             → logits over 1924 UCI moves
```

~300K parameters. Trains on CPU.

## Learning roadmap

| Stage | Goal | Status |
|---|---|---|
| 0 | Scaffolding: model, dataset, training loop, eval harness | ✅ done |
| 1 | Puzzle training — policy head learns tactics | 🔄 in progress |
| 2 | Supervised training on human games — value head learns positional sense | |
| 3 | Alpha-beta search with learned eval + move ordering | |
| 4 | Lichess deployment for absolute ELO baseline (~1400–1700 rapid) | partial |
| 5 | Self-play loop — promote when new version wins >55% | |

Recommended order: 0 → 1 → 3 → 4 → 2 → 5.

## Dataset plan

| Dataset | Source | Used in |
|---|---|---|
| Lichess puzzles (~3M) | `database.lichess.org/lichess_db_puzzle.csv.zst` | Stage 1 |
| Lichess games filtered ≥2000 ELO | monthly PGN dumps | Stage 2 |
| Self-play games | generated locally | Stage 5 |

## Stage 1: Puzzle training

### 1. Download the puzzle CSV

```bash
wget https://database.lichess.org/lichess_db_puzzle.csv.zst
zstd -d lichess_db_puzzle.csv.zst
# result: lichess_db_puzzle.csv (~1.6GB, ~3M puzzles)
```

### 2. Build the binary dataset

```julia
using Cassandra
n = Cassandra.prepare_puzzles("lichess_db_puzzle.csv", "data/puzzles.bin")
# ~3M records written; skips puzzles with unknown answer moves
```

Or via the training script (auto-builds if `data/puzzles.bin` doesn't exist):

```bash
julia --project=. scripts/train_puzzles.jl lichess_db_puzzle.csv
```

### 3. Train

```bash
julia --project=. scripts/train_puzzles.jl lichess_db_puzzle.csv

# Override defaults (EPOCHS=20, BATCH_SIZE=256, LR=1e-3):
EPOCHS=50 BATCH_SIZE=512 LR=5e-4 julia --project=. scripts/train_puzzles.jl lichess_db_puzzle.csv data/puzzles.bin checkpoints/
```

Checkpoints are saved to `checkpoints/latest.jld2` after each epoch; final model to `checkpoints/final.jld2`. Training log written to `checkpoints/train_log.jsonl`.

Expected outcome after 20 epochs: policy loss drops from ~7.5 (ln 1924 ≈ random) to ~3–5; trained model wins >70% vs random in the arena.

### 4. Monitor training

```bash
cp checkpoints/train_log.jsonl dashboard/
cd dashboard && python -m http.server 8000
# open localhost:8000
```

The dashboard polls `train_log.jsonl` every 30 seconds and updates live. Shows current epoch, policy loss, time per epoch, dataset size, and a loss curve. Displays a pulsing dot while training is active (last log entry < 5 min old).

## Deploying a checkpoint to Lichess

```bash
# Copy latest checkpoint → deployed.jld2 and write dashboard/deployed.json
julia --project=. scripts/deploy.jl

# Then start the bot pointing at the deployed checkpoint
CASSANDRA_MODEL=checkpoints/deployed.jld2 julia bot/main.jl
```

The bot logs every game result to `dashboard/bot_log.jsonl`. The dashboard reads this file and shows W/L/D stats filtered to the currently deployed epoch, along with a green dashed line on the loss chart marking when that model was deployed.

## Running the bot

```bash
# set token in bot/.env
LICHESS_TOKEN=lip_...

julia bot/main.jl
```

To use a trained model:
```bash
CASSANDRA_MODEL=/path/to/model.jld2 julia bot/main.jl
```

## Project layout

```
src/
  Model/
    MoveIndex.jl        # 1924 UCI move enumeration and index
    CassandraModel.jl   # Flux model, build/save/load, forward pass
  Search/
    AlphaBeta.jl        # FEN/move utilities; alpha-beta search (Stage 3)
    MoveOrder.jl        # move ordering (Stage 3)
    TT.jl               # transposition table (Stage 3)
  Eval/
    Classical.jl        # hand-crafted eval (stub)
    NNEval.jl           # NN eval integration (stub)
  Training/
    DataPipeline.jl     # flat-binary dataset reader/writer
    Trainer.jl          # train_epoch! with MSE + cross-entropy loss
    SelfPlay.jl         # play_game, evaluate harness
    Imitation.jl        # puzzle/game-record data loading (Stage 1–2)
bot/
  main.jl               # Lichess bot
```
