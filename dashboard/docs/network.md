# Network Architecture

Cassandra uses a single **dual-headed neural network** that drives both move selection and position evaluation.

## Input representation

Each board position is encoded as a flat `Float32` vector of **`773` features**:

| Slice | Size | Description |
|-------|------|-------------|
| Piece planes | 768 | 12 piece types × 64 squares (one-hot) |
| Side to move | 1 | `1.0` = white, `0.0` = black |
| Castling rights | 4 | KQkq flags |
| Total | **773** | |

Pieces are ordered `[P, N, B, R, Q, K, p, n, b, r, q, k]`. Square indexing is rank-major (a1 = 0 … h8 = 63).

## Trunk

A shallow fully-connected trunk converts the flat input to a shared latent representation:

```
Input (773) → Dense(773→256, relu) → Dense(256→256, relu)
```

Both heads branch from this 256-dimensional embedding.

## Value head

Predicts the expected outcome from the perspective of the side to move:

```
Dense(256→1, tanh)   →  v ∈ [-1, +1]
```

- `+1` = current side wins
- `-1` = current side loses
- `0`  = draw

The value head is used at **alpha-beta leaf nodes** to replace classical material evaluation.

## Policy head

Predicts a distribution over all legal moves from the current position:

```
Dense(256→1924, identity)   →  raw logits over UCI move index
```

- **1924** is the total number of distinct UCI moves seen in Lichess puzzle data.
- At inference, logits are masked to legal moves only, then softmax is applied.
- The policy head is used for **move ordering** inside alpha-beta (high-logit moves searched first) and for **1-ply greedy play** during self-play data generation.

## Why this design

| Choice | Reason |
|--------|--------|
| Flat input, no CNN | Board is small (8×8); translation equivariance matters less than in image tasks; simpler to iterate on |
| Shared trunk | Value and policy share positional understanding; fewer parameters than two separate networks |
| tanh value output | Natural [-1,+1] range matches alpha-beta score convention |
| 1924 policy outputs | Fixed index derived from puzzle corpus; avoids dynamic per-position output sizing |
