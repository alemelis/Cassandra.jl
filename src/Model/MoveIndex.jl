function _build_uci_move_index()
    moves = Set{String}()

    sq(f, r) = string(Char(Int('a') + f - 1)) * string(r)

    for fr in 1:8, ff in 1:8
        from = sq(ff, fr)
        for tr in 1:8, tf in 1:8
            (fr == tr && ff == tf) && continue
            dr, df = tr - fr, tf - ff

            is_rook   = dr == 0 || df == 0
            is_bishop = abs(dr) == abs(df)
            is_knight = (abs(dr) == 1 && abs(df) == 2) || (abs(dr) == 2 && abs(df) == 1)
            is_king   = abs(dr) <= 1 && abs(df) <= 1

            # white pawn: 1 or 2 forward, diagonal captures
            is_wpawn = (df == 0 && dr == 1) ||
                       (df == 0 && dr == 2 && fr == 2) ||
                       (abs(df) == 1 && dr == 1)
            # black pawn: same but downward
            is_bpawn = (df == 0 && dr == -1) ||
                       (df == 0 && dr == -2 && fr == 7) ||
                       (abs(df) == 1 && dr == -1)

            if is_rook || is_bishop || is_knight || is_king || is_wpawn || is_bpawn
                to = sq(tf, tr)
                # promotions: white pawn to rank 8, black pawn to rank 1
                if (is_wpawn && fr == 7 && tr == 8) || (is_bpawn && fr == 2 && tr == 1)
                    for p in ('q', 'r', 'b', 'n')
                        push!(moves, from * to * p)
                    end
                else
                    push!(moves, from * to)
                end
            end
        end
    end

    # castling king moves are already covered by is_king (e1g1, e1c1, e8g8, e8c8)
    sorted = sort!(collect(moves))
    idx = Dict{String,Int}(m => i for (i, m) in enumerate(sorted))
    return sorted, idx
end

const UCI_MOVES, UCI2IDX = _build_uci_move_index()
const N_MOVES = length(UCI_MOVES)
