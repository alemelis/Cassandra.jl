const START_FEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

# Material evaluation from the perspective of the side to move, normalised to
# [-1, 1] by the maximum imbalance (queen + 2 rooks = 19 pawns).
const _MAT_NORM = 19f0
function material_eval(board::Bobby.Board)::Float32
    # board.active: true = white to move, false = black to move
    active  = board.active ? board.white : board.black
    passive = board.active ? board.black : board.white
    score = (count_ones(active.P)  - count_ones(passive.P))  * 1 +
            (count_ones(active.N)  - count_ones(passive.N))  * 3 +
            (count_ones(active.B)  - count_ones(passive.B))  * 3 +
            (count_ones(active.R)  - count_ones(passive.R))  * 5 +
            (count_ones(active.Q)  - count_ones(passive.Q))  * 9
    return clamp(Float32(score) / _MAT_NORM, -1f0, 1f0)
end

function apply_moves(moves_str::AbstractString, fen::AbstractString=START_FEN)::Bobby.Board
    board = Bobby.loadFen(fen)
    ms = strip(moves_str)
    isempty(ms) && return board
    for uci in split(ms)
        m = Bobby.uciMoveToMove(board, String(uci))
        board = Bobby.makeMove(board, m)
    end
    return board
end
