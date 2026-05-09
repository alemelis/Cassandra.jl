const START_FEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

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
