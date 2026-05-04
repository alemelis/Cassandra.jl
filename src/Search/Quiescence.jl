const QS_MAX_PLY = 8

function _qs_order!(moves::Vector{Bobby.Move})
    scores = map(m -> _capture_score(m), moves)
    perm = sortperm(scores; rev=true)
    return moves[perm]
end

function qsearch(board::Bobby.Board, alpha::Float32, beta::Float32,
                 deadline::Float64, ply::Int)::Float32
    time() > deadline && return ABORT_SCORE
    stand = leaf_eval(board)
    stand >= beta && return beta
    stand > alpha && (alpha = stand)
    ply >= QS_MAX_PLY && return alpha

    legal = Bobby.getMoves(board, board.active)
    in_check = Bobby.inCheck(board, board.active)
    if isempty(legal.moves)
        return in_check ? -MATE_SCORE : 0f0
    end
    board.halfmove >= 100 && return 0f0

    moves = in_check ? legal.moves : filter(_is_tactical, legal.moves)
    isempty(moves) && return alpha

    moves = _qs_order!(moves)
    for m in moves
        if !in_check
            gain = _CAPTURE_VALS[Int(m.take.type) + 1]
            if m.promotion != Bobby.PIECE_NONE
                gain = max(gain, _CAPTURE_VALS[Int(m.promotion) + 1])
            end
            (stand + gain / 900f0 + 0.05f0) <= alpha && continue
        end
        child = Bobby.makeMove(board, m)
        score = -qsearch(child, -beta, -alpha, deadline, ply + 1)
        time() > deadline && return ABORT_SCORE
        score >= beta && return beta
        score > alpha && (alpha = score)
    end
    return alpha
end