# Engine Documentation

Simple but accurate reference for Cassandra's internals. Key for anyone continuing development.

---

## Overview

Cassandra is a **learning chess engine** written in Julia. It plays on Lichess as `cassandra-jl` and relies on [Bobby.jl](https://github.com/anomalyco/Bobby.jl) for move generation and board representation.

The engine is neural-network-driven: a single dual-headed NN provides both move selection (policy) and position evaluation (value). Training starts with puzzle imitation (supervised), with self-play (reinforcement) planned for later stages.

---

## Matchmaking

Cassandra runs as a Lichess bot and finds games through two mechanisms:

### Open Challenges
The bot posts open challenges that any bot can accept. It maintains up to `BOT_MAX_OPENS` (default 4) pending open challenges at a time.

### Targeted Challenges
With probability `BOT_TARGETED_P` (default 0.25), the bot sends a targeted challenge to a specific opponent. Eligible opponents are filtered by:

- **Rating range**: Within ±400 ELO of Cassandra's current rating (`_eligible()` in `bot/main.jl:332-353`)
- **Rate limiting**: Exponential backoff if a bot returns HTTP 429 (`bot/main.jl:40-79`)

### Arena / Tournament Auto-Join
The bot automatically joins Lichess arenas that match these criteria (`bot/main.jl:446-455`):

- Name contains "bot" (case-insensitive)
- Variant is "standard"
- Clock limit between 30–900 seconds

It polls for new tournaments every 120 seconds (`arena_loop()`, `bot/main.jl:474-497`).

### Time Control Rotation
The bot cycles through time controls (`bot/main.jl:81-88`):

```
(60, 0), (60, 0), (120, 1), (120, 1)
# two 1-minute games, two 2-minute increment games
```

### Configuration

| Variable | Default | File |
|----------|---------|------|
| `BOT_MAX_GAMES` | 2 | `docker-compose.yml:31` |
| `BOT_MAX_OPENS` | 4 | `docker-compose.yml:30` |
| `BOT_TARGETED_P` | 0.25 | `docker-compose.yml:29` |
| `BOT_CONTROL_PORT` | 8080 | `docker-compose.yml:28` |

---

## Training

### Neural Network Architecture

Cassandra uses a **dual-headed neural network** defined in `src/Model/CassandraModel.jl`.

#### Input Representation
Each board position is encoded as a flat `Float32` vector of **773 features**:

| Slice | Size | Description |
|-------|------|-------------|
| Piece planes | 768 | 12 piece types × 64 squares (one-hot) |
| Side to move | 1 | `1.0` = white, `0.0` = black |
| Castling rights | 4 | KQkq flags |

Pieces are ordered `[P, N, B, R, Q, K, p, n, b, r, q, k]`. Square indexing is rank-major (a1 = 0 … h8 = 63).

#### Network Structure

```
Input (773)
  → Dense(773 → 256, relu)
  → Dense(256 → 128, relu)        ← shared trunk
  → Value head: Dense(128 → 32, relu) → Dense(32 → 1, tanh)   → v ∈ [-1, +1]
  → Policy head: Dense(128 → 1924, identity)                    → logits over UCI moves
```

- **Value head**: Predicts expected outcome from the side-to-move's perspective (+1 = win, -1 = loss, 0 = draw)
- **Policy head**: Outputs logits over **1924** possible UCI moves (derived from Lichess puzzle corpus)
- **Total parameters**: ~300K with default architecture

#### Why This Design?

| Choice | Reason |
|--------|--------|
| Flat input, no CNN | Board is small (8×8); simpler to iterate on |
| Shared trunk | Value and policy share positional understanding; fewer parameters |
| tanh value output | Natural [-1, +1] range matches alpha-beta score convention |
| 1924 policy outputs | Fixed index derived from puzzle corpus; avoids dynamic per-position output sizing |

---

### Training Stages

#### Stage 1 — Puzzle Imitation (Current)

**Data source**: [Lichess puzzle database](https://database.lichess.org/#puzzles) (~4M tactics, each with a known best continuation).

**Pipeline** (`src/Training/Imitation.jl`):
1. `prepare_puzzles(csv, bin)` — reads raw CSV, applies the first puzzle move to reach the *response position*, converts board to 773-feature input tensor
2. Stores `(tensor, value_target, policy_index)` records in a compact binary file
3. `train_epoch!(model, opt, dataset)` — streams binary file in random mini-batches

**Loss function**:
```
L = value_weight · MSE(value, target_value) + policy_weight · CE(policy_logits, target_move)
```

- Policy target: the known best reply (one-hot cross-entropy)
- Value target: `0.0` for puzzle positions (outcome unknown at the response ply)
- Typical weights: `policy_weight=1.0`, `value_weight=0.0` in Stage 1 (focus on policy)

**Why puzzles first?** Puzzle positions are densely informative — every record has a definitively correct move, which bootstraps the policy head quickly. Cold-starting from random play would require orders of magnitude more games.

#### Stage 2 — Self-Play (Planned)

**Implementation**: `src/Training/SelfPlay.jl`

Planned flow:
1. `play_game(model_a, model_b)` — plays a complete game using 1-ply policy-greedy move selection (`policy_best_move()`)
2. Value targets set to `+1 / -1 / 0` based on game outcome
3. Policy targets come from the move actually played
4. Mix self-play records with puzzle records to avoid catastrophic forgetting

**Arena evaluation**: After each epoch, `evaluate(model_new, model_old, n)` plays `n` games and accepts the new model only if win rate ≥ 55% (configurable via `WIN_THRESHOLD`).

---

### Training Configuration

Set via environment variables in `scripts/train.jl`:

| Variable | Default | Meaning |
|----------|---------|---------|
| `EPOCHS` | 20 | Training epochs per run |
| `BATCH_SIZE` | 512 | Records per mini-batch |
| `LR` | 3e-4 | Adam learning rate |
| `LR_MIN` | 3e-6 | Cosine decay floor |
| `WEIGHT_DECAY` | 1e-4 | AdamW weight decay |
| `VALUE_WEIGHT` | 0.0 | Value head loss weight |
| `POLICY_WEIGHT` | 1.0 | Policy head loss weight |
| `EVAL_GAMES` | 0 | Arena games after training (0 = skip) |
| `TRUNK_SIZES` | "256,128" | Network architecture |
| `DROPOUT` | 0.1 | Dropout rate |
| `BASE_MODEL` | "" | Pre-trained model to continue training |

**Optimizer**: AdamW with cosine learning rate decay.

**Checkpointing**: Saves to `checkpoints/latest.jld2` after each epoch.

---

## Search

### Algorithm: Negamax Alpha-Beta with Iterative Deepening

Implementation: `src/Search/AlphaBeta.jl`

#### Core Search (`_negamax()`, lines 14-74)
- Standard negamax formulation with alpha-beta pruning
- **Transposition table**: Probes at entry (`tt_probe()`, line 23), stores results at exit (line 71)
- **Leaf evaluation**: Falls back to `value_eval()` when depth ≤ 0 (line 33-34)
- **Move ordering**: Uses neural network policy logits to score moves (line 37-38)
- **Pruning**: `alpha ≥ beta && break` at line 62

#### Iterative Deepening (`search()`, lines 76-120)
- Default time limit: **3 seconds** per move (`AB_TIME_LIMIT = 3.0`, line 1)
- Hard deadline: `deadline = time() + time_limit` (line 84)
- Loops `for depth in 1:max_depth` (line 92)
- Reorders moves based on previous iteration results (lines 114-116)
- Configurable max depth via `set_max_depth!()` (default 3 plies, `MAX_DEPTH` Ref at lines 5-8)

#### Entry Point
`select_move(model, board)` (lines 122-126) — called by the bot to choose a move.

---

### Move Ordering

Implementation: `src/Search/MoveOrder.jl`

`order_moves!()` scores moves using `_move_priority()`:
- **TT best move**: +100,000
- **Captures**: +10,000 + capture_value × 10 − moving_piece_value
- **Neural network policy logits**: Higher logit = higher priority

Moves are sorted in descending score order.

---

### Transposition Table

Implementation: `src/Search/TT.jl`

- **Size**: 1M entries
- **Entry fields**: `hash`, `depth`, `score`, `flag` (exact/lower/upper bound), `best_idx`
- **Constants**: `INF_SCORE = 200,000`, `MATE_SCORE = 100,000`
- `tt_probe()`: Returns stored score if valid and deep enough
- `tt_store!()`: Stores new entries, keeps deeper results

---

### Time Management

- **Hard deadline**: Set at search start (`deadline = time() + time_limit`)
- **Checks**: At search entry (line 19), after each child search (lines 53-56), and during iterative deepening (lines 93, 104, 112)
- **Abort sentinel**: `ABORT_SCORE = 0.0f0` returned when time expires

---

## Evaluation

### Primary: Neural Network Evaluation

Implementation: `src/Eval/NNEval.jl`

`value_eval(model, board)`:
- Calls `forward(model, board, buf)` to get the value head output
- Returns a scalar in `[-1, +1]` from the side-to-move's perspective
- Used at alpha-beta leaf nodes instead of classical material evaluation

`policy_info(model, board)`:
- Returns value, policy entropy, and top-5 moves with probabilities
- Uses softmax over legal move logits

---

## Known Issues & Todo

| Issue | Location | Status |
|-------|----------|--------|
| No null-move pruning | `src/Search/AlphaBeta.jl` | Not implemented (could help with tactics) |
| No futility pruning | `src/Search/AlphaBeta.jl` | Not implemented |
| No razoring | `src/Search/AlphaBeta.jl` | Not implemented |

---

## File Reference

| Component | File | Key Lines |
|-----------|------|-----------|
| Main module | `src/Cassandra.jl` | Entry point |
| Negamax Alpha-Beta | `src/Search/AlphaBeta.jl` | 14-74, 76-120 |
| Move ordering | `src/Search/MoveOrder.jl` | 1-27 |
| Transposition table | `src/Search/TT.jl` | 1-41 |
| NN model | `src/Model/CassandraModel.jl` | 1-112 |
| Move index (1924) | `src/Model/MoveIndex.jl` | 1-47 |
| NN evaluation | `src/Eval/NNEval.jl` | 1-35 |
| Material eval | `src/Board.jl` | 3-16 |
| Training loop | `src/Training/Trainer.jl` | 19-86 |
| Puzzle data | `src/Training/Imitation.jl` | 14-77 |
| Self-play | `src/Training/SelfPlay.jl` | 16-54 |
| Data pipeline | `src/Training/DataPipeline.jl` | Binary I/O |
| Training script | `scripts/train.jl` | Full config |
| Lichess bot | `bot/main.jl` | 330-497 |
| Dashboard | `dashboard/index.html` | Full SPA |
| Dashboard API | `dashboard/server.py` | REST endpoints |
