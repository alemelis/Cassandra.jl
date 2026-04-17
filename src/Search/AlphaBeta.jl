const START_FEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

function apply_uci_move(board::Bobby.Board, uci::AbstractString)::Bobby.Board
    src = uci[1:2]
    dst = uci[3:4]
    prm = length(uci) == 5 ? uci[5] : ""
    legal = Bobby.filterMoves(board, Bobby.getMoves(board, board.active))
    for m in legal.moves
        Bobby.UINT2PGN[m.from] == src || continue
        Bobby.UINT2PGN[m.to] == dst || continue
        ok = (prm == 'q' && m.promotion == Bobby.PIECE_QUEEN)   ||
             (prm == 'r' && m.promotion == Bobby.PIECE_ROOK)    ||
             (prm == 'b' && m.promotion == Bobby.PIECE_BISHOP)  ||
             (prm == 'n' && m.promotion == Bobby.PIECE_KNIGHT)  ||
             (prm == ""  && m.promotion == Bobby.PIECE_NONE)
        ok && return Bobby.makeMove(board, m)
    end
    error("Illegal move: $uci")
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
    legal = Bobby.filterMoves(board, Bobby.getMoves(board, board.active))
    isempty(legal.moves) && return nothing
    m = rand(legal.moves)
    uci = Bobby.UINT2PGN[m.from] * Bobby.UINT2PGN[m.to]
    if m.promotion != Bobby.PIECE_NONE
        promo = Dict(Bobby.PIECE_QUEEN=>'q', Bobby.PIECE_ROOK=>'r',
                     Bobby.PIECE_BISHOP=>'b', Bobby.PIECE_KNIGHT=>'n')
        uci *= string(promo[m.promotion])
    end
    return uci
end
