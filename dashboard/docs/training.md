# Training

Cassandra trains its dual-headed network from labelled positions. The pipeline
is intentionally minimal — flat-binary records on disk, a streaming reader,
and one Flux training loop with two losses.

Code: `src/Training/{DataPipeline,Imitation,PGNData,Trainer,SelfPlay}.jl`,
runner at `scripts/train.jl`.

---

## The data pipeline

A *record* is a single (position, value, policy-target, legal-mask, weight).
Records are packed back-to-back in a `.bin` file with a small header
(`DatasetWriter` / `DatasetReader`). One epoch = one full pass.

| Field | Type | What |
|-------|------|------|
| tensor | `Float32 × 1280` | Flattened `(8,8,20)` board planes |
| value | `Float32` | Target in `[-1, 1]` from side-to-move's perspective |
| policy_idx | `Int32` | Index into the 1924-move table; the move to imitate |
| legal_mask | `Float32 × 1924` | 0 for legal moves, `-1e9` for illegal — added to logits before softmax |
| weight | `Float32` | Per-record loss weight in `[0, 1]` |

Why flat binary: it streams from disk at full I/O bandwidth and is trivially
shardable. No serialisation overhead.

---

## Two data sources

### Lichess puzzles → `prepare_puzzles`

Each puzzle is a tactic with a known forcing solution. We walk the solution:

- **Our moves** (the puzzle's intended best move at each turn) → `value = +1`,
  policy target = the move.
- **Opponent's forced replies** → `value = -1`, policy target = the move.

The first move of the solution is the *setup* (the move that creates the
puzzle); we apply it before recording anything. Skipped if any move fails to
parse, the position is illegal, or the policy index isn't in `UCI2IDX`.

Each record's weight uses a sigmoid centred on rating 1200, multiplied by a
popularity factor:

```
rating_w = sigmoid((rating − 1200) / 400)
pop_w    = clamp((popularity + 100) / 200, 0.05, 1)
weight   = clamp(rating_w · pop_w, 0.02, 1)
```

So a 2200-rated, popular puzzle counts ~10× more than a 600-rated, unpopular
one. Prevents trivial puzzles from dominating the gradient.

### Lichess PGN games → `prepare_pgn`

For each game (filtered to ≥ some Elo), we walk the move list and record one
position-per-move. Value target = the eventual game outcome from the
side-to-move's perspective (`+1` if they won, `-1` if they lost, `0` if
draw). Policy target = the move actually played.

Trades: less precise per-record (game outcome ≠ position eval) but vastly
more data (~10 M positions per monthly dump). Best used as the **value-head
training signal** — the policy loss benefits less since human players are
noisy.

---

## The training loop

`train_epoch!(model, opt_state, dataset_path; ...)` does one pass:

```julia
for (tensors, values, policy_idxs, legal_mask, weights) in batch_iterator(...)
    targets = onehotbatch(policy_idxs, 1:1924)

    value_preds, logits = model(tensors)

    # Weighted MSE for value head
    per_lv = (vec(value_preds) .- values).^2
    lv = sum(weights .* per_lv) / sum(weights)

    # Mask illegal moves before softmax, then weighted CE
    masked_logits = logits .+ legal_mask
    per_lp = -sum(targets .* logsoftmax(masked_logits; dims=1); dims=1)
    lp = sum(weights .* per_lp) / sum(weights)

    total = value_weight*lv + policy_weight*lp
    update!(opt_state, model, gradient(total))
end
```

Two losses, summed:

- **Value MSE.** Squared error between the predicted scalar and the target
  in `[-1, 1]`.
- **Policy cross-entropy.** Standard CE over the 1924-move softmax. Illegal
  moves are masked to `-1e9` *before* softmax so the gradient only competes
  among legal candidates — this prevents the network from wasting capacity
  on never-legal moves.

Both losses are **sample-weighted** by the per-record weight; the
denominator is the batch's total weight (not its size), so a batch full of
low-confidence puzzles contributes proportionally less.

---

## Multi-dataset mixing

The second `train_epoch!` overload takes `(dataset_paths, mixing_weights)`
and samples each batch from one dataset by probability. Useful for blending
puzzles + PGN games during a single run:

```julia
train_epoch!(model, opt_state,
    ["data/puzzles.bin", "data/elite_pgn.bin"],
    [0.4, 0.6])  # 40% puzzles, 60% PGN
```

The total batch count for the epoch is the weighted average of dataset
sizes. Each batch is randomly sampled (`random_batch`, not the streaming
iterator), which means with replacement — fine for large datasets, but if
you mix one tiny dataset in, expect heavy duplication of those records.

---

## Checkpoint and log format

After each epoch:

- `checkpoints/<name>.jld2` — model state + arch metadata + `meta` dict
  (run name, epoch, losses, dataset paths).
- One JSON line appended to `<log_path>` (`checkpoints/train_log.jsonl`):
  `{ts, epoch, n_batches, seconds, loss_value, loss_policy, loss_total,
   batch_size, n_records}`.

The dashboard polls `train_log.jsonl` to draw the live loss curve.

---

## Run script (`scripts/train.jl`)

The standard entry point. Reads env vars (`EPOCHS`, `BATCH_SIZE`, `LR`,
dataset paths) and orchestrates:

1. (Re)build the dataset binaries if missing.
2. Build a fresh model (or resume from a checkpoint).
3. Pick a random run name (`silent_lasker`, `tactical_morphy`, …).
4. Loop `train_epoch!` for the configured number of epochs.
5. Write the final checkpoint and append to the log.

---

## What's missing

- **Validation split.** Currently we report training loss only. A held-out
  set (a few thousand puzzles never seen during training) would catch
  overfitting and let us early-stop. Easy fix.
- **Lr schedule.** Constant LR throughout. Cosine or step decay generally
  buys a fraction of a percent on policy accuracy at the same compute cost.
- **Self-play data generation.** `SelfPlay.jl` exists but isn't wired into
  the loop. The plan: every N epochs, play 1000 self-play games at
  short TC, label positions with the search's TT-derived value, append to
  a self-play dataset, and mix at low weight (`0.1`).
- **GPU.** Currently CPU-only via `Flux.cpu_device()`. The conv model is
  small enough that GPU only matters above ~64 channels.
