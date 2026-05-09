# Classical tapered evaluation using PeSTO piece-square tables.
# All values in centipawns. Returns score from side-to-move perspective.
#
# Square mapping from Bobby bit index:
#   tz = trailing_zeros(sq_bit)
#   white PSQT index (Julia 1-based): 64 - tz      (CPW layout: a8=1, h1=64)
#   black PSQT index (Julia 1-based): (tz ⊻ 7) + 1  (rank-mirrored)

# ── Piece values ────────────────────────────────────────────────────────────
const PVAL_MG = (82, 337, 365, 477, 1025, 0)   # P N B R Q K
const PVAL_EG = (94, 281, 297, 512,  936, 0)

# ── PeSTO PSQT tables (CPW layout: index 1=a8 … 64=h1) ─────────────────────
# Each table: 64 Int16 values, reading rank 8→1, file a→h.

const _PSQT_P_MG = Int16[
   0,   0,   0,   0,   0,   0,   0,   0,
  98, 134,  61,  95,  68, 126,  34, -11,
  -6,   7,  26,  31,  65,  56,  25, -20,
 -14,  13,   6,  21,  23,  12,  17, -23,
 -27,  -2,  -5,  12,  17,   6,  10, -25,
 -26,  -4,  -4, -10,   3,   3,  33, -12,
 -35,  -1, -20, -23, -15,  24,  38, -22,
   0,   0,   0,   0,   0,   0,   0,   0,
]

const _PSQT_P_EG = Int16[
   0,   0,   0,   0,   0,   0,   0,   0,
 178, 173, 158, 134, 147, 132, 165, 187,
  94, 100,  85,  67,  56,  53,  82,  84,
  32,  24,  13,   5,  -2,   4,  17,  17,
  13,   9,  -3,  -7,  -7,  -8,   3,  -1,
   4,   7,  -6,   1,   0,  -5,  -1,  -8,
  13,   8,   8,  10,  13,   0,   2,  -7,
   0,   0,   0,   0,   0,   0,   0,   0,
]

const _PSQT_N_MG = Int16[
 -167, -89, -34, -49,  61, -97, -15, -107,
  -73, -41,  72,  36,  23,  62,   7,  -17,
  -47,  60,  37,  65,  84, 129,  73,   44,
   -9,  17,  19,  53,  37,  69,  18,   22,
  -13,   4,  16,  13,  28,  19,  21,   -8,
  -23,  -9,  12,  10,  19,  17,  25,  -16,
  -29, -53, -12,  -3,  -1,  18, -14,  -19,
 -105, -21, -58, -33, -17, -28, -19,  -23,
]

const _PSQT_N_EG = Int16[
 -58, -38, -13, -28, -31, -27, -63, -99,
 -25,  -8, -25,  -2,  -9, -25, -24, -52,
 -24, -20,  10,   9,  -1,  -9, -19, -41,
 -17,   3,  22,  22,  22,  11,   8, -18,
 -18,  -6,  16,  25,  16,  17,   4, -18,
 -23,  -3,  -1,  15,  10,  -3, -20, -22,
 -42, -20, -10,  -5,  -2, -20, -23, -44,
 -29, -51, -23, -15, -22, -18, -50, -64,
]

const _PSQT_B_MG = Int16[
 -29,   4, -82, -37, -25, -42,   7,  -8,
 -26,  16, -18, -13,  30,  59,  18, -47,
 -16,  37,  43,  40,  35,  50,  37,  -2,
  -4,   5,  19,  50,  37,  37,   7,  -2,
  -6,  13,  13,  26,  34,  12,  10,   4,
   0,  15,  15,  15,  14,  27,  18,  10,
   4,  15,  16,   0,   7,  21,  33,   1,
 -33,  -3, -14, -21, -13, -12, -39, -21,
]

const _PSQT_B_EG = Int16[
 -14, -21, -11,  -8,  -7,  -9, -17, -24,
  -8,  -4,   7, -12,  -3, -13,  -4, -14,
   2,  -8,   0,  -1,  -2,   6,   0,   4,
  -3,   9,  12,   9,  14,  10,   3,   2,
  -6,   3,  13,  19,   7,  10,  -3,  -9,
 -12,  -3,   8,  10,  13,   3,  -7, -15,
 -14, -18,  -7,  -1,   4,  -9, -15, -27,
 -23,  -9, -23,  -5,  -9, -16,  -5, -17,
]

const _PSQT_R_MG = Int16[
  32,  42,  32,  51,  63,   9,  31,  43,
  27,  32,  58,  62,  80,  67,  26,  44,
  -5,  19,  26,  36,  17,  45,  61,  16,
 -24, -11,   7,  26,  24,  35,  -8, -20,
 -36, -26, -12,  -1,   9,  -7,   6, -23,
 -45, -25, -16, -17,   3,   0,  -5, -33,
 -44, -16, -20,  -9,  -1,  11,  -6, -71,
 -19, -13,   1,  17,  16,   7, -37, -26,
]

const _PSQT_R_EG = Int16[
  13,  10,  18,  15,  12,  12,   8,   5,
  11,  13,  13,  11,  -3,   3,   8,   3,
   7,   7,   7,   5,   4,  -3,  -5,  -3,
   4,   3,  13,   1,   2,   1,  -1,   2,
   3,   5,   8,   4,  -5,  -6,  -8, -11,
  -4,   0,  -5,  -1,  -7, -12,  -8, -16,
  -6,  -6,   0,   2,  -9,  -9, -11,  -3,
  -9,   2,   3,  -1,  -5, -13,   4, -20,
]

const _PSQT_Q_MG = Int16[
 -28,   0,  29,  12,  59,  44,  43,  45,
 -24, -39,  -5,   1, -16,  57,  28,  54,
 -13, -17,   7,   8,  29,  56,  47,  57,
 -27, -27, -16, -16,  -1,  17,  -2,   1,
  -9, -26,  -9, -10,  -2,  -4,   3,  -3,
 -14,   2, -11,  -2,  -5,   2,  14,   5,
 -35,  -8,  11,   2,   8,  15,  -3,   1,
  -1, -18,  -9,  10, -15, -25, -31, -50,
]

const _PSQT_Q_EG = Int16[
  -9,  22,  22,  27,  27,  19,  10,  20,
 -17,  20,  32,  41,  58,  25,  30,   0,
 -20,   6,   9,  49,  47,  35,  19,   9,
   3,  22,  24,  45,  57,  40,  57,  36,
 -18,  28,  19,  47,  31,  34,  39,  23,
 -16, -27,  15,   6,   9,  17,  10,   5,
 -22, -23, -30, -16, -16, -23, -36, -32,
 -33, -28, -22, -43,  -5, -32, -20, -41,
]

const _PSQT_K_MG = Int16[
 -65,  23,  16, -15, -56, -34,   2,  13,
  29,  -1, -20,  -7,  -8,  -4, -38, -29,
  -9,  24,   2, -16, -20,   6,  22, -22,
 -17, -20, -12, -27, -30, -25, -14, -36,
 -49,  -1, -27, -39, -46, -44, -33, -51,
 -14, -14, -22, -46, -44, -30, -15, -27,
   1,   7,  -8, -64, -43, -16,   9,   8,
 -15,  36,  12, -54,   8, -28,  24,  14,
]

const _PSQT_K_EG = Int16[
 -74, -35, -18, -18, -11,  15,   4, -17,
 -12,  17,  14,  17,  17,  38,  23,  11,
  10,  17,  23,  15,  20,  45,  44,  13,
  -8,  22,  24,  27,  26,  33,  26,   3,
 -18,  -4,  21,  24,  27,  23,   9, -11,
 -19,  -3,  11,  21,  23,  16,   7,  -9,
 -27, -11,   4,  13,  14,   4,  -5, -17,
 -53, -34, -21, -11, -28, -14, -24, -43,
]

# Indexed by Bobby piece type (1=P,2=N,3=B,4=R,5=Q,6=K)
const _MG_TABLES = (_PSQT_P_MG, _PSQT_N_MG, _PSQT_B_MG, _PSQT_R_MG, _PSQT_Q_MG, _PSQT_K_MG)
const _EG_TABLES = (_PSQT_P_EG, _PSQT_N_EG, _PSQT_B_EG, _PSQT_R_EG, _PSQT_Q_EG, _PSQT_K_EG)

# File masks (a=1 through h=8, in Bobby bit layout)
# In Bobby: file h bits have tz%8==0, file a bits have tz%8==7
const _FILE_MASKS = ntuple(f -> begin
    # f=1 means a-file (tz&7 == 7-f+1 = 8-f), f=8 means h-file (tz&7==0)
    bobby_f = 8 - f   # tz & 7 for this file
    mask = UInt64(0)
    for rank in 0:7
        mask |= UInt64(1) << (rank * 8 + bobby_f)
    end
    mask
end, 8)

# ── Phase for tapering ──────────────────────────────────────────────────────
# N=1, B=1, R=2, Q=4; max = 4+4+8+8 = 24
@inline function _game_phase(w::Bobby.ChessSet, b::Bobby.ChessSet)::Int
    p = count_ones(w.N) + count_ones(b.N) +
        count_ones(w.B) + count_ones(b.B) +
        2 * (count_ones(w.R) + count_ones(b.R)) +
        4 * (count_ones(w.Q) + count_ones(b.Q))
    min(p, 24)
end

# ── Per-side PSQT score ─────────────────────────────────────────────────────
@inline function _side_score(cs::Bobby.ChessSet, is_white::Bool)
    mg = 0; eg = 0
    for pt in 1:6
        bb = (pt == 1 ? cs.P : pt == 2 ? cs.N : pt == 3 ? cs.B :
              pt == 4 ? cs.R : pt == 5 ? cs.Q : cs.K)
        bb == UInt64(0) && continue
        tbl_mg = _MG_TABLES[pt]; tbl_eg = _EG_TABLES[pt]
        val_mg = PVAL_MG[pt];    val_eg = PVAL_EG[pt]
        b = bb
        while b != UInt64(0)
            tz = Int(trailing_zeros(b))
            b &= b - UInt64(1)   # popbit
            idx = is_white ? (64 - tz) : ((tz ⊻ 7) + 1)
            mg += val_mg + tbl_mg[idx]
            eg += val_eg + tbl_eg[idx]
        end
    end
    return mg, eg
end

# ── Structural bonuses ──────────────────────────────────────────────────────
@inline function _structural(white::Bobby.ChessSet, black::Bobby.ChessSet,
                             cfg_bishop_pair::Int, cfg_rook_open::Int, cfg_rook_semi::Int)::Int
    bonus = 0

    # Bishop pair
    count_ones(white.B) >= 2 && (bonus += cfg_bishop_pair)
    count_ones(black.B) >= 2 && (bonus -= cfg_bishop_pair)

    all_pawns = white.P | black.P

    # Rook on open/semi-open file
    wrooks = white.R; brooks = black.R
    for f in 1:8
        fmask = _FILE_MASKS[f]
        has_wpawn = (white.P & fmask) != UInt64(0)
        has_bpawn = (black.P & fmask) != UInt64(0)
        if (wrooks & fmask) != UInt64(0)
            if !has_wpawn && !has_bpawn
                bonus += cfg_rook_open
            elseif !has_wpawn
                bonus += cfg_rook_semi
            end
        end
        if (brooks & fmask) != UInt64(0)
            if !has_wpawn && !has_bpawn
                bonus -= cfg_rook_open
            elseif !has_bpawn
                bonus -= cfg_rook_semi
            end
        end
    end

    return bonus
end

# ── Public entry point ───────────────────────────────────────────────────────
function classical_eval(board::Bobby.Board,
                        bishop_pair_cp::Int=40,
                        rook_open_cp::Int=25,
                        rook_semi_cp::Int=12)::Float32
    w = board.white; bk = board.black
    phase = _game_phase(w, bk)

    wmg, weg = _side_score(w, true)
    bmg, beg = _side_score(bk, false)

    mg_score = wmg - bmg
    eg_score = weg - beg

    # taper: phase=24 → full MG, phase=0 → full EG
    tapered = (mg_score * phase + eg_score * (24 - phase)) ÷ 24

    structural = _structural(w, bk, bishop_pair_cp, rook_open_cp, rook_semi_cp)

    raw = tapered + structural

    # Return from side-to-move perspective
    return Float32(board.active ? raw : -raw)
end
