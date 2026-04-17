const START_FEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

function apply_uci_move(board::Bobby.Board, uci::AbstractString)::Bobby.Board
    m = Bobby.uciMoveToMove(board, String(uci))
    return Bobby.makeMove(board, m)
end

function apply_moves(moves_str::AbstractString, fen::AbstractString=START_FEN)::Bobby.Board
    board = Bobby.loadFen(fen)
    ms = strip(moves_str)
    isempty(ms) && return board
    for uci in split(ms)
        board = apply_uci_move(board, String(uci))
    end
    return board
end

function select_move(board::Bobby.Board)::Union{String,Nothing}
    legal = Bobby.getMoves(board, board.active)
    isempty(legal.moves) && return nothing
    return Bobby.moveToUCI(rand(legal.moves))
end
