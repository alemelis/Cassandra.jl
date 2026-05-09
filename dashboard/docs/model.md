# Neural model

Cassandra carries a small dual-headed neural network: one **value** head
(scalar in `[-1, 1]`, position evaluation), one **policy** head (logits
over 1924 UCI moves, move prior). It is currently used **only as an
optional move-ordering hint** in search; the value head is trained but
not yet consulted at leaves.

Code: `src/Model/CassandraModel.jl`, `src/Model/MoveIndex.jl`.

---

## Why a dual head

This is the AlphaZero/Leela design: one trunk learns position
representations, two heads learn the two things you need for a search:

- **Value (v ∈ [-1, 1])** — "who's winning, by how much" — fed into the
  search to break ties at leaves and as a target for self-play.
- **Policy (p over moves)** — "which moves should I look at first" — used as
  a move-ordering prior, the single highest-leverage place to inject prior
  knowledge into alpha-beta.

The trunk is shared for parameter efficiency: the features needed to predict
"who's winning" are largely the same as those needed to predict "what's the
right move".

---

## Two architectures, same interface

### `build_model` — flat MLP (legacy, arch v1)

```
Input (1280 floats = 8×8×20 planes flattened)
  → Dense(1280→256, relu)
  → Dense(256→128, relu)
  ├── Value head:  Dense(128→32, relu) → Dense(32→1, tanh) → scalar
  └── Policy head: Dense(128→1924)
```

~300 K parameters. Retained so older checkpoints still load.

### `build_conv_model` — small ResNet (current, arch v2)

```
Input → reshape (8,8,20,B)
  → Conv 3×3 (20→C, SamePad) → BN → relu          (stem)
  → N × ResBlock(C → C)                            (residual tower)
  ├── Policy head: Conv 1×1 (C→16) → flatten → Dense(1024 → 1924)
  └── Value head:  Conv 1×1 (C→4)  → flatten → Dense(256 → 64, relu)
                                              → Dense(64 → 1, tanh)
```

Defaults: `C = 32`, `N = 2 blocks`. Each ResBlock is two `Conv(3×3) → BN
→ relu` layers with a residual add. The residual structure trains far better
than the MLP at the same parameter budget; conv stems exploit the
translation structure of board patterns (a knight-fork pattern looks the
same wherever it occurs).

The conv model is the recommended default for new training runs.

---

## Input encoding (`Bobby.board_to_tensor!`)

The board is encoded as a `(8, 8, 20)` tensor — 20 planes per square. The
exact plane layout lives in Bobby; conceptually:

- 12 planes for the 6 piece types × 2 colours (one-hot piece presence).
- Castling-rights planes (one per K/Q-side × colour, broadcast across the
  board).
- Side-to-move plane (constant 0 or 1).
- En-passant target plane.

Flattened to a 1280-vector for the MLP, kept as `(8, 8, 20, B)` for the conv
model (the `_InputReshape` layer at the top of the trunk does the swap).

The encoding is symmetric — the network sees positions from white's
perspective. Black-to-move positions are flipped before the forward pass
(handled in `Bobby.board_to_tensor!`).

---

## Move enumeration (1924 logits)

`UCI_MOVES` is the precomputed enumeration of every legal UCI string in any
chess position: 1924 entries covering all `<from><to><promotion?>` triples
that can ever arise. `UCI2IDX` is the reverse map.

This is fixed and shared by training and inference. The policy head's output
shape `(1924,)` is the softmax-pre-output over this list. At inference we
mask illegal moves to `-1e9` before softmax so the legal moves' probabilities
sum to 1.

---

## Forward pass

```julia
forward(model, board) → (value::Float32, logits::Vector{Float32, 1924})
```

Internally builds the input tensor (a fresh buffer, `_fresh_buf()`) and runs
the two heads. There is **no batching** in inference today — every call is
a single position. Inside search this is one forward pass per node when
`ordering.use_policy_logits` is on, which dominates the per-node cost.

**Tuning.**

- The forward call should be **cached on the TT entry** so repeated probes
  pay nothing. Currently it isn't.
- For deeper search you almost certainly want to **batch policy queries**
  across nodes — one of the few places where parallel search interacts
  cleanly with classical alpha-beta.

---

## Persistence

`save_model(path, model; meta)` writes a `.jld2` file containing:

- `arch_version_conv` (or `arch_trunk_sizes` for the MLP) → tells the loader
  which builder to call.
- `arch_n_channels`, `arch_n_blocks` → conv hyperparameters.
- `trunk`, `value_head`, `policy_head` → `Flux.state()` of each.
- `meta` → arbitrary `Dict{String,Any}` (run name, epoch, eval losses,
  dataset description, …).

`load_model(path) → (model, meta)` reconstructs the right architecture,
loads weights, and returns the meta. The bot reads `run_name` and `epoch`
out of the meta to display on the dashboard and in game intros.

---

## What the model is *not* doing yet

- **Leaf evaluation.** The value head is trained but not yet used in search.
  Wiring it in is a single-line change in `_negamax` (replace
  `classical_eval` at depth 0); the question is *when* it pays off Elo-wise.
  Today (untrained or weakly-trained on puzzles) the classical eval is
  better. Once stage 2 (PGN training on strong games) lands, the value head
  should be competitive.
- **Search guidance beyond move ordering.** Full PUCT-style MCTS is a
  separate engine; we are not building that. The plan is to keep alpha-beta
  and use the network as a "policy + value oracle", AlphaBeta-NN style.
- **NNUE.** A specialised, sparse, incremental network designed to run at
  millions of evals/sec. This is the gold standard for classical engines
  with neural eval; not on the immediate roadmap.
