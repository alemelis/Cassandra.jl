function handcrafted_eval(board::Bobby.Board)::Float32
    in_check = Bobby.inCheck(board, board.active)
    in_check && return -0.95f0
    pieces = board.white.P + board.white.N + board.white.B +
             board.white.R + board.white.Q + board.white.K +
             board.black.P + board.black.N + board.black.B +
             board.black.R + board.black.Q + board.black.K
    pieces == 1 && return 0f0
    return material_eval(board)
end