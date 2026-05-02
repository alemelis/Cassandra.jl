# Training Strategy

Cassandra is trained in two stages: supervised imitation from puzzles, followed by self-play reinforcement.

## Stage 1 — Puzzle imitation

**Data source**: [Lichess puzzle database](https://database.lichess.org/#puzzles) (~4 M tactics puzzles, each with a known best continuation).

**Pipeline**:

1. `prepare_puzzles(csv, bin)` — reads the raw CSV, applies the first puzzle move to reach the *response position*, converts the board to the 773-feature input tensor, and stores `(tensor, value=0, policy_idx)` records in a compact binary file.
2. `train_epoch!(model, opt, dataset)` — streams the binary file in random mini-batches, computes a combined loss, and updates weights with Adam.

**Loss function**:

```
L = α · CE(policy_logits, target_move) + (1 - α) · MSE(value, target_value)
```

- Policy target: the known best reply (one-hot cross-entropy).
- Value target: `0.0` for all puzzle positions (outcome unknown at the response ply).
- `α = 0.9` weights policy learning more heavily in Stage 1, since value supervision is weak.

**Why puzzles first?**  
Puzzle positions are densely informative: every record has a definitively correct move, which bootstraps the policy head quickly. Cold-starting from random play would require orders of magnitude more games to reach the same move-ordering quality.

## Stage 2 — Self-play (roadmap)

Self-play uses the current model to generate full games, then trains on the outcomes.

**Planned flow**:

1. `play_game(model_a, model_b)` — plays one game, records `(board, move, result)` triples.
2. Value targets are set to `+1 / -1 / 0` depending on game outcome.
3. Policy targets come from the move actually played (or MCTS visit counts in a future version).
4. Mix self-play records with puzzle records to avoid catastrophic forgetting of tactical patterns.

**Arena evaluation**: after each self-play epoch, `evaluate(model_new, model_old, n)` plays `n` games and accepts the new model only if it wins ≥ 55 % (configurable via `WIN_THRESHOLD`).

## Hyperparameters

| Variable | Default | Meaning |
|----------|---------|---------|
| `EPOCHS` | `50` | training epochs per run |
| `BATCH_SIZE` | `2048` | records per mini-batch |
| `LR` | `1e-3` | Adam learning rate |
| `EVAL_GAMES` | `0` | arena games after training (0 = skip) |
| `WIN_THRESHOLD` | `0.55` | acceptance threshold for arena eval |

## Deployment workflow

1. Training saves a checkpoint as `checkpoints/<run_name>.jld2` at the end of each run.
2. The dashboard **Deploy** panel lists available checkpoints; select one and click *Deploy*.
3. `deployed.jld2` is updated and `deployed.json` records the model name + epoch.
4. The bot receives a `POST /reload` signal and swaps the model in-memory after its current game finishes — no restart needed.
