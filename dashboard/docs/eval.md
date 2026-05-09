# Evaluation

Cassandra uses a **classical tapered evaluation** at every leaf. Score is
always reported from the **side-to-move's perspective** in centipawns
(100 cp ≈ one pawn), so negamax can negate when recursing.

Code: `src/Eval/Classical.jl`. Single entry point: `classical_eval(board,
bishop_pair_cp, rook_open_cp, rook_semi_cp)`.

---

## Why classical eval (still)

A small classical eval is:

- **Fast** — hundreds of nanoseconds. The search visits millions of leaves;
  a slow eval hard-caps depth.
- **Differentiable in the dashboard sense** — every term has a knob you can
  reason about and tune by playing matches.
- **Strong enough.** PSQT + tapering + a few structural bonuses already
  reaches ~2200–2400 Elo when paired with a competent search. Stockfish
  played at this level for years before NNUE.

The next eval gains come from **Texel-tuning** the existing PSQT and
structural coefficients on labelled positions, then layering in king safety,
passed pawns, and mobility. See the [Roadmap](roadmap.md).

---

## Material in centipawns

Each piece type has a fixed value used as the baseline for positional scoring:

| Piece  | MG value | EG value |
|--------|----------|----------|
| Pawn   | 82       | 94       |
| Knight | 337      | 281      |
| Bishop | 365      | 297      |
| Rook   | 477      | 512      |
| Queen  | 1025     | 936      |

MG = middlegame, EG = endgame. Pieces are worth less in the endgame when
there are fewer targets to coordinate against — except rooks, which gain
because endgames produce open files.

These values come from the **PeSTO** tuning, which is one of the most heavily
optimised public sets of classical eval coefficients. They are *very good
defaults* and tuning by hand is unlikely to beat them; if you want to go
further, the right move is to swap in **Texel tuning** (gradient descent on
labelled positions) rather than guess.

---

## Piece-Square Tables (PSQT)

Each piece has a 64-entry table (one per square) of MG and EG bonuses. The
mental model: this is "the piece is worth its base value, *plus* a positional
bias for being on this square". Knights in the centre, pawns advancing,
king huddled in MG and central in EG. Black's tables are the white tables
mirrored across rank 4½.

Example (knight MG, rank 8 → rank 1, a → h):

```
-167 -89 -34 -49  61 -97 -15 -107
 -73 -41  72  36  23  62   7  -17
 -47  60  37  65  84 129  73   44
  -9  17  19  53  37  69  18   22
 -13   4  16  13  28  19  21   -8
 -23  -9  12  10  19  17  25  -16
 -29 -53 -12  -3  -1  18 -14  -19
-105 -21 -58 -33 -17 -28 -19  -23
```

PSQT runs in `_side_score` for both colours; the loop over set bits uses the
standard `b &= b - 1` pop-bit idiom to walk pieces.

---

## Tapered evaluation {#tapered-eval}

Using separate MG and EG tables avoids discontinuities at piece exchanges.
A **game phase** is computed from remaining non-pawn material:

```
phase = #N + #B + 2·#R + 4·#Q     (both sides, clamped to [0, 24])
```

Phase 24 = full opening/middlegame. Phase 0 = bare kings (endgame). The
final score is a linear blend:

```
score = (mg_score · phase + eg_score · (24 − phase)) / 24
```

This makes the engine naturally re-evaluate piece worth as the game
simplifies — no special-case rules needed.

---

## Structural bonuses

Three knobs, all in `EvalConfig`:

### Bishop pair {#bishop-pair}

Holding both bishops earns `eval.bishop_pair_cp` (default 40). Two bishops
control squares of both colours and are increasingly powerful in open
positions. The bonus is per side and net-summed.

### Rook on open file {#rook-open-file}

For each file:

- **Open** (no pawns of either colour) — `eval.rook_open_cp` (default 25)
- **Semi-open from white's POV** (no white pawns, has black pawns) —
  `eval.rook_semi_cp` (default 12)

Both apply per rook. Reproduced symmetrically for black.

---

## What's *not* in the eval (yet)

These omissions cost real Elo. In rough order of leverage:

1. **King safety.** Pawn shield in front of the castled king, attacker count
   on king-zone squares, open files near the king. Easily +50 Elo.
2. **Passed pawns.** Bonus that grows by rank (especially 6th/7th); doubled if
   protected. +30 Elo.
3. **Pawn structure.** Penalty for doubled, isolated, backward pawns;
   bonus for connected and phalanx pawns. +20 Elo.
4. **Mobility.** Count of squares each piece attacks. Already implicit in
   PSQT but explicit mobility (especially for bishops and rooks) is +20 Elo.
5. **Knight outposts.** Knights on rank 4–6 supported by a pawn and not
   attackable by an enemy pawn. +10 Elo.

Each fits cleanly into `_structural` or as a new helper. The risk: every term
adds eval cost (and hence reduces NPS). The right way to add them is one at
a time, with a small ablation match per term.

---

## Score perspective

`classical_eval` returns from the **side-to-move's perspective**: positive =
the side currently moving is better. Negamax exploits this directly — every
recursive call negates and the same machinery handles both colours.

The conversion from "white-good" raw to side-to-move:

```julia
return Float32(board.active ? raw : -raw)
```

`board.active` is `true` for white. Mate scores are in `Search/TT.jl`:
`MATE_SCORE = 100_000`, `INF_SCORE = 200_000`, with mate-distance
adjustment so transpositions can reuse mate-in-N entries (see
[Transposition table](transposition-table.md)).
