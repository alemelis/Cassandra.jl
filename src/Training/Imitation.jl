"""
    prepare_puzzles(csv_path, output_path; max_puzzles=typemax(Int)) → Int

Reads the Lichess puzzle CSV and writes a binary dataset file.
Returns the number of records written.

Each puzzle contributes one record per move in its solution sequence:
- Our moves  (even indices in the solution): value = +1.0 (winning position)
- Their moves (odd indices in the solution): value = -1.0 (losing position)

Skips puzzles where any move fails to parse or isn't in UCI2IDX.
`max_puzzles` limits the number of puzzles processed (not records written).
"""
function prepare_puzzles(csv_path::AbstractString,
                         output_path::AbstractString;
                         max_puzzles::Int=typemax(Int))::Int
    writer  = DatasetWriter(output_path)
    buf     = Array{Float32,3}(undef, 8, 8, Bobby.N_PLANES)
    skipped = 0
    n_puzzles = 0

    open(csv_path) do io
        readline(io)  # skip header
        for line in eachline(io)
            n_puzzles >= max_puzzles && break

            fields = split(line, ',')
            length(fields) < 4 && (skipped += 1; continue)

            fen       = String(fields[2])
            moves_str = String(fields[3])
            uci_list  = split(moves_str)
            length(uci_list) < 2 && (skipped += 1; continue)

            board = try Bobby.loadFen(fen) catch; skipped += 1; continue end

            # Apply the setup move (opponent's last move that creates the puzzle).
            setup = try Bobby.uciMoveToMove(board, String(uci_list[1])) catch; skipped += 1; continue end
            board = Bobby.makeMove(board, setup)

            # Walk the solution sequence. uci_list[2] is our first move (+1),
            # uci_list[3] is their forced reply (-1), uci_list[4] our next (+1), …
            ok = true
            for (i, uci) in enumerate(uci_list[2:end])
                value      = isodd(i) ? 1f0 : -1f0   # our moves = +1, their moves = -1
                policy_idx = get(UCI2IDX, String(uci), 0)
                if policy_idx == 0
                    ok = false; break
                end

                legal     = Bobby.getMoves(board, board.active)
                legal_idxs = Int[]
                for m in legal.moves
                    idx = get(UCI2IDX, Bobby.moveToUCI(m), 0)
                    idx != 0 && push!(legal_idxs, idx)
                end
                if !(policy_idx in legal_idxs)
                    ok = false; break
                end

                legal_mask = build_legal_mask(legal_idxs)
                tensor     = board_to_input!(buf, board)
                write_record!(writer, tensor, value, policy_idx, legal_mask)

                move  = try Bobby.uciMoveToMove(board, String(uci)) catch; ok = false; break end
                board = Bobby.makeMove(board, move)
            end

            ok ? (n_puzzles += 1) : (skipped += 1)
        end
    end

    close_dataset(writer)
    n = writer.count
    @info "prepare_puzzles done" puzzles=n_puzzles records=n skipped=skipped path=output_path
    return n
end
