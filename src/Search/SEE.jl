# Static Exchange Evaluator.
#
# Computes the signed material balance of a sequential capture exchange on
# a single square, assuming both sides recapture with their least-valuable
# attacker until one side has nothing left. Used to prune obviously losing
# captures in qsearch and (optionally) demote them in move ordering.
#
# Builds on Bobby's PEXT slider attack tables and the static
# KNIGHT / KING / PAWN_X_{WHITE,BLACK} arrays exposed via the `Bobby.*`
# private-internal access pattern that the rest of the search already uses.

# Centipawn material values, indexed by Bobby piece type (1..6). PIECE_NONE
# (0) returns 0 — used to terminate the exchange loop cleanly.
const _SEE_VALS = (0, 100, 320, 330, 500, 900, 20_000)

# Reusable exchange-stack buffer. SEE is invoked serially (single-threaded
# search), so a module-level scratch keeps the function allocation-free.
const _SEE_GAIN_BUF = Vector{Int}(undef, 32)

# All attackers of `sq` (single-bit bitboard) given `occupancy`. Returns a
# bitboard of every white + black piece that attacks the square. Pawn
# attacks use Bobby's pre-computed PAWN_X tables (idx is the *target*
# square; the table gives the squares a pawn of that colour would have to
# stand on to capture there).
@inline function _attackers_to(white::Bobby.ChessSet, black::Bobby.ChessSet,
                               sq::UInt64, sq_idx::Int, occupancy::UInt64)::UInt64
    a = UInt64(0)

    # Pawns
    a |= Bobby.PAWN_X_WHITE[sq_idx] & white.P
    a |= Bobby.PAWN_X_BLACK[sq_idx] & black.P

    # Knights, kings
    a |= Bobby.KNIGHT[sq_idx] & (white.N | black.N)
    a |= Bobby.KING[sq_idx]   & (white.K | black.K)

    # Sliders — restrict to live pieces by ANDing with occupancy at the end
    rooks_queens   = white.R | white.Q | black.R | black.Q
    bishops_queens = white.B | white.Q | black.B | black.Q

    a |= Bobby.getSliderAttack(sq, occupancy, true)  & rooks_queens
    a |= Bobby.getSliderAttack(sq, occupancy, false) & bishops_queens

    return a & occupancy
end

# Returns (bb, piece_type) of the least valuable attacker for `side` from
# the `attackers` mask. piece_type is PIECE_NONE (0) when no attacker exists.
@inline function _least_valuable_attacker(white::Bobby.ChessSet, black::Bobby.ChessSet,
                                          attackers::UInt64, side_white::Bool)::Tuple{UInt64,UInt8}
    cs = side_white ? white : black
    for (bb, pt) in ((cs.P, Bobby.PIECE_PAWN),
                     (cs.N, Bobby.PIECE_KNIGHT),
                     (cs.B, Bobby.PIECE_BISHOP),
                     (cs.R, Bobby.PIECE_ROOK),
                     (cs.Q, Bobby.PIECE_QUEEN),
                     (cs.K, Bobby.PIECE_KING))
        cand = attackers & bb
        cand != UInt64(0) && return (cand & (-cand), pt)   # isolate LSB
    end
    return (UInt64(0), Bobby.PIECE_NONE)
end

"""
    see(board, move) -> Int

Static exchange evaluation of `move` on `board`. Positive = side-to-move
wins material on the exchange, 0 = even, negative = loses material. Does
not consider promotions or en-passant (treats them as plain captures —
SEE's job is filtering hopeless captures, not exact scoring).
"""
function see(board::Bobby.Board, move::Bobby.Move)::Int
    # Non-capture: nothing to evaluate (SEE only used to gate captures).
    move.take.type == 0 && return 0

    target     = move.to
    target_idx = Bobby.sq2idx(target)
    from       = move.from

    white = board.white
    black = board.black

    occupancy = board.taken & ~from         # lift the moving piece off
    attackers = _attackers_to(white, black, target, target_idx, occupancy)
    attackers &= ~from                       # we already moved this piece

    # gain[d] = side-to-move material balance after d half-moves of the
    # exchange. Depth is bounded by the total number of attackers (≤16);
    # we reuse a module-level scratch buffer to keep SEE allocation-free.
    gain = _SEE_GAIN_BUF

    gain[1]    = _SEE_VALS[Int(move.take.type) + 1]
    cur_piece  = move.type                   # piece now sitting on target
    side_white = !board.active               # opposite of the side that just captured
    d          = 1

    while true
        # After the previous half-move, captures and slider moves can have
        # uncovered an x-ray attacker. Re-scan sliders against the current
        # occupancy and merge in any newly-exposed attackers.
        rq = white.R | white.Q | black.R | black.Q
        bq = white.B | white.Q | black.B | black.Q
        attackers |= Bobby.getSliderAttack(target, occupancy, true)  & rq
        attackers |= Bobby.getSliderAttack(target, occupancy, false) & bq
        attackers &= occupancy

        lva_bb, lva_pt = _least_valuable_attacker(white, black, attackers, side_white)
        lva_pt == Bobby.PIECE_NONE && break

        d += 1
        gain[d] = _SEE_VALS[Int(cur_piece) + 1] - gain[d-1]

        # Pruning: if the side-to-move cannot do better than the running
        # negamax minimum, stop early.
        if max(-gain[d-1], gain[d]) < 0
            break
        end

        attackers &= ~lva_bb
        occupancy &= ~lva_bb
        cur_piece  = lva_pt
        side_white = !side_white

        # King-capture safeguard: if a king made the capture and the
        # opposite side still has attackers, the king walks into check —
        # the exchange must terminate here (king cannot legally be retaken,
        # so the swap ends at d).
        if lva_pt == Bobby.PIECE_KING
            opp_cs = side_white ? white : black
            opp_pieces = opp_cs.P | opp_cs.N | opp_cs.B |
                         opp_cs.R | opp_cs.Q | opp_cs.K
            if attackers & opp_pieces != UInt64(0)
                # We can't actually capture the king, so back out this half-move.
                d -= 1
            end
            break
        end
    end

    # Negamax-fold the gain stack to compute the root score.
    while d > 1
        gain[d-1] = -max(-gain[d-1], gain[d])
        d -= 1
    end
    return gain[1]
end
